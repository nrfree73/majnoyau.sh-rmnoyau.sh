#!/bin/bash
# ==============================================================================
# Mise à jour automatisée du Noyau Linux (Ubuntu Mainline)
# Auteur original : RISTOVSKI Nicolas (2016-11)
# Mise à jour & Refonte : 2026-11 (HTTPS, Grille, Anti-Cache, GPG/SHA256)
# ==============================================================================

clear

# ==============================================================================
# 1. GESTION DU DOSSIER TEMPORAIRE ET NETTOYAGE AUTOMATIQUE
# ==============================================================================
TEMP_DIR=$(mktemp -d /tmp/kernel_update_XXXXXX)

cleanup() {
    # Restaure l'affichage du curseur et l'état normal du terminal
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null

    if [ -d "$TEMP_DIR/.gnupg" ]; then
        GNUPGHOME="$TEMP_DIR/.gnupg" gpgconf --kill all >/dev/null 2>&1
    fi
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Déclenche cleanup() uniquement à la sortie réelle du script
trap cleanup EXIT

# Force l'arrêt immédiat du script lors d'un CTRL+C (ce qui déclenchera EXIT)
trap 'echo ""; echo -e " \033[1;33mInterruption par l'\''utilisateur (CTRL+C). Nettoyage...\033[0m"; exit 130' INT TERM

# ==============================================================================
# 2. VÉRIFICATION DU RÉSEAU ET DES DÉPENDANCES
# ==============================================================================
echo -n "Vérification de la connexion internet... "
if command -v curl >/dev/null 2>&1; then
    network_ok=$(curl -sI --connect-timeout 5 https://kernel.ubuntu.com/mainline/ >/dev/null 2>&1 && echo "1" || echo "0")
else
    gw=$(ip r | awk '/default/ {print $3; exit}')
    network_ok=$([ -n "$gw" ] && ping -q -w 2 -c 1 "$gw" >/dev/null 2>&1 && echo "1" || echo "0")
fi

if [ "$network_ok" == "0" ]; then
    echo -e "\033[1;31mÉCHEC\033[0m"
    echo "Pas de réseau internet ! Mise à jour du noyau impossible... [Entrée] pour quitter."
    read -r
    exit 1
fi
echo -e "\033[1;32mOK\033[0m"

# Installation des outils requis (lynx, wget, gnupg, curl)
MISSING_PKGS=()
command -v lynx >/dev/null 2>&1 || MISSING_PKGS+=("lynx")
command -v wget >/dev/null 2>&1 || MISSING_PKGS+=("wget")
command -v gpg  >/dev/null 2>&1 || MISSING_PKGS+=("gnupg")
command -v curl >/dev/null 2>&1 || MISSING_PKGS+=("curl")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installation des dépendances manquantes : ${MISSING_PKGS[*]}..."
    sudo apt-get update -qq && sudo apt-get install -y "${MISSING_PKGS[@]}"
    for pkg in "${MISSING_PKGS[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1 && [ "$pkg" != "gnupg" ]; then
            echo "Échec de l'installation du paquet '$pkg' ! [Entrée] pour quitter..."
            read -r
            exit 1
        fi
    done
fi

# ==============================================================================
# 3. DÉTECTION DE L'ARCHITECTURE MATÉRIELLE
# ==============================================================================
if command -v dpkg >/dev/null 2>&1; then
    arch=$(dpkg --print-architecture)
else
    case "$(uname -m)" in
        x86_64)              arch="amd64" ;;
        i386|i486|i586|i686) arch="i386" ;;
        aarch64|arm64)       arch="arm64" ;;
        armv7l|armv8l|armhf) arch="armhf" ;;
        ppc64le)             arch="ppc64el" ;;
        s390x)               arch="s390x" ;;
        riscv64)             arch="riscv64" ;;
        *)                   arch="$(uname -m)" ;;
    esac
fi

echo -e "\tArchitecture détectée : \033[1;33m$arch\033[0m"
echo ""

# ==============================================================================
# 4. RÉCUPÉRATION EN TEMPS RÉEL ET PAGINATION EN GRILLE (HTTPS + ANTI-CACHE)
# ==============================================================================
BASE_URL="https://kernel.ubuntu.com/mainline/"
echo "Récupération et vérification en temps réel des versions depuis Ubuntu Mainline..."
echo -e "\033[0;33mNote : Les versions de test (Release Candidates / RC) sont exclues de la liste.\033[0m"

raw_html=$(curl -sL -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "${BASE_URL}?nocache=$(date +%s)" 2>/dev/null)

mapfile -t all_versions < <(
    echo "$raw_html" \
    | grep -oE 'href="v[0-9]+\.[0-9]+[^"]*/"' \
    | sed -E 's/href="//; s/"$//' \
    | grep -v "rc" \
    | sed 's|/$||' \
    | sort -uV \
    | sed "s|^|${BASE_URL}|; s|$|/|"
)

total_versions=${#all_versions[@]}
if [ "$total_versions" -eq 0 ]; then
    echo -e "\033[1;31mErreur : Impossible de récupérer la liste des noyaux depuis $BASE_URL.\033[0m"
    exit 1
fi

# Vérification en temps réel des 5 derniers dossiers (élimine les dossiers vides ou en échec)
check_count=5
[ "$total_versions" -lt "$check_count" ] && check_count=$total_versions

for ((i = total_versions - 1; i >= total_versions - check_count; i--)); do
    test_url="${all_versions[$i]}"
    page_root=$(curl -sL -H "Cache-Control: no-cache" "$test_url" 2>/dev/null)
    page_arch=$(curl -sL -H "Cache-Control: no-cache" "${test_url}${arch}/" 2>/dev/null)
    if ! printf "%s\n%s\n" "$page_root" "$page_arch" | grep -qE "_(${arch}|all)\.deb"; then
        unset 'all_versions[i]'
    fi
done

# Réindexation propre du tableau après suppression des dossiers vides
all_versions=("${all_versions[@]}")
total_versions=${#all_versions[@]}

page_size=60
page_step=1
max_pages=$(( (total_versions + page_size - 1) / page_size ))

load_kernel_page() {
    local start_idx=$(( total_versions - (page_step * page_size) ))
    local count=$page_size
    if [ $start_idx -lt 0 ]; then
        count=$(( page_size + start_idx ))
        start_idx=0
    fi
    versions_list=( "${all_versions[@]:$start_idx:$count}" )
    num_options=${#versions_list[@]}
    cols=5
    rows=$(( (num_options + cols - 1) / cols ))
}

clear
tput civis 2>/dev/null
load_kernel_page
active_index=$(( num_options - 1 ))

# Fonction utilitaire pour centrer une ligne de texte selon sa longueur réelle
print_centered() {
    local text="$1"
    local plain_text
    plain_text=$(echo -e "$text" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 120)
    local pad=$(( (term_cols - ${#plain_text}) / 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "%*s%b\n" "$pad" "" "$text"
}

print_header() {
    print_centered "\033[1;36m[ Mise à jour automatisée du Noyau Linux ]\033[0m"
    print_centered "\033[0;37m... RISTOVSKI Nicolas (2016-11) ...\033[0m"
    print_centered "\033[0;37mupdate: (2026-11)\033[0m"
    echo ""
    print_centered "\033[1;37mArchitecture détectée : \033[1;33m${arch}\033[0m   |   \033[0;37m(Noyaux RC non listés)\033[0m"
    echo ""
}

display_menu() {
    local r c idx
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 120)
    
    # La grille fait 5 colonnes de 21 caractères = 105 caractères de large
    local grid_width=$(( cols * 21 ))
    local left_margin=$(( (term_cols - grid_width) / 2 ))
    [ $left_margin -lt 0 ] && left_margin=0

    # Replace le curseur tout en haut à gauche sans clignotement
    tput cup 0 0
    
    # Affiche l'en-tête centré et en couleur
    print_header
    
    for ((r=0; r<rows; r++)); do
        echo -ne "\033[K"
        printf "%*s" "$left_margin" ""
        for ((c=0; c<cols; c++)); do
            idx=$(( r + c * rows ))
            if [ $idx -lt $num_options ]; then
                local ver_name
                ver_name=$(basename "${versions_list[$idx]}")
                if [ $idx -eq $active_index ]; then
                    printf "\033[1;37;44m > %-16s\033[0m  " "$ver_name"
                else
                    printf "   %-16s  " "$ver_name"
                fi
            fi
        done
        echo ""
    done

    echo ""
    local real_page=$(( max_pages - page_step + 1 ))
    echo -ne "\033[K"
    print_centered "\033[1;36m--- Page $real_page/$max_pages | [Flèches]: Naviguer | [-]: Précédent | [+]: Suivant | [Entrée]: Valider ---\033[0m"
    
    # Efface uniquement ce qui reste en dessous
    echo -ne "\033[J"
}

while true; do
    display_menu
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 key
        if [[ $key == "[A" ]]; then
            ((active_index--))
            [ $active_index -lt 0 ] && active_index=$((num_options - 1))
        elif [[ $key == "[B" ]]; then
            ((active_index++))
            [ $active_index -ge $num_options ] && active_index=0
        elif [[ $key == "[D" ]]; then
            [ $active_index -ge $rows ] && active_index=$(( active_index - rows ))
        elif [[ $key == "[C" ]]; then
            [ $(( active_index + rows )) -lt $num_options ] && active_index=$(( active_index + rows ))
        fi
    elif [[ $key == "-" ]]; then
        if [ $page_step -lt $max_pages ]; then
            ((page_step++))
            load_kernel_page
            active_index=0
        fi
    elif [[ $key == "+" ]]; then
        if [ $page_step -gt 1 ]; then
            ((page_step--))
            load_kernel_page
            active_index=0
        fi
    elif [[ $key == "" ]]; then
        break
    fi
done

tput cnorm 2>/dev/null

# ==============================================================================
# 5. SÉLECTION DE LA VARIANTE (GENERIC / LOWLATENCY)
# ==============================================================================
clear
echo ""
kernelURL="${versions_list[$active_index]}"
site=$(basename "$kernelURL")
site2="${site#v}"

echo -e " \033[1m   Version sélectionnée pour installation : \033[1;32m$site\033[0m ($kernelURL)"
echo -e " \033[1;36m   Version du noyau actuellement chargée  : $(uname -r)\033[0m"
echo ""
echo -e " \033[1;32m   Noyaux actuellement installés dans /boot :\033[0m"
ls /boot 2>/dev/null | grep initrd | cut -d- -f2,3,4 | sed 's/^/\t/'
echo ""

prompt_msg=$(printf "\033[3m\tSouhaitez-vous installer la variante 'lowlatency' (y/n) ? \033[0m")
echo -ne "$prompt_msg"

while true; do
    read -rsn1 key
    case "$key" in
        [yY]) low=1; choix="lowlatency"; echo "y"; break ;;
        [nN]) low=0; choix="generic";    echo "n"; break ;;
    esac
done
echo ""

# ==============================================================================
# 6. RECHERCHE DES PAQUETS ET VÉRIFICATION DE DISPONIBILITÉ
# ==============================================================================
echo -e "    \033[1;4;36m--- Recherche des paquets distants sur le serveur ---\033[0m"

root_links=$(lynx -dump -listonly -nonumbers "${kernelURL}" 2>/dev/null)

if echo "$root_links" | grep -qE "_${arch}\.deb$"; then
    mapfile -t liste_debs < <(echo "$root_links" | grep -E "\.deb$")
    pkg_base_url="${kernelURL}"
else
    mapfile -t liste_debs < <(
        lynx -dump -listonly -nonumbers "${kernelURL}${arch}/" 2>/dev/null | grep -E "\.deb$"
        echo "$root_links" | grep -E "_all\.deb$"
    )
    pkg_base_url="${kernelURL}${arch}/"
fi

if [ ${#liste_debs[@]} -eq 0 ]; then
    echo -e "\t\033[1;31mErreur : Aucun paquet .deb trouvé pour l'architecture '$arch'.\033[0m"
    exit 1
fi

if [ "$choix" == "lowlatency" ] && ! printf "%s\n" "${liste_debs[@]}" | grep -q "lowlatency"; then
    echo -e "\t\033[1;31m⚠️  Note : Pas de paquets 'lowlatency' disponibles pour v.${site2}.\033[0m"
    echo -e "\t\033[1;31m   Bascule automatique sur la variante 'generic'...\033[0m"
    echo ""
    choix="generic"
    low=0
fi

# Vérification si cette version et variante exactes sont déjà installées
if ls /boot/initrd.img-"${site2}"*-"${choix}" >/dev/null 2>&1; then
    echo ""
    echo -e " \033[1;31m   [ABANDON] Le noyau Linux $site ($choix) est déjà installé sur votre système !\033[0m"
    exit 0
fi

# Filtrage de la révision la plus récente et des paquets cibles
latest_revision=$(printf "%s\n" "${liste_debs[@]}" | grep "$choix" | grep -oE "[0-9]{8,12}" | sort -V | tail -1)
[ -z "$latest_revision" ] && latest_revision=$(printf "%s\n" "${liste_debs[@]}" | grep -oE "[0-9]{8,12}" | sort -V | tail -1)

if [ -z "$latest_revision" ]; then
    mapfile -t target_urls < <(
        printf "%s\n" "${liste_debs[@]}" | sort -u \
        | grep -E "(_all\.deb|_${arch}\.deb)$" \
        | grep -E "(linux-headers-.*_all\.deb|${choix})"
    )
else
    mapfile -t target_urls < <(
        printf "%s\n" "${liste_debs[@]}" | sort -u \
        | grep -E "(_all\.deb|_${arch}\.deb)$" \
        | grep "$latest_revision" \
        | grep -E "(linux-headers-.*_all\.deb|${choix})"
    )
fi

if [ ${#target_urls[@]} -eq 0 ]; then
    echo -e "\t\033[1;31mErreur : Impossible d'identifier les paquets à télécharger.\033[0m"
    exit 1
fi

echo -e " \033[1;3;32m   Noyau prêt pour téléchargement : $site ($choix)\033[0m"
for url in "${target_urls[@]}"; do
    echo -e "\t\033[1;3;36m-> $(basename "$url")\033[0m"
done
echo -e "    \033[4;36m______________________________________________________________\033[0m"
echo ""

echo -e "\t\033[1;4;92m  [Entrée] pour lancer le téléchargement et la vérification GPG !\033[0m"
echo -e "\t\033[1;31m  Ou [CTRL]-[C] pour annuler et quitter...\033[0m"

while true; do
    read -rsn1 key
    [[ "$key" == "" ]] && break
done

# ==============================================================================
# 7. TÉLÉCHARGEMENT ET VÉRIFICATION CRYPTOGRAPHIQUE (GPG + SHA256)
# ==============================================================================
cd "$TEMP_DIR" || exit 1

# Vérification de l'espace disque disponible (en Mo) avant téléchargement
free_boot=$(df -m /boot | awk 'NR==2 {print $4}')
free_tmp=$(df -m "$TEMP_DIR" | awk 'NR==2 {print $4}')

if [ "$free_boot" -lt 150 ]; then
    echo -e " \033[1;31m[ALERTE] Espace insuffisant dans /boot (${free_boot} Mo libres, 150 Mo requis) !\033[0m"
    echo -e " \033[1;33mSupprimez d'anciens noyaux avant de continuer pour éviter de bloquer GRUB.\033[0m"
    exit 1
fi

if [ "$free_tmp" -lt 300 ]; then
    echo -e " \033[1;31m[ALERTE] Espace insuffisant dans $TEMP_DIR (${free_tmp} Mo libres, 300 Mo requis) !\033[0m"
    exit 1
fi

echo ""
echo -e " \033[1;32m\tTéléchargement des paquets dans : $TEMP_DIR\033[0m"
echo ""

for url in "${target_urls[@]}"; do
    wget -q --show-progress "$url" || {
        echo -e " \033[1;31mErreur lors du téléchargement de $(basename "$url").\033[0m"
        exit 1
    }
done

echo ""
echo -e " \033[1;36m\tVérification de l'authenticité et de l'intégrité (GPG & SHA256)...\033[0m"

CHECKSUM_URL=""
if echo "$root_links" | grep -q "CHECKSUMS$"; then
    CHECKSUM_URL="${kernelURL}"
elif lynx -dump -listonly -nonumbers "${pkg_base_url}" 2>/dev/null | grep -q "CHECKSUMS$"; then
    CHECKSUM_URL="${pkg_base_url}"
fi

if [ -n "$CHECKSUM_URL" ]; then
    wget -q "${CHECKSUM_URL}CHECKSUMS" -O CHECKSUMS
    wget -q "${CHECKSUM_URL}CHECKSUMS.gpg" -O CHECKSUMS.gpg

    if [ -s CHECKSUMS ] && [ -s CHECKSUMS.gpg ]; then
        export GNUPGHOME="$TEMP_DIR/.gnupg"
        mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

        # 1. Importation du trousseau officiel d'Ubuntu
        [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ] && gpg --import /usr/share/keyrings/ubuntu-archive-keyring.gpg >/dev/null 2>&1

        # 2. Téléchargement et importation de la clé Kernel PPA
        KS_HOST="keyserver.ubuntu.com"
        UBUNTU_KERNEL_KEY="60AA7B6F30434AE68E569963E50C6A0917C622B0"
        curl -kfsSL "https://${KS_HOST}/pks/lookup?op=get&options=mr&search=0x${UBUNTU_KERNEL_KEY}" -o key.asc 2>/dev/null
        [ -s key.asc ] && gpg --import key.asc >/dev/null 2>&1

        # 3. Vérification de la signature GPG
        GPG_OUTPUT=$(gpg --verify CHECKSUMS.gpg CHECKSUMS 2>&1)
        GPG_STATUS=$?

        if [ $GPG_STATUS -eq 0 ]; then
            echo -e "\t\033[1;32m✔ Signature GPG valide (Kernel PPA <kernel-ppa@canonical.com>).\033[0m"
        elif echo "$GPG_OUTPUT" | grep -qiE "expired|expirée"; then
            echo -e "\t\033[1;32m✔ Signature GPG authentique (clé d'archive expirée, normal pour ce noyau).\033[0m"
        else
            echo -e "\t\033[1;33m⚠️  Échec GPG : $(echo "$GPG_OUTPUT" | tail -n 1)\033[0m"
            read -rp "	Continuer malgré tout avec la vérification SHA256 uniquement (y/N) ? " bypass_gpg
            [[ ! "$bypass_gpg" =~ ^[yY]$ ]] && exit 1
        fi

        # 4. Vérification stricte des empreintes SHA256 des paquets téléchargés
        sha_failed=0
        for deb in *.deb; do
            expected_sha=$(grep -E "[a-fA-F0-9]{64}.*${deb}$" CHECKSUMS | awk '{print $1}' | head -1)
            if [ -n "$expected_sha" ]; then
                actual_sha=$(sha256sum "$deb" | awk '{print $1}')
                if [ "$expected_sha" == "$actual_sha" ]; then
                    echo -e "\t\033[1;32m✔ SHA256 OK : \033[0m $deb"
                else
                    echo -e "\t\033[1;31m✘ SHA256 INVALIDE : \033[0m $deb"
                    sha_failed=1
                fi
            fi
        done

        if [ "$sha_failed" -eq 1 ]; then
            echo -e " \033[1;31m[ERREUR CRITIQUE] Fichier(s) corrompu(s). Installation annulée.\033[0m"
            exit 1
        fi
    fi
else
    echo -e "\t\033[1;33m⚠️  Fichiers CHECKSUMS absents pour cette version ancienne.\033[0m"
fi

# ==============================================================================
# 8. INSTALLATION DU NOUVEAU NOYAU ET MISE À JOUR DE GRUB
# ==============================================================================
echo ""
read -rp " [Entrée] pour installer le noyau $site ($choix) ou [CTRL]-[C] pour annuler... "
echo ""

echo -e " \033[1;36m\tInstallation des paquets .deb en cours...\033[0m"
if ! sudo dpkg -i *.deb; then
    echo -e " \033[1;33m\t⚠️  Dépendances manquantes détectées, tentative de réparation avec apt...\033[0m"
    sudo apt-get install -f -y || {
        echo -e " \033[1;31m[ERREUR] Échec de l'installation du noyau.\033[0m"
        exit 1
    }
fi

echo ""
echo -e " \033[1;36m\tMise à jour du chargeur d'amorçage (GRUB)...\033[0m"
if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

echo ""
echo -e " \033[1;32m✔ Installation du noyau $site ($choix) terminée avec succès !\033[0m"
echo -e " \033[1;33m\tUn redémarrage est nécessaire pour charger le nouveau noyau.\033[0m"
echo ""

read -rp "	Voulez-vous redémarrer l'ordinateur maintenant (y/N) ? " reboot_now
if [[ "$reboot_now" =~ ^[yY]$ ]]; then
    echo -e " \033[1;36m\tRedémarrage du système...\033[0m"
    sudo reboot
else
    echo -e " \033[1;32m\tPensez à redémarrer manuellement plus tard. À bientôt !\033[0m"
fi

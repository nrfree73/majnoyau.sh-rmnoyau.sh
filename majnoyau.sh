#!/bin/bash
# ==============================================================================
# Mise à jour automatisée du Noyau Linux (Ubuntu Mainline)
# Auteur original : RISTOVSKI Nicolas (2016-11)
# Mise à jour & Refonte : 2026-11 (HTTPS, Grille, Anti-Cache, GPG/SHA256, DKMS/UEFI)
# ==============================================================================

set -euo pipefail
clear

# ==============================================================================
# 1. GESTION DU DOSSIER TEMPORAIRE, NETTOYAGE ET SAISIE STRICTE Y/N
# ==============================================================================
TEMP_DIR=$(mktemp -d /tmp/kernel_update_XXXXXX) || {
    echo "Erreur critique : Impossible de créer le dossier temporaire."
    exit 1
}

CLEANUP_DONE=0
cleanup() {
    [ "$CLEANUP_DONE" -eq 1 ] && return
    CLEANUP_DONE=1

    tput cnorm 2>/dev/null || true
    stty sane 2>/dev/null || true

    if [ -d "${TEMP_DIR:-}/.gnupg" ]; then
        GNUPGHOME="$TEMP_DIR/.gnupg" gpgconf --kill all >/dev/null 2>&1 || true
    fi
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

on_interrupt() {
    echo ""
    echo -e " \033[1;33mInterruption par l'utilisateur (CTRL+C). Nettoyage...\033[0m"
    cleanup
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# Fonction de confirmation stricte : n'accepte uniquement que les touches y/Y ou n/N
ask_yn() {
    local prompt="$1"
    local ans=""
    echo -ne "$prompt"
    while true; do
        read -rsn1 ans || true
        case "$ans" in
            [yY]) echo "y"; return 0 ;;
            [nN]) echo "n"; return 1 ;;
        esac
    done
}

# ==============================================================================
# 2. VÉRIFICATION DE L'ESPACE DISQUE, DU RÉSEAU, DÉPENDANCES, SECURE BOOT ET DKMS
# ==============================================================================
free_boot=$(df -Pm /boot | awk 'NR==2 {print $4}')
free_tmp=$(df -Pm "$TEMP_DIR" | awk 'NR==2 {print $4}')

if [ "$free_boot" -lt 250 ]; then
    echo -e " \033[1;31m[ALERTE] Espace insuffisant dans /boot (${free_boot} Mo libres, 250 Mo requis) !\033[0m"
    echo -e " \033[1;33mSupprimez d'anciens noyaux pour éviter de bloquer GRUB lors de l'installation.\033[0m"
    if ask_yn " Voulez-vous exécuter 'sudo apt-get autoremove --purge' de manière interactive maintenant (y/n) ? "; then
        echo ""
        sudo apt-get autoremove --purge || true
        free_boot=$(df -Pm /boot | awk 'NR==2 {print $4}')
        if [ "$free_boot" -lt 250 ]; then
            echo -e " \033[1;31mEspace toujours insuffisant dans /boot (${free_boot} Mo libres). Abandon.\033[0m"
            exit 1
        fi
        echo -e " \033[1;32mEspace libéré dans /boot : ${free_boot} Mo disponibles.\033[0m"
        echo ""
    else
        exit 1
    fi
fi

if [ "$free_tmp" -lt 350 ]; then
    echo -e " \033[1;31m[ALERTE] Espace insuffisant dans $TEMP_DIR (${free_tmp} Mo libres, 350 Mo requis) !\033[0m"
    exit 1
fi

echo -n "Vérification de la connexion internet... "
if command -v curl >/dev/null 2>&1; then
    network_ok=$(curl -sI --connect-timeout 5 --max-time 8 https://kernel.ubuntu.com/mainline/ >/dev/null 2>&1 && echo "1" || echo "0")
else
    gw=$(ip r | awk '/default/ {print $3; exit}')
    network_ok=$([ -n "${gw:-}" ] && ping -q -w 2 -c 1 "$gw" >/dev/null 2>&1 && echo "1" || echo "0")
fi

if [ "$network_ok" == "0" ]; then
    echo -e "\033[1;31mÉCHEC\033[0m"
    echo "Pas de réseau internet ! Mise à jour du noyau impossible... [Entrée] pour quitter."
    read -r
    exit 1
fi
echo -e "\033[1;32mOK\033[0m"
echo ""

# Installation précoce des outils requis (wget, gnupg, curl)
MISSING_PKGS=()
command -v wget >/dev/null 2>&1 || MISSING_PKGS+=("wget")
command -v gpg  >/dev/null 2>&1 || MISSING_PKGS+=("gnupg")
command -v curl >/dev/null 2>&1 || MISSING_PKGS+=("curl")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installation des dépendances manquantes : ${MISSING_PKGS[*]}..."
    sudo apt-get update -qq && sudo apt-get install -y "${MISSING_PKGS[@]}"
    for pkg in "${MISSING_PKGS[@]}"; do
        bin_name="$pkg"
        [ "$pkg" == "gnupg" ] && bin_name="gpg"
        if ! command -v "$bin_name" >/dev/null 2>&1; then
            echo "Échec de l'installation du paquet '$pkg' (commande '$bin_name' introuvable) ! [Entrée] pour quitter..."
            read -r
            exit 1
        fi
    done
    echo ""
fi

# Vérification du Secure Boot UEFI
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
        echo -e "\033[1;33m⚠️  [AVERTISSEMENT SECURE BOOT UEFI ACTIVÉ]\033[0m"
        echo -e "\033[0;33m   Les noyaux Ubuntu Mainline ne sont pas signés pour le Secure Boot.\033[0m"
        echo -e "\033[0;33m   Le système refusera de démarrer sur ce noyau tant que Secure Boot est actif.\033[0m"
        if ! ask_yn "   Continuer malgré tout (y/n) ? "; then
            exit 0
        fi
        echo ""
    fi
fi

# Vérification des modules DKMS actifs
if command -v dkms >/dev/null 2>&1; then
    dkms_list=$(dkms status 2>/dev/null || true)
    if [ -n "$dkms_list" ]; then
        echo -e "\033[1;33m⚠️  [AVERTISSEMENT MODULES DKMS DÉTECTÉS]\033[0m"
        echo -e "\033[0;33m   Des pilotes externes compilés via DKMS sont présents sur votre système :\033[0m"
        echo "$dkms_list" | sed 's/^/     - /'
        echo -e "\033[0;33m   Un noyau trop récent peut provoquer un échec de compilation de ces pilotes.\033[0m"
        read -rp "   Appuyez sur [Entrée] pour continuer ou [CTRL]-[C] pour annuler... "
        echo ""
    fi
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

raw_html=$(curl -sL --connect-timeout 5 --max-time 15 -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "${BASE_URL}?nocache=$(date +%s)" 2>/dev/null || true)

mapfile -t all_versions < <(
    echo "$raw_html" \
    | grep -oE 'href="v[0-9]+\.[0-9]+[^"]*/"' \
    | sed -E 's/href="//; s/"$//' \
    | grep -viE -- '-rc[0-9]*' \
    | sed 's|/$||' \
    | sort -uV \
    | sed "s|^|${BASE_URL}|; s|$|/|" || true
)

total_versions=${#all_versions[@]}
if [ "$total_versions" -eq 0 ]; then
    echo -e "\033[1;31mErreur : Impossible de récupérer la liste des noyaux depuis $BASE_URL.\033[0m"
    exit 1
fi

check_count=8
[ "$total_versions" -lt "$check_count" ] && check_count=$total_versions

for ((i = total_versions - 1; i >= total_versions - check_count; i--)); do
    test_url="${all_versions[$i]}"
    page_root=$(curl -sL --connect-timeout 3 --max-time 5 -H "Cache-Control: no-cache" "$test_url" 2>/dev/null || true)
    page_arch=$(curl -sL --connect-timeout 3 --max-time 5 -H "Cache-Control: no-cache" "${test_url}${arch}/" 2>/dev/null || true)
    if ! printf "%s\n%s\n" "$page_root" "$page_arch" | grep -qE "_${arch}\.deb"; then
        unset 'all_versions[i]'
    fi
done

all_versions=("${all_versions[@]}")
total_versions=${#all_versions[@]}

if [ "$total_versions" -eq 0 ]; then
    echo -e "\033[1;31mErreur : Aucun noyau valide trouvé pour l'architecture '$arch'.\033[0m"
    exit 1
fi

page_size=60
page_step=1
max_pages=$(( (total_versions + page_size - 1) / page_size ))

update_grid_dimensions() {
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 120)
    cols=$(( term_cols / 22 ))
    [ "$cols" -lt 1 ] && cols=1
    [ "$cols" -gt 5 ] && cols=5
    rows=$(( (num_options + cols - 1) / cols ))
}

load_kernel_page() {
    local start_idx=$(( total_versions - (page_step * page_size) ))
    local count=$page_size
    if [ $start_idx -lt 0 ]; then
        count=$(( page_size + start_idx ))
        start_idx=0
    fi
    versions_list=( "${all_versions[@]:$start_idx:$count}" )
    num_options=${#versions_list[@]}
    update_grid_dimensions
}

clear
tput civis 2>/dev/null || true
load_kernel_page
active_index=$(( num_options - 1 ))

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
    update_grid_dimensions
    local r c idx
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 120)
    local grid_width=$(( cols * 21 ))
    local left_margin=$(( (term_cols - grid_width) / 2 ))
    [ $left_margin -lt 0 ] && left_margin=0

    tput cup 0 0
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
    echo -ne "\033[J"
}

while true; do
    display_menu
    read -rsn1 key || true
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.5 key || true
        if [[ $key == "[A" ]]; then
            ((active_index--)) || true
            [ $active_index -lt 0 ] && active_index=$((num_options - 1))
        elif [[ $key == "[B" ]]; then
            ((active_index++)) || true
            [ $active_index -ge $num_options ] && active_index=0
        elif [[ $key == "[D" ]]; then
            [ $active_index -ge $rows ] && active_index=$(( active_index - rows ))
        elif [[ $key == "[C" ]]; then
            [ $(( active_index + rows )) -lt $num_options ] && active_index=$(( active_index + rows ))
        fi
    elif [[ $key == "-" ]]; then
        if [ $page_step -lt $max_pages ]; then
            ((page_step++)) || true
            load_kernel_page
            active_index=0
        fi
    elif [[ $key == "+" ]]; then
        if [ $page_step -gt 1 ]; then
            ((page_step--)) || true
            load_kernel_page
            active_index=0
        fi
    elif [[ $key == "" ]]; then
        break
    fi
done

tput cnorm 2>/dev/null || true

# ==============================================================================
# 5. RECHERCHE DES PAQUETS ET SÉLECTION DE LA VARIANTE (GENERIC / LOWLATENCY)
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
ls /boot 2>/dev/null | grep initrd | cut -d- -f2,3,4 | sed 's/^/\t/' || true
echo ""

echo -e "\t\033[0;33mℹ️  Note : Les noyaux Mainline très récents peuvent exiger des bibliothèques système (ex. libc6/libssl)\033[0m"
echo -e "\t\033[0;33m   plus récentes que celles fournies par d'anciennes versions Ubuntu LTS.\033[0m"
echo ""

echo -e "    \033[1;4;36m--- Recherche des paquets distants sur le serveur ---\033[0m"

fetch_links() {
    local target_url="$1"
    curl -sL --connect-timeout 5 --max-time 10 -H "Cache-Control: no-cache" "$target_url" 2>/dev/null \
        | grep -oE 'href="[^"]+"' \
        | sed -E 's/^href="//; s/"$//' \
        | while read -r href; do
            if [[ "$href" =~ ^https?:// ]]; then
                echo "$href"
            elif [[ "$href" != \?* && "$href" != /* ]]; then
                echo "${target_url%/}/${href#/}"
            fi
        done || true
}

root_links=$(fetch_links "${kernelURL}")

if echo "$root_links" | grep -qE "_${arch}\.deb$"; then
    mapfile -t liste_debs < <(echo "$root_links" | grep -E "\.deb$" || true)
    pkg_base_url="${kernelURL}"
else
    mapfile -t liste_debs < <(
        fetch_links "${kernelURL}${arch}/" | grep -E "\.deb$" || true
        echo "$root_links" | grep -E "_all\.deb$" || true
    )
    pkg_base_url="${kernelURL}${arch}/"
fi

if [ ${#liste_debs[@]} -eq 0 ]; then
    echo -e "\t\033[1;31mErreur : Aucun paquet .deb trouvé pour l'architecture '$arch'.\033[0m"
    exit 1
fi

# Inhiber la question lowlatency si aucun paquet lowlatency n'existe pour cette version
has_lowlatency=0
for u in "${liste_debs[@]}"; do
    if [[ "$(basename "$u")" == *lowlatency* ]]; then
        has_lowlatency=1
        break
    fi
done

if [ "$has_lowlatency" -eq 1 ]; then
    if ask_yn "\033[3m\tSouhaitez-vous installer la variante 'lowlatency' (y/n) ? \033[0m"; then
        choix="lowlatency"
    else
        choix="generic"
    fi
    echo ""
else
    choix="generic"
    echo -e "\t\033[0;36mℹ️  Variante 'lowlatency' non disponible pour $site : sélection automatique de 'generic'.\033[0m"
    echo ""
fi

if ls /boot/initrd.img-"${site2}"-*-"${choix}" >/dev/null 2>&1; then
    echo -e " \033[1;31m   [ABANDON] Le noyau Linux $site ($choix) est déjà installé sur votre système !\033[0m"
    exit 0
fi

# Gestion sûre des révisions multiples (extraction de l'horodatage uniquement sur le nom de fichier)
latest_arch_rev=$(
    for u in "${liste_debs[@]}"; do basename "$u"; done \
    | grep -E "_${arch}\.deb$" | grep "$choix" \
    | grep -oE "\.[0-9]{8,12}_" | tr -d '._' | sort -V | tail -1 || true
)
latest_all_rev=$(
    for u in "${liste_debs[@]}"; do basename "$u"; done \
    | grep -E "_all\.deb$" \
    | grep -oE "\.[0-9]{8,12}_" | tr -d '._' | sort -V | tail -1 || true
)

mapfile -t target_urls < <(
    {
        if [ -n "$latest_arch_rev" ]; then
            printf "%s\n" "${liste_debs[@]}" | grep -E "_${arch}\.deb$" | grep "$choix" | grep "$latest_arch_rev" || true
        else
            printf "%s\n" "${liste_debs[@]}" | grep -E "_${arch}\.deb$" | grep "$choix" || true
        fi

        if [ -n "$latest_all_rev" ]; then
            printf "%s\n" "${liste_debs[@]}" | grep -E "linux-headers-.*_all\.deb$" | grep "$latest_all_rev" || true
        else
            printf "%s\n" "${liste_debs[@]}" | grep -E "linux-headers-.*_all\.deb$" || true
        fi
    } | sort -u
)

if [ ${#target_urls[@]} -eq 0 ]; then
    echo -e "\t\033[1;31mErreur : Impossible d'identifier les paquets à télécharger.\033[0m"
    exit 1
fi

# Vérification de la complétude du build (image, modules, headers)
has_image=$(printf "%s\n" "${target_urls[@]}" | grep -c "linux-image-" || true)
has_modules=$(printf "%s\n" "${target_urls[@]}" | grep -c "linux-modules-" || true)
has_headers=$(printf "%s\n" "${target_urls[@]}" | grep -c "linux-headers-" || true)

if [ "$has_image" -eq 0 ] || [ "$has_modules" -eq 0 ] || [ "$has_headers" -lt 2 ]; then
    echo -e "\t\033[1;33m⚠️  [AVERTISSEMENT BUILD INCOMPLET]\033[0m"
    echo -e "\t\033[0;33m   Certains composants habituels semblent absents (image:$has_image, modules:$has_modules, headers:$has_headers).\033[0m"
    echo -e "\t\033[0;33m   La compilation sur les serveurs Ubuntu Mainline a peut-être échoué partiellement.\033[0m"
    if ! ask_yn "\tContinuer malgré tout (y/n) ? "; then
        exit 1
    fi
    echo ""
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
    read -rsn1 key || true
    [[ "$key" == "" ]] && break
done

# ==============================================================================
# 6. TÉLÉCHARGEMENT ET VÉRIFICATION CRYPTOGRAPHIQUE (GPG + SHA256)
# ==============================================================================
cd "$TEMP_DIR" || exit 1

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

# Téléchargement des fichiers de contrôle (sous-dossier arch + racine)
curl -fsSL --connect-timeout 5 --max-time 10 "${pkg_base_url}CHECKSUMS" -o CHECKSUMS_ARCH 2>/dev/null || rm -f CHECKSUMS_ARCH
curl -fsSL --connect-timeout 5 --max-time 10 "${pkg_base_url}CHECKSUMS.gpg" -o CHECKSUMS_ARCH.gpg 2>/dev/null || rm -f CHECKSUMS_ARCH.gpg
curl -fsSL --connect-timeout 5 --max-time 10 "${kernelURL}CHECKSUMS" -o CHECKSUMS_ROOT 2>/dev/null || rm -f CHECKSUMS_ROOT
curl -fsSL --connect-timeout 5 --max-time 10 "${kernelURL}CHECKSUMS.gpg" -o CHECKSUMS_ROOT.gpg 2>/dev/null || rm -f CHECKSUMS_ROOT.gpg

# Préparation de l'environnement GPG isolé
export GNUPGHOME="$TEMP_DIR/.gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ] && gpg --import /usr/share/keyrings/ubuntu-archive-keyring.gpg >/dev/null 2>&1 || true

KS_HOST="keyserver.ubuntu.com"
UBUNTU_KERNEL_KEY="60AA7B6F30434AE68E569963E50C6A0917C622B0"
if curl -fsSL --connect-timeout 5 --max-time 10 "https://${KS_HOST}/pks/lookup?op=get&options=mr&search=0x${UBUNTU_KERNEL_KEY}" -o key.asc 2>/dev/null && [ -s key.asc ]; then
    if gpg --with-colons --import-options show-only --import key.asc 2>/dev/null | grep -q "^fpr:.*:${UBUNTU_KERNEL_KEY}:"; then
        gpg --import key.asc >/dev/null 2>&1 || true
    else
        echo -e "\t\033[1;31m[ALERTE SÉCURITÉ] Empreinte de la clé GPG téléchargée non conforme !\033[0m"
        exit 1
    fi
fi

verify_checksum_target() {
    local label="$1"
    local data_f="$2"
    local sig_f="$3"
    local out_f="$4"
    local gpg_out=""

    if [ -s "$data_f" ] && [ -s "$sig_f" ]; then
        gpg_out=$(LC_ALL=C gpg --status-fd 2 --verify "$sig_f" "$data_f" 2>&1 >/dev/null || true)
        if echo "$gpg_out" | grep -q "^\[GNUPG:\] VALIDSIG"; then
            echo -e "\t\033[1;32m✔ Signature GPG valide ($label - Kernel PPA <kernel-ppa@canonical.com>).\033[0m"
            cat "$data_f" >> "$out_f"
            return 0
        elif echo "$gpg_out" | grep -q "^\[GNUPG:\] EXPKEYSIG"; then
            echo -e "\t\033[1;32m✔ Signature GPG authentique ($label - clé d'archive expirée, normal pour ce noyau).\033[0m"
            cat "$data_f" >> "$out_f"
            return 0
        else
            echo -e "\t\033[1;33m⚠️  Échec de vérification GPG ($label) : $(echo "$gpg_out" | grep -v "^\[GNUPG:\]" | tail -n 1)\033[0m"
            if ask_yn "\tIgnorer l'échec GPG pour $label et continuer (y/n) ? "; then
                cat "$data_f" >> "$out_f"
                return 0
            else
                exit 1
            fi
        fi
    elif [ -s "$data_f" ] && grep -q "^-----BEGIN PGP SIGNED MESSAGE-----" "$data_f"; then
        gpg_out=$(LC_ALL=C gpg --status-fd 2 --decrypt "$data_f" > "${data_f}_EXTRACTED" 2>&1 || true)
        if [ -s "${data_f}_EXTRACTED" ] && echo "$gpg_out" | grep -q "^\[GNUPG:\] VALIDSIG"; then
            echo -e "\t\033[1;32m✔ Signature GPG valide ($label - Kernel PPA <kernel-ppa@canonical.com>).\033[0m"
            cat "${data_f}_EXTRACTED" >> "$out_f"
            return 0
        elif [ -s "${data_f}_EXTRACTED" ] && echo "$gpg_out" | grep -q "^\[GNUPG:\] EXPKEYSIG"; then
            echo -e "\t\033[1;32m✔ Signature GPG authentique ($label - clé d'archive expirée, normal pour ce noyau).\033[0m"
            cat "${data_f}_EXTRACTED" >> "$out_f"
            return 0
        else
            echo -e "\t\033[1;33m⚠️  Échec de vérification GPG ($label) : $(echo "$gpg_out" | grep -v "^\[GNUPG:\]" | tail -n 1)\033[0m"
            if ask_yn "\tIgnorer l'échec GPG pour $label et continuer (y/n) ? "; then
                [ -s "${data_f}_EXTRACTED" ] && cat "${data_f}_EXTRACTED" >> "$out_f"
                return 0
            else
                exit 1
            fi
        fi
    elif [ -s "$data_f" ]; then
        echo -e "\t\033[1;33m⚠️  Fichier $label trouvé sans signature GPG associée.\033[0m"
        cat "$data_f" >> "$out_f"
        return 0
    fi
    return 1
}

VERIFIED_MERGED="CHECKSUMS_MERGED"
: > "$VERIFIED_MERGED"

verify_checksum_target "arch" "CHECKSUMS_ARCH" "CHECKSUMS_ARCH.gpg" "$VERIFIED_MERGED" || true
if [ "${pkg_base_url}" != "${kernelURL}" ]; then
    verify_checksum_target "root" "CHECKSUMS_ROOT" "CHECKSUMS_ROOT.gpg" "$VERIFIED_MERGED" || true
fi

if [ -s "$VERIFIED_MERGED" ]; then
    tr -d '\r' < "$VERIFIED_MERGED" | awk '
        length($1) == 64 && $1 ~ /^[a-fA-F0-9]+$/ {
            file = $NF
            sub(/^.*\//, "", file)
            sub(/^\*/, "", file)
            print tolower($1) "  " file
        }
    ' | sort -u > CHECKSUMS_CLEAN

    sha_failed=0
    missing_hashes=()
    for deb in *.deb; do
        matched_line=$(awk -v f="$deb" '$2 == f { print $0; exit }' CHECKSUMS_CLEAN)
        if [ -n "$matched_line" ]; then
            if printf "%s\n" "$matched_line" | sha256sum --status -c - 2>/dev/null; then
                echo -e "\t\033[1;32m✔ SHA256 OK : \033[0m $deb"
            else
                echo -e "\t\033[1;31m✘ SHA256 INVALIDE : \033[0m $deb"
                sha_failed=1
            fi
        else
            missing_hashes+=("$deb")
        fi
    done

    if [ "$sha_failed" -eq 1 ]; then
        echo -e " \033[1;31m[ERREUR CRITIQUE] Fichier(s) corrompu(s) détecté(s). Installation annulée.\033[0m"
        exit 1
    fi

    if [ ${#missing_hashes[@]} -gt 0 ]; then
        echo -e "\t\033[1;33m⚠️  [EMPREINTES .DEB NON PUBLIÉES SUR LE SERVEUR]\033[0m"
        echo -e "\t\033[0;33m   Canonical n'a signé que les métadonnées de build dans CHECKSUMS (aucun SHA256 publié pour les .deb) :\033[0m"
        for mh in "${missing_hashes[@]}"; do
            echo -e "\t\033[0;33m     - $mh\033[0m"
        done
        if ! ask_yn "\tPoursuivre l'installation via HTTPS vérifié (y/n) ? "; then
            exit 1
        fi
        echo ""
    fi
else
    echo -e "\t\033[1;33m⚠️  [AUCUN FICHIER CHECKSUMS TROUVÉ SUR LE SERVEUR]\033[0m"
    echo -e "\t\033[0;33m   L'intégrité cryptographique SHA256/GPG ne peut pas être vérifiée pour cette version.\033[0m"
    if ! ask_yn "\tPoursuivre l'installation malgré l'absence de CHECKSUMS (y/n) ? "; then
        exit 1
    fi
    echo ""
fi

# ==============================================================================
# 7. INSTALLATION DU NOUVEAU NOYAU ET MISE À JOUR DE GRUB
# ==============================================================================
echo ""
read -rp " [Entrée] pour installer le noyau $site ($choix) ou [CTRL]-[C] pour annuler... "
echo ""

if ! sudo -v; then
    echo -e " \033[1;31m[ERREUR] Privilèges administrateur (sudo) requis pour l'installation.\033[0m"
    exit 1
fi

echo -e " \033[1;36m\tInstallation des paquets .deb via apt (résolution des dépendances)...\033[0m"
if ! sudo apt-get install -y --allow-downgrades ./*.deb; then
    echo -e " \033[1;31m[ERREUR] Échec de l'installation du noyau (dépendances incompatibles ou paquet bloqué).\033[0m"
    exit 1
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

if ask_yn "\tVoulez-vous redémarrer l'ordinateur maintenant (y/n) ? "; then
    echo -e " \033[1;36m\tRedémarrage du système...\033[0m"
    sudo reboot
else
    echo -e " \033[1;32m\tPensez à redémarrer manuellement plus tard. À bientôt !\033[0m"
fi

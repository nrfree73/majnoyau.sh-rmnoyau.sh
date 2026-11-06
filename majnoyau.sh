#!/bin/bash
clear
echo "          [ Mise à jour automatisée du Noyau Linux ]  "
echo "              ...  RISTOVSKI Nicolas (2016-11) ..."
echo  "                             update: (2026-11)"
echo ""
#network test...
networktest=$(ping -q -w 1 -c 1 `ip r | grep default | cut -d ' ' -f 3` > /dev/null && echo "1" || echo "0")
if [ "$networktest" == "0" ]; then 
echo "Pas de reseau internet ! mise à jour du noyau impossible... [enter] pour quitter." 
read a 
exit; fi
#lynx test...si installé sinon install depuis depot logiciel
if ! which lynx > /dev/null; then sudo apt-get install lynx -y; fi
if ! which lynx > /dev/null; then echo "echec installation pkg 'lynx' ! [enter] sortie du programme..." 
read a
exit; fi
#architecture test...(arch=amd64 || i386)
if [ "$(getconf LONG_BIT)" == "64" ]; then arch=amd64; else arch=i386; fi
#clear
low=0
# Kernel URL
echo "	Liste des dernières versions du Kernel... "

# ==============================================================================
# BLOC LOGIQUE : MENU INTERACTIF EN GRILLE ( pagination avec touches + et - )
# ==============================================================================
page_step=1

load_kernel_page() {
    local tail_val=$(( page_step * 60 ))
    local head_val=60
    
    # Commande originale ajustée dynamiquement avec tail et head pour paginer par bloc de 60
    mapfile -t versions_list < <(lynx -dump -nonumbers http://kernel.ubuntu.com/~kernel-ppa/mainline/ | grep -v rc | grep -E '/v[0-9]' | tail -${tail_val} | head -${head_val} | sort -V)
    
    num_options=${#versions_list[@]}
    cols=5
    rows=$(( (num_options + cols - 1) / cols ))
}

load_kernel_page
active_index=0

display_menu() {
    local r c idx
    # Remonter le curseur au début de la grille
    for ((r=0; r<rows; r++)); do echo -ne "\033[F"; done
    
    for ((r=0; r<rows; r++)); do
        for ((c=0; c<cols; c++)); do
            idx=$(( r + c * rows ))
            if [ $idx -lt $num_options ]; then
                # Extraction du numéro de version pur (ex: v7.3.1) pour un affichage compact
                local ver_name=$(echo "${versions_list[$idx]}" | cut -d/ -f6)
                if [ -z "$ver_name" ]; then
                    ver_name=$(echo "${versions_list[$idx]}" | cut -d/ -f5)
                fi
                
                if [ $idx -eq $active_index ]; then
                    # Élément sélectionné (Surbrillance Bleu)
                    printf "\033[1;37;44m > %-18s\033[0m   " "$ver_name"
                else
                    # Élément normal
                    printf "   %-18s   " "$ver_name"
                fi
            fi
        done
        echo ""
    done
    # Ligne informative d'aide à la navigation
    echo -ne "\033[K"
    echo -e "	--- [Flèches]: Naviguer | [-]: 60 versions antérieures | [+]: 60 versions suivantes ---"
    echo -ne "\033[F"
}

# Réserver l'espace à l'écran (+1 pour la ligne d'information)
for ((r=0; r<=rows; r++)); do echo ""; done

while true; do
    display_menu
    
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.1 key
        if [[ $key == "[A" ]]; then
            # Flèche HAUT
            ((active_index--))
            [ $active_index -lt 0 ] && active_index=$((num_options - 1))
        elif [[ $key == "[B" ]]; then
            # Flèche BAS
            ((active_index++))
            [ $active_index -ge $num_options ] && active_index=0
        elif [[ $key == "[D" ]]; then
            # Flèche GAUCHE
            if [ $active_index -ge $rows ]; then
                active_index=$(( active_index - rows ))
            fi
        elif [[ $key == "[C" ]]; then
            # Flèche DROITE
            if [ $(( active_index + rows )) -lt $num_options ]; then
                active_index=$(( active_index + rows ))
            fi
        fi
    elif [[ $key == "-" ]]; then
        # RECULER DE 60 VERSIONS ANTÉRIEURES
        # Effacer proprement la grille précédente
        for ((r=0; r<=rows; r++)); do echo -ne "\033[F\033[K"; done
        
        ((page_step++))
        load_kernel_page
        active_index=0
        
        # Ré-ouvrir l'espace à l'écran pour la nouvelle grille
        for ((r=0; r<=rows; r++)); do echo ""; done
    elif [[ $key == "+" ]]; then
        # AVANCER VERS LES 60 VERSIONS PLUS RÉCENTES
        if [ $page_step -gt 1 ]; then
            for ((r=0; r<=rows; r++)); do echo -ne "\033[F\033[K"; done
            
            ((page_step--))
            load_kernel_page
            active_index=0
            
            for ((r=0; r<=rows; r++)); do echo ""; done
        fi
    elif [[ $key == "" ]]; then
        # Touche ENTRÉE
        break
    fi
done

# Nettoyage console avant la suite du script
clear
echo ""
echo ""

kernelURL=${versions_list[$active_index]}
site=$(echo "$kernelURL" | cut -d/ -f6)
[ -z "$site" ] && site=$(echo "$kernelURL" | cut -d/ -f5)
# ==============================================================================

perso="v"$(uname -r |cut -d- -f1) #numéro noyau démarré sur le PC (vx.xx)
perso2=$(uname -r |cut -d- -f3) #type: generic ou lowlatency
test=0
echo ""
#echo -e "  Voici la version du noyau sélectionnée pour installation: \033[1;32m$kernelURL\033[0m"
echo -e "\033[1m   Voici la version du noyau sélectionnée pour installation:   \033[1;32m$kernelURL\033[0m"
echo ""
#echo -e "\033[1;31m	Version du noyau linux actuellement chargée: $(uname -r)\033[0m"
echo -e "\033[1;36m	Version du noyau actuellement chargée: $(uname -r)\033[0m"

echo ""
echo -e "\033[1;32m        Liste des noyaux actuellement installés sur votre Linux:\033[0m"
echo -ne "\033[1;32m"
ls /boot | grep initrd | cut -d- -f2,3,4 | sed 's/^/\t/'
echo -ne "\033[0m"
#ls /boot |grep initrd |cut -d- -f2,3,4
echo
site=$(echo "$kernelURL" | cut -d/ -f5);

echo
#echo "	Version selectionnée pour installation: " $site
echo -e "\033[1;32m	Version selectionnée pour installation: $site\033[0m"

# Extraction du numéro de version pur (ex: 6.18.60 au lieu de v6.18.60)
site2=$(echo "$site" | cut -dv -f2)

# Vérification immédiate si cette version précise est déjà présente dans /boot
installed=$(ls /boot 2>/dev/null | grep initrd | grep "$site2" | cut -d- -f2,3)
installed2=$(ls /boot 2>/dev/null | grep initrd | grep "$site2" | cut -d- -f4)

if [ -z "$installed" ]; then installed=0.0; fi

# Si la version ET le type de noyau (generic/lowlatency) correspondent, on abandonne
if [[ "$installed" =~ "$site2" ]] && [[ "$installed2" == "$choix" ]] ; then
    echo ""
    echo -e "\033[1;31m	[ABANDON] Le noyau Linux $site ($choix) est déjà installé sur votre système !\033[0m"
    echo ""
    echo -e "\033[1m	Rappel des noyaux actuellement installés :\033[0m"
    ls /boot | grep initrd | cut -d- -f2,3,4 | sed 's/^/\t/'
    echo ""
    exit 1
fi

#read -p "	Souhaitez-vous installer une version du noyau 'lowlatency' (y/n) ?" low
# Préparation du texte en italique (sans espace à la fin car read ne l'attend plus)
prompt_msg=$(printf "\e[3m\tSouhaitez-vous installer une version du noyau 'lowlatency' (y/n) ?\e[0m")

echo -ne "$prompt_msg"

while true; do
    # Lit une seule touche (-n1) en mode silencieux (-s)
    read -rsn1 key
    
    case "$key" in
        [yY])
            low=1
            echo "y" # Affiche le choix de l'utilisateur à l'écran
            break
            ;;
        [nN])
            low=0
            echo "n" # Affiche le choix de l'utilisateur à l'écran
            break
            ;;
        *)
            # Ignore toutes les autres touches (inhibe le reste)
            ;;
    esac
done

if [ $low == 1 ]; then 
    choix=lowlatency;
else
    choix=generic;
fi

echo
#echo "      noyau choisi pour installation: " $site "" $choix
echo -e "\033[1;3;32m      noyau choisi pour installation: $site $choix\033[0m"

#perso = generic ou lowlatency et choix =low ou generic (test=1 si on a un type generic et on choisi lowlatency sinon test=0)
if [ $perso2 == generic ] && [ $low = 1 ]; then test=1; fi
if [ $perso2 == lowlatency ] && [ $low = 0 ]; then test=1; fi

site2=$(echo $site | cut -dv -f2);

clear
echo ""

# ==============================================================================
# AFFICHAGE DES PAQUETS DEPUIS LE SERVEUR VIA CURL JUSTE APRÈS LA SÉLECTION
# ==============================================================================
#echo "      --- Liste des paquets distants disponibles sur le serveur ---"
echo -e "      \033[1;4;36m--- Liste des paquets distants disponibles sur le serveur ---\033[0m"
echo
# On interroge le sous-dossier de l'architecture pour trouver les debs spécifiques + le dossier parent pour le paquet _all.deb
mapfile -t liste_debs < <(
    lynx -dump -listonly -nonumbers "${kernelURL}${arch}/" 2>/dev/null | grep -E "\.deb$"
    lynx -dump -listonly -nonumbers "${kernelURL}" 2>/dev/null | grep -E "_all\.deb$"
)

# 1. Vérification si le type choisi existe sur le serveur (ex: cherche s'il y a du lowlatency)
if [ "$choix" == "lowlatency" ] && ! printf "%s\n" "${liste_debs[@]}" | grep -q "lowlatency"; then
    echo -e "\t\033[1;31m⚠️  Note : Pas de paquets 'lowlatency' disponibles pour ce noyau v.${site2}.\033[0m"
    echo -e "\t\033[1;31m   Bascule automatique sur la version 'generic'...\033[0m"
    echo ""
    choix="generic"
    low=0
fi

# 2. Tri des doublons ET filtrage strict selon le type final retenu
for line in $(printf "%s\n" "${liste_debs[@]}" | sort -u | grep -E "(_all|$choix)"); do
    echo -e "\t\033[1;3;36m-> $(basename "$line")\033[0m"
done
echo -e "      \033[4;36m______________________________________________________________\033[0m"
echo ""


installed=$(ls /boot |grep initrd | grep "$site2" | cut -d- -f2,3)
installed2=$(ls /boot |grep initrd | grep "$site2" | cut -d- -f4)
if [ -z "$installed" ]; then installed=0.0; fi #si le systeme à deja été installé avec la derniere version du noyau on à un résultat <> "" alors on s'arrete..sinon GO.
if [[ "$installed" =~ "$site2" ]] && [[ "$installed2" == "$choix" ]] ; then
echo ""
echo "Votre noyau linux " $site "est déjà installé ! "
echo $kernelURL
echo "Rappel des noyaux installés sur votre Linux..."
echo
ls /boot |grep initrd
exit;
fi
if [ $site == $perso ] && [ $test == 0 ]; then #le test precedent est verifie ici
echo ""
echo "Votre noyau est déjà à la dernière version " "$site" "-" "$perso2" "! tout est OK... [enter] pour sortir !"
read a
exit;
else
echo
echo
#echo " [enter] pour poursuivre la mise à jour du noyau v." $site2 "-" $choix "! ou [CTRL]-[C] pour annuler et quitter..."
#echo -e "\t\033[1;4;31m[enter] pour poursuivre la mise à jour du noyau v. $site2 - $choix !\n\n\t ou [CTRL]-[C] pour annuler et quitter...\033[0m"
echo -e "\t\033[1;4;92m[enter] pour poursuivre la mise à jour du noyau v. $site2 - $choix !\n\n\t\t ou [CTRL]-[C] pour annuler et quitter...\033[0m"


while true; do
    # Capture une seule touche en mode silencieux
    read -rsn1 key
    # En Bash, la touche Entrée renvoie une chaîne vide ""
    if [[ "$key" == "" ]]; then
        break
    fi
    # Toutes les autres touches du clavier sont totalement ignorées et bloquées
done

read a;
fi
# Downloading latest lowlatency Kernel
#generic
if [ $low == 0 ]; then
# generic header
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL generic headers |cut -d ' ' -f4 |grep "$arch" |grep generic |grep headers |tail -1)
# generic image
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL generic headers |cut -d ' ' -f4 |grep "$arch" |grep generic |grep image |tail -1)
# generic module
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL generic modules |cut -d ' ' -f4 |grep "$arch" |grep generic |grep modules |tail -1)
# generic modules-extra (AJOUT INDISPENSABLE)
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL generic modules |cut -d ' ' -f4 |grep "$arch" |grep generic |grep "modules-extra" |tail -1)
# all
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL headers |cut -d ' ' -f4 |grep all |tail -1);
fi
#lowlatency
if [ $low == 1 ]; then
# lowlatency header
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL lowlatency headers |cut -d ' ' -f4 |grep "$arch" |grep lowlatency |grep headers |tail -1)
# lowlatency image
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL lowlatency headers |cut -d ' ' -f4 |grep "$arch" |grep lowlatency |grep image |tail -1)
# lowlatency module
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL lowlatency modules |cut -d ' ' -f4 |grep "$arch" |grep lowlatency |grep modules |tail -1)
# lowlatency modules-extra (AJOUT INDISPENSABLE)
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL lowlatency modules |cut -d ' ' -f4 |grep "$arch" |grep lowlatency |grep "modules-extra" |tail -1)
# all
wget $(lynx -dump -nonumbers -listonly -dont-wrap-pre $kernelURL headers |cut -d ' ' -f4 |grep all |tail -1);
fi
# Installing Kernel
clear
echo
echo " [enter] pour installer le noyau  " $kernelURL
read a
sudo dpkg -i linux*.deb
#remove latest downloaded kernel... generic or lowlatency
#generic
echo
echo
echo "Effacement des fichiers temporaires (paquets deb) " $kernelURL
if [ $low == 0 ]; then
rm linux-*.deb
fi
#lowlatency
if [ $low == 1 ]; then
rm linux-*.deb
fi
echo

installed=$(ls /boot |grep initrd | grep "$site2" | cut -d- -f2)
if [ -z "$installed" ]; then installed=0.0; fi


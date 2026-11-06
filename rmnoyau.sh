#!/bin/bash
clear
echo "Choisissez la version du noyau à désinstaller (Flèches + [Entrée], ou Ctrl+C pour quitter)"
echo

# Récupération de la liste brute des noyaux installés
mapfile -t versions_list < <(ls /boot | grep initrd | cut -d- -f2,3,4)

# Ajout de l'option pour quitter proprement à la fin du tableau
versions_list+=("QUITTER !")

# ==============================================================================
# BLOC LOGIQUE : MENU INTERACTIF EN GRILLE (2 COLONNES)
# ==============================================================================
active_index=0
num_options=${#versions_list[@]}
cols=2
# Calcul du nombre de lignes nécessaires pour la grille
rows=$(( (num_options + cols - 1) / cols ))

display_menu() {
    local r c idx
    # Remonter le curseur au début de la grille pour rafraîchir l'affichage
    for ((r=0; r<rows; r++)); do echo -ne "\033[F"; done
    
    for ((r=0; r<rows; r++)); do
        for ((c=0; c<cols; c++)); do
            idx=$(( r + c * rows ))
            if [ $idx -lt $num_options ]; then
                if [ $idx -eq $active_index ]; then
                    # Élément sélectionné (Surbrillance Bleu)
                    printf "\033[1;37;44m > %-24s\033[0m   " "${versions_list[$idx]}"
                else
                    # Élément normal
                    printf "   %-24s   " "${versions_list[$idx]}"
                fi
            fi
        done
        echo ""
    done
}

# Réserver l'espace à l'écran avant la boucle d'affichage
for ((r=0; r<rows; r++)); do echo ""; done

while true; do
    display_menu
    
    # Capture des touches directionnelles
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
    elif [[ $key == "" ]]; then
        # Touche ENTRÉE valide le choix
        break
    fi
done

# Récupération de la sélection
FILENAME=${versions_list[$active_index]}
# ==============================================================================

# Gestion du choix utilisateur
case "$FILENAME" in
    "QUITTER !")
        echo "Exiting."
        exit 0
        ;;
    *)
        clear
        echo "Noyau choisi: $FILENAME"
        echo ""
        
        # ----------------------------------------------------------------------
        # DOUBLE CONFIRMATION DE SÉCURITÉ avant exécution
        # ----------------------------------------------------------------------
        read -p "⚠️ CONFIRMATION 1 : Êtes-vous sûr de vouloir supprimer le noyau $FILENAME ? (y/N) : " conf1
        if [[ ! "$conf1" =~ ^[yY]$ ]]; then
            echo "Action annulée par l'utilisateur."
            exit 0
        fi

        echo ""
        read -p "🚨 CONFIRMATION 2 : Attention, la suppression est IRREVOCABLE. Confirmer définitivement ? (y/N) : " conf2
        if [[ ! "$conf2" =~ ^[yY]$ ]]; then
            echo "Action annulée au second niveau de sécurité."
            exit 0
        fi
        # ----------------------------------------------------------------------

        clear
        echo "Suppression en cours du noyau : $FILENAME..."
        echo apt-get remove linux-headers-$FILENAME* linux-image-$FILENAME* linux-modules-$FILENAME* --purge
        echo
        echo "saisir mot de passe root.."
        sudo apt-get remove linux-headers-$FILENAME* linux-image-$FILENAME* linux-modules-$FILENAME* --purge
        echo
        echo "liste des noyaux restants sur votre Linux:"
        echo
        ls /boot | grep initrd
        echo
        echo "Enter pour sortir..."
        read a
        exit 0
        ;;
esac


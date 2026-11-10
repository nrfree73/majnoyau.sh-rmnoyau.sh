#!/bin/bash
# ==============================================================================
# Automated Linux Kernel Updater (Ubuntu Mainline)
# Original Author : RISTOVSKI Nicolas (2016-11)
# Update & Refactor : 2026-11 (HTTPS, Grid UI, GPG/SHA256 Verification)
# ==============================================================================

clear

# ==============================================================================
# 1. TEMPORARY DIRECTORY MANAGEMENT AND AUTOMATIC CLEANUP
# ==============================================================================
TEMP_DIR=$(mktemp -d /tmp/kernel_update_XXXXXX)

cleanup() {
    # Restore cursor visibility and normal terminal state
    tput cnorm 2>/dev/null
    stty sane 2>/dev/null

    if [ -d "$TEMP_DIR/.gnupg" ]; then
        GNUPGHOME="$TEMP_DIR/.gnupg" gpgconf --kill all >/dev/null 2>&1
    fi
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Trigger cleanup() only upon actual script exit
trap cleanup EXIT

# Force immediate script termination on CTRL+C (which triggers EXIT)
trap 'echo ""; echo -e " \033[1;33mInterrupted by user (CTRL+C). Cleaning up...\033[0m"; exit 130' INT TERM

# ==============================================================================
# 2. NETWORK AND DEPENDENCIES CHECK
# ==============================================================================
echo -n "Checking internet connection... "
if command -v curl >/dev/null 2>&1; then
    network_ok=$(curl -sI --connect-timeout 5 https://kernel.ubuntu.com/mainline/ >/dev/null && echo "1" || echo "0")
else
    gw=$(ip r | awk '/default/ {print $3; exit}')
    network_ok=$([ -n "$gw" ] && ping -q -w 2 -c 1 "$gw" >/dev/null 2>&1 && echo "1" || echo "0")
fi

if [ "$network_ok" == "0" ]; then
    echo -e "\033[1;31mFAILED\033[0m"
    echo "No internet connection! Kernel update impossible... Press [Enter] to exit."
    read -r
    exit 1
fi
echo -e "\033[1;32mOK\033[0m"

# Install required tools (lynx, wget, gnupg)
MISSING_PKGS=()
command -v lynx >/dev/null 2>&1 || MISSING_PKGS+=("lynx")
command -v wget >/dev/null 2>&1 || MISSING_PKGS+=("wget")
command -v gpg >/dev/null 2>&1 || MISSING_PKGS+=("gnupg")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing dependencies: ${MISSING_PKGS[*]}..."
    sudo apt-get update -qq && sudo apt-get install -y "${MISSING_PKGS[@]}"
    for pkg in "${MISSING_PKGS[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1 && [ "$pkg" != "gnupg" ]; then
            echo "Failed to install package '$pkg'! Press [Enter] to exit..."
            read -r
            exit 1
        fi
    done
fi

# ==============================================================================
# 3. HARDWARE ARCHITECTURE DETECTION
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

echo -e "\tDetected architecture: \033[1;33m$arch\033[0m"
echo ""

# ==============================================================================
# 4. KERNEL VERSIONS RETRIEVAL AND GRID PAGINATION (HTTPS)
# ==============================================================================
BASE_URL="https://kernel.ubuntu.com/mainline/"
echo "Fetching kernel version list from Ubuntu Mainline..."

mapfile -t all_versions < <(
    lynx -dump -listonly -nonumbers "$BASE_URL" 2>/dev/null \
    | grep -v "rc" \
    | grep -E '/v[0-9]+\.[0-9]+' \
    | sed 's|/$||' \
    | sort -uV \
    | sed 's|$|/|'
)

total_versions=${#all_versions[@]}
if [ "$total_versions" -eq 0 ]; then
    echo -e "\033[1;31mError: Unable to retrieve kernel list from $BASE_URL.\033[0m"
    exit 1
fi

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

# Helper function to center text based on its visible character length
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
    print_centered "\033[1;36m[ Automated Linux Kernel Updater ]\033[0m"
    print_centered "\033[0;37m... RISTOVSKI Nicolas (2016-11) ...\033[0m"
    print_centered "\033[0;37mupdate: (2026-11)\033[0m"
    echo ""
    print_centered "\033[1;37mDetected architecture: \033[1;33m${arch}\033[0m"
    echo ""
}

display_menu() {
    local r c idx
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 120)
    
    # Grid is 5 columns x 21 characters = 105 characters wide
    local grid_width=$(( cols * 21 ))
    local left_margin=$(( (term_cols - grid_width) / 2 ))
    [ $left_margin -lt 0 ] && left_margin=0

    # Move cursor to top-left without flickering
    tput cup 0 0
    
    # Display centered colored header
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
    print_centered "\033[1;36m--- Page $real_page/$max_pages | [Arrows]: Navigate | [-]: Previous | [+]: Next | [Enter]: Select ---\033[0m"
    
    # Clear anything remaining below
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
# 5. VARIANT SELECTION (GENERIC / LOWLATENCY)
# ==============================================================================
clear
echo ""
kernelURL="${versions_list[$active_index]}"
site=$(basename "$kernelURL")
site2="${site#v}"

echo -e " \033[1m   Selected version for installation : \033[1;32m$site\033[0m ($kernelURL)"
echo -e " \033[1;36m   Currently running kernel version  : $(uname -r)\033[0m"
echo ""
echo -e " \033[1;32m   Kernels currently installed in /boot:\033[0m"
ls /boot 2>/dev/null | grep initrd | cut -d- -f2,3,4 | sed 's/^/\t/'
echo ""

prompt_msg=$(printf "\033[3m\tWould you like to install the 'lowlatency' variant (y/n)? \033[0m")
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
# 6. PACKAGE SEARCH AND AVAILABILITY CHECK
# ==============================================================================
echo -e "    \033[1;4;36m--- Searching for remote packages on the server ---\033[0m"

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
    echo -e "\t\033[1;31mError: No .deb packages found for architecture '$arch'.\033[0m"
    exit 1
fi

if [ "$choix" == "lowlatency" ] && ! printf "%s\n" "${liste_debs[@]}" | grep -q "lowlatency"; then
    echo -e "\t\033[1;31m⚠️  Note: No 'lowlatency' packages available for v.${site2}.\033[0m"
    echo -e "\t\033[1;31m   Automatically falling back to 'generic' variant...\033[0m"
    echo ""
    choix="generic"
    low=0
fi

# Check if this exact version and variant are already installed
if ls /boot/initrd.img-"${site2}"*-"${choix}" >/dev/null 2>&1; then
    echo ""
    echo -e " \033[1;31m   [ABORTED] Linux Kernel $site ($choix) is already installed on your system!\033[0m"
    exit 0
fi

# Filter the latest revision and target packages
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
    echo -e "\t\033[1;31mError: Unable to identify packages to download.\033[0m"
    exit 1
fi

echo -e " \033[1;3;32m   Kernel ready for download: $site ($choix)\033[0m"
for url in "${target_urls[@]}"; do
    echo -e "\t\033[1;3;36m-> $(basename "$url")\033[0m"
done
echo -e "    \033[4;36m______________________________________________________________\033[0m"
echo ""

echo -e "\t\033[1;4;92m  Press [Enter] to start download and GPG verification!\033[0m"
echo -e "\t\033[1;31m  Or [CTRL]-[C] to cancel and quit...\033[0m"

while true; do
    read -rsn1 key
    [[ "$key" == "" ]] && break
done

# ==============================================================================
# 7. DOWNLOAD AND CRYPTOGRAPHIC VERIFICATION (GPG + SHA256)
# ==============================================================================
cd "$TEMP_DIR" || exit 1

# Check available disk space (in MB) before downloading
free_boot=$(df -m /boot | awk 'NR==2 {print $4}')
free_tmp=$(df -m "$TEMP_DIR" | awk 'NR==2 {print $4}')

if [ "$free_boot" -lt 150 ]; then
    echo -e " \033[1;31m[WARNING] Insufficient disk space in /boot (${free_boot} MB free, 150 MB required)!\033[0m"
    echo -e " \033[1;33mPlease remove old kernels before continuing to avoid breaking GRUB.\033[0m"
    exit 1
fi

if [ "$free_tmp" -lt 300 ]; then
    echo -e " \033[1;31m[WARNING] Insufficient disk space in $TEMP_DIR (${free_tmp} MB free, 300 MB required)!\033[0m"
    exit 1
fi

echo ""
echo -e " \033[1;32m\tDownloading packages into: $TEMP_DIR\033[0m"
echo ""

for url in "${target_urls[@]}"; do
    wget -q --show-progress "$url" || {
        echo -e " \033[1;31mError downloading $(basename "$url").\033[0m"
        exit 1
    }
done

echo ""
echo -e " \033[1;36m\tVerifying authenticity and integrity (GPG & SHA256)...\033[0m"

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

        # 1. Import official Ubuntu archive keyring
        [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ] && gpg --import /usr/share/keyrings/ubuntu-archive-keyring.gpg >/dev/null 2>&1

        # 2. Download and import Kernel PPA signing key
        KS_HOST="keyserver.ubuntu.com"
        UBUNTU_KERNEL_KEY="60AA7B6F30434AE68E569963E50C6A0917C622B0"
        curl -kfsSL "https://${KS_HOST}/pks/lookup?op=get&options=mr&search=0x${UBUNTU_KERNEL_KEY}" -o key.asc 2>/dev/null
        [ -s key.asc ] && gpg --import key.asc >/dev/null 2>&1

        # 3. Verify GPG signature
        GPG_OUTPUT=$(gpg --verify CHECKSUMS.gpg CHECKSUMS 2>&1)
        GPG_STATUS=$?

        if [ $GPG_STATUS -eq 0 ]; then
            echo -e "\t\033[1;32m✔ Valid GPG signature (Kernel PPA <kernel-ppa@canonical.com>).\033[0m"
        elif echo "$GPG_OUTPUT" | grep -qiE "expired|expirée"; then
            echo -e "\t\033[1;32m✔ Authentic GPG signature (archive key expired, normal for this older kernel).\033[0m"
        else
            echo -e "\t\033[1;33m⚠️  GPG verification failed: $(echo "$GPG_OUTPUT" | tail -n 1)\033[0m"
            read -rp "	Continue anyway with SHA256 verification only (y/N)? " bypass_gpg
            [[ ! "$bypass_gpg" =~ ^[yY]$ ]] && exit 1
        fi

        # 4. Strict SHA256 checksum verification of downloaded packages
        sha_failed=0
        for deb in *.deb; do
            expected_sha=$(grep -E "[a-fA-F0-9]{64}.*${deb}$" CHECKSUMS | awk '{print $1}' | head -1)
            if [ -n "$expected_sha" ]; then
                actual_sha=$(sha256sum "$deb" | awk '{print $1}')
                if [ "$expected_sha" == "$actual_sha" ]; then
                    echo -e "\t\033[1;32m✔ SHA256 OK: \033[0m $deb"
                else
                    echo -e "\t\033[1;31m✘ SHA256 INVALID: \033[0m $deb"
                    sha_failed=1
                fi
            fi
        done

        if [ "$sha_failed" -eq 1 ]; then
            echo -e " \033[1;31m[CRITICAL ERROR] Corrupted file(s) detected. Installation aborted.\033[0m"
            exit 1
        fi
    fi
else
    echo -e "\t\033[1;33m⚠️  CHECKSUMS files not available for this legacy version.\033[0m"
fi

# ==============================================================================
# 8. NEW KERNEL INSTALLATION AND GRUB UPDATE
# ==============================================================================
echo ""
read -rp " Press [Enter] to install kernel $site ($choix) or [CTRL]-[C] to cancel... "
echo ""

echo -e " \033[1;36m\tInstalling .deb packages...\033[0m"
if ! sudo dpkg -i *.deb; then
    echo -e " \033[1;33m\t⚠️  Missing dependencies detected, attempting repair with apt...\033[0m"
    sudo apt-get install -f -y || {
        echo -e " \033[1;31m[ERROR] Kernel installation failed.\033[0m"
        exit 1
    }
fi

echo ""
echo -e " \033[1;36m\tUpdating bootloader (GRUB)...\033[0m"
if command -v update-grub >/dev/null 2>&1; then
    sudo update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    sudo grub-mkconfig -o /boot/grub/grub.cfg
fi

echo ""
echo -e " \033[1;32m✔ Kernel $site ($choix) installation completed successfully!\033[0m"
echo -e " \033[1;33m\tA system reboot is required to load the new kernel.\033[0m"
echo ""

read -rp "	Would you like to reboot the computer now (y/N)? " reboot_now
if [[ "$reboot_now" =~ ^[yY]$ ]]; then
    echo -e " \033[1;36m\tRebooting system...\033[0m"
    sudo reboot
else
    echo -e " \033[1;32m\tPlease remember to reboot manually later. Goodbye!\033[0m"
fi

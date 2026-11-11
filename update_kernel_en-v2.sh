#!/bin/bash
# ==============================================================================
# Automated Linux Kernel Update (Ubuntu Mainline)
# Original Author : RISTOVSKI Nicolas (2016-11)
# Update & Refactor : 2026-11 (HTTPS, Grid, Anti-Cache, GPG/SHA256, DKMS/UEFI)
# ==============================================================================

set -o pipefail
clear

# ==============================================================================
# 1. TEMPORARY DIRECTORY MANAGEMENT, CLEANUP AND STRICT Y/N INPUT
# ==============================================================================
TEMP_DIR=$(mktemp -d /tmp/kernel_update_XXXXXX) || {
    echo "Critical error: Unable to create temporary directory."
    exit 1
}

cleanup() {
    tput cnorm 2>/dev/null || true
    stty sane 2>/dev/null || true

    if [ -d "$TEMP_DIR/.gnupg" ]; then
        GNUPGHOME="$TEMP_DIR/.gnupg" gpgconf --kill all >/dev/null 2>&1 || true
    fi
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

on_interrupt() {
    echo ""
    echo -e " \033[1;33mInterrupted by user (CTRL+C). Cleaning up...\033[0m"
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# Strict confirmation function: accepts only y/Y or n/N keys
ask_yn() {
    local prompt="$1"
    local ans
    echo -ne "$prompt"
    while true; do
        read -rsn1 ans
        case "$ans" in
            [yY]) echo "y"; return 0 ;;
            [nN]) echo "n"; return 1 ;;
        esac
    done
}

# ==============================================================================
# 2. DISK SPACE, NETWORK, SECURE BOOT, DKMS AND DEPENDENCIES CHECK
# ==============================================================================
free_boot=$(df -Pm /boot | awk 'NR==2 {print $4}')
free_tmp=$(df -Pm "$TEMP_DIR" | awk 'NR==2 {print $4}')

if [ "$free_boot" -lt 250 ]; then
    echo -e " \033[1;31m[ALERT] Insufficient space in /boot (${free_boot} MB free, 250 MB required)!\033[0m"
    echo -e " \033[1;33mRemove old kernels to avoid breaking GRUB during installation.\033[0m"
    if ask_yn " Do you want to run 'sudo apt-get autoremove --purge' now (y/n)? "; then
        echo ""
        sudo apt-get autoremove --purge -y
        free_boot=$(df -Pm /boot | awk 'NR==2 {print $4}')
        if [ "$free_boot" -lt 250 ]; then
            echo -e " \033[1;31mStill insufficient space in /boot (${free_boot} MB free). Aborting.\033[0m"
            exit 1
        fi
        echo -e " \033[1;32mSpace freed in /boot: ${free_boot} MB available.\033[0m"
        echo ""
    else
        exit 1
    fi
fi

if [ "$free_tmp" -lt 350 ]; then
    echo -e " \033[1;31m[ALERT] Insufficient space in $TEMP_DIR (${free_tmp} MB free, 350 MB required)!\033[0m"
    exit 1
fi

echo -n "Checking internet connection... "
if command -v curl >/dev/null 2>&1; then
    network_ok=$(curl -sI --connect-timeout 5 --max-time 8 https://kernel.ubuntu.com/mainline/ >/dev/null 2>&1 && echo "1" || echo "0")
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
echo ""

# Check UEFI Secure Boot status
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
        echo -e "\033[1;33m⚠️  [UEFI SECURE BOOT WARNING]\033[0m"
        echo -e "\033[0;33m   Ubuntu Mainline kernels are not signed for Secure Boot.\033[0m"
        echo -e "\033[0;33m   The system will refuse to boot this kernel while Secure Boot is active.\033[0m"
        if ! ask_yn "   Do you still want to continue (y/n)? "; then
            exit 0
        fi
        echo ""
    fi
fi

# Check active DKMS modules
if command -v dkms >/dev/null 2>&1; then
    dkms_list=$(dkms status 2>/dev/null || true)
    if [ -n "$dkms_list" ]; then
        echo -e "\033[1;33m⚠️  [DKMS MODULES DETECTED]\033[0m"
        echo -e "\033[0;33m   External drivers built via DKMS are present on your system:\033[0m"
        echo "$dkms_list" | sed 's/^/     - /'
        echo -e "\033[0;33m   A much newer kernel may cause these drivers to fail building.\033[0m"
        read -rp "   Press [Enter] to continue or [CTRL]-[C] to cancel... "
        echo ""
    fi
fi

# Install required tools (wget, gnupg, curl)
MISSING_PKGS=()
command -v wget >/dev/null 2>&1 || MISSING_PKGS+=("wget")
command -v gpg  >/dev/null 2>&1 || MISSING_PKGS+=("gnupg")
command -v curl >/dev/null 2>&1 || MISSING_PKGS+=("curl")

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
# 4. REAL-TIME FETCHING AND GRID PAGINATION (HTTPS + ANTI-CACHE)
# ==============================================================================
BASE_URL="https://kernel.ubuntu.com/mainline/"
echo "Fetching and verifying kernel versions in real time from Ubuntu Mainline..."
echo -e "\033[0;33mNote: Release Candidate (RC) test versions are excluded from the list.\033[0m"

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
    echo -e "\033[1;31mError: Unable to retrieve kernel list from $BASE_URL.\033[0m"
    exit 1
fi

check_count=5
[ "$total_versions" -lt "$check_count" ] && check_count=$total_versions

for ((i = total_versions - 1; i >= total_versions - check_count; i--)); do
    test_url="${all_versions[$i]}"
    page_root=$(curl -sL --connect-timeout 3 --max-time 5 -H "Cache-Control: no-cache" "$test_url" 2>/dev/null || true)
    page_arch=$(curl -sL --connect-timeout 3 --max-time 5 -H "Cache-Control: no-cache" "${test_url}${arch}/" 2>/dev/null || true)
    # Strict check for architecture-specific packages (_${arch}.deb)
    if ! printf "%s\n%s\n" "$page_root" "$page_arch" | grep -qE "_${arch}\.deb"; then
        unset 'all_versions[i]'
    fi
done

all_versions=("${all_versions[@]}")
total_versions=${#all_versions[@]}

if [ "$total_versions" -eq 0 ]; then
    echo -e "\033[1;31mError: No valid kernel found for architecture '$arch'.\033[0m"
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
    print_centered "\033[1;36m[ Automated Linux Kernel Update ]\033[0m"
    print_centered "\033[0;37m... RISTOVSKI Nicolas (2016-11) ...\033[0m"
    print_centered "\033[0;37mupdate: (2026-11)\033[0m"
    echo ""
    print_centered "\033[1;37mDetected architecture: \033[1;33m${arch}\033[0m   |   \033[0;37m(RC kernels excluded)\033[0m"
    echo ""
}

display_menu() {
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
    print_centered "\033[1;36m--- Page $real_page/$max_pages | [Arrows]: Navigate | [-]: Previous | [+]: Next | [Enter]: Confirm ---\033[0m"
    echo -ne "\033[J"
}

while true; do
    display_menu
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 -t 0.5 key
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

tput cnorm 2>/dev/null || true

# ==============================================================================
# 5. PACKAGE SEARCH AND VARIANT SELECTION (GENERIC / LOWLATENCY)
# ==============================================================================
clear
echo ""
kernelURL="${versions_list[$active_index]}"
site=$(basename "$kernelURL")
site2="${site#v}"

echo -e " \033[1m   Selected version for installation : \033[1;32m$site\033[0m ($kernelURL)"
echo -e " \033[1;36m   Currently running kernel version  : $(uname -r)\033[0m"
echo ""
echo -e " \033[1;32m   Kernels currently installed in /boot :\033[0m"
ls /boot 2>/dev/null | grep initrd | cut -d- -f2,3,4 | sed 's/^/\t/' || true
echo ""

echo -e "    \033[1;4;36m--- Searching for remote packages on the server ---\033[0m"

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
    echo -e "\t\033[1;31mError: No .deb packages found for architecture '$arch'.\033[0m"
    exit 1
fi

# Suppress lowlatency prompt if no lowlatency package filename exists for this version
has_lowlatency=0
for u in "${liste_debs[@]}"; do
    if [[ "$(basename "$u")" == *lowlatency* ]]; then
        has_lowlatency=1
        break
    fi
done

if [ "$has_lowlatency" -eq 1 ]; then
    if ask_yn "\033[3m\tDo you want to install the 'lowlatency' variant (y/n)? \033[0m"; then
        low=1
        choix="lowlatency"
    else
        low=0
        choix="generic"
    fi
    echo ""
else
    low=0
    choix="generic"
    echo -e "\t\033[0;36mℹ️  'lowlatency' variant not available for $site: automatically selecting 'generic'.\033[0m"
    echo ""
fi

if ls /boot/initrd.img-"${site2}"*-"${choix}" >/dev/null 2>&1; then
    echo -e " \033[1;31m   [ABORTED] Linux kernel $site ($choix) is already installed on your system!\033[0m"
    exit 0
fi

# Safe handling of multiple revisions (headers_all.deb may retain initial build timestamp)
latest_arch_rev=$(printf "%s\n" "${liste_debs[@]}" | grep -E "_${arch}\.deb$" | grep "$choix" | grep -oE "[0-9]{8,12}" | sort -V | tail -1 || true)
latest_all_rev=$(printf "%s\n" "${liste_debs[@]}" | grep -E "_all\.deb$" | grep -oE "[0-9]{8,12}" | sort -V | tail -1 || true)

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
    echo -e "\t\033[1;31mError: Unable to identify packages to download.\033[0m"
    exit 1
fi

# Build completeness check (image, modules, headers)
has_image=$(printf "%s\n" "${target_urls[@]}" | grep -c "linux-image-" || true)
has_modules=$(printf "%s\n" "${target_urls[@]}" | grep -c "linux-modules-" || true)
has_headers=$(printf "%s\n" "${target_urls[@]}" | grep -c "linux-headers-" || true)

if [ "$has_image" -eq 0 ] || [ "$has_modules" -eq 0 ] || [ "$has_headers" -lt 2 ]; then
    echo -e "\t\033[1;33m⚠️  [INCOMPLETE BUILD WARNING]\033[0m"
    echo -e "\t\033[0;33m   Some standard components appear to be missing (image:$has_image, modules:$has_modules, headers:$has_headers).\033[0m"
    echo -e "\t\033[0;33m   The build on Ubuntu Mainline servers may have partially failed.\033[0m"
    if ! ask_yn "\tContinue anyway (y/n)? "; then
        exit 1
    fi
    echo ""
fi

echo -e " \033[1;3;32m   Kernel ready for download: $site ($choix)\033[0m"
for url in "${target_urls[@]}"; do
    echo -e "\t\033[1;3;36m-> $(basename "$url")\033[0m"
done
echo -e "    \033[4;36m______________________________________________________________\033[0m"
echo ""

echo -e "\t\033[1;4;92m  Press [Enter] to start download and GPG verification!\033[0m"
echo -e "\t\033[1;31m  Or [CTRL]-[C] to cancel and exit...\033[0m"

while true; do
    read -rsn1 key
    [[ "$key" == "" ]] && break
done

# ==============================================================================
# 6. DOWNLOAD AND CRYPTOGRAPHIC VERIFICATION (GPG + SHA256)
# ==============================================================================
cd "$TEMP_DIR" || exit 1

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

# Fetch checksum files (arch subdirectory + root)
curl -fsSL --connect-timeout 5 --max-time 10 "${pkg_base_url}CHECKSUMS" -o CHECKSUMS_ARCH 2>/dev/null || rm -f CHECKSUMS_ARCH
curl -fsSL --connect-timeout 5 --max-time 10 "${pkg_base_url}CHECKSUMS.gpg" -o CHECKSUMS_ARCH.gpg 2>/dev/null || rm -f CHECKSUMS_ARCH.gpg
curl -fsSL --connect-timeout 5 --max-time 10 "${kernelURL}CHECKSUMS" -o CHECKSUMS_ROOT 2>/dev/null || rm -f CHECKSUMS_ROOT
curl -fsSL --connect-timeout 5 --max-time 10 "${kernelURL}CHECKSUMS.gpg" -o CHECKSUMS_ROOT.gpg 2>/dev/null || rm -f CHECKSUMS_ROOT.gpg

# Prepare GPG environment
export GNUPGHOME="$TEMP_DIR/.gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ] && gpg --import /usr/share/keyrings/ubuntu-archive-keyring.gpg >/dev/null 2>&1 || true

KS_HOST="keyserver.ubuntu.com"
UBUNTU_KERNEL_KEY="60AA7B6F30434AE68E569963E50C6A0917C622B0"
if curl -fsSL --connect-timeout 5 --max-time 10 "https://${KS_HOST}/pks/lookup?op=get&options=mr&search=0x${UBUNTU_KERNEL_KEY}" -o key.asc 2>/dev/null && [ -s key.asc ]; then
    if gpg --with-colons --import-options show-only --import key.asc 2>/dev/null | grep -q "fpr:::::::::${UBUNTU_KERNEL_KEY}:"; then
        gpg --import key.asc >/dev/null 2>&1 || true
    else
        echo -e "\t\033[1;31m[SECURITY ALERT] Downloaded GPG key fingerprint mismatch!\033[0m"
    fi
fi

# Detect detached signature (.gpg) or inline clearsigned signature
VERIFIED_DATA_FILE=""
gpg_valid=0

if [ -s CHECKSUMS_ARCH ] && [ -s CHECKSUMS_ARCH.gpg ]; then
    GPG_STATUS_OUT=$(LC_ALL=C gpg --status-fd 1 --verify CHECKSUMS_ARCH.gpg CHECKSUMS_ARCH 2>&1 || true)
    VERIFIED_DATA_FILE="CHECKSUMS_ARCH"
elif [ -s CHECKSUMS_ROOT ] && [ -s CHECKSUMS_ROOT.gpg ]; then
    GPG_STATUS_OUT=$(LC_ALL=C gpg --status-fd 1 --verify CHECKSUMS_ROOT.gpg CHECKSUMS_ROOT 2>&1 || true)
    VERIFIED_DATA_FILE="CHECKSUMS_ROOT"
elif [ -s CHECKSUMS_ARCH ] && grep -q "BEGIN PGP SIGNED MESSAGE" CHECKSUMS_ARCH; then
    GPG_STATUS_OUT=$(LC_ALL=C gpg --status-fd 1 --decrypt CHECKSUMS_ARCH > CHECKSUMS_ARCH_EXTRACTED 2>&1 || true)
    [ -s CHECKSUMS_ARCH_EXTRACTED ] && VERIFIED_DATA_FILE="CHECKSUMS_ARCH_EXTRACTED"
elif [ -s CHECKSUMS_ROOT ] && grep -q "BEGIN PGP SIGNED MESSAGE" CHECKSUMS_ROOT; then
    GPG_STATUS_OUT=$(LC_ALL=C gpg --status-fd 1 --decrypt CHECKSUMS_ROOT > CHECKSUMS_ROOT_EXTRACTED 2>&1 || true)
    [ -s CHECKSUMS_ROOT_EXTRACTED ] && VERIFIED_DATA_FILE="CHECKSUMS_ROOT_EXTRACTED"
fi

if [ -n "$VERIFIED_DATA_FILE" ]; then
    if echo "$GPG_STATUS_OUT" | grep -q "^\[GNUPG:\] GOODSIG"; then
        echo -e "\t\033[1;32m✔ Valid GPG signature (Kernel PPA <kernel-ppa@canonical.com>).\033[0m"
        gpg_valid=1
    elif echo "$GPG_STATUS_OUT" | grep -q "^\[GNUPG:\] EXPKEYSIG"; then
        echo -e "\t\033[1;32m✔ Authentic GPG signature (archive key expired, expected for older kernels).\033[0m"
        gpg_valid=1
    else
        echo -e "\t\033[1;33m⚠️  GPG verification failed: $(echo "$GPG_STATUS_OUT" | grep -v "^\[GNUPG:\]" | tail -n 1)\033[0m"
        if ! ask_yn "\tContinue anyway (y/n)? "; then
            exit 1
        fi
    fi
elif [ -s CHECKSUMS_ARCH ]; then
    VERIFIED_DATA_FILE="CHECKSUMS_ARCH"
elif [ -s CHECKSUMS_ROOT ]; then
    VERIFIED_DATA_FILE="CHECKSUMS_ROOT"
fi

# Verify SHA256 hashes if a CHECKSUMS file is available (silent if absent)
if [ -n "$VERIFIED_DATA_FILE" ] && [ -s "$VERIFIED_DATA_FILE" ]; then
    tr -d '\r' < "$VERIFIED_DATA_FILE" | awk '
        length($1) == 64 && $1 ~ /^[a-fA-F0-9]+$/ {
            file = $NF
            sub(/^.*\//, "", file)
            sub(/^\*/, "", file)
            print tolower($1) "  " file
        }
    ' > CHECKSUMS_CLEAN

    sha_failed=0
    for deb in *.deb; do
        matched_line=$(awk -v f="$deb" '$2 == f { print $0; exit }' CHECKSUMS_CLEAN)
        if [ -n "$matched_line" ]; then
            if printf "%s\n" "$matched_line" | sha256sum --status -c - 2>/dev/null; then
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

# ==============================================================================
# 7. NEW KERNEL INSTALLATION AND GRUB UPDATE
# ==============================================================================
echo ""
read -rp " Press [Enter] to install kernel $site ($choix) or [CTRL]-[C] to cancel... "
echo ""

if ! sudo -v; then
    echo -e " \033[1;31m[ERROR] Administrator (sudo) privileges required for installation.\033[0m"
    exit 1
fi

echo -e " \033[1;36m\tInstalling .deb packages via apt (resolving dependencies)...\033[0m"
if ! sudo apt-get install -y --allow-downgrades ./*.deb; then
    echo -e " \033[1;31m[ERROR] Kernel installation failed (incompatible dependencies or held package).\033[0m"
    exit 1
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

if ask_yn "\tDo you want to reboot the computer now (y/n)? "; then
    echo -e " \033[1;36m\tRebooting system...\033[0m"
    sudo reboot
else
    echo -e " \033[1;32m\tRemember to reboot manually later. Goodbye!\033[0m"
fi

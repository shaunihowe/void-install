#!/usr/bin/env bash
# Void Linux whole-disk installer. Edit this block, read README.md, then run as root.
# This script ERASES the selected disk. --check performs preflight only.

# ----------------------------- Configuration -----------------------------
DISK=""                       # e.g. /dev/nvme0n1; /dev/disk/by-id/... is preferred
ERASE_DISK=false               # Explicit authorization to erase DISK; no extra prompt
HOSTNAME="void"
LOCALE="en_GB.UTF-8"
KEYMAP="uk"                   # Linux console (kbd) name
XKB_LAYOUT="gb"               # Xorg greeter and Wayland keyboard name
XKB_VARIANT=""
NATURAL_SCROLL=false         # true reverses touchpad scrolling
TIMEZONE="Europe/London"
HARDWARECLOCK="UTC"           # UTC or localtime; UTC is recommended
EFI_MIB=512
BOOT_MIB=2048
SWAP_MIB=8192                 # 0 disables swap; hibernation is not configured
QUIET_BOOT=true
BOOT_MESSAGE="Booting Void Linux..."
REPOSITORY="https://repo-default.voidlinux.org/current"

CORE_PACKAGES=(
    base-system linux cryptsetup grub-x86_64-efi efibootmgr
    e2fsprogs dosfstools kbd tzdata glibc-locales sudo NetworkManager
    xorg lxqt lxqt-wayland-session labwc sddm dbus elogind
    qt6-wayland qt5-wayland mesa-dri xorg-server-xwayland
    network-manager-applet pulseaudio pavucontrol pipewire
    swaylock swayidle wlopm brightnessctl
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr slurp
    gvfs udisks2 plymouth dejavu-fonts-ttf qps mousepad parole
)
PACKAGES=(
    firefox git vim clang make
)
SERVICES=(
    # Additional services whose packages you have included above, e.g. chronyd
)
# --------------------------- End configuration ---------------------------

# No passwords are accepted from the environment or written to configuration.
TARGET=""
WORKDIR=""
CRYPT_NAME=""
CRYPT_OPEN=false
STAGE="initialization"
DISK_ID=""
ROOT_UUID=""
BOOT_UUID=""
EFI_UUID=""
LUKS_UUID=""
INSTALL_PACKAGES=()
MOUNTS=()

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: bash install-void.sh [--check | --help]

Edit the configuration block first. Normal execution erases DISK when
ERASE_DISK=true. Use an official x86_64 glibc Void live USB, booted in UEFI
mode with Secure Boot disabled and internet already connected.

--check  Validate settings, disk safety, tools, and the package transaction.
         Does not install packages, partition, format, mount, or ask for secrets.
         Temporary repository metadata is removed on exit.
--help   Show this help without requiring root or Void Linux.
EOF
}

require_commands() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 || die "Missing command: $command"
    done
}

validate_config() {
    local name value package service required found
    [[ -n $DISK && $DISK == /dev/* && $DISK != *[[:space:]]* ]] ||
        die 'Set DISK to the whole disk you intend to erase.'
    [[ $ERASE_DISK == true || $ERASE_DISK == false ]] || die 'ERASE_DISK must be true or false.'
    [[ $QUIET_BOOT == true || $QUIET_BOOT == false ]] || die 'QUIET_BOOT must be true or false.'
    [[ $NATURAL_SCROLL == true || $NATURAL_SCROLL == false ]] || die 'NATURAL_SCROLL must be true or false.'
    [[ $HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
        die 'HOSTNAME must be a single valid hostname label (1–63 characters).'
    [[ $LOCALE =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || die 'Use a locale such as en_GB.UTF-8.'
    [[ $KEYMAP =~ ^[a-zA-Z0-9_-]+$ ]] || die 'KEYMAP must be a kbd keymap name.'
    [[ $XKB_LAYOUT =~ ^[a-zA-Z0-9_-]+$ ]] || die 'XKB_LAYOUT must be a single XKB layout name.'
    [[ $XKB_VARIANT =~ ^[a-zA-Z0-9_-]*$ ]] || die 'XKB_VARIANT must be empty or a single XKB variant.'
    [[ $TIMEZONE =~ ^[a-zA-Z0-9_+/-]+$ && $TIMEZONE != /* && $TIMEZONE != *..* ]] ||
        die 'Invalid TIMEZONE path.'
    [[ -f /usr/share/zoneinfo/$TIMEZONE ]] || die "Unknown timezone: $TIMEZONE"
    [[ $HARDWARECLOCK == UTC || $HARDWARECLOCK == localtime ]] || die 'HARDWARECLOCK must be UTC or localtime.'
    # Restrict generated Plymouth/GRUB strings to inert printable characters.
    [[ -n $BOOT_MESSAGE && ${#BOOT_MESSAGE} -le 100 && $BOOT_MESSAGE =~ ^[a-zA-Z0-9\ .,:!?_-]+$ ]] ||
        die 'BOOT_MESSAGE must be 1–100 letters, numbers, spaces, or .,:!?_- characters.'
    [[ $REPOSITORY =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/[a-zA-Z0-9/_-]+$ &&
       $REPOSITORY != */musl* ]] || die 'REPOSITORY must be an HTTPS Void glibc repository URL.'
    for name in EFI_MIB BOOT_MIB SWAP_MIB; do
        value=${!name}
        [[ $value =~ ^(0|[1-9][0-9]*)$ && ${#value} -le 7 ]] || die "$name must be a nonnegative integer in MiB."
        (( value <= 1048576 )) || die "$name exceeds the supported 1 TiB limit."
    done
    (( EFI_MIB >= 260 && BOOT_MIB >= 512 )) || die 'EFI_MIB must be at least 260 and BOOT_MIB at least 512.'
    (( ${#CORE_PACKAGES[@]} > 0 )) || die 'CORE_PACKAGES cannot be empty.'
    INSTALL_PACKAGES=()
    for package in "${CORE_PACKAGES[@]}" "${PACKAGES[@]}"; do
        [[ $package =~ ^[a-zA-Z0-9][a-zA-Z0-9+_.-]*$ ]] || die "Invalid package name: $package"
        found=false
        for value in "${INSTALL_PACKAGES[@]}"; do
            [[ $value != "$package" ]] || found=true
        done
        $found || INSTALL_PACKAGES+=("$package")
    done
    # Avoid generating an unbootable system if a required core entry was removed.
    for required in base-system linux cryptsetup grub-x86_64-efi efibootmgr \
        e2fsprogs dosfstools kbd tzdata glibc-locales sudo NetworkManager \
        xorg lxqt lxqt-wayland-session labwc sddm dbus elogind \
        qt6-wayland qt5-wayland mesa-dri xorg-server-xwayland \
        network-manager-applet pulseaudio pavucontrol pipewire \
        swaylock swayidle wlopm brightnessctl xdg-desktop-portal \
        xdg-desktop-portal-gtk xdg-desktop-portal-wlr slurp \
        gvfs udisks2 plymouth dejavu-fonts-ttf qps mousepad parole; do
        found=false
        for package in "${INSTALL_PACKAGES[@]}"; do
            [[ $package != "$required" ]] || found=true
        done
        $found || die "Required core package was removed: $required"
    done
    for service in "${SERVICES[@]}"; do
        [[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]] || die "Invalid service name: $service"
        case $service in
            dhcpcd|wpa_supplicant|iwd|wicd|connmand|acpid|gdm|lightdm|greetd|sddm-lxqt|agetty-tty1|agetty-tty7)
                die "Service conflicts with the configured desktop: $service" ;;
        esac
    done
}

validate_environment() {
    (( EUID == 0 )) || die 'Run as root from a Void live USB.'
    [[ $(uname -m) == x86_64 ]] || die 'Only x86_64 is supported.'
    [[ -d /sys/firmware/efi ]] || die 'Boot the live USB in UEFI mode.'
    if [[ -f /sys/firmware/efi/fw_platform_size ]]; then
        [[ $(cat /sys/firmware/efi/fw_platform_size) == 64 ]] || die '64-bit UEFI firmware is required.'
    fi
    [[ -f /etc/os-release ]] || die 'Cannot identify the live system.'
    # shellcheck disable=SC1091
    ( . /etc/os-release; [[ $ID == void ]] ) || die 'Use an official Void Linux live USB.'
    require_commands xbps-install xbps-query xbps-uhelper
    [[ $(xbps-uhelper arch) == x86_64 ]] || die 'Use the x86_64 glibc live image.'
    [[ -d /var/db/xbps/keys ]] || die 'The live image has no trusted XBPS keys.'
    validate_secure_boot /sys/firmware/efi/efivars
}

validate_secure_boot() {
    local efivars=${1:-/sys/firmware/efi/efivars} secure_var value
    require_commands mountpoint od
    mountpoint -q "$efivars" || die 'Mount efivarfs before installation so firmware state and boot entries are accessible.'
    for secure_var in "$efivars"/SecureBoot-*; do
        # Firmware built without Secure Boot support (including plain OVMF) does
        # not expose this variable. A mounted efivarfs distinguishes that case
        # from an inaccessible variable store.
        if [[ ! -e $secure_var ]]; then
            say 'Firmware does not expose Secure Boot; using unsigned UEFI boot'
            return
        fi
        [[ -r $secure_var ]] || die 'Cannot read the firmware Secure Boot variable.'
        value=$(od -An -tu1 -j4 -N1 "$secure_var")
        [[ ${value//[[:space:]]/} == 0 ]] || die 'Disable Secure Boot in firmware before installing.'
    done
}

ensure_live_tools() {
    local check_only=$1 pair tool package
    local live_packages=()
    for pair in cryptsetup:cryptsetup sfdisk:util-linux mkfs.ext4:e2fsprogs \
        mkfs.vfat:dosfstools loadkeys:kbd; do
        tool=${pair%%:*}
        package=${pair#*:}
        command -v "$tool" >/dev/null 2>&1 || live_packages+=("$package")
    done
    [[ -d /usr/share/X11/xkb/symbols ]] || live_packages+=(xkeyboard-config)
    if (( ${#live_packages[@]} > 0 )); then
        [[ $check_only != true ]] || die 'Live tools are missing; install cryptsetup util-linux e2fsprogs dosfstools kbd xkeyboard-config, then repeat --check.'
        say 'Installing missing tools into the live environment'
        # Older official ISOs require an XBPS self-update before any other
        # transaction against the rolling repository can be performed.
        xbps-install -S -y -u -i -R "$REPOSITORY" xbps </dev/null
        xbps-install -S -y -i -R "$REPOSITORY" "${live_packages[@]}" </dev/null
    fi
    require_commands cryptsetup sfdisk mkfs.ext4 mkfs.vfat loadkeys lsblk blockdev \
        findmnt swapon udevadm mount umount mountpoint chroot blkid flock \
        awk sed sort od dd mkswap readlink mktemp install cp chmod chown stat find
    loadkeys --parse --quiet "$KEYMAP" </dev/null || die "Cannot parse keymap: $KEYMAP"
    [[ -f /usr/share/X11/xkb/symbols/$XKB_LAYOUT ]] || die "Unknown XKB layout: $XKB_LAYOUT"
    if [[ -n $XKB_VARIANT ]]; then
        grep -Eq "xkb_symbols[[:space:]]+\"$XKB_VARIANT\"" "/usr/share/X11/xkb/symbols/$XKB_LAYOUT" ||
            die "Unknown XKB variant: $XKB_LAYOUT/$XKB_VARIANT"
    fi
    [[ -f /etc/default/libc-locales ]] || die 'The live image has no glibc locale list.'
    awk -v locale="$LOCALE" '
        { sub(/^[#[:space:]]+/, ""); if ($1 == locale && $2 == "UTF-8") found=1 }
        END { exit !found }
    ' /etc/default/libc-locales || die "Unknown glibc locale: $LOCALE"
}

is_block_device() { [[ -b $1 ]]; }

device_has_holders() {
    local entry
    for entry in /sys/class/block/"${1##*/}"/holders/*; do
        [[ ! -e $entry ]] || return 0
    done
    return 1
}

validate_disk() {
    local resolved disk_type write_protected mounted nodes node swaps swap identity
    resolved=$(readlink -f -- "$DISK") || die "Cannot resolve disk: $DISK"
    is_block_device "$resolved" || die "Not a block device: $DISK"
    DISK=$resolved
    disk_type=$(lsblk -dnro TYPE "$DISK") || die 'Cannot inspect target disk.'
    [[ $disk_type == disk ]] || die 'DISK must be a whole physical/virtual disk, not a partition, loop device, or mapper.'
    write_protected=$(blockdev --getro "$DISK") || die 'Cannot read disk write protection.'
    [[ $write_protected == 0 ]] || die 'The target disk is read-only.'
    mounted=$(lsblk -nro MOUNTPOINTS "$DISK") || die 'Cannot inspect target mounts.'
    [[ ! $mounted =~ [^[:space:]] ]] || die 'The target disk or one of its descendants is mounted or used as swap. Unmount it first; never select the live USB.'
    nodes=$(lsblk -nrpo NAME "$DISK") || die 'Cannot inspect target descendants.'
    [[ -n $nodes ]] || die 'The target disk has no identifiable block nodes.'
    swaps=$(swapon --show --noheadings --raw --output NAME) || die 'Cannot inspect active swap.'
    while IFS= read -r node; do
        device_has_holders "$node" && die "Active block-device holder on $node; deactivate it first."
        while IFS= read -r swap; do
            [[ -n $swap ]] || continue
            [[ $(readlink -f -- "$swap") != "$node" ]] || die "Active swap on $node."
        done <<< "$swaps"
    done <<< "$nodes"
    identity=$(lsblk -dnro MAJ:MIN,SIZE,MODEL,SERIAL,WWN "$DISK") || die 'Cannot identify target device.'
    [[ -n $identity ]] || die 'Empty target device identity.'
    [[ -z $DISK_ID || $DISK_ID == "$identity" ]] || die 'Target device changed during preflight.'
    DISK_ID=$identity
}

copy_trusted_keys() {
    local destination=$1 key count=0
    install -d -m 755 "$destination/var/db/xbps/keys"
    for key in /var/db/xbps/keys/*.plist; do
        [[ -f $key ]] || continue
        cp -- "$key" "$destination/var/db/xbps/keys/"
        (( count += 1 ))
    done
    (( count > 0 )) || die 'No trusted XBPS signing keys found on the live image.'
}

check_capacity() {
    local installed_bytes=$1 download_bytes=${2:-0} disk_bytes minimum_mib root_mib
    disk_bytes=$(blockdev --getsize64 "$DISK") || die 'Cannot read disk capacity.'
    [[ $disk_bytes =~ ^[0-9]+$ ]] || die 'Invalid disk capacity.'
    # Downloaded archives remain in /var/cache/xbps while files are unpacked.
    minimum_mib=$(( (installed_bytes + download_bytes + 1048575) / 1048576 + 4096 ))
    (( minimum_mib >= 8192 )) || minimum_mib=8192
    minimum_mib=$(( minimum_mib + SWAP_MIB ))
    # Leave room for GPT alignment, the LUKS2 header/keyslots, and metadata.
    root_mib=$(( disk_bytes / 1048576 - EFI_MIB - BOOT_MIB - 64 ))
    (( root_mib >= minimum_mib )) || die "Disk is too small: encrypted root needs at least ${minimum_mib} MiB including swap and free space."
}

check_repository() {
    local installed_bytes download_bytes sizes status=0 package
    STAGE='repository and package preflight'
    WORKDIR=$(mktemp -d /tmp/void-install.XXXXXXXX)
    chmod 700 "$WORKDIR"
    copy_trusted_keys "$WORKDIR/probe"
    say 'Checking the signed repository and resolving all requested packages'
    # Dry run + in-memory repository sync; never import an unknown key interactively.
    XBPS_ARCH=x86_64 xbps-install -M -n -i -R "$REPOSITORY" -r "$WORKDIR/probe" \
        "${INSTALL_PACKAGES[@]}" </dev/null >"$WORKDIR/packages.plan" 2>"$WORKDIR/repository.log" || status=$?
    # XBPS emits a complete dry-run plan but returns ENOSPC (28) when the live
    # RAM filesystem is smaller than the proposed installation. That is not the
    # destination disk. Accept ONLY that status, then validate the complete plan
    # and independently check the real destination's capacity below.
    if (( status != 0 && status != 28 )); then
        cat "$WORKDIR/repository.log" >&2
        die "Repository/package resolution failed (XBPS exit $status)."
    fi
    for package in "${INSTALL_PACKAGES[@]}"; do
        awk -v package="$package" '
            NF == 6 && $2 == "install" && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ {
                name=$1; sub(/-[^-]+$/, "", name); if (name == package) found=1
            }
            END { exit !found }
        ' "$WORKDIR/packages.plan" || die "The resolved package plan is incomplete: $package"
    done
    sizes=$(awk 'NF == 6 && $2 == "install" && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ {
            installed += $5; download += $6; rows++
        }
        END { if (!rows) exit 1; printf "%.0f %.0f\n", installed, download }' "$WORKDIR/packages.plan") ||
        die 'Could not read installed/download sizes from the XBPS package plan.'
    read -r installed_bytes download_bytes <<< "$sizes"
    check_capacity "$installed_bytes" "$download_bytes"
}

print_summary() {
    say 'Selected installation'
    lsblk -dn -o NAME,SIZE,MODEL,SERIAL "$DISK"
    printf 'ALL existing partitions/data on %s will be replaced.\n' "$DISK"
    printf 'EFI: %s MiB; /boot: %s MiB; encrypted ext4 root: remainder; swapfile: %s MiB\n' \
        "$EFI_MIB" "$BOOT_MIB" "$SWAP_MIB"
    printf 'Hostname: %s; locale: %s; console: %s; desktop: %s %s; timezone: %s\n' \
        "$HOSTNAME" "$LOCALE" "$KEYMAP" "$XKB_LAYOUT" "$XKB_VARIANT" "$TIMEZONE"
    printf 'LXQt Wayland + labwc + SDDM; quiet boot: %s; repository: %s\n' "$QUIET_BOOT" "$REPOSITORY"
    printf 'Packages: %s\n' "${INSTALL_PACKAGES[*]}"
}

read_encryption_secret() {
    local confirmation
    # Remove inherited export attributes as well as any inherited value.
    unset LUKS_PASSPHRASE
    export -n confirmation
    while :; do
        IFS= read -r -s -p 'Disk encryption passphrase: ' LUKS_PASSPHRASE <&9 || die 'Passphrase entry cancelled.'
        printf '\n' >&9
        IFS= read -r -s -p 'Confirm encryption passphrase: ' confirmation <&9 || die 'Passphrase confirmation cancelled.'
        printf '\n' >&9
        if [[ -n $LUKS_PASSPHRASE && $LUKS_PASSPHRASE == "$confirmation" ]]; then
            unset confirmation
            return
        fi
        printf 'Passphrases must be nonempty and match. Try again.\n' >&9
        unset LUKS_PASSPHRASE confirmation
    done
}

partition_path() {
    local disk=$1 number=$2
    if [[ $disk =~ [0-9]$ ]]; then printf '%sp%s\n' "$disk" "$number"
    else printf '%s%s\n' "$disk" "$number"; fi
}

write_partition_table() {
    # MiB suffixes let sfdisk align correctly on both 512-byte and 4Kn disks.
    printf 'label: gpt\n\nsize=%sMiB, type=U, name="EFI"\nsize=%sMiB, type=L, name="boot"\ntype=ca7d7ccb-63ed-4c53-861c-1742536059cc, name="cryptroot"\n' \
        "$EFI_MIB" "$BOOT_MIB" | sfdisk --wipe always --wipe-partitions always "$DISK"
}

create_encrypted_root() {
    local crypt_part=$1
    export -n LUKS_PASSPHRASE
    # Both operations consume the exact same byte string on stdin. Secrets never
    # appear in argv, exported variables, temporary files, or the initramfs.
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$crypt_part"
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --type luks --key-file=- "$crypt_part" "$CRYPT_NAME"
    CRYPT_OPEN=true
    unset LUKS_PASSPHRASE
}

partition_and_mount() {
    local efi_part boot_part crypt_part attempt
    STAGE='partitioning and encryption'
    validate_disk                         # Repeat immediately before the destructive step.
    [[ $ERASE_DISK == true ]] || die 'ERASE_DISK must be true to partition.'
    write_partition_table
    # sfdisk already reloads the partition table; settle udev before use.
    udevadm settle
    efi_part=$(partition_path "$DISK" 1)
    boot_part=$(partition_path "$DISK" 2)
    crypt_part=$(partition_path "$DISK" 3)
    for (( attempt=0; attempt<10; attempt++ )); do
        [[ ! -b $efi_part || ! -b $boot_part || ! -b $crypt_part ]] || break
        sleep 1
        udevadm settle
    done
    [[ -b $efi_part && -b $boot_part && -b $crypt_part ]] || die 'New partition nodes did not appear.'
    CRYPT_NAME="void-install-$$"
    [[ ! -e /dev/mapper/$CRYPT_NAME ]] || die 'Temporary encryption mapper already exists.'
    create_encrypted_root "$crypt_part"
    mkfs.vfat -F 32 -n EFI "$efi_part"
    mkfs.ext4 -F -L boot "$boot_part"
    mkfs.ext4 -F -L void-root "/dev/mapper/$CRYPT_NAME"
    LUKS_UUID=$(cryptsetup luksUUID "$crypt_part")
    ROOT_UUID=$(blkid -s UUID -o value "/dev/mapper/$CRYPT_NAME")
    BOOT_UUID=$(blkid -s UUID -o value "$boot_part")
    EFI_UUID=$(blkid -s UUID -o value "$efi_part")
    [[ -n $LUKS_UUID && -n $ROOT_UUID && -n $BOOT_UUID && -n $EFI_UUID ]] || die 'Could not obtain filesystem identifiers.'
    TARGET=$(mktemp -d /mnt/void-install.XXXXXXXX)
    mount "/dev/mapper/$CRYPT_NAME" "$TARGET"
    MOUNTS+=("$TARGET")
    chmod 755 "$TARGET"
    chown 0:0 "$TARGET"
    install -d "$TARGET/boot"
    mount "$boot_part" "$TARGET/boot"
    MOUNTS+=("$TARGET/boot")
    install -d "$TARGET/boot/efi"
    mount -o umask=0077 "$efi_part" "$TARGET/boot/efi"
    MOUNTS+=("$TARGET/boot/efi")
}

prepare_chroot() {
    install -d "$TARGET"/{dev,proc,sys,run,etc}
    mount --rbind /dev "$TARGET/dev"
    MOUNTS+=("$TARGET/dev")
    mount --make-rslave "$TARGET/dev"
    mount -t proc proc "$TARGET/proc"
    MOUNTS+=("$TARGET/proc")
    mount --rbind /sys "$TARGET/sys"
    MOUNTS+=("$TARGET/sys")
    mount --make-rslave "$TARGET/sys"
    mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$TARGET/run"
    MOUNTS+=("$TARGET/run")
}

in_target() {
    chroot "$TARGET" /usr/bin/env -u XBPS_ARCH -u XBPS_TARGET_ARCH \
        -u LANG -u LC_ALL PATH=/usr/bin:/usr/sbin:/bin:/sbin "$@"
}

install_packages() {
    STAGE='package installation'
    copy_trusted_keys "$TARGET"
    prepare_chroot
    say 'Installing packages (this can take a while)'
    # Configure packages only after fstab/crypttab/dracut settings have been written.
    XBPS_ARCH=x86_64 xbps-install -S -y -U -i -R "$REPOSITORY" -r "$TARGET" \
        "${INSTALL_PACKAGES[@]}" </dev/null
    rm -f "$TARGET/etc/resolv.conf"
    cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
    install -d "$TARGET/etc/xbps.d"
    printf 'repository=%s\n' "$REPOSITORY" >"$TARGET/etc/xbps.d/00-repository-main.conf"
}

write_system_config() {
    STAGE='system configuration'
    install -d "$TARGET/etc"/{default,dracut.conf.d,X11/xorg.conf.d,sudoers.d}
    printf '%s\n' "$HOSTNAME" >"$TARGET/etc/hostname"
    cat >"$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME
EOF
    printf 'LANG=%s\n' "$LOCALE" >"$TARGET/etc/locale.conf"
    # Avoid forcing LC_ALL; applications can still choose individual categories.
    printf 'KEYMAP="%s"\nHARDWARECLOCK="%s"\n' "$KEYMAP" "$HARDWARECLOCK" >"$TARGET/etc/rc.conf"
    printf 'KEYMAP=%s\n' "$KEYMAP" >"$TARGET/etc/vconsole.conf"
    ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
    printf '%s\n' "$TIMEZONE" >"$TARGET/etc/timezone"
    [[ -f $TARGET/etc/default/libc-locales ]] || die 'Target glibc locale list is missing.'
    awk -v locale="$LOCALE" '
        { original=$0; sub(/^[#[:space:]]+/, "");
          if ($1 == locale && $2 == "UTF-8") { print locale " UTF-8"; found=1 }
          else print original }
        END { if (!found) exit 1 }
    ' "$TARGET/etc/default/libc-locales" >"$WORKDIR/libc-locales" || die 'Locale is missing from target glibc.'
    cp "$WORKDIR/libc-locales" "$TARGET/etc/default/libc-locales"
    cat >"$TARGET/etc/X11/xorg.conf.d/00-keyboard.conf" <<EOF
Section "InputClass"
    Identifier "installer-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$XKB_LAYOUT"
    Option "XkbVariant" "$XKB_VARIANT"
EndSection
EOF
    cat >"$TARGET/etc/fstab" <<EOF
# Generated by install-void.sh. /home and swap are inside the encrypted root.
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$BOOT_UUID /boot ext4 defaults,noatime 0 2
UUID=$EFI_UUID /boot/efi vfat defaults,umask=0077 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev,mode=1777 0 0
EOF
    printf 'cryptroot UUID=%s none luks\n' "$LUKS_UUID" >"$TARGET/etc/crypttab"
    if (( SWAP_MIB > 0 )); then
        say "Creating ${SWAP_MIB} MiB encrypted swapfile"
        # dd guarantees allocated ext4 blocks; no sparse-file surprises.
        ( umask 077; dd if=/dev/zero of="$TARGET/swapfile" bs=1M count="$SWAP_MIB" status=progress )
        chmod 600 "$TARGET/swapfile"
        mkswap "$TARGET/swapfile"
        printf '/swapfile none swap defaults 0 0\n' >>"$TARGET/etc/fstab"
    fi
    cat >"$TARGET/etc/dracut.conf.d/20-encrypted-root.conf" <<'EOF'
# Generic images avoid inheriting the live USB's host-only root configuration.
hostonly="no"
add_dracutmodules+=" crypt i18n "
install_items+=" /etc/crypttab /etc/vconsole.conf /etc/locale.conf "
EOF
    write_lxqt_wayland_config
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$TARGET/etc/sudoers.d/10-wheel"
    chmod 440 "$TARGET/etc/sudoers.d/10-wheel"
}

write_lxqt_wayland_config() {
    local skel="$TARGET/etc/skel/.config"
    install -d "$skel"/{lxqt,labwc,autostart} "$TARGET/etc/sddm.conf.d" \
        "$TARGET/etc/sv/sddm-lxqt/log" "$TARGET/usr/local/bin" "$TARGET/usr/local/libexec" \
        "$TARGET/usr/local/share/void-installer/"{wayland-sessions,xsessions} \
        "$TARGET/etc/xdg/xdg-desktop-portal"

    # Offer one configured session; no remembered-session or autologin tricks.
    # SDDM's greeter uses X11; the authenticated desktop uses Wayland.
    cat >"$TARGET/etc/sddm.conf.d/50-void-lxqt.conf" <<'EOF'
[General]
DisplayServer=x11

[X11]
SessionDir=/usr/local/share/void-installer/xsessions

[Wayland]
SessionDir=/usr/local/share/void-installer/wayland-sessions
EOF
    cat >"$TARGET/usr/local/share/void-installer/wayland-sessions/void-lxqt-wayland.desktop" <<'EOF'
[Desktop Entry]
Name=LXQt (Wayland)
Comment=LXQt desktop with labwc
Exec=/usr/local/bin/start-lxqt-wayland
TryExec=/usr/bin/startlxqtwayland
Type=Application
DesktopNames=LXQt;labwc;
EOF
    cat >"$TARGET/etc/sv/sddm-lxqt/run" <<'EOF'
#!/bin/sh
exec 2>&1
sv check dbus >/dev/null || exit 1
sv check elogind >/dev/null || exit 1
if command -v plymouth >/dev/null 2>&1 && plymouth --ping 2>/dev/null; then
    plymouth quit --retain-splash || exit 1
fi
# Preserve the distribution's locale and elogind setup.
cd /etc/sv/sddm || exit 1
exec /etc/sv/sddm/run
EOF
    cat >"$TARGET/etc/sv/sddm-lxqt/log/run" <<'EOF'
#!/bin/sh
install -d -m 700 /var/log/sddm-lxqt
exec svlogd -tt /var/log/sddm-lxqt
EOF
    cat >"$TARGET/usr/local/bin/start-lxqt-wayland" <<'EOF'
#!/bin/sh
set -eu
set -a
# shellcheck disable=SC1091
. /etc/locale.conf
set +a
unset LC_ALL DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=lxqt-wayland
export XDG_CURRENT_DESKTOP=LXQt:labwc:wlroots
export QT_QPA_PLATFORM=wayland
exec dbus-run-session -- /usr/local/libexec/run-lxqt-wayland "$@"
EOF
    cat >"$TARGET/usr/local/libexec/run-lxqt-wayland" <<'EOF'
#!/bin/sh
set -eu
# A PipeWire core is needed by the wlroots portal. PulseAudio handles audio;
# no WirePlumber or pipewire-pulse is started. Reap our core on logout.
pipewire &
capture_pid=$!
# shellcheck disable=SC2317 # Invoked indirectly by the EXIT trap.
stop_capture() {
    kill "$capture_pid" 2>/dev/null || :
    wait "$capture_pid" 2>/dev/null || :
}
trap stop_capture EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if startlxqtwayland "$@"; then status=0; else status=$?; fi
exit "$status"
EOF
    cat >"$TARGET/usr/local/libexec/lxqt-wayland-startup" <<'EOF'
#!/bin/sh
set -eu
# Locking must start even if optional desktop/audio initialization fails.
/usr/local/libexec/lxqt-wayland-idle &
# Import only after labwc has created the display. No systemd user manager.
dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP \
    XDG_SESSION_TYPE XDG_SESSION_DESKTOP
if [ -n "${DISPLAY:-}" ]; then dbus-update-activation-environment DISPLAY; fi
pulseaudio --start
EOF
    cat >"$TARGET/usr/local/bin/lock-lxqt-wayland" <<'EOF'
#!/bin/sh
# The daemonizing parent returns only once the compositor confirms locking.
exec swaylock --daemonize --color 202020 --show-keyboard-layout
EOF
    cat >"$TARGET/usr/local/libexec/lxqt-wayland-idle" <<'EOF'
#!/bin/sh
exec swayidle -w \
    timeout 300 '/usr/local/bin/lock-lxqt-wayland' \
    timeout 600 'wlopm --off "*"' resume 'wlopm --on "*"' \
    before-sleep '/usr/local/bin/lock-lxqt-wayland' \
    lock '/usr/local/bin/lock-lxqt-wayland'
EOF
    cat >"$skel/lxqt/session.conf" <<'EOF'
[General]
compositor=labwc
lock_command_wayland=/usr/local/bin/lock-lxqt-wayland
EOF
    cat >"$skel/labwc/environment" <<EOF
XKB_DEFAULT_LAYOUT=$XKB_LAYOUT
XKB_DEFAULT_VARIANT=$XKB_VARIANT
EOF
    cat >"$skel/labwc/autostart" <<'EOF'
#!/bin/sh
# lxqt-session is started by startlxqtwayland's labwc -S argument.
# Do not start the panel, PolicyKit agent or notification daemon twice.
/usr/local/libexec/lxqt-wayland-startup
EOF
    cat >"$skel/labwc/rc.xml" <<EOF
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <default />
    <keybind key="W-Return"><action name="Execute" command="qterminal" /></keybind>
    <keybind key="A-F2"><action name="Execute" command="lxqt-runner" /></keybind>
    <keybind key="W-e"><action name="Execute" command="pcmanfm-qt" /></keybind>
    <keybind key="W-l"><action name="Execute" command="/usr/local/bin/lock-lxqt-wayland" /></keybind>
    <keybind key="W-S-e"><action name="Execute" command="lxqt-leave --logout" /></keybind>
    <keybind key="XF86_AudioLowerVolume"><action name="Execute" command="pactl set-sink-volume @DEFAULT_SINK@ -5%" /></keybind>
    <keybind key="XF86_AudioRaiseVolume"><action name="Execute" command="pactl set-sink-volume @DEFAULT_SINK@ +5%" /></keybind>
    <keybind key="XF86_AudioMute"><action name="Execute" command="pactl set-sink-mute @DEFAULT_SINK@ toggle" /></keybind>
    <keybind key="XF86_MonBrightnessUp"><action name="Execute" command="brightnessctl set +5%" /></keybind>
    <keybind key="XF86_MonBrightnessDown"><action name="Execute" command="brightnessctl set 5%-" /></keybind>
  </keyboard>
  <mouse><default /></mouse>
  <libinput>
    <device category="touchpad">
      <naturalScroll>$NATURAL_SCROLL</naturalScroll>
      <tap>true</tap>
      <disableWhileTyping>true</disableWhileTyping>
    </device>
  </libinput>
</labwc_config>
EOF
    cat >"$skel/autostart/nm-applet.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Network connections
Exec=nm-applet --indicator
OnlyShowIn=LXQt;
Terminal=false
EOF
    cat >"$TARGET/etc/xdg/xdg-desktop-portal/lxqt-portals.conf" <<'EOF'
[preferred]
default=lxqt;gtk;
org.freedesktop.impl.portal.FileChooser=lxqt
org.freedesktop.impl.portal.Screenshot=wlr
org.freedesktop.impl.portal.ScreenCast=wlr
EOF
    chmod 755 "$TARGET/etc/sv/sddm-lxqt/run" "$TARGET/etc/sv/sddm-lxqt/log/run" \
        "$TARGET/usr/local/bin/"{start-lxqt-wayland,lock-lxqt-wayland} \
        "$TARGET/usr/local/libexec/"{run-lxqt-wayland,lxqt-wayland-startup,lxqt-wayland-idle} \
        "$skel/labwc/autostart"
}

write_plymouth_config() {
    local theme_dir="$TARGET/usr/share/plymouth/themes/void-simple"
    install -d "$theme_dir" "$TARGET/etc/plymouth"
    cat >"$theme_dir/void-simple.plymouth" <<'EOF'
[Plymouth Theme]
Name=Void Simple
Description=Static boot message and encrypted-root password prompt
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/void-simple
ScriptFile=/usr/share/plymouth/themes/void-simple/void-simple.script
EOF
    printf 'boot_message = "%s";\n' "$BOOT_MESSAGE" >"$theme_dir/void-simple.script"
    cat >>"$theme_dir/void-simple.script" <<'EOF'
Window.SetBackgroundTopColor(0, 0, 0);
Window.SetBackgroundBottomColor(0, 0, 0);
message = Sprite();
prompt_sprite = Sprite();
entry_sprite = Sprite();

fun centre(sprite, text, y) {
    local.image = Image.Text(text, 1, 1, 1, "DejaVu Sans 16");
    sprite.SetImage(image);
    sprite.SetPosition(Window.GetX() + (Window.GetWidth() - image.GetWidth()) / 2,
                       Window.GetY() + Window.GetHeight() / 2 + y, 10);
}
centre(message, boot_message, -50);

fun normal() {
    prompt_sprite.SetOpacity(0);
    entry_sprite.SetOpacity(0);
}
fun password(prompt, bullets) {
    local.mask = "";
    # Limit visual width; never display any actual passphrase characters.
    for (local.i = 0; i < bullets && i < 40; i++) mask += "*";
    centre(prompt_sprite, "Disk encryption passphrase:", 0);
    centre(entry_sprite, mask, 35);
    prompt_sprite.SetOpacity(1);
    entry_sprite.SetOpacity(1);
}
fun question(prompt, entry) {
    centre(prompt_sprite, prompt, 0);
    centre(entry_sprite, entry, 35);
    prompt_sprite.SetOpacity(1);
    entry_sprite.SetOpacity(1);
}
Plymouth.SetDisplayNormalFunction(normal);
Plymouth.SetDisplayPasswordFunction(password);
Plymouth.SetDisplayQuestionFunction(question);
normal();
EOF
    cat >"$TARGET/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=void-simple
ShowDelay=0
EOF
    if [[ $QUIET_BOOT == true ]]; then
        cat >"$TARGET/etc/dracut.conf.d/30-plymouth.conf" <<'EOF'
add_dracutmodules+=" plymouth "
# The script theme loads label.so at runtime (dlopen), so dependency scanning
# alone will not include it. Include its font configuration and a real font too.
install_items+=" /usr/lib/plymouth/label.so /etc/fonts/fonts.conf /usr/share/fonts/TTF/DejaVuSans.ttf "
EOF
    else
        printf 'omit_dracutmodules+=" plymouth "\n' >"$TARGET/etc/dracut.conf.d/30-plymouth.conf"
    fi
}

write_grub_config() {
    local default_args menu_style timeout
    default_args='loglevel=4 rd.plymouth=0 plymouth.enable=0'
    menu_style=menu
    timeout=5
    if [[ $QUIET_BOOT == true ]]; then
        default_args='quiet splash loglevel=3'
        menu_style=hidden
        timeout=2
    fi
    cat >"$TARGET/etc/default/grub" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=$menu_style
GRUB_TIMEOUT=$timeout
GRUB_DISTRIBUTOR="Void"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=false
GRUB_CMDLINE_LINUX="rd.luks.uuid=$LUKS_UUID rd.vconsole.keymap=$KEYMAP"
GRUB_CMDLINE_LINUX_DEFAULT="$default_args"
EOF
    # A separate generator keeps the first entries free of GRUB's stock loading
    # banners without modifying the distribution's 10_linux or kernel hooks.
    # It discovers versioned kernels every time grub-mkconfig runs.
    cat >"$TARGET/etc/default/void-installer-boot" <<EOF
ROOT_UUID='$ROOT_UUID'
BOOT_UUID='$BOOT_UUID'
LUKS_UUID='$LUKS_UUID'
KEYMAP='$KEYMAP'
BOOT_MESSAGE='$BOOT_MESSAGE'
QUIET_BOOT='$QUIET_BOOT'
EOF
    cat >"$TARGET/etc/grub.d/09_void_installer" <<'EOF'
#!/bin/sh
set -eu
# shellcheck disable=SC1091
. /etc/default/void-installer-boot
# shellcheck disable=SC1091
. /etc/default/grub
for kernel in $(find /boot -maxdepth 1 -name 'vmlinuz-*' -type f -printf '%f\n' | sort -Vr); do
    version=${kernel#vmlinuz-}
    case "$version" in *[!a-zA-Z0-9._+-]*|'') continue ;; esac
    [ -s "/boot/initramfs-${version}.img" ] || continue
    common="root=UUID=$ROOT_UUID ro ${GRUB_CMDLINE_LINUX:-rd.luks.uuid=$LUKS_UUID rd.vconsole.keymap=$KEYMAP}"
    cat <<ENTRY
menuentry 'Void Linux ($version)' --class void --class gnu-linux --class os {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    echo '$BOOT_MESSAGE'
    linux /vmlinuz-$version $common ${GRUB_CMDLINE_LINUX_DEFAULT:-}
    initrd /initramfs-$version.img
}
menuentry 'Void Linux ($version, verbose recovery)' --class void --class gnu-linux --class os {
    search --no-floppy --fs-uuid --set=root $BOOT_UUID
    linux /vmlinuz-$version $common loglevel=7 rd.debug rd.shell rd.plymouth=0 plymouth.enable=0
    initrd /initramfs-$version.img
}
ENTRY
done
EOF
    chmod 755 "$TARGET/etc/grub.d/09_void_installer"
}

configure_packages_and_services() {
    local service
    STAGE='package configuration and desktop services'
    say 'Configuring packages and building boot images'
    in_target xbps-reconfigure -a </dev/null
    in_target xbps-reconfigure -f glibc-locales </dev/null
    in_target visudo -c
    # Enable services in the on-disk runlevel, not /var/service (a /run symlink).
    install -d "$TARGET/etc/runit/runsvdir/default"
    for service in dhcpcd wpa_supplicant iwd wicd connmand acpid agetty-tty1 agetty-tty7 lightdm greetd; do
        rm -f "$TARGET/etc/runit/runsvdir/default/$service"
    done
    for service in dbus elogind NetworkManager sddm "${SERVICES[@]}"; do
        local service_dir="/etc/sv/$service"
        [[ $service != sddm ]] || service_dir=/etc/sv/sddm-lxqt
        [[ -x $TARGET$service_dir/run ]] || die "No installed runit service named $service. Add its package to PACKAGES."
        if [[ $service == sddm ]]; then
            [[ -x $TARGET/etc/sv/sddm/run ]] || die 'The package-owned SDDM service is missing.'
        fi
        ln -sfn "$service_dir" "$TARGET/etc/runit/runsvdir/default/$service"
    done
    # tty2 and other stock text consoles remain available for recovery.
    [[ -x $TARGET/etc/sv/agetty-tty2/run ]] || die 'The recovery text-console service is missing.'
    ln -sfn /etc/sv/agetty-tty2 "$TARGET/etc/runit/runsvdir/default/agetty-tty2"
}

create_users() {
    local username
    STAGE='user setup'
    say 'Set the root password'
    in_target passwd root <&9 >&9 2>&9
    while :; do
        IFS= read -r -p 'Default username: ' username <&9 || die 'Username entry cancelled.'
        [[ $username =~ ^[a-z_][a-z0-9_-]{0,30}$ && $username != root ]] || {
            printf 'Use a lowercase username starting with a letter or underscore (up to 31 characters).\n' >&9
            continue
        }
        if in_target getent passwd "$username" >/dev/null; then
            printf 'That account already exists. Choose another username.\n' >&9
            continue
        fi
        break
    done
    in_target useradd -m -s /bin/bash -G wheel,network "$username"
    say "Set the password for $username"
    in_target passwd "$username" <&9 >&9 2>&9
    # useradd copies the preconfigured LXQt/labwc defaults with user ownership.
    printf 'Created %s with password-required sudo access.\n' "$username"
}

install_bootloader() {
    STAGE='bootloader installation and final verification'
    say 'Installing GRUB and checking generated boot files'
    # Write both a named NVRAM entry and the standard firmware fallback path.
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void --recheck
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram --recheck
    # Rebuild explicitly after all configuration; hooks also rebuild on updates.
    in_target dracut --regenerate-all --force </dev/null
    in_target grub-mkconfig -o /boot/grub/grub.cfg
    in_target grub-script-check /boot/grub/grub.cfg
    [[ -s $TARGET/boot/efi/EFI/Void/grubx64.efi && -s $TARGET/boot/efi/EFI/BOOT/BOOTX64.EFI ]] ||
        die 'GRUB EFI images are missing.'
    local kernel version count=0
    for kernel in "$TARGET"/boot/vmlinuz-*; do
        [[ -f $kernel ]] || continue
        version=${kernel##*/vmlinuz-}
        [[ -s $TARGET/boot/initramfs-$version.img ]] || die "Missing initramfs for $version."
        (( count += 1 ))
    done
    (( count > 0 )) || die 'No installed kernel images found.'
    in_target findmnt --verify --tab-file /etc/fstab
    sync
}

cleanup() {
    local index failed=false
    unset LUKS_PASSPHRASE
    while (( ${#MOUNTS[@]} > 0 )); do
        index=$(( ${#MOUNTS[@]} - 1 ))
        # --recursive is needed for the private /dev and /sys bind submounts.
        if umount --recursive "${MOUNTS[index]}"; then
            unset 'MOUNTS[index]'
        else
            printf 'Could not unmount %s; inspect it manually.\n' "${MOUNTS[index]}" >&2
            failed=true
            break                         # Never unmount a parent of a busy child.
        fi
    done
    if ! $failed && [[ $CRYPT_OPEN == true ]]; then
        if cryptsetup close "$CRYPT_NAME"; then CRYPT_OPEN=false
        else failed=true; printf 'Could not close mapper %s.\n' "$CRYPT_NAME" >&2; fi
    fi
    if [[ -n $WORKDIR && $WORKDIR == /tmp/void-install.* && -d $WORKDIR ]]; then
        rm -rf -- "$WORKDIR"
    fi
    if ! $failed && [[ -n $TARGET && $TARGET == /mnt/void-install.* ]]; then
        rmdir -- "$TARGET" || failed=true
    fi
    if $failed; then return 1; fi
    MOUNTS=()
}

on_exit() {
    local status=$?
    trap - EXIT ERR INT TERM HUP
    if (( status != 0 )); then
        printf '\nInstallation stopped during: %s (exit %s).\n' "$STAGE" "$status" >&2
        printf 'No formatting step will be retried automatically. See README.md for recovery.\n' >&2
    fi
    cleanup || status=1
    exit "$status"
}

acquire_install_lock() {
    require_commands flock
    exec 8>/run/lock/void-install.lock
    flock -n 8 || die 'Another installer instance is running.'
}

main() {
    # Even bash -x must not trace secret reads or the key pipe. Disable core dumps.
    set +x +v
    set -Eeuo pipefail
    umask 022
    ulimit -c 0
    local check_only=false
    case ${1:-} in
        --help|-h) usage; return ;;
        --check) check_only=true ;;
        '') ;;
        *) usage >&2; die 'Unknown argument.' ;;
    esac
    (( $# <= 1 )) || die 'Use --check or --help without other arguments.'
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    validate_config
    if ! $check_only; then
        [[ $ERASE_DISK == true ]] || die 'Set ERASE_DISK=true in the configuration to authorize whole-disk erasure.'
    fi
    validate_environment
    # --check writes only its temporary probe directory, never a system lock.
    if ! $check_only; then
        acquire_install_lock
    fi
    STAGE='live environment preflight'
    ensure_live_tools "$check_only"
    validate_disk
    check_repository
    print_summary
    if $check_only; then
        say 'Preflight passed. No disk changes were made.'
        return
    fi
    # A real controlling terminal is mandatory; redirects/pipes cannot supply secrets.
    exec 9<>/dev/tty
    loadkeys --quiet "$KEYMAP"
    STAGE='encryption passphrase entry'
    read_encryption_secret
    partition_and_mount
    install_packages
    write_system_config
    write_plymouth_config
    write_grub_config
    configure_packages_and_services
    create_users
    install_bootloader
    STAGE='final cleanup'
    cleanup
    trap - EXIT
    say 'Installation complete. Filesystems unmounted and encryption mapper closed.'
    printf 'Remove the live USB and reboot when ready. Secure Boot must remain disabled.\n'
    printf 'Boot: %s -> encryption passphrase -> SDDM login -> LXQt Wayland.\n' "$BOOT_MESSAGE"
}

# Sourcing is deliberately side-effect-free so safety/configuration logic can be tested.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

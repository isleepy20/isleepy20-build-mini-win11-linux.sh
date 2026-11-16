#!/usr/bin/env bash
#
# build-mini-win11-linux.sh
#
# Builds a bootable hybrid BIOS/UEFI live ISO (< 5 GB) from a minimal Ubuntu
# 24.04 LTS (noble) debootstrap, with an XFCE lightweight desktop restyled to
# look like Windows 11, plus Wine, Flatpak and standard Linux services.
#
#   PROFILE=lite  (default)  XFCE desktop, virtual kernel, zstd SquashFS,
#                            zram swap. Optimized to boot under 1 GB RAM
#                            for QEMU / Vectras VM / Limbo / VirtualBox.
#   PROFILE=kde              KDE Plasma desktop, generic kernel + firmware,
#                            xz SquashFS. Needs 3-4 GB RAM.
#
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
RELEASE="noble"
ARCH="amd64"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
SEC_MIRROR="${SEC_MIRROR:-http://security.ubuntu.com/ubuntu}"

WORKDIR="${WORKDIR:-$PWD/mini-win11-build}"
OUTDIR="${OUTDIR:-$PWD}"
ISO_NAME="${ISO_NAME:-win11-linux-minimal.iso}"
ZIP_NAME="${ZIP_NAME:-${ISO_NAME%.iso}.zip}"
CHUNK_MB="${CHUNK_MB:-1800}"
GH_ASSET_LIMIT=2000000000
VOLID="WIN11_LINUX"

LIVE_USER="win11"
LIVE_HOSTNAME="win11-linux"

PROFILE="${PROFILE:-lite}"
case "$PROFILE" in lite|kde) ;; *) echo "PROFILE must be lite or kde" >&2; exit 1 ;; esac
WITH_FIRMWARE="${WITH_FIRMWARE:-0}"
WITH_WINE="${WITH_WINE:-1}"
WITH_BROWSER="${WITH_BROWSER:-1}"
WITH_WINE32="${WITH_WINE32:-0}"
PRUNE_FIRMWARE="${PRUNE_FIRMWARE:-1}"
COMPOSITOR="${COMPOSITOR:-0}"
if [[ "$PROFILE" == "lite" ]]; then SQUASH_COMP="${SQUASH_COMP:-zstd}"; else SQUASH_COMP="${SQUASH_COMP:-xz}"; fi

THEME_KDE_REPO="${THEME_KDE_REPO:-https://github.com/yeyushengfan258/Win11OS-kde.git}"
THEME_GTK_REPO="${THEME_GTK_REPO:-https://github.com/vinceliuice/Fluent-gtk-theme.git}"
THEME_ICON_REPO="${THEME_ICON_REPO:-https://github.com/yeyushengfan258/Win11-icon-theme.git}"

MAX_BYTES=4800000000
TARGET_BYTES=3800000000
MIN_FREE_BYTES=$((25 * 1000 * 1000 * 1000))

ROOTFS="$WORKDIR/rootfs"
ISODIR="$WORKDIR/iso"
BOOTWORK="$WORKDIR/bootimg"
SRCDIR="$WORKDIR/src"
ISO_PATH="$OUTDIR/$ISO_NAME"

RUN_QEMU=0
[[ "${1:-}" == "--run-qemu" ]] && RUN_QEMU=1

###############################################################################
# Helpers, mount handling, cleanup trap
###############################################################################
log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

unmount_chroot() {
  [[ -d "$ROOTFS" ]] || return 0
  local m
  while read -r m; do
    umount -l "$m" 2>/dev/null || true
  done < <(awk -v r="$ROOTFS" '$2==r || index($2, r"/")==1 {print $2}' /proc/mounts | sort -r)
}

cleanup() {
  local rc=$?
  set +e
  unmount_chroot
  [[ -d "$ROOTFS" ]] && rm -f "$ROOTFS/usr/sbin/policy-rc.d"
  if (( rc != 0 )); then
    warn "Build failed (exit $rc). Work directory kept for inspection: $WORKDIR"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mount_chroot() {
  mkdir -p "$ROOTFS"/{proc,sys,dev/pts,run}
  mount -t proc  proc   "$ROOTFS/proc"
  mount -t sysfs sysfs  "$ROOTFS/sys"
  mount --bind   /dev   "$ROOTFS/dev"
  mount -t devpts devpts "$ROOTFS/dev/pts"
  mount -t tmpfs tmpfs  "$ROOTFS/run"
  mkdir -p "$ROOTFS/run/lock"
}

chroot_sh() {
  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-xterm}" LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DEBIAN_FRONTEND=noninteractive "$@"
}

apt_install() { chroot_sh apt-get install -y --no-install-recommends "$@"; }

###############################################################################
# 0. Host checks and dependencies
###############################################################################
(( EUID == 0 )) || die "Run as root (sudo)."
command -v apt-get >/dev/null || die "Host must be Debian/Ubuntu-based."

mkdir -p "$WORKDIR" "$OUTDIR"
avail=$(df --output=avail -B1 "$WORKDIR" | tail -1 | tr -d ' ')
(( avail >= MIN_FREE_BYTES )) || die "Need at least 25 GB free in $WORKDIR (have $((avail/1000000000)) GB)."

HOST_PKGS=(debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin
           grub-common mtools dosfstools git curl ca-certificates ubuntu-keyring zip)
missing=()
for p in "${HOST_PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if (( ${#missing[@]} )); then
  log "Installing host dependencies: ${missing[*]}"
  apt-get update
  apt-get install -y "${missing[@]}"
fi

log "Cleaning previous build state"
unmount_chroot
rm -rf "$ROOTFS" "$ISODIR" "$BOOTWORK"
mkdir -p "$ISODIR/casper" "$ISODIR/boot/grub" "$ISODIR/.disk" "$BOOTWORK" "$SRCDIR"

###############################################################################
# 1. Fetch theme sources on the host
###############################################################################
fetch_repo() {
  local url=$1 dest=$2
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only --depth 1 >/dev/null 2>&1 || true
  else
    rm -rf "$dest"
    git clone --depth 1 "$url" "$dest" >/dev/null 2>&1 || warn "Could not clone $url (continuing without it)"
  fi
}
log "Fetching Windows 11 theme sources"
fetch_repo "$THEME_ICON_REPO" "$SRCDIR/Win11-icon-theme"
if [[ "$PROFILE" == "kde" ]]; then
  fetch_repo "$THEME_KDE_REPO" "$SRCDIR/Win11OS-kde"
else
  fetch_repo "$THEME_GTK_REPO" "$SRCDIR/Fluent-gtk-theme"
fi

###############################################################################
# 2. Bootstrap minimal Ubuntu 24.04
###############################################################################
log "Bootstrapping Ubuntu $RELEASE ($ARCH, minbase)"
KEYRING_OPT=()
[[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] && \
  KEYRING_OPT=(--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg)

debootstrap --arch="$ARCH" --variant=minbase --components=main,universe,restricted,multiverse \
  "${KEYRING_OPT[@]}" \
  --include=ca-certificates,gnupg,locales,apt-utils \
  "$RELEASE" "$ROOTFS" "$MIRROR"

mount_chroot

if [[ -s /run/systemd/resolve/resolv.conf ]]; then
  cp -L /run/systemd/resolve/resolv.conf "$ROOTFS/etc/resolv.conf"
else
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOTFS/etc/resolv.conf"
fi

printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

###############################################################################
# 3. APT / dpkg configuration
###############################################################################
log "Configuring apt and dpkg for minimal size"
rm -rf "$ROOTFS/etc/apt/sources.list.d/"*
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main restricted universe multiverse
deb $MIRROR $RELEASE-updates main restricted universe multiverse
deb $SEC_MIRROR $RELEASE-security main restricted universe multiverse
EOF

cat > "$ROOTFS/etc/apt/apt.conf.d/99-mini" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
Acquire::GzipIndexes "true";
EOF

cat > "$ROOTFS/etc/apt/preferences.d/no-snap.pref" <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/01-minimal" <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/gtk-doc/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*/*
path-include=/usr/share/locale/locale.alias
EOF

echo "$LIVE_HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $LIVE_HOSTNAME
::1 localhost ip6-localhost ip6-loopback
EOF
: > "$ROOTFS/etc/fstab"
ln -sf /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
echo "Etc/UTC" > "$ROOTFS/etc/timezone"
printf 'XKBMODEL="pc105"\nXKBLAYOUT="us"\nXKBVARIANT=""\nXKBOPTIONS=""\n' > "$ROOTFS/etc/default/keyboard"

chroot_sh apt-get update

###############################################################################
# 4. Pre-create systemd users/groups & install core system
###############################################################################
log "Pre-creating systemd users and groups"
chroot_sh groupadd -g 102 systemd-journal 2>/dev/null || true
chroot_sh useradd -u 102 -g systemd-journal -d / -s /usr/sbin/nologin systemd-journal 2>/dev/null || true
chroot_sh groupadd -g 100 systemd-network 2>/dev/null || true
chroot_sh useradd -u 100 -g systemd-network -d / -s /usr/sbin/nologin systemd-network 2>/dev/null || true
chroot_sh groupadd -g 103 systemd-resolve 2>/dev/null || true
chroot_sh useradd -u 103 -g systemd-resolve -d / -s /usr/sbin/nologin systemd-resolve 2>/dev/null || true

log "Installing core system and casper"
if [[ "$PROFILE" == "lite" ]]; then
  CORE_PKGS=(
    systemd systemd-sysv systemd-resolved systemd-timesyncd libpam-systemd udev kmod
    dbus dbus-user-session dbus-x11 sudo polkitd pkexec upower udisks2
    iproute2 iputils-ping curl wget ca-certificates less nano file unzip xz-utils zstd
    network-manager wpasupplicant iw wireless-regdb
    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils
    bluez ufw openssh-server systemd-zram-generator
    locales tzdata keyboard-configuration kbd
    xdg-user-dirs xdg-utils
    ntfs-3g exfatprogs dosfstools e2fsprogs
    initramfs-tools casper
  )
else
  CORE_PKGS=(
    systemd systemd-sysv systemd-resolved systemd-timesyncd udev kmod
    dbus dbus-user-session dbus-x11 sudo polkitd pkexec
    iproute2 iputils-ping curl wget ca-certificates less nano file unzip xz-utils zstd
    network-manager wpasupplicant iw wireless-regdb
    pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth alsa-utils
    bluez cups ufw openssh-server
    locales tzdata keyboard-configuration kbd
    xdg-user-dirs xdg-utils
    ntfs-3g exfatprogs dosfstools e2fsprogs
    initramfs-tools casper
  )
fi
apt_install "${CORE_PKGS[@]}"

log "Generating en_US.UTF-8 locale only"
echo 'en_US.UTF-8 UTF-8' > "$ROOTFS/etc/locale.gen"
chroot_sh locale-gen
chroot_sh update-locale LANG=en_US.UTF-8

log "Installing kernel and firmware"
echo 'RESUME=none' > "$ROOTFS/etc/initramfs-tools/conf.d/resume"
if [[ "$PROFILE" == "lite" ]]; then
  apt_install linux-image-virtual
  if [[ "$WITH_FIRMWARE" == "1" ]]; then apt_install linux-firmware; fi
else
  apt_install linux-image-generic linux-firmware
fi

KVER="$(chroot_sh bash -c 'ls /lib/modules | sort -V | tail -1')"
[[ -n "$KVER" ]] || die "No kernel installed in chroot"
apt_install "linux-modules-extra-$KVER" || warn "linux-modules-extra-$KVER unavailable; continuing"

cat > "$ROOTFS/etc/casper.conf" <<EOF
export USERNAME="$LIVE_USER"
export USERFULLNAME="Windows 11 Live User"
export HOST="$LIVE_HOSTNAME"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="Mini-Win11-Linux"
EOF

###############################################################################
# 5. Desktop environment (KDE for PC, XFCE for Lite)
###############################################################################
if [[ "$PROFILE" == "lite" ]]; then
  log "Installing XFCE desktop (lite profile)"
  chroot_sh bash -c 'echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections'
  chroot_sh apt-get update

  GUI_PKGS=(
    xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-fbdev
    xserver-xorg-video-vesa xserver-xorg-video-qxl xserver-xorg-video-vmware
    x11-xserver-utils xauth libgl1-mesa-dri libglx-mesa0
    xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfconf xfce4-appfinder
    thunar thunar-volman tumbler xfce4-terminal xfce4-whiskermenu-plugin
    xfce4-pulseaudio-plugin xfce4-notifyd xfce4-taskmanager
    mousepad ristretto xarchiver network-manager-gnome policykit-1-gnome
    gvfs gvfs-daemons lightdm lightdm-gtk-greeter
    adwaita-icon-theme gtk2-engines-murrine librsvg2-common
    fonts-inter fonts-noto-core xdg-desktop-portal-gtk
  )
  if [[ "$WITH_BROWSER" == "1" ]]; then GUI_PKGS+=(epiphany-browser); fi
  apt_install "${GUI_PKGS[@]}"
else
  log "Installing minimal KDE Plasma"
  chroot_sh bash -c 'echo "sddm shared/default-x-display-manager select sddm" | debconf-set-selections'
  chroot_sh apt-get update

  GUI_PKGS=(
    xserver-xorg xserver-xorg-input-libinput xserver-xorg-video-fbdev
    xserver-xorg-video-vesa x11-xserver-utils xauth
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 mesa-vulkan-drivers libvulkan1
    plasma-desktop plasma-workspace plasma-workspace-wayland kwin-x11 kwin-wayland
    sddm sddm-theme-breeze kde-config-sddm
    breeze breeze-icon-theme breeze-gtk-theme kde-config-gtk-style
    systemsettings kscreen plasma-nm plasma-pa powerdevil bluedevil print-manager
    plasma-discover plasma-discover-backend-flatpak plasma-systemmonitor
    xdg-desktop-portal xdg-desktop-portal-kde xdg-desktop-portal-gtk
    dolphin kio-extras ark gwenview konsole falkon
    libkf5config-bin qt5-style-kvantum
    qml-module-qtquick-controls qml-module-qtquick-controls2 qml-module-qtquick-layouts
    qml-module-qtgraphicaleffects libqt5svg5
    fonts-inter fonts-noto-core fonts-noto-color-emoji
  )
  apt_install "${GUI_PKGS[@]}"
fi

###############################################################################
# 6. Wine and Flatpak
###############################################################################
log "Installing Wine and Flatpak"
if [[ "$WITH_WINE" == "1" ]]; then
  if [[ "$WITH_WINE32" == "1" ]]; then
    chroot_sh dpkg --add-architecture i386
    chroot_sh apt-get update
    apt_install wine wine64 libwine fonts-wine wine32:i386 libwine:i386
  else
    apt_install wine wine64 libwine fonts-wine
  fi
fi
apt_install flatpak

mkdir -p "$ROOTFS/etc/flatpak/remotes.d"
curl -fsSL https://dl.flathub.org/repo/flathub.flatpakrepo \
  -o "$ROOTFS/etc/flatpak/remotes.d/flathub.flatpakrepo" \
  || warn "Could not download flathub.flatpakrepo"

###############################################################################
# 7. Windows 11 look and feel setup
###############################################################################
log "Installing Windows 11 themes"
mkdir -p "$ROOTFS/tmp/themes"
for d in Win11OS-kde Fluent-gtk-theme Win11-icon-theme; do
  [[ -d "$SRCDIR/$d" ]] && cp -a "$SRCDIR/$d" "$ROOTFS/tmp/themes/$d"
done

if [[ "$PROFILE" == "kde" ]]; then
  cat > "$ROOTFS/tmp/install-themes.sh" <<'STAGE_EOF'
#!/bin/bash
set -u
T=/tmp/themes
KDE=$T/Win11OS-kde
ICO=$T/Win11-icon-theme

cp_tree() {
  [ -d "$1" ] || return 1
  mkdir -p "$2" && cp -a "$1"/. "$2"/ && echo "installed $1 -> $2"
}

if [ -d "$ICO" ]; then
  ( cd "$ICO" && bash ./install.sh -d /usr/share/icons ) >/tmp/icon-install.log 2>&1 \
  || ( cd "$ICO" && bash ./install.sh ) >>/tmp/icon-install.log 2>&1 || true
fi

if [ -d "$KDE" ]; then
  cp_tree "$KDE/aurorae/themes"        /usr/share/aurorae/themes    || cp_tree "$KDE/aurorae" /usr/share/aurorae/themes
  cp_tree "$KDE/color-schemes"         /usr/share/color-schemes
  cp_tree "$KDE/plasma/desktoptheme"   /usr/share/plasma/desktoptheme
  cp_tree "$KDE/plasma/look-and-feel"  /usr/share/plasma/look-and-feel
  cp_tree "$KDE/sddm/themes"           /usr/share/sddm/themes       || cp_tree "$KDE/sddm" /usr/share/sddm/themes
  cp_tree "$KDE/Kvantum"               /usr/share/Kvantum
  cp_tree "$KDE/wallpapers"            /usr/share/backgrounds/win11 || cp_tree "$KDE/wallpaper" /usr/share/backgrounds/win11
fi
gtk-update-icon-cache -f /usr/share/icons/Win11 >/dev/null 2>&1 || true
exit 0
STAGE_EOF
  chroot_sh bash /tmp/install-themes.sh || true
else
  cat > "$ROOTFS/tmp/install-themes.sh" <<'STAGE_EOF'
#!/bin/bash
set -u
T=/tmp/themes
if [ -d "$T/Fluent-gtk-theme" ]; then
  ( cd "$T/Fluent-gtk-theme" && bash ./install.sh -d /usr/share/themes -c light ) >/tmp/gtk-install.log 2>&1 \
  || ( cd "$T/Fluent-gtk-theme" && bash ./install.sh -d /usr/share/themes ) >>/tmp/gtk-install.log 2>&1 \
  || ( cd "$T/Fluent-gtk-theme" && bash ./install.sh ) >>/tmp/gtk-install.log 2>&1 || true
fi
if [ -d "$T/Win11-icon-theme" ]; then
  ( cd "$T/Win11-icon-theme" && bash ./install.sh -d /usr/share/icons ) >/tmp/icon-install.log 2>&1 \
  || ( cd "$T/Win11-icon-theme" && bash ./install.sh ) >>/tmp/icon-install.log 2>&1 || true
fi
gtk-update-icon-cache -f /usr/share/icons/Win11 >/dev/null 2>&1 || true
exit 0
STAGE_EOF
  chroot_sh bash /tmp/install-themes.sh || true
fi

if [[ "$PROFILE" == "kde" ]]; then
  cat > "$ROOTFS/tmp/configure-desktop.sh" <<'STAGE_EOF'
#!/bin/bash
set -u
export XDG_CONFIG_HOME=/etc/skel/.config
mkdir -p "$XDG_CONFIG_HOME" /etc/win11-linux /etc/sddm.conf.d

pick() {
  local x
  x=$(ls -1 "$1" 2>/dev/null | grep -i -- "$2" | grep -iv dark | head -1)
  [ -z "$x" ] && x=$(ls -1 "$1" 2>/dev/null | grep -i -- "$2" | head -1)
  echo "$x"
}
kw() {
  if [ -n "${5:-}" ]; then
    kwriteconfig5 --file "$1" --group "$2" --key "$3" --type "$5" "$4"
  else
    kwriteconfig5 --file "$1" --group "$2" --key "$3" "$4"
  fi
}

LAF=$(pick /usr/share/plasma/look-and-feel win11)
DT=$(pick /usr/share/plasma/desktoptheme win11)
AUR=$(pick /usr/share/aurorae/themes win11)
COLOR=$(ls -1 /usr/share/color-schemes 2>/dev/null | sed 's/\.colors$//' | grep -i win11 | grep -iv dark | head -1)
ICON=$(ls -1 /usr/share/icons 2>/dev/null | grep -ix win11 | head -1)
[ -z "$ICON" ] && ICON=$(pick /usr/share/icons win11)
KV=$(pick /usr/share/Kvantum win11)
SDDMTHEME=$(pick /usr/share/sddm/themes win11)
WALL=$(find /usr/share/backgrounds/win11 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | sort | head -1)

kw kdeglobals KDE SingleClick false bool
[ -n "$LAF" ]   && kw kdeglobals KDE LookAndFeelPackage "$LAF"
[ -n "$KV" ]    && kw kdeglobals KDE widgetStyle kvantum
[ -n "$COLOR" ] && kw kdeglobals General ColorScheme "$COLOR"
[ -n "$ICON" ]  && kw kdeglobals Icons Theme "$ICON"
FONT="Inter,10,-1,5,50,0,0,0,0,0"
kw kdeglobals General font "$FONT"
kw kdeglobals General menuFont "$FONT"
kw kdeglobals General toolBarFont "$FONT"
kw kdeglobals General smallestReadableFont "Inter,8,-1,5,50,0,0,0,0,0"

[ -n "$DT" ] && kw plasmarc Theme name "$DT"
if [ -n "$KV" ]; then
  mkdir -p "$XDG_CONFIG_HOME/Kvantum"
  kw Kvantum/kvantum.kvconfig General theme "$KV"
fi

if [ -n "$AUR" ]; then
  kw kwinrc org.kde.kdecoration2 library org.kde.kwin.aurorae
  kw kwinrc org.kde.kdecoration2 theme "__aurorae__svg__$AUR"
fi
kw kwinrc org.kde.kdecoration2 ButtonsOnLeft ""
kw kwinrc org.kde.kdecoration2 ButtonsOnRight "IAX"
kw kwinrc Plugins blurEnabled true bool

kw kscreenlockerrc Daemon Autolock false bool
kw kscreenlockerrc Daemon LockOnResume false bool
kw ksplashrc KSplash Theme None

kw dolphinrc General ShowFullPath true bool
kw dolphinrc General BrowseThroughArchives true bool
kw dolphinrc General ShowStatusBar FullWidth
kw dolphinrc General RememberOpenedTabs false bool

mkdir -p /etc/skel/{Desktop,Documents,Downloads,Pictures,Music,Videos}

mkdir -p /etc/skel/.config/gtk-3.0
cat > /etc/skel/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-icon-theme-name=${ICON:-breeze}
gtk-font-name=Inter 10
gtk-application-prefer-dark-theme=false
EOF

cat > /etc/sddm.conf.d/10-win11.conf <<EOF
[Autologin]
User=$LIVE_USER
Session=plasma
Relogin=false

[General]
Numlock=on

[Theme]
Current=${SDDMTHEME:-breeze}
EOF

cat > /etc/win11-linux/theme.env <<EOF
LAF="$LAF"
WALLPAPER="$WALL"
EOF
exit 0
STAGE_EOF
  chroot_sh LIVE_USER="$LIVE_USER" bash /tmp/configure-desktop.sh
else
  cat > "$ROOTFS/tmp/configure-desktop.sh" <<'STAGE_EOF'
#!/bin/bash
set -u
CFG=/etc/skel/.config
XF=$CFG/xfce4/xfconf/xfce-perchannel-xml
mkdir -p "$XF" "$CFG/gtk-3.0" /etc/lightdm/lightdm.conf.d /usr/share/backgrounds/win11 /etc/win11-linux

pick() {
  local x
  x=$(ls -1 "$1" 2>/dev/null | grep -i -- "$2" | grep -iv dark | head -1)
  [ -z "$x" ] && x=$(ls -1 "$1" 2>/dev/null | grep -i -- "$2" | head -1)
  echo "$x"
}
GTK=$(pick /usr/share/themes fluent); [ -z "$GTK" ] && GTK=Adwaita
ICON=$(ls -1 /usr/share/icons 2>/dev/null | grep -ix win11 | head -1)
[ -z "$ICON" ] && ICON=$(pick /usr/share/icons win11)
[ -z "$ICON" ] && ICON=Adwaita
WM=Default; [ -d "/usr/share/themes/$GTK/xfwm4" ] && WM=$GTK
COMP=false; [ "${COMPOSITOR:-0}" = "1" ] && COMP=true

cat > "$XF/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$GTK"/>
    <property name="IconThemeName" type="string" value="$ICON"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Inter 10"/>
  </property>
</channel>
EOF

cat > "$XF/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$WM"/>
    <property name="use_compositing" type="bool" value="$COMP"/>
    <property name="button_layout" type="string" value="|HMC"/>
  </property>
</channel>
EOF

cat > "$XF/xfce4-panel.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=10;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="44"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="show-labels" type="bool" value="false"/>
      <property name="flat-buttons" type="bool" value="true"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="pulseaudio"/>
    <property name="plugin-6" type="string" value="clock"/>
  </property>
</channel>
EOF

cat > /usr/share/backgrounds/win11/bloom.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs><radialGradient id="a" cx="50%" cy="58%" r="75%">
    <stop offset="0" stop-color="#7cc0ff"/><stop offset="0.45" stop-color="#1f6fe5"/><stop offset="1" stop-color="#051c4a"/>
  </radialGradient></defs>
  <rect width="1920" height="1080" fill="url(#a)"/>
</svg>
EOF

mkdir -p /etc/skel/{Desktop,Documents,Downloads,Pictures,Music,Videos}

cat > /etc/lightdm/lightdm.conf.d/50-win11.conf <<EOF
[Seat:*]
autologin-user=$LIVE_USER
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF
exit 0
STAGE_EOF
  chroot_sh LIVE_USER="$LIVE_USER" COMPOSITOR="$COMPOSITOR" bash /tmp/configure-desktop.sh
fi

if [[ "$PROFILE" == "kde" ]]; then
  cat > "$ROOTFS/usr/local/bin/win11-first-login" <<'WIN11_FIRST_LOGIN_EOF'
#!/bin/bash
MARK="$HOME/.config/.win11-layout-applied"
[ -e "$MARK" ] && exit 0
[ -r /etc/win11-linux/theme.env ] && . /etc/win11-linux/theme.env

for _ in $(seq 1 60); do
  dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.NameHasOwner string:org.kde.plasmashell 2>/dev/null \
    | grep -q 'boolean true' && break
  sleep 1
done
sleep 3

[ -n "${LAF:-}" ] && lookandfeeltool -a "$LAF" >/dev/null 2>&1
sleep 2

read -r -d '' JS <<'JS_EOF' || true
var old = panels();
for (var i = 0; i < old.length; i++) { old[i].remove(); }

var panel = new Panel();
panel.location = "bottom";
panel.height = 44;
panel.hiding = "none";

var pad = panel.addWidget("org.kde.plasma.panelspacer");
pad.currentConfigGroup = ["General"];
pad.writeConfig("expanding", false);
pad.writeConfig("length", 200);

panel.addWidget("org.kde.plasma.panelspacer");

var start = panel.addWidget("org.kde.plasma.kickoff");
start.currentConfigGroup = ["General"];
start.writeConfig("icon", "start-here-kde");

var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers",
  "preferred://filemanager,preferred://browser,applications:org.kde.konsole.desktop,applications:org.kde.discover.desktop");

panel.addWidget("org.kde.plasma.panelspacer");

panel.addWidget("org.kde.plasma.systemtray");
panel.addWidget("org.kde.plasma.digitalclock");
panel.addWidget("org.kde.plasma.showdesktop");
JS_EOF

dbus-send --session --print-reply --dest=org.kde.plasmashell /PlasmaShell \
  org.kde.PlasmaShell.evaluateScript string:"$JS" >/dev/null 2>&1

if [ -n "${WALLPAPER:-}" ] && [ -f "$WALLPAPER" ]; then
  plasma-apply-wallpaperimage "$WALLPAPER" >/dev/null 2>&1
fi

mkdir -p "$(dirname "$MARK")"
touch "$MARK"
WIN11_FIRST_LOGIN_EOF
  chmod +x "$ROOTFS/usr/local/bin/win11-first-login"

  mkdir -p "$ROOTFS/etc/xdg/autostart"
  cat > "$ROOTFS/etc/xdg/autostart/win11-first-login.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Windows 11 layout (first login)
Exec=/usr/local/bin/win11-first-login
X-KDE-autostart-phase=2
OnlyShowIn=KDE;
NoDisplay=true
EOF
else
  cat > "$ROOTFS/usr/local/bin/win11-first-login" <<'WIN11_FIRST_LOGIN_EOF'
#!/bin/bash
MARK="$HOME/.config/.win11-layout-applied"
[ -e "$MARK" ] && exit 0
for _ in $(seq 1 40); do
  xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -q 'last-image$' && break
  sleep 1
done
xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'last-image$' | while read -r p; do
  xfconf-query -c xfce4-desktop -p "$p" -s /usr/share/backgrounds/win11/bloom.svg
done
mkdir -p "$(dirname "$MARK")"; touch "$MARK"
WIN11_FIRST_LOGIN_EOF
  chmod +x "$ROOTFS/usr/local/bin/win11-first-login"

  mkdir -p "$ROOTFS/etc/xdg/autostart"
  cat > "$ROOTFS/etc/xdg/autostart/win11-first-login.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Windows 11 wallpaper (first login)
Exec=/usr/local/bin/win11-first-login
OnlyShowIn=XFCE;
NoDisplay=true
EOF
fi

###############################################################################
# 8. Services
###############################################################################
log "Enabling services"
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/20-live.conf" <<'EOF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true
EOF

sed -i 's/^ENABLED=.*/ENABLED=yes/' "$ROOTFS/etc/ufw/ufw.conf"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' "$ROOTFS/etc/default/ufw"

if [[ "$PROFILE" == "lite" ]]; then DM_UNITS="lightdm"; else DM_UNunits="sddm cups"; fi
chroot_sh systemctl enable NetworkManager systemd-resolved systemd-timesyncd \
  bluetooth ssh ufw $DM_UNITS
chroot_sh systemctl set-default graphical.target
chroot_sh systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true

if [[ "$PROFILE" == "lite" ]]; then
  # Mask heavy background timers for ultra-fast mobile boot
  chroot_sh systemctl mask apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
    dpkg-db-backup.timer e2scrub_all.timer fstrim.timer man-db.timer \
    NetworkManager-wait-online.service systemd-networkd-wait-online.service || true

  # Low-memory zram swap configuration
  cat > "$ROOTFS/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
EOF
  cat > "$ROOTFS/etc/sysctl.d/99-lowmem.conf" <<'EOF'
vm.swappiness = 100
vm.vfs_cache_pressure = 120
vm.page-cluster = 0
EOF
fi

###############################################################################
# 9. Slimming & initramfs
###############################################################################
log "Slimming the root filesystem"
cat > "$ROOTFS/tmp/slim.sh" <<'STAGE_EOF'
#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive

if [ "${PRUNE_FIRMWARE:-1}" = "1" ]; then
  for d in netronome mellanox liquidio cxgb4 bnx2x qed qlogic myri10ge ueagle-atm 3com advansys; do
    rm -rf "/usr/lib/firmware/$d" "/lib/firmware/$d" 2>/dev/null
  done
fi

find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null
find /usr/share/doc -type d -empty -delete 2>/dev/null
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/groff /usr/share/lintian /usr/share/gtk-doc
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name locale.alias -exec rm -rf {} + 2>/dev/null

update-initramfs -u -k all

apt-get -y clean
rm -rf /var/cache/apt/archives/* /var/cache/apt/*.bin /var/lib/apt/lists/* \
       /var/cache/debconf/*-old /var/lib/dpkg/*-old /var/cache/ldconfig/aux-cache
rm -rf /root/.cache /root/.wget-hsts /var/tmp/*
find / -xdev -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null
exit 0
STAGE_EOF
chroot_sh PRUNE_FIRMWARE="$PRUNE_FIRMWARE" bash /tmp/slim.sh

VMLINUZ="$(ls -1 "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)"
INITRD="$(ls -1 "$ROOTFS"/boot/initrd.img-* | sort -V | tail -1)"
[[ -f "$VMLINUZ" && -f "$INITRD" ]] || die "Kernel/initrd not found in chroot /boot"
cp "$VMLINUZ" "$ISODIR/casper/vmlinuz"
cp "$INITRD"  "$ISODIR/casper/initrd"
chmod 644 "$ISODIR/casper/vmlinuz" "$ISODIR/casper/initrd"

chroot_sh dpkg-query -W --showformat='${Package}\t${Version}\n' > "$ISODIR/casper/filesystem.manifest"

rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/tmp/.[!.]* 2>/dev/null || true
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
unmount_chroot
rm -f "$ROOTFS/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
printf '%s' "$(du -sx --block-size=1 "$ROOTFS" | cut -f1)" > "$ISODIR/casper/filesystem.size"

###############################################################################
# 10. SquashFS with compression options
###############################################################################
log "Creating filesystem.squashfs ($SQUASH_COMP)"
case "$SQUASH_COMP" in
  xz)   COMP_OPTS=(-comp xz -b 1M -Xdict-size 100% -Xbcj x86) ;;
  zstd) COMP_OPTS=(-comp zstd -Xcompression-level 19 -b 256K) ;;
  *)    die "SQUASH_COMP must be xz or zstd" ;;
esac
mksquashfs "$ROOTFS" "$ISODIR/casper/filesystem.squashfs" \
  "${COMP_OPTS[@]}" \
  -noappend -no-recovery -processors "$(nproc)" \
  -wildcards -e 'boot/vmlinuz*' 'boot/initrd.img*' 'boot/System.map*' 'boot/config-*' \
  -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'

###############################################################################
# 11. GRUB and ISO Generation
###############################################################################
log "Preparing bootloader"
touch "$ISODIR/.win11-live"
echo "Win11-Linux Minimal [$PROFILE] (Ubuntu $RELEASE) - $(date -u +%Y-%m-%d)" > "$ISODIR/.disk/info"

if [[ "$PROFILE" == "lite" ]]; then
  CMDLINE="boot=casper loglevel=3 mitigations=off nowatchdog fsck.mode=skip noresume"
  cat > "$ISODIR/boot/grub/grub.cfg" <<EOF
search --no-floppy --set=root --file /.win11-live
insmod all_video
set gfxpayload=text
set default=0
set timeout=2

menuentry "Win11-Linux Minimal (live, 1 GB RAM friendly)" {
    linux /casper/vmlinuz $CMDLINE quiet splash ---
    initrd /casper/initrd
}
menuentry "Safe graphics (nomodeset)" {
    linux /casper/vmlinuz $CMDLINE nomodeset quiet splash ---
    initrd /casper/initrd
}
menuentry "Text mode only (boot test)" {
    linux /casper/vmlinuz $CMDLINE systemd.unit=multi-user.target ---
    initrd /casper/initrd
}
menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check ---
    initrd /casper/initrd
}
EOF
else
  cat > "$ISODIR/boot/grub/grub.cfg" <<'EOF'
search --no-floppy --set=root --file /.win11-live
insmod all_video
set default=0
set timeout=5

menuentry "Win11-Linux Minimal (KDE live)" {
    linux /casper/vmlinuz boot=casper quiet ---
    initrd /casper/initrd
}
menuentry "Safe graphics (nomodeset)" {
    linux /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd
}
menuentry "Load to RAM" {
    linux /casper/vmlinuz boot=casper toram quiet ---
    initrd /casper/initrd
}
menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet ---
    initrd /casper/initrd
}
EOF
fi

cat > "$BOOTWORK/grub-embed.cfg" <<'EOF'
search --no-floppy --set=root --file /.win11-live
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

MODS="linux normal iso9660 search search_fs_file configfile all_video gzio part_msdos part_gpt fat echo test"

grub-mkstandalone --format=i386-pc --output="$BOOTWORK/core.img" \
  --install-modules="$MODS biosdisk memdisk tar ls" \
  --modules="linux normal iso9660 biosdisk search" \
  --locales="" --fonts="" \
  "boot/grub/grub.cfg=$BOOTWORK/grub-embed.cfg"
cat /usr/lib/grub/i386-pc/cdboot.img "$BOOTWORK/core.img" > "$BOOTWORK/bios.img"

grub-mkstandalone --format=x86_64-efi --output="$BOOTWORK/bootx64.efi" \
  --locales="" --fonts="" \
  "boot/grub/grub.cfg=$BOOTWORK/grub-embed.cfg"
dd if=/dev/zero of="$BOOTWORK/efiboot.img" bs=1M count=16 status=none
mkfs.vfat -n WIN11EFI "$BOOTWORK/efiboot.img" >/dev/null
mmd   -i "$BOOTWORK/efiboot.img" ::EFI ::EFI/BOOT
mcopy -i "$BOOTWORK/efiboot.img" "$BOOTWORK/bootx64.efi" ::EFI/BOOT/BOOTx64.EFI

log "Writing md5sum.txt"
( cd "$ISODIR" && find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt )

log "Building hybrid BIOS/UEFI ISO with xorriso"
rm -f "$ISO_PATH"
( cd "$ISODIR" && xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
    -volid "$VOLID" \
    -output "$ISO_PATH" \
    -eltorito-boot boot/grub/bios.img \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      --eltorito-catalog boot/grub/boot.cat \
      --grub2-boot-info --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot -e EFI/efiboot.img -no-emul-boot \
    -append_partition 2 0xef "$BOOTWORK/efiboot.img" \
    -graft-points \
      "/EFI/efiboot.img=$BOOTWORK/efiboot.img" \
      "/boot/grub/bios.img=$BOOTWORK/bios.img" \
      "." )

###############################################################################
# 12. Size check & release packaging
###############################################################################
bytes=$(stat -c %s "$ISO_PATH")
gb=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b/1000000000 }')
log "Final ISO size: ${gb} GB"

(
  cd "$OUTDIR"
  rm -f "$ZIP_NAME" "$ZIP_NAME".[0-9]* SHA256SUMS.txt release-assets.txt
  zip -q -1 "$ZIP_NAME" "$ISO_NAME"
  split -b "${CHUNK_MB}M" -d -a 3 --numeric-suffixes=1 "$ZIP_NAME" "$ZIP_NAME."
  rm -f "$ZIP_NAME"
  mapfile -t ZIP_PARTS < <(ls -1 "$ZIP_NAME".[0-9][0-9][0-9] | sort)

  {
    echo "# Win11-Linux Minimal - SHA256SUMS"
    for f in "$ISO_NAME" "${ZIP_PARTS[@]}"; do
      echo "# $(stat -c %s "$f")  $f"
    done
    sha256sum "$ISO_NAME" "${ZIP_PARTS[@]}"
  } > SHA256SUMS.txt

  {
    if (( $(stat -c %s "$ISO_NAME") < GH_ASSET_LIMIT )); then echo "$ISO_NAME"; fi
    printf '%s\n' "${ZIP_PARTS[@]}"
    echo "SHA256SUMS.txt"
  } > release-assets.txt
)

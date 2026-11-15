#!/usr/bin/env bash
#
# build-mini-win11-linux.sh
#
# Builds a bootable hybrid BIOS/UEFI live ISO (< 5 GB) from a minimal Ubuntu
# 24.04 LTS (noble) debootstrap, with a minimal KDE Plasma desktop restyled to
# look like Windows 11, plus Wine, Flatpak and the standard Linux services.
#
# Run as root on an Ubuntu/Debian host with ~25 GB free disk and network:
#     sudo ./build-mini-win11-linux.sh [--run-qemu]
#
# Optional environment variables:
#     WORKDIR=<dir>          work directory            (default: ./mini-win11-build)
#     OUTDIR=<dir>           where the .iso is written (default: .)
#     ISO_NAME=<file>        output ISO name           (default: win11-linux-minimal.iso)
#     ZIP_NAME=<file>        split ZIP base name       (default: ISO_NAME with .zip)
#     CHUNK_MB=1800          ZIP volume size in MiB    (< 1.9 GB per part)
#     MIRROR / SEC_MIRROR    Ubuntu mirrors
#     WITH_WINE32=1          add i386 multiarch + wine32 (+~300 MB)
#     PRUNE_FIRMWARE=0       keep all of linux-firmware (+~150-250 MB)
#     THEME_KDE_REPO / THEME_ICON_REPO   theme git repos (pin a commit/fork for
#                            reproducible builds; upstream layout may change)
#
# Notes:
#   * Uses linux-image-generic + linux-modules-extra + linux-firmware instead of
#     the linux-generic metapackage, to avoid shipping kernel headers.
#   * Secure Boot is not supported (unsigned GRUB). Disable Secure Boot or
#     replace the EFI binary with shim + signed GRUB.
#   * sshd is installed/enabled but ufw is enabled with default-deny incoming,
#     so SSH is unreachable until you run: sudo ufw allow ssh
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
CHUNK_MB="${CHUNK_MB:-1800}"             # 1800 MiB = ~1.89 GB per part
GH_ASSET_LIMIT=2000000000                # raw ISO is only a release asset if below this
VOLID="WIN11_LINUX"

LIVE_USER="win11"
LIVE_HOSTNAME="win11-linux"

WITH_WINE32="${WITH_WINE32:-0}"
PRUNE_FIRMWARE="${PRUNE_FIRMWARE:-1}"
THEME_KDE_REPO="${THEME_KDE_REPO:-https://github.com/yeyushengfan258/Win11OS-kde.git}"
THEME_ICON_REPO="${THEME_ICON_REPO:-https://github.com/yeyushengfan258/Win11-icon-theme.git}"

MAX_BYTES=4800000000      # hard fail above 4.8 GB (decimal)
TARGET_BYTES=3800000000   # warn above 3.8 GB
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

# Run a command inside the chroot with a clean environment.
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
# 1. Fetch theme sources on the host (keeps git out of the image)
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
fetch_repo "$THEME_KDE_REPO"  "$SRCDIR/Win11OS-kde"
fetch_repo "$THEME_ICON_REPO" "$SRCDIR/Win11-icon-theme"

###############################################################################
# 2. Bootstrap minimal Ubuntu 24.04
###############################################################################
log "Bootstrapping Ubuntu $RELEASE ($ARCH, minbase)"
KEYRING_OPT=()
[[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] && \
  KEYRING_OPT=(--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg)

debootstrap --arch="$ARCH" --variant=minbase --components=main,universe \
  "${KEYRING_OPT[@]}" \
  --include=ca-certificates,gnupg,locales,apt-utils \
  "$RELEASE" "$ROOTFS" "$MIRROR"

mount_chroot

# DNS for the chroot (avoid host's 127.0.0.53 stub)
if [[ -s /run/systemd/resolve/resolv.conf ]]; then
  cp -L /run/systemd/resolve/resolv.conf "$ROOTFS/etc/resolv.conf"
else
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOTFS/etc/resolv.conf"
fi

# Never start daemons inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

###############################################################################
# 3. APT / dpkg configuration: no recommends, no docs, no extra locales, no snap
###############################################################################
log "Configuring apt and dpkg for minimal size"
rm -f "$ROOTFS/etc/apt/sources.list.d/ubuntu.sources"
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
# 4. Core Linux system, live-boot scripts, kernel
###############################################################################
log "Installing core system and casper"
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
apt_install "${CORE_PKGS[@]}"

log "Generating en_US.UTF-8 locale only"
echo 'en_US.UTF-8 UTF-8' > "$ROOTFS/etc/locale.gen"
chroot_sh locale-gen
chroot_sh update-locale LANG=en_US.UTF-8

log "Installing kernel and firmware"
echo 'RESUME=none' > "$ROOTFS/etc/initramfs-tools/conf.d/resume"
apt_install linux-image-generic linux-firmware
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
# 5. Minimal KDE Plasma desktop (no kde-full)
###############################################################################
log "Installing minimal KDE Plasma"
chroot_sh bash -c 'echo "sddm shared/default-x-display-manager select sddm" | debconf-set-selections'

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
  dolphin kio-extras ark gwenview konsole spectacle falkon
  libkf5config-bin qt5-style-kvantum
  qml-module-qtquick-controls qml-module-qtquick-controls2 qml-module-qtquick-layouts
  qml-module-qtgraphicaleffects libqt5svg5
  fonts-inter fonts-noto-core fonts-noto-color-emoji
)
apt_install "${GUI_PKGS[@]}"

###############################################################################
# 6. Wine (minimal) and Flatpak
###############################################################################
log "Installing Wine and Flatpak"
if [[ "$WITH_WINE32" == "1" ]]; then
  chroot_sh dpkg --add-architecture i386
  chroot_sh apt-get update
  apt_install wine wine64 libwine fonts-wine wine32:i386 libwine:i386
else
  apt_install wine wine64 libwine fonts-wine
fi
apt_install flatpak

mkdir -p "$ROOTFS/etc/flatpak/remotes.d"
curl -fsSL https://dl.flathub.org/repo/flathub.flatpakrepo \
  -o "$ROOTFS/etc/flatpak/remotes.d/flathub.flatpakrepo" \
  || warn "Could not download flathub.flatpakrepo; add it manually later"

###############################################################################
# 7. Windows 11 look and feel
###############################################################################
log "Installing Windows 11 themes"
mkdir -p "$ROOTFS/tmp/themes"
for d in Win11OS-kde Win11-icon-theme; do
  [[ -d "$SRCDIR/$d" ]] && cp -a "$SRCDIR/$d" "$ROOTFS/tmp/themes/$d"
done

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
  || ( cd "$ICO" && bash ./install.sh ) >>/tmp/icon-install.log 2>&1 \
  || echo "WARN: Win11 icon theme install.sh failed (see /tmp/icon-install.log)"
fi

if [ -d "$KDE" ]; then
  cp_tree "$KDE/aurorae/themes"        /usr/share/aurorae/themes   || cp_tree "$KDE/aurorae" /usr/share/aurorae/themes
  cp_tree "$KDE/color-schemes"         /usr/share/color-schemes
  cp_tree "$KDE/plasma/desktoptheme"   /usr/share/plasma/desktoptheme
  cp_tree "$KDE/plasma/look-and-feel"  /usr/share/plasma/look-and-feel
  cp_tree "$KDE/sddm/themes"           /usr/share/sddm/themes      || cp_tree "$KDE/sddm" /usr/share/sddm/themes
  cp_tree "$KDE/Kvantum"               /usr/share/Kvantum
  cp_tree "$KDE/wallpapers"            /usr/share/backgrounds/win11 || cp_tree "$KDE/wallpaper" /usr/share/backgrounds/win11
fi
gtk-update-icon-cache -f /usr/share/icons/Win11 >/dev/null 2>&1 || true
exit 0
STAGE_EOF
chroot_sh bash /tmp/install-themes.sh || warn "Theme installation reported errors; falling back to Breeze where needed"

log "Writing desktop configuration (skel, SDDM, Dolphin, panel layout)"
cat > "$ROOTFS/tmp/configure-desktop.sh" <<'STAGE_EOF'
#!/bin/bash
set -u
export XDG_CONFIG_HOME=/etc/skel/.config
mkdir -p "$XDG_CONFIG_HOME" /etc/win11-linux /etc/sddm.conf.d

pick() { # dir pattern -> prefers non-dark variant
  local x
  x=$(ls -1 "$1" 2>/dev/null | grep -i -- "$2" | grep -iv dark | head -1)
  [ -z "$x" ] && x=$(ls -1 "$1" 2>/dev/null | grep -i -- "$2" | head -1)
  echo "$x"
}
kw() { # file group key value [type]
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

echo "detected: LAF=$LAF DT=$DT AUR=$AUR COLOR=$COLOR ICON=$ICON KV=$KV SDDM=$SDDMTHEME WALL=$WALL"

# --- kdeglobals ---
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

# --- Plasma theme, Kvantum ---
[ -n "$DT" ] && kw plasmarc Theme name "$DT"
if [ -n "$KV" ]; then
  mkdir -p "$XDG_CONFIG_HOME/Kvantum"
  kw Kvantum/kvantum.kvconfig General theme "$KV"
fi

# --- KWin: Aurorae decoration (rounded), buttons on the right like Windows ---
if [ -n "$AUR" ]; then
  kw kwinrc org.kde.kdecoration2 library org.kde.kwin.aurorae
  kw kwinrc org.kde.kdecoration2 theme "__aurorae__svg__$AUR"
fi
kw kwinrc org.kde.kdecoration2 ButtonsOnLeft ""
kw kwinrc org.kde.kdecoration2 ButtonsOnRight "IAX"
kw kwinrc Plugins blurEnabled true bool

# --- Live-session comfort ---
kw kscreenlockerrc Daemon Autolock false bool
kw kscreenlockerrc Daemon LockOnResume false bool
kw ksplashrc KSplash Theme None

# --- Dolphin: Windows Explorer-like (details view, full path, status bar) ---
kw dolphinrc General ShowFullPath true bool
kw dolphinrc General BrowseThroughArchives true bool
kw dolphinrc General ShowStatusBar FullWidth
kw dolphinrc General RememberOpenedTabs false bool
VP=/etc/skel/.local/share/dolphin/view_properties/global
mkdir -p "$VP"
cat > "$VP/.directory" <<EOF
[Dolphin]
Timestamp=2024,1,1,0,0,0
Version=4
ViewMode=1
SortRole=text
SortFoldersFirst=true
VisibleRoles=Details_text,Details_modificationtime,Details_type,Details_size
EOF

# --- Windows-like home folders ---
mkdir -p /etc/skel/{Desktop,Documents,Downloads,Pictures,Music,Videos}

# --- GTK apps follow the look ---
mkdir -p /etc/skel/.config/gtk-3.0
cat > /etc/skel/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-icon-theme-name=${ICON:-breeze}
gtk-font-name=Inter 10
gtk-application-prefer-dark-theme=false
EOF

# --- SDDM: autologin into the casper live user, themed greeter ---
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

# --- First-login values consumed by /usr/local/bin/win11-first-login ---
cat > /etc/win11-linux/theme.env <<EOF
LAF="$LAF"
WALLPAPER="$WALL"
EOF
exit 0
STAGE_EOF
chroot_sh LIVE_USER="$LIVE_USER" bash /tmp/configure-desktop.sh

# First-login script: applies look-and-feel, builds the centered Win11 taskbar
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

/* fixed spacer balances the system tray so the app icons sit in the center */
var pad = panel.addWidget("org.kde.plasma.panelspacer");
pad.currentConfigGroup = ["General"];
pad.writeConfig("expanding", false);
pad.writeConfig("length", 200);

panel.addWidget("org.kde.plasma.panelspacer");          /* expanding left  */

var start = panel.addWidget("org.kde.plasma.kickoff");  /* Start button    */
start.currentConfigGroup = ["General"];
start.writeConfig("icon", "start-here-kde");

var tasks = panel.addWidget("org.kde.plasma.icontasks"); /* icon-only taskbar */
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers",
  "preferred://filemanager,preferred://browser,applications:org.kde.konsole.desktop,applications:org.kde.discover.desktop");

panel.addWidget("org.kde.plasma.panelspacer");          /* expanding right */

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

# ufw: enabled at boot, default deny incoming (no iptables calls needed in chroot)
sed -i 's/^ENABLED=.*/ENABLED=yes/' "$ROOTFS/etc/ufw/ufw.conf"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' "$ROOTFS/etc/default/ufw"

chroot_sh systemctl enable NetworkManager systemd-resolved systemd-timesyncd \
  bluetooth cups ssh ufw sddm
chroot_sh systemctl set-default graphical.target
chroot_sh systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true

###############################################################################
# 9. Aggressive size reduction, initramfs rebuild
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

# Docs, man pages, info, non-English locales (copyright files are kept)
find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null
find /usr/share/doc -type d -empty -delete 2>/dev/null
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/groff /usr/share/lintian /usr/share/gtk-doc
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name locale.alias -exec rm -rf {} + 2>/dev/null

# Rebuild initramfs with casper + all modules
update-initramfs -u -k all

# Caches and leftovers
apt-get -y clean
rm -rf /var/cache/apt/archives/* /var/cache/apt/*.bin /var/lib/apt/lists/* \
       /var/cache/debconf/*-old /var/lib/dpkg/*-old /var/cache/ldconfig/aux-cache
rm -rf /root/.cache /root/.wget-hsts /var/tmp/*
find / -xdev -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null
exit 0
STAGE_EOF
chroot_sh PRUNE_FIRMWARE="$PRUNE_FIRMWARE" bash /tmp/slim.sh

# Kernel + initrd go next to the squashfs on the ISO
VMLINUZ="$(ls -1 "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)"
INITRD="$(ls -1 "$ROOTFS"/boot/initrd.img-* | sort -V | tail -1)"
[[ -f "$VMLINUZ" && -f "$INITRD" ]] || die "Kernel/initrd not found in chroot /boot"
cp "$VMLINUZ" "$ISODIR/casper/vmlinuz"
cp "$INITRD"  "$ISODIR/casper/initrd"
chmod 644 "$ISODIR/casper/vmlinuz" "$ISODIR/casper/initrd"

# Manifest (before the final wipe of /tmp)
chroot_sh dpkg-query -W --showformat='${Package}\t${Version}\n' > "$ISODIR/casper/filesystem.manifest"

# Final root cleanup, then detach mounts before packing
rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/tmp/.[!.]* 2>/dev/null || true
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
rm -f "$ROOTFS/usr/sbin/policy-rc.d"
unmount_chroot
rm -f "$ROOTFS/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
printf '%s' "$(du -sx --block-size=1 "$ROOTFS" | cut -f1)" > "$ISODIR/casper/filesystem.size"

###############################################################################
# 10. SquashFS with maximum xz compression
###############################################################################
log "Creating filesystem.squashfs (xz, 1M blocks, 100% dictionary) - this takes a while"
mksquashfs "$ROOTFS" "$ISODIR/casper/filesystem.squashfs" \
  -comp xz -b 1M -Xdict-size 100% -Xbcj x86 \
  -noappend -no-recovery -processors "$(nproc)" \
  -wildcards -e 'boot/vmlinuz*' 'boot/initrd.img*' 'boot/System.map*' 'boot/config-*' \
  -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*'

###############################################################################
# 11. GRUB (BIOS + UEFI) and hybrid ISO
###############################################################################
log "Preparing bootloader"
touch "$ISODIR/.win11-live"
echo "Mini Win11 Linux (Ubuntu $RELEASE) - $(date -u +%Y-%m-%d)" > "$ISODIR/.disk/info"

cat > "$ISODIR/boot/grub/grub.cfg" <<'EOF'
search --no-floppy --set=root --file /.win11-live
insmod all_video
set default=0
set timeout=5

menuentry "Mini Win11 Linux (live)" {
    linux /casper/vmlinuz boot=casper quiet ---
    initrd /casper/initrd
}
menuentry "Mini Win11 Linux (safe graphics)" {
    linux /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd
}
menuentry "Mini Win11 Linux (load to RAM)" {
    linux /casper/vmlinuz boot=casper toram quiet ---
    initrd /casper/initrd
}
menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet ---
    initrd /casper/initrd
}
EOF

cat > "$BOOTWORK/grub-embed.cfg" <<'EOF'
search --no-floppy --set=root --file /.win11-live
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

MODS="linux normal iso9660 search search_fs_file configfile all_video gzio part_msdos part_gpt fat echo test"

# BIOS: cdboot.img + standalone core.img
grub-mkstandalone --format=i386-pc --output="$BOOTWORK/core.img" \
  --install-modules="$MODS biosdisk memdisk tar ls" \
  --modules="linux normal iso9660 biosdisk search" \
  --locales="" --fonts="" \
  "boot/grub/grub.cfg=$BOOTWORK/grub-embed.cfg"
cat /usr/lib/grub/i386-pc/cdboot.img "$BOOTWORK/core.img" > "$BOOTWORK/bios.img"

# UEFI: standalone BOOTx64.EFI inside a FAT image
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
# 12. Strict size check
###############################################################################
bytes=$(stat -c %s "$ISO_PATH")
gb=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b/1000000000 }')
log "Final ISO: $ISO_PATH"
log "Final ISO size: ${gb} GB (${bytes} bytes)"
if (( bytes > MAX_BYTES )); then
  die "ISO is ${gb} GB, which exceeds the 4.8 GB limit. Re-run with PRUNE_FIRMWARE=1, drop packages from GUI_PKGS (e.g. falkon, mesa-vulkan-drivers), or unset WITH_WINE32."
elif (( bytes > TARGET_BYTES )); then
  warn "ISO is ${gb} GB: under the 4.8 GB limit but above the 3.8 GB target."
else
  log "Size OK: within the 2.5-3.8 GB target range or smaller."
fi

###############################################################################
# 13. Release artifacts: ISO, split ZIP (parts < 1.9 GB), SHA256SUMS.txt
###############################################################################
log "Packaging release artifacts"
(
  cd "$OUTDIR"
  rm -f "$ZIP_NAME" "$ZIP_NAME".[0-9]* SHA256SUMS.txt release-assets.txt

  # Split ZIP: <name>.zip.001, .002, ... (reassemble: cat <name>.zip.* > <name>.zip)
  zip -q -1 "$ZIP_NAME" "$ISO_NAME"
  split -b "${CHUNK_MB}M" -d -a 3 --numeric-suffixes=1 "$ZIP_NAME" "$ZIP_NAME."
  rm -f "$ZIP_NAME"
  mapfile -t ZIP_PARTS < <(ls -1 "$ZIP_NAME".[0-9][0-9][0-9] | sort)
  (( ${#ZIP_PARTS[@]} )) || die "No ZIP parts were produced"

  # Checksum manifest: size comments + standard sha256sum lines
  {
    echo "# Win11-Linux Minimal - SHA256SUMS"
    echo "# Verify: sha256sum -c --ignore-missing SHA256SUMS.txt"
    echo "# <size in bytes>  <file>"
    for f in "$ISO_NAME" "${ZIP_PARTS[@]}"; do
      echo "# $(stat -c %s "$f")  $f"
    done
    sha256sum "$ISO_NAME" "${ZIP_PARTS[@]}"
  } > SHA256SUMS.txt

  # Files to attach to a GitHub release (single asset limit is 2 GiB)
  {
    if (( $(stat -c %s "$ISO_NAME") < GH_ASSET_LIMIT )); then echo "$ISO_NAME"; fi
    printf '%s\n' "${ZIP_PARTS[@]}"
    echo "SHA256SUMS.txt"
  } > release-assets.txt
)
log "Release assets:"; sed 's/^/    /' "$OUTDIR/release-assets.txt"
if ! grep -qx "$ISO_NAME" "$OUTDIR/release-assets.txt"; then
  warn "ISO exceeds the GitHub asset limit; it ships as split ZIP parts (full ISO stays in the workflow artifact)."
fi

###############################################################################
# 14. QEMU verification commands
###############################################################################
if [[ -w /dev/kvm ]]; then ACCEL="-enable-kvm -cpu host"; else ACCEL="-cpu max"; fi

QEMU_BIOS="qemu-system-x86_64 $ACCEL -machine q35 -smp 4 -m 4G \
-cdrom \"$ISO_PATH\" -boot d -device virtio-vga -display gtk \
-audiodev pa,id=snd0 -device ich9-intel-hda -device hda-duplex,audiodev=snd0 \
-nic user,model=virtio-net-pci"

QEMU_UEFI="$QEMU_BIOS -bios /usr/share/ovmf/OVMF.fd"

cat <<EOF

================ Test the ISO in QEMU ================
# BIOS (legacy):
$QEMU_BIOS

# UEFI (needs: apt install ovmf qemu-system-x86):
$QEMU_UEFI

# Write to USB (replace /dev/sdX!):
sudo dd if="$ISO_PATH" of=/dev/sdX bs=4M status=progress conv=fsync
======================================================
EOF

if (( RUN_QEMU )); then
  command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed (apt install qemu-system-x86)"
  log "Launching QEMU (BIOS mode)"
  eval "$QEMU_BIOS"
fi

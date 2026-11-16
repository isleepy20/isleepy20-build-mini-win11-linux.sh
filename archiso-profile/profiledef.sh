#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="win11-arch-minimal"
iso_label="ARCH_WIN11_$(date +%Y%m)"
iso_publisher="Casey <https://github.com/isleepy20>"
iso_application="Arch Linux Win11 Live ISO"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
archps="x86_64"
airootfs_image_type="squashfs"
airootfs_image_tool_options=("-comp" "zstd" "-Xcompression-level" "19")
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/usr/local/bin/switch-theme"]="0:0:755"
)

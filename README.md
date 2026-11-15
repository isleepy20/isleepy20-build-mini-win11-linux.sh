# Win11-Linux Minimal

A lightweight, high-performance Windows 11 styled Linux OS built on Ubuntu 24.04 LTS.

[![Build](https://github.com/isleepy20/build-mini-win11-linux.sh/actions/workflows/build.yml/badge.svg)](https://github.com/isleepy20/build-mini-win11-linux.sh/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Base OS](https://img.shields.io/badge/base-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)

## Downloads

<!-- RELEASE:START -->
| Asset | Description | Size | SHA-256 |
|---|---|---|---|
| [`win11-linux-minimal.iso`](https://github.com/isleepy20/isleepy20-build-mini-win11-linux.sh/releases/download/v1.0.7/win11-linux-minimal.iso) | Bootable hybrid BIOS/UEFI ISO | 1.37 GiB | `e990354173433d80…` |
| [`win11-linux-minimal.zip.001`](https://github.com/isleepy20/isleepy20-build-mini-win11-linux.sh/releases/download/v1.0.7/win11-linux-minimal.zip.001) | Compressed archive, part 1 of 1 | 1.34 GiB | `be4a5c82ebfcd9e8…` |
| [`SHA256SUMS.txt`](https://github.com/isleepy20/isleepy20-build-mini-win11-linux.sh/releases/download/v1.0.7/SHA256SUMS.txt) | Checksums and exact sizes | 299 B | n/a |

Release **v1.0.7**. Download every `win11-linux-minimal.zip.NNN` part, then:

```bash
cat win11-linux-minimal.zip.* > win11-linux-minimal.zip && unzip win11-linux-minimal.zip
sha256sum -c --ignore-missing SHA256SUMS.txt
```
<!-- RELEASE:END -->

Latest builds: [Releases](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/latest)

## Features

- **Base:** Ubuntu 24.04 LTS (noble), `debootstrap` minbase, no snaps, `en_US.UTF-8` only
- **Boot:** hybrid BIOS and UEFI ISO, live session via `casper`, xz-compressed SquashFS (`-comp xz -b 1M -Xdict-size 100%`)
- **Services:** `systemd`, `NetworkManager`, `PipeWire` + `WirePlumber`, `BlueZ`, `CUPS`, `ufw`, `OpenSSH`
- **Desktop:** minimal KDE Plasma (no `kde-full`) with a Windows 11 look: Win11OS-kde theme, Win11 icons, centered taskbar, Start menu, rounded windows, Explorer-style Dolphin
- **Apps:** `Wine` (64-bit core) for `.exe` files, `Flatpak` with Flathub preconfigured, Discover, Falkon

## Verify and boot

Verify integrity (parts and ISO you downloaded):

```bash
sha256sum -c --ignore-missing SHA256SUMS.txt
```

Rebuild the ISO from split ZIP parts:

```bash
cat win11-linux-minimal.zip.* > win11-linux-minimal.zip
unzip win11-linux-minimal.zip
```

Boot in QEMU (BIOS):

```bash
qemu-system-x86_64 -enable-kvm -cpu host -machine q35 -smp 4 -m 4G \
  -cdrom win11-linux-minimal.iso -boot d -device virtio-vga -display gtk \
  -nic user,model=virtio-net-pci
```

Boot in QEMU (UEFI, needs `ovmf`):

```bash
qemu-system-x86_64 -enable-kvm -cpu host -machine q35 -smp 4 -m 4G \
  -bios /usr/share/ovmf/OVMF.fd -cdrom win11-linux-minimal.iso -boot d \
  -device virtio-vga -display gtk -nic user,model=virtio-net-pci
```

Vectras VM (Android): create an x86_64 VM, attach the ISO as CD-ROM, set 4 GB RAM, boot from CD.

## Build from source

Run as root on Ubuntu or Debian with about 25 GB free disk and network access:

```bash
sudo ./build-mini-win11-linux.sh
```

Output goes to the current directory: the ISO, `win11-linux-minimal.zip.001…`, `SHA256SUMS.txt`. The build fails if the ISO exceeds 4.8 GB. CI (`.github/workflows/build.yml`) does the same on every push to `main`, publishes a release, updates this table, and sets the repository About text and topics. Setting those needs a token with admin rights stored as the secret `REPO_ADMIN_TOKEN`.

## Notes

- Live user `win11`, no password, passwordless `sudo`, auto-login.
- `ufw` is enabled with incoming traffic denied. SSH stays unreachable until you run `sudo ufw allow ssh`.
- Secure Boot is not supported. Disable it in firmware.
- Not affiliated with Microsoft. Themes come from the upstream Win11OS-kde and Win11-icon-theme projects under their own licenses.

## License

[MIT](LICENSE) for the build script and workflow.

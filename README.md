# Win11-Linux Minimal

A lightweight, high-performance live Linux distribution featuring an XFCE desktop restyled with a Windows 11 aesthetic, optimized for mobile virtualization (Limbo, QEMU) and low-RAM environments.

## Features
* **Lightweight Footprint:** Sub-1 GB ISO built to boot smoothly under 1 GB of RAM.
* **Dual Boot Support:** Hybrid BIOS (`i386-pc`) and UEFI (`x86_64-efi`) bootable image.
* **Windows 11 Aesthetic:** Custom taskbar layout, icon packs, wallpaper, and theme switcher.
* **Pre-configured Stack:** Includes Wine, Flatpak, NetworkManager, PipeWire audio, and zram swap compression.

---

## Download & Release Assets

<!-- RELEASE:START -->
| Asset | Description | Size | SHA-256 |
|---|---|---|---|
| [`win11-linux-minimal.iso`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/download/v1.0.18/win11-linux-minimal.iso) | Bootable hybrid BIOS/UEFI ISO | 669.2 MiB | `bb0a2aad1031101d…` |
| [`win11-linux-minimal.zip.001`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/download/v1.0.18/win11-linux-minimal.zip.001) | Compressed archive, part 1 of 1 | 637.5 MiB | `1e6bf7e55fb7eecb…` |
| [`SHA256SUMS.txt`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/download/v1.0.18/SHA256SUMS.txt) | Checksums and exact sizes | 297 B | n/a |

Release **v1.0.18**. Download every `win11-linux-minimal.zip.NNN` part, then:

```bash
cat win11-linux-minimal.zip.* > win11-linux-minimal.zip && unzip win11-linux-minimal.zip
sha256sum -c --ignore-missing SHA256SUMS.txt

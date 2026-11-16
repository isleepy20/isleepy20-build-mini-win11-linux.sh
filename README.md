# Custom Win11-Linux Minimal OS

A lightweight, high-performance customized live Linux distribution featuring an XFCE desktop restyled with a Windows 11 aesthetic, optimized for mobile virtualization (Limbo, QEMU) and low RAM environments.

## ✨ Features
* **Lightweight Base:** Minimal footprint designed to boot smoothly under 1 GB of RAM[cite: 3].
* **Dual Boot Support:** Built as a hybrid ISO supporting both Legacy BIOS (`i386-pc`) and UEFI (`x86_64-efi`)[cite: 3].
* **Windows 11 Skin & Theme Toggle:** Custom taskbar layouts, icon themes, and wallpaper configurations with an integrated toggle script.
* **Pre-configured Stack:** Includes networking, audio support via PipeWire, and minimal system components.

---

## 📦 Download & Release Assets

The table below is automatically updated with the latest build artifacts and checksums whenever a release is published:

<!-- RELEASE:START -->
| Asset | Description | Size | SHA-256 |
|---|---|---|---|
| [`win11-linux-minimal.iso`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/download/v1.0.1/win11-linux-minimal.iso) | Bootable hybrid BIOS/UEFI ISO | 850.0 MiB | `a1b2c3d4e5f6g7h8…` |
| [`SHA256SUMS.txt`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/download/v1.0.1/SHA256SUMS.txt) | Checksums and exact sizes | 142 B | n/a |
<!-- RELEASE:END -->

---

## 🚀 How to Verify and Use

1. Download the ISO artifact directly from the [Releases page](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases).
2. Verify the download integrity using the checksum file:
   ```bash
   sha256sum -c --ignore-missing SHA256SUMS.txt

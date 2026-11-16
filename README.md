# Custom Win11-Linux Minimal OS

A lightweight, high-performance customized live Linux distribution featuring an XFCE desktop restyled with a Windows 11 aesthetic, optimized for mobile virtualization (Limbo, QEMU) and low RAM environments.

## ✨ Features
* **Lightweight Base:** Minimal footprint designed to boot smoothly under 1 GB of RAM[cite: 3].
* **Dual Boot Support:** Built as a hybrid ISO supporting both Legacy BIOS (`i386-pc`) and UEFI (`x86_64-efi`)[cite: 3].
* **Windows 11 Skin & Theme Toggle:** Custom taskbar layouts, icon themes, and wallpaper configurations with an integrated toggle script.
* **Pre-configured Stack:** Includes networking, audio support via PipeWire, and minimal system components.

---

## 📦 Download & Release Assets

The latest build artifacts, split archives, and checksums are available below:

<!-- RELEASE:START -->
| Asset | Description | Size | SHA-256 |
|---|---|---|---|
| [`win11-linux-minimal.iso`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/latest/download/win11-linux-minimal.iso) | Bootable hybrid BIOS/UEFI ISO | ~850 MiB | *See checksums* |
| [`win11-linux-minimal.zip.001`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/latest/download/win11-linux-minimal.zip.001) | Split compressed archive (Part 1) | ~1.8 GiB | *See checksums* |
| [`SHA256SUMS.txt`](https://github.com/isleepy20/isleepy20-my-arch-win11-iso/releases/latest/download/SHA256SUMS.txt) | Checksums and exact sizes | 142 B | n/a |
<!-- RELEASE:END -->

Release **v1.0** (or your latest workflow run). If you downloaded the split zip parts, combine and verify them using:

```bash
cat win11-linux-minimal.zip.* > win11-linux-minimal.zip && unzip win11-linux-minimal.zip
sha256sum -c --ignore-missing SHA256SUMS.txt

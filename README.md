# Win11-Linux Minimal

A lightweight, high-performance Windows 11 styled Linux OS built on Ubuntu 24.04 LTS.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Base OS](https://img.shields.io/badge/base-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)

## Downloads

<!-- RELEASE:START -->
| Asset | Description | Size | SHA-256 |
|---|---|---|---|
| [`win11-linux-minimal.iso`](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/download/v1.0.7/win11-linux-minimal.iso) | Bootable hybrid BIOS/UEFI ISO | 1.37 GiB | `e990354173433d80…` |
| [`win11-linux-minimal.zip.001`](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/download/v1.0.7/win11-linux-minimal.zip.001) | Compressed archive, part 1 of 1 | 1.34 GiB | `be4a5c82ebfcd9e8…` |
| [`SHA256SUMS.txt`](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/download/v1.0.7/SHA256SUMS.txt) | Checksums and exact sizes | 299 B | n/a |

Release **v1.0.7**. Download every `win11-linux-minimal.zip.NNN` part, then:

```bash
cat win11-linux-minimal.zip.* > win11-linux-minimal.zip && unzip win11-linux-minimal.zip
sha256sum -c --ignore-missing SHA256SUMS.txt

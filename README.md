# Win11-Linux Minimal

A lightweight, high-performance Windows 11 styled Linux OS built on Ubuntu 24.04 LTS.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Base OS](https://img.shields.io/badge/base-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)

## Downloads

<!-- RELEASE:START -->
| Asset | Description | Size | SHA-256 |
|---|---|---|---|
| [`win11-linux-minimal.iso`](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/download/v1.0.9/win11-linux-minimal.iso) | Bootable hybrid BIOS/UEFI ISO | 669.2 MiB[cite: 7] | `9827019fefcf…`[cite: 7] |
| [`win11-linux-minimal.zip.001`](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/download/v1.0.9/win11-linux-minimal.zip.001) | Compressed archive, part 1 of 1 | 637.5 MiB[cite: 7] | `476b047c7e17…`[cite: 7] |
| [`SHA256SUMS.txt`](https://github.com/isleepy20/build-mini-win11-linux.sh/releases/download/v1.0.9/SHA256SUMS.txt) | Checksums and exact sizes | 299 B[cite: 7] | n/a[cite: 7] |

Release **v1.0.9**[cite: 7]. Download every `win11-linux-minimal.zip.NNN` part, then[cite: 7]:

```bash
cat win11-linux-minimal.zip.* > win11-linux-minimal.zip && unzip win11-linux-minimal.zip
sha256sum -c --ignore-missing SHA256SUMS.txt

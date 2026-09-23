# ArchLinuxARM Docker Builder

Reproducible ArchLinuxARM builds for ARM boards and emulators, driven entirely by Docker Buildx.

[![Build & Push](https://img.shields.io/github/actions/workflow/status/devDucks/ArchLinuxARM/buildx.yml?branch=main&label=build)](https://github.com/devDucks/ArchLinuxARM/actions)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue)](./LICENSE)

## Overview

This project builds ArchLinuxARM root filesystems and Raspberry Pi disk images using multi-stage Docker builds, entirely on x86_64 via QEMU user-mode emulation. Three images are produced:

| Image | Description |
|---|---|
| **base / minimal** | Alpine-bootstrapped ArchLinuxARM `aarch64` rootfs, produced with `pacman` and `arch-install-scripts` rather than a native chroot. |
| **aarch64** | The base image plus kernel, glibc, `openssh`, and DHCP networking via `systemd-networkd`. |
| **astroarch** | A KDE Plasma desktop image built on top of the aarch64 image, pre-loaded with an astrophotography stack (KStars/Ekos, INDI, PHD2, astrometry.net index files) and remote access via VNC/RDP. |

Each build target can export a rootfs tarball, and the astroarch rootfs can be converted into a bootable Raspberry Pi `.img`.

## Requirements

- Docker with Buildx
- `binfmt`/QEMU support for `arm64` on the build host (the `Makefile` sets this up for you, see below)
- For image creation: `sfdisk`, `losetup`, `mkfs.vfat`, `mkfs.ext4`, `blkid` (Linux only, requires `sudo`)

## Quick start

```bash
git clone git@github.com:MattBlack85/ArchLinuxARM-docker.git
cd ArchLinuxARM-docker
```

Register the `arm64` QEMU binfmt handler (also done automatically by targets that need it):

```bash
make binfmt
```

Build the minimal ArchLinuxARM image:

```bash
make build-minimal
```

Build the full ArchLinuxARM image (kernel, SSH, networking):

```bash
make build-aarch64
```

Build AstroArch (KDE Plasma + astrophotography stack):

```bash
make build-astroarch
```

Build an AUR package (and any AUR-only dependencies) for `aarch64` and copy the resulting package file(s) into the current directory:

```bash
make build-aur PKG=<aur-package-name>
```

`scripts/build-aur.sh` recursively resolves and builds AUR-only dependencies, and PKGBUILDs that don't declare `aarch64` are built anyway via `makepkg --ignorearch`. Dependencies are installed by that script running as root directly (not via `sudo`) — BuildKit mounts `RUN` steps `nosuid`, so a setuid tool like `sudo` can never regain root once a step has dropped to an unprivileged user; only root-to-non-root (`su`, to run `makepkg` itself) works reliably there.

## Make targets

| Target | Description |
|---|---|
| `binfmt` | Registers QEMU's `arm64` binfmt handler on the host. |
| `build-minimal` | Minimal ArchLinuxARM rootfs (`dockerfiles/Dockerfile.base`, `archarm` target). |
| `build-aarch64` | Full ArchLinuxARM image with kernel, SSH, and networking. |
| `build-aarch64-rootfs` | Exports the aarch64 rootfs as `archlinuxarm-aarch64-rootfs.tar`. |
| `build-astroarch` | AstroArch desktop image (KDE + INDI stack). |
| `build-astroarch-rootfs` | Builds the AstroArch rootfs image (`astroarch-rootfs:latest`). |
| `build-aur PKG=<name>` | Builds an AUR package (and any AUR-only dependencies) for `aarch64` (`dockerfiles/Dockerfile.aur`) and copies the resulting `.pkg.tar.*` file(s) into the current directory. |
| `create-rootfs-container` | Creates a throwaway container from `astroarch-rootfs:latest` to extract its filesystem. |
| `copy-rootfs-tar` | Copies `astroarch-rootfs.tar` out of that container into `./rootfs.tar` and removes it. |
| `prepare-img BOARD=<board>` | Builds the rootfs with the board's kernel flavor, then runs `scripts/build_img.sh` to produce a bootable `archarm-<board>-aarch64.img`. `<board>` must match a file in `boards/` (currently `rpi`, `orangepi5b`, `odroid-n2plus`). |

## Image details

### `dockerfiles/Dockerfile.base`

- Bootstraps the ArchLinuxARM `aarch64` userland from an Alpine builder stage (no native chroot required).
- Installs the ArchLinuxARM keyring and package database directly into the target rootfs.
- Final stage (`archarm`) is a `FROM scratch` image containing the rootfs plus `qemu-aarch64-static`, so it runs on x86_64 hosts.
- `export` target produces `archlinuxarm-aarch64-rootfs.tar`.

### `dockerfiles/Dockerfile.aarch64`

- Based on the minimal image (`ghcr.io/devducks/archlinuxarm-basic`).
- Sets the ArchLinuxARM mirrorlist and initializes pacman's keyring.
- Installs `glibc`, `linux-aarch64`, `nano`, `openssh`.
- Configures DHCP networking via `systemd-networkd` and enables `sshd`.
- `export` target produces `archlinuxarm-aarch64-rootfs.tar`.

### `dockerfiles/Dockerfile.astroarch`

- Based on the aarch64 image (`ghcr.io/devducks/archlinuxarm`).
- Adds the AstroMatto package repository.
- Installs KDE Plasma, KStars/Ekos, INDI drivers and third-party drivers, PHD2, TigerVNC, XRDP, and supporting tools.
- Downloads astrometry.net index files into the default user's KStars data directory.
- `astroarch-rootfs` target builds and exports the rootfs directly (no QEMU boot step is needed to finalize the image).

## Building a bootable image

```bash
make prepare-img BOARD=rpi            # Raspberry Pi
make prepare-img BOARD=orangepi5b     # Orange Pi 5 / 5B (rk3588s)
make prepare-img BOARD=odroid-n2plus  # Odroid N2+ (Amlogic S922X)
```

This produces `archarm-<board>-aarch64.img`: a partitioned disk image with a FAT32 `/boot` and an ext4 `/`, built by `scripts/build_img.sh`. Everything board-specific — kernel flavor, boot strategy, partition offset, how to embed a bootloader ahead of the partition table, and the kernel console — lives in `boards/<board>.conf`, not in the script or the Makefile:

| Board | Kernel | Boot strategy | Notes |
|---|---|---|---|
| `rpi` | `linux-rpi` | `firmware` (config.txt/cmdline.txt) | Nothing lives ahead of partition 1. |
| `orangepi5b` | generic `linux-aarch64` | `extlinux` | Embeds a prebuilt rk3588s U-Boot (from [schneid-l/u-boot-rockchip](https://github.com/schneid-l/u-boot-rockchip)) at sector 64, ahead of the partition table. |
| `odroid-n2plus` | generic `linux-aarch64` | `extlinux` | Embeds ArchLinux ARM's mainline U-Boot for the N2 family via a two-step, MBR-preserving write (Amlogic's install scheme, not a single raw offset). **Not yet boot-tested on real hardware.** |

To add a new board, drop in a `boards/<name>.conf` setting `KERNEL_FLAVOR`, `BOOT_STRATEGY` (`firmware` or `extlinux`), `BOOT_START`, `CONSOLE`, and (for `extlinux` boards that need one) `UBOOT_URL`. The default bootloader install is a single `dd` at `UBOOT_OFFSET_SECTORS`; a board whose SoC needs a different write sequence (like Amlogic's MBR-preserving two-step write) overrides the `install_bootloader()` shell function in its own `.conf` instead of touching `scripts/build_img.sh`.

To customize the image before flashing, boot it under QEMU, make your changes, and shut down cleanly:

```bash
./scripts/start_qemu.sh
```

Then flash it to an SD card:

```bash
sudo dd if=archarm-rpi-aarch64.img of=/dev/sdX bs=4M status=progress
sync
```

Insert the card into the board and boot; SSH will be available once DHCP assigns an address.

## Default credentials

| Image | User | Password |
|---|---|---|
| ArchLinuxARM (aarch64) | `root` | `alarm` |
| AstroArch | `astronaut` | `astro` |

SSH is enabled by default on both images. Change these credentials before exposing either image on an untrusted network.

## Mirrors

The aarch64 image's `/etc/pacman.d/mirrorlist` is populated with:

```
Server = http://dk.mirror.archlinuxarm.org/$arch/$repo
Server = http://de3.mirror.archlinuxarm.org/$arch/$repo
Server = http://eu.mirror.archlinuxarm.org/$arch/$repo
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
```

Adjust mirrors by editing the relevant Dockerfile.

## CI/CD

`.github/workflows/buildx.yml` builds and pushes the minimal and aarch64 images to GHCR (`ghcr.io/<owner>/archlinuxarm-basic` and `ghcr.io/<owner>/archlinuxarm`) on pushes to `main`, on version tags, weekly on a schedule, and on manual dispatch. Pull requests build without pushing.

## Project layout

```
.
├── boards/
│   ├── rpi.conf
│   ├── orangepi5b.conf
│   └── odroid-n2plus.conf
├── configs/
│   └── resolv.conf
├── dockerfiles/
│   ├── Dockerfile.base
│   ├── Dockerfile.aarch64
│   └── Dockerfile.astroarch
├── scripts/
│   ├── build_img.sh
│   └── start_qemu.sh
├── Makefile
└── README.md
```

## License

[GPL-3.0](./LICENSE)

#!/usr/bin/env bash
set -euo pipefail

# --- settings ---
BOARD=${BOARD:-rpi}       # rpi | orangepi5b
IMG=${IMG:-archarm-${BOARD}-aarch64.img}
SIZE=${SIZE:-20G}         # total image size
BOOT_MB=${BOOT_MB:-768}   # FAT32 /boot size in MiB
ROOT_LABEL=${ROOT_LABEL:-ALARM_ROOT}
BOOT_LABEL=${BOOT_LABEL:-ALARM_BOOT}
ROOTFS_TAR=${ROOTFS_TAR:-rootfs.tar}
# Orange Pi 5B (rk3588s): pre-built, signed U-Boot + ATF + DDR blob, combined
# into a single binary written raw at sector 64 (32KiB) ahead of the first
# partition. See https://github.com/schneid-l/u-boot-rockchip
UBOOT_URL=${UBOOT_URL:-https://github.com/schneid-l/u-boot-rockchip/releases/latest/download/u-boot-orangepi-5-rk3588s.bin}

# sanity
[ -f "$ROOTFS_TAR" ] || { echo "Missing $ROOTFS_TAR"; exit 1; }
case "$BOARD" in
  rpi|orangepi5b) ;;
  *) echo "Unknown BOARD=$BOARD (expected rpi or orangepi5b)"; exit 1 ;;
esac

# tools needed: sfdisk, losetup, mkfs.vfat, mkfs.ext4, tar, rsync or cp -a
command -v sfdisk >/dev/null
command -v losetup >/dev/null

# --- create sparse disk file ---
truncate -s "$SIZE" "$IMG"

# --- partition table: 768MiB FAT32 boot, rest ext4 root ---
# rpi: 1MiB alignment is enough, nothing lives ahead of partition 1.
# orangepi5b: the rk3588s U-Boot blob (idbloader+u-boot.itb, ~9.3MiB) is
# written raw starting at sector 64, so partition 1 must start well past it -
# 16MiB is the conventional Rockchip/Armbian offset.
if [ "$BOARD" = "orangepi5b" ]; then
  BOOT_START=32768                            # 16MiB (512b sectors)
else
  BOOT_START=2048                             # 1MiB (512b sectors)
fi
BOOT_SIZE=$(( BOOT_MB * 2048 ))               # sectors (MiB * 2048)
sfdisk "$IMG" <<EOF
label: dos
unit: sectors
${IMG}1 : start=${BOOT_START}, size=${BOOT_SIZE}, type=c
${IMG}2 : start=$((BOOT_START+BOOT_SIZE)), type=83
EOF

# --- orangepi5b: fetch and embed U-Boot ahead of the partition table ---
if [ "$BOARD" = "orangepi5b" ]; then
  command -v curl >/dev/null
  UBOOT_BIN=$(mktemp)
  trap 'rm -f "$UBOOT_BIN"' EXIT
  curl -fL "$UBOOT_URL" -o "$UBOOT_BIN"
  dd if="$UBOOT_BIN" of="$IMG" bs=512 seek=64 conv=notrunc,fsync
  rm -f "$UBOOT_BIN"
  trap - EXIT
fi

# --- map loop with partitions ---
LOOP=$(sudo losetup --find --show --partscan "$IMG")
BOOT_DEV=${LOOP}p1
ROOT_DEV=${LOOP}p2
PARTUUID=$(sudo blkid -s PARTUUID -o value "$ROOT_DEV")

# --- mkfs ---
sudo mkfs.vfat -F 32 -n "$BOOT_LABEL" "$BOOT_DEV"
sudo mkfs.ext4 -F -L "$ROOT_LABEL" "$ROOT_DEV"

BOOT_UUID=$(sudo blkid -s UUID -o value "$BOOT_DEV")
ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_DEV")

# --- mount ---
sudo mkdir -p /mnt/arch-root /mnt/arch-boot
sudo mount "$ROOT_DEV" /mnt/arch-root
sudo mkdir -p /mnt/arch-root/boot
sudo mount "$BOOT_DEV" /mnt/arch-boot

# --- extract rootfs (preserve xattrs/owners) ---
sudo tar --numeric-owner -xpf "$ROOTFS_TAR" -C /mnt/arch-root

# --- hostname & hosts (cannot be set during Docker build) ---
echo "astroarch" | sudo tee /mnt/arch-root/etc/hostname >/dev/null
printf '127.0.0.1\tlocalhost\n127.0.1.1\tastroarch\n' | sudo tee -a /mnt/arch-root/etc/hosts >/dev/null

# --- move/copy boot files to the FAT32 partition ---
# Official instructions literally "move root/boot/* to boot" when using their tarball.
# We do the equivalent from our extracted rootfs.
if [ -d /mnt/arch-root/boot ] && [ -n "$(ls -A /mnt/arch-root/boot)" ]; then
  sudo cp -a /mnt/arch-root/boot/* /mnt/arch-boot/
fi

# --- minimal boot config depending on strategy ---
if [ "$BOARD" = "orangepi5b" ]; then
  # U-Boot (embedded ahead of partition 1 above) loads the kernel via
  # extlinux.conf; linux-aarch64 provides /Image, /dtbs, /initramfs-linux.img.
  if [ ! -d /mnt/arch-boot/extlinux ]; then
    sudo install -d /mnt/arch-boot/extlinux
    sudo tee /mnt/arch-boot/extlinux/extlinux.conf >/dev/null <<EOF
DEFAULT arch
MENU TITLE Arch Linux ARM
TIMEOUT 3

LABEL arch
  LINUX /Image
  INITRD /initramfs-linux.img
  FDTDIR /dtbs
  APPEND root=PARTUUID=${PARTUUID} rw rootwait console=ttyS2,1500000
EOF
  fi
else
  # If you installed linux-rpi (+ raspberrypi-bootloader), firmware boots kernel*.img via config.txt/cmdline.txt
  if [ -f /mnt/arch-boot/kernel8.img ]; then
    # Only write a fallback config.txt if the rootfs didn't already provide one (e.g. from astroarch_build.sh)
    if [ ! -f /mnt/arch-boot/config.txt ]; then
      printf 'arm_64bit=1\nenable_uart=1\n' | sudo tee /mnt/arch-boot/config.txt >/dev/null
    fi
    # Fix root= in cmdline.txt: the rootfs copy has the Docker build's /dev/vda2 UUID, not the real PARTUUID.
    # If a cmdline.txt already exists (e.g. from astroarch_build.sh), patch only root=; otherwise write a minimal one.
    if [ -f /mnt/arch-boot/cmdline.txt ]; then
      sudo sed -i "s|root=[^ ]*|root=PARTUUID=${PARTUUID}|" /mnt/arch-boot/cmdline.txt
    else
      echo "console=serial0,115200 console=ttyAMA0,115200 root=PARTUUID=${PARTUUID} rw rootwait" \
        | sudo tee /mnt/arch-boot/cmdline.txt >/dev/null
    fi
  fi

  # If you installed linux-aarch64 + uboot-raspberrypi, ensure extlinux.conf exists
  if [ -d /mnt/arch-boot/extlinux ]; then
    :
  elif [ -f /mnt/arch-boot/u-boot.bin ] || [ -f /mnt/arch-root/boot/u-boot.bin ]; then
    sudo install -d /mnt/arch-boot/extlinux
    sudo tee /mnt/arch-boot/extlinux/extlinux.conf >/dev/null <<EOF
DEFAULT arch
MENU TITLE Arch Linux ARM
TIMEOUT 3

LABEL arch
  LINUX /Image
  INITRD /initramfs-linux.img
  FDTDIR /dtbs
  APPEND root=PARTUUID=${PARTUUID} rw rootwait console=ttyAMA0,115200 console=serial0,115200
EOF
  fi
fi

# --- fstab (Pi 4 aarch64 note: ALARM docs use mmcblk1) ---
# Use PARTUUIDs so device names don’t matter.
sudo tee /mnt/arch-root/etc/fstab <<EOF
UUID=${ROOT_UUID}  /      ext4   defaults,noatime  0 1
UUID=${BOOT_UUID}  /boot  vfat   defaults,noatime  0 2
EOF

sync

# --- unmount & detach ---
sudo umount /mnt/arch-boot || true
sudo umount /mnt/arch-root || true
sudo losetup -d "$LOOP"

echo "OK: ${IMG} is ready."

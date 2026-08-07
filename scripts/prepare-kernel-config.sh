#!/usr/bin/env bash
set -euo pipefail

[[ -x scripts/config ]] || {
  printf 'prepare-kernel-config: run from a Linux source root\n' >&2
  exit 2
}

make defconfig

# Keep the upstream architecture defconfig as the hardware baseline, then add
# the networking, filesystem and virtual-machine features commonly needed by
# general-purpose VPS/cloud systems.
scripts/config --file .config \
  --enable MODULES \
  --enable BLK_DEV_INITRD \
  --enable DEVTMPFS \
  --enable DEVTMPFS_MOUNT \
  --enable TMPFS \
  --enable PROC_FS \
  --enable SYSFS \
  --enable NET \
  --enable INET \
  --enable IPV6 \
  --enable TCP_CONG_ADVANCED \
  --enable TCP_CONG_BBR \
  --enable DEFAULT_BBR \
  --set-str DEFAULT_TCP_CONG bbr \
  --enable NET_SCHED \
  --enable NET_SCH_FQ \
  --enable NET_SCH_FQ_CODEL \
  --enable NET_SCH_DEFAULT \
  --disable DEFAULT_CODEL \
  --enable DEFAULT_FQ \
  --disable DEFAULT_FQ_PIE \
  --disable DEFAULT_SFQ \
  --disable DEFAULT_PFIFO_FAST \
  --disable DEFAULT_FQ_CODEL \
  --set-str DEFAULT_NET_SCH fq \
  --enable EXT4_FS \
  --module XFS_FS \
  --module BTRFS_FS \
  --enable SCSI \
  --enable BLK_DEV_SD \
  --enable BLK_DEV_NVME \
  --enable VIRTIO \
  --enable VIRTIO_PCI \
  --enable VIRTIO_BLK \
  --enable VIRTIO_NET \
  --module TUN \
  --module BRIDGE \
  --module VLAN_8021Q \
  --module OVERLAY_FS \
  --enable CGROUPS \
  --enable NAMESPACES \
  --disable LOCALVERSION_AUTO \
  --disable DEBUG_INFO \
  --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
  --disable DEBUG_INFO_DWARF4 \
  --disable DEBUG_INFO_DWARF5 \
  --disable RUST \
  --set-str SYSTEM_TRUSTED_KEYS '' \
  --set-str SYSTEM_REVOCATION_KEYS ''

# Optional cloud drivers. Kconfig will silently discard symbols unavailable on
# the current architecture.
scripts/config --file .config \
  --module SCSI_VIRTIO \
  --module ENA_ETHERNET \
  --module GVE \
  --module HYPERV_NET \
  --module HYPERV_STORAGE \
  --module XEN_NETDEV_FRONTEND \
  --module XEN_BLKDEV_FRONTEND || true

make olddefconfig

grep -qx 'CONFIG_TCP_CONG_BBR=y' .config
grep -qx 'CONFIG_DEFAULT_BBR=y' .config
grep -qx 'CONFIG_DEFAULT_TCP_CONG="bbr"' .config
grep -qx 'CONFIG_NET_SCH_FQ=y' .config
grep -qx 'CONFIG_DEFAULT_FQ=y' .config
grep -qx 'CONFIG_DEFAULT_NET_SCH="fq"' .config
grep -qx 'CONFIG_EXT4_FS=y' .config
grep -qx 'CONFIG_BLK_DEV_INITRD=y' .config
printf 'Prepared generic Linux configuration with built-in BBR and fq.\n'

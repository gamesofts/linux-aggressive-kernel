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
  --enable NETFILTER \
  --enable NF_CONNTRACK \
  --enable NF_NAT \
  --enable NF_TABLES \
  --enable NF_TABLES_INET \
  --enable NFT_CT \
  --enable NFT_NAT \
  --enable NFT_MASQ \
  --enable NFT_FIB_IPV4 \
  --enable NFT_FIB_IPV6 \
  --enable NFT_FIB_INET \
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

# The upstream defconfig carries desktop and physical-machine subsystems.
# A cloud VPS needs neither GPU acceleration nor consumer radios, cameras,
# audio, legacy peripheral buses, or local joystick/remote-control devices.
# Keep virtual framebuffer/console, serial console, block/USB rescue paths
# and PCI/ACPI/EFI support untouched for cloud recovery compatibility.
# Avoid disabling network vendor families: some KVM guests emulate physical
# NICs, and passthrough/SR-IOV may rely on vendor-specific NIC drivers.
#
# Removing GPU drivers also eliminates i915 built-in firmware warnings.
# Preserve legacy wired NICs/PHYs as modules; missing device firmware must
# still be installed on systems which actually use those physical adapters.
scripts/config --file .config \
  --disable DRM_I915 \
  --disable DRM_XE \
  --disable DRM_AMDGPU \
  --disable DRM_RADEON \
  --disable DRM_NOUVEAU \
  --disable DRM_GMA500 \
  --disable SOUND \
  --disable MEDIA_SUPPORT \
  --disable BT \
  --disable WLAN \
  --disable NFC \
  --disable CAN \
  --disable HAMRADIO \
  --disable IEEE802154 \
  --disable FIREWIRE \
  --disable PARPORT \
  --disable PCMCIA \
  --disable THUNDERBOLT \
  --disable USB_GADGET \
  --disable INPUT_JOYSTICK \
  --disable RC_CORE

# Keep firmware-dependent Ethernet drivers loadable, not built-in.
scripts/config --file .config \
  --module REALTEK_PHY \
  --module TIGON3 \
  --module E100 \
  --module R8169

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

# Kconfig may silently discard requests or re-select their symbols, so
# inspect the resolved configuration on both x86_64 and arm64.
cloud_disabled=(
  DRM_I915 DRM_XE DRM_AMDGPU DRM_RADEON DRM_NOUVEAU DRM_GMA500
  SOUND MEDIA_SUPPORT BT WLAN NFC CAN HAMRADIO IEEE802154
  FIREWIRE PARPORT PCMCIA THUNDERBOLT USB_GADGET INPUT_JOYSTICK RC_CORE
)
for feature in "${cloud_disabled[@]}"; do
  if grep -Eq "^CONFIG_${feature}=[ym]$" .config; then
    printf 'Cloud VPS profile unexpectedly enabled CONFIG_%s\n' "$feature" >&2
    exit 1
  fi
done

# Physical Ethernet may still be useful for emulated/virtualized NICs.
# None of these firmware-dependent drivers should be compiled into vmlinux.
for driver in REALTEK_PHY TIGON3 E100 R8169; do
  if grep -qx "CONFIG_${driver}=y" .config; then
    printf 'Firmware-dependent NIC CONFIG_%s must be modular\n' "$driver" >&2
    exit 1
  fi
done

grep -qx 'CONFIG_TCP_CONG_BBR=y' .config
grep -qx 'CONFIG_DEFAULT_BBR=y' .config
grep -qx 'CONFIG_DEFAULT_TCP_CONG="bbr"' .config
grep -qx 'CONFIG_NET_SCH_FQ=y' .config
grep -qx 'CONFIG_DEFAULT_FQ=y' .config
grep -qx 'CONFIG_DEFAULT_NET_SCH="fq"' .config
grep -qx 'CONFIG_NETFILTER=y' .config
grep -qx 'CONFIG_NF_CONNTRACK=y' .config
grep -qx 'CONFIG_NF_NAT=y' .config
grep -qx 'CONFIG_NF_TABLES=y' .config
grep -qx 'CONFIG_NF_TABLES_INET=y' .config
grep -qx 'CONFIG_NF_TABLES_IPV4=y' .config
grep -qx 'CONFIG_NF_TABLES_IPV6=y' .config
grep -qx 'CONFIG_NFT_CT=y' .config
grep -qx 'CONFIG_NFT_NAT=y' .config
grep -qx 'CONFIG_NFT_MASQ=y' .config
grep -qx 'CONFIG_NFT_FIB_IPV4=y' .config
grep -qx 'CONFIG_NFT_FIB_IPV6=y' .config
grep -qx 'CONFIG_NFT_FIB_INET=y' .config
grep -qx 'CONFIG_EXT4_FS=y' .config
grep -qx 'CONFIG_BLK_DEV_INITRD=y' .config
printf 'Prepared cloud VPS Linux configuration with built-in BBR, fq and nftables NAT support.\n'

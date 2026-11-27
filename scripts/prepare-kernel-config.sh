#!/usr/bin/env bash
set -euo pipefail

[[ -x scripts/config ]] || {
  printf 'prepare-kernel-config: run from a Linux source root\n' >&2
  exit 2
}

LLVM="${LLVM:-1}"
make_args=()
if [[ "$LLVM" != "0" ]]; then
  make_args+=(LLVM="$LLVM")
fi

make "${make_args[@]}" defconfig

# Keep the upstream architecture defconfig as the hardware baseline, then add
# the networking, crypto, forwarding, filesystem and virtual-machine features
# needed by high-throughput, low-latency VPS/cloud systems.
scripts/config --file .config \
  --enable CC_OPTIMIZE_FOR_PERFORMANCE \
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
  --enable IP_ADVANCED_ROUTER \
  --enable IP_MULTIPLE_TABLES \
  --enable IP_ROUTE_MULTIPATH \
  --enable IPV6_MULTIPLE_TABLES \
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
  --enable NF_FLOW_TABLE \
  --enable NF_FLOW_TABLE_INET \
  --enable NFT_FLOW_OFFLOAD \
  --enable NFT_TPROXY \
  --enable NFT_SOCKET \
  --enable NFT_REDIR \
  --enable NFT_REJECT \
  --enable NFT_REJECT_INET \
  --enable NFT_COMPAT \
  --enable TCP_CONG_ADVANCED \
  --enable TCP_CONG_BBR \
  --enable DEFAULT_BBR \
  --set-str DEFAULT_TCP_CONG bbr \
  --enable NET_SCHED \
  --enable NET_SCH_FQ \
  --enable NET_SCH_FQ_CODEL \
  --module NET_SCH_NETEM \
  --module NET_SCH_TBF \
  --module NET_SCH_HTB \
  --module NET_SCH_CAKE \
  --enable NET_SCH_DEFAULT \
  --disable DEFAULT_CODEL \
  --enable DEFAULT_FQ \
  --disable DEFAULT_FQ_PIE \
  --disable DEFAULT_SFQ \
  --disable DEFAULT_PFIFO_FAST \
  --disable DEFAULT_FQ_CODEL \
  --set-str DEFAULT_NET_SCH fq \
  --module TLS \
  --enable TLS_DEVICE \
  --module WIREGUARD \
  --enable CRYPTO_GCM \
  --enable CRYPTO_CHACHA20 \
  --enable CRYPTO_CHACHA20POLY1305 \
  --enable CRYPTO_LZ4 \
  --enable CRYPTO_ZSTD \
  --enable BPF_SYSCALL \
  --enable BPF_JIT \
  --enable BPF_JIT_ALWAYS_ON \
  --enable NET_RX_BUSY_POLL \
  --enable RPS \
  --enable RFS_ACCEL \
  --enable XPS \
  --enable XDP_SOCKETS \
  --enable PREEMPT_DYNAMIC \
  --disable PREEMPT_NONE \
  --disable PREEMPT \
  --disable PREEMPT_RT \
  --enable PREEMPT_LAZY \
  --disable HZ_100 \
  --disable HZ_300 \
  --disable HZ_1000 \
  --enable HZ_250 \
  --enable NO_HZ_IDLE \
  --enable HIGH_RES_TIMERS \
  --enable TRANSPARENT_HUGEPAGE \
  --disable TRANSPARENT_HUGEPAGE_ALWAYS \
  --enable TRANSPARENT_HUGEPAGE_MADVISE \
  --enable LRU_GEN \
  --enable LRU_GEN_ENABLED \
  --enable ZSWAP \
  --module ZRAM \
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

if [[ "$LLVM" != "0" ]]; then
  scripts/config --file .config \
    --disable LTO_NONE \
    --disable LTO_CLANG_FULL \
    --enable LTO_CLANG_THIN
fi

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

# Optional architecture-specific cloud, virtualization and hardware-crypto
# drivers. Kconfig silently discards symbols unavailable on the current arch.
scripts/config --file .config \
  --enable KVM_GUEST \
  --enable PARAVIRT_SPINLOCKS \
  --enable X86_X2APIC \
  --module CRYPTO_AES_NI_INTEL \
  --module CRYPTO_AES_ARM64_CE_BLK \
  --module CRYPTO_GHASH_ARM64_CE \
  --module SCSI_VIRTIO \
  --module ENA_ETHERNET \
  --module GVE \
  --module HYPERV_NET \
  --module HYPERV_STORAGE \
  --module XEN_NETDEV_FRONTEND \
  --module XEN_BLKDEV_FRONTEND || true

make "${make_args[@]}" olddefconfig

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

if [[ "$LLVM" != "0" ]]; then
  grep -qx 'CONFIG_LTO_CLANG_THIN=y' .config
fi

grep -qx 'CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y' .config
grep -qx 'CONFIG_PREEMPT_DYNAMIC=y' .config
grep -Eq '^CONFIG_PREEMPT_(LAZY|VOLUNTARY)=y$' .config
grep -qx 'CONFIG_HZ_250=y' .config
grep -qx 'CONFIG_NO_HZ_IDLE=y' .config
grep -qx 'CONFIG_HIGH_RES_TIMERS=y' .config
grep -qx 'CONFIG_TCP_CONG_BBR=y' .config
grep -qx 'CONFIG_DEFAULT_BBR=y' .config
grep -qx 'CONFIG_DEFAULT_TCP_CONG="bbr"' .config
grep -qx 'CONFIG_NET_SCH_FQ=y' .config
grep -qx 'CONFIG_DEFAULT_FQ=y' .config
grep -qx 'CONFIG_DEFAULT_NET_SCH="fq"' .config
grep -qx 'CONFIG_NET_SCH_NETEM=m' .config
grep -qx 'CONFIG_NET_SCH_TBF=m' .config
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
grep -qx 'CONFIG_NF_FLOW_TABLE=y' .config
grep -qx 'CONFIG_NF_FLOW_TABLE_INET=y' .config
grep -qx 'CONFIG_NFT_FLOW_OFFLOAD=y' .config
grep -qx 'CONFIG_NFT_TPROXY=y' .config
grep -qx 'CONFIG_NFT_SOCKET=y' .config
grep -qx 'CONFIG_IP_MULTIPLE_TABLES=y' .config
grep -qx 'CONFIG_IPV6_MULTIPLE_TABLES=y' .config
grep -qx 'CONFIG_TLS=m' .config
grep -qx 'CONFIG_WIREGUARD=m' .config
grep -qx 'CONFIG_BPF_JIT=y' .config
grep -qx 'CONFIG_BPF_JIT_ALWAYS_ON=y' .config
grep -qx 'CONFIG_NET_RX_BUSY_POLL=y' .config
grep -qx 'CONFIG_RPS=y' .config
grep -qx 'CONFIG_XPS=y' .config
grep -qx 'CONFIG_XDP_SOCKETS=y' .config
grep -qx 'CONFIG_TRANSPARENT_HUGEPAGE=y' .config
grep -qx 'CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y' .config
grep -qx 'CONFIG_LRU_GEN=y' .config
grep -qx 'CONFIG_LRU_GEN_ENABLED=y' .config
grep -qx 'CONFIG_EXT4_FS=y' .config
grep -qx 'CONFIG_BLK_DEV_INITRD=y' .config
printf 'Prepared cloud VPS Linux configuration (LLVM=%s) with built-in BBR, fq, nftables flowtable, kTLS, WireGuard, PREEMPT_LAZY and HZ_250.\n' "$LLVM"

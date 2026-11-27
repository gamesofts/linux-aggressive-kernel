#!/usr/bin/env python3
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
workflow = (root / ".github/workflows/build-aggressive-kernel.yml").read_text()
installer = (root / "kernel.sh").read_text()
installer_proxy = (root / "kernel-jsdelivr.sh").read_text()
config = (root / "scripts/prepare-kernel-config.sh").read_text()
patcher = (root / "scripts/apply-aggressive-bbr.py").read_text()
fq_patcher = (root / "scripts/apply-fq-tuning.py").read_text()
metadata = (root / "metadata/aggressive-bbr.env").read_text()
resolver = (root / "scripts/resolve-stable-kernel.sh").read_text()

for required in [
    "bbr_pixie_gain",
    "bbr_pixie_recompute_gain",
    "bbr_effective_pacing_gain",
    "bbr_effective_cwnd_gain",
    "bbr_bdp_raw",
    "bbr_inflight_raw",
    "bbr_probe_rtt_cwnd",
    "bbr_update_pixie_feedback",
    "bbr_reset_pixie_feedback",
    "bbr_u32_add_sat",
    "bbr_pixie_max_gain",
    "bbr_pixie_probe_max_gain",
    "bbr_pixie_cwnd_max_gain",
    "BBR_MIN_RTT_WIN_SEC=15",
    "BBR_PROBE_RTT_CWND_GAIN_PERCENT=50",
    "BBR_PROBE_BW_DRAIN_PERCENT=62",
    "BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1",
    "BBR_PIXIE_FEEDBACK_EXIT_RTTS=4",
    "BBR_PIXIE_MIN_SAMPLES=32",
    "BBR_PIXIE_DEADBAND_BPS=50",
    "BBR_PIXIE_MAX_GAIN_PERCENT=150",
    "BBR_PIXIE_PROBE_MAX_GAIN_PERCENT=187",
    "BBR_PIXIE_CWND_MAX_GAIN_PERCENT=250",
    "BBR_PIXIE_HOTPATH_CACHED=1",
]:
    assert required in patcher

for required in [
    "FQ_DEFAULT_PLIMIT=32768",
    "FQ_DEFAULT_FLOW_PLIMIT=2000",
    "FQ_DEFAULT_BUCKETS=4096",
]:
    assert required in fq_patcher

for required in [
    "PROFILE_NAME=linux-aggressive-bbr-v1",
    "BBR_TUNING_REVISION=6",
    "BBR_BW_RTTS=10",
    "BBR_MIN_RTT_WIN_SEC=15",
    "BBR_PROBE_RTT_CWND_GAIN_PERCENT=50",
    "BBR_PROBE_BW_GAIN_PERCENT=150",
    "BBR_PROBE_BW_DRAIN_PERCENT=62",
    "BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1",
    "BBR_PIXIE_FEEDBACK_EXIT_RTTS=4",
    "BBR_PIXIE_MIN_SAMPLES=32",
    "BBR_PIXIE_DEADBAND_BPS=50",
    "BBR_PIXIE_MAX_GAIN_PERCENT=150",
    "BBR_PIXIE_PROBE_MAX_GAIN_PERCENT=187",
    "BBR_PIXIE_CWND_MAX_GAIN_PERCENT=250",
    "FQ_DEFAULT_PLIMIT=32768",
    "FQ_DEFAULT_FLOW_PLIMIT=2000",
    "FQ_DEFAULT_BUCKETS=4096",
]:
    assert required in metadata

assert "https://www.kernel.org/releases.json" in resolver
assert "latest_stable" in resolver

for required in [
    'make "${make_args[@]}" defconfig',
    "--enable CC_OPTIMIZE_FOR_PERFORMANCE",
    "--enable LTO_CLANG_THIN",
    "--enable PREEMPT_DYNAMIC",
    "--enable PREEMPT_LAZY",
    "--enable HZ_250",
    "--enable NO_HZ_IDLE",
    "--enable HIGH_RES_TIMERS",
    "--enable TCP_CONG_BBR",
    "--enable DEFAULT_BBR",
    "--set-str DEFAULT_TCP_CONG bbr",
    "--enable NET_SCH_FQ",
    "--enable DEFAULT_FQ",
    "--set-str DEFAULT_NET_SCH fq",
    "--module NET_SCH_NETEM",
    "--module NET_SCH_TBF",
    "--enable EXT4_FS",
    "--enable BLK_DEV_INITRD",
    "--enable NETFILTER",
    "--enable NF_CONNTRACK",
    "--enable NF_NAT",
    "--enable NF_TABLES",
    "--enable NF_TABLES_INET",
    "--enable NFT_CT",
    "--enable NFT_NAT",
    "--enable NFT_MASQ",
    "--enable NFT_FIB_IPV4",
    "--enable NFT_FIB_IPV6",
    "--enable NFT_FIB_INET",
    "--enable NF_FLOW_TABLE",
    "--enable NF_FLOW_TABLE_INET",
    "--enable NFT_FLOW_OFFLOAD",
    "--enable NFT_TPROXY",
    "--enable NFT_SOCKET",
    "--enable IP_MULTIPLE_TABLES",
    "--enable IPV6_MULTIPLE_TABLES",
    "--module TLS",
    "--module WIREGUARD",
    "--enable BPF_JIT",
    "--enable BPF_JIT_ALWAYS_ON",
    "--enable NET_RX_BUSY_POLL",
    "--enable RPS",
    "--enable XPS",
    "--enable XDP_SOCKETS",
    "--enable TRANSPARENT_HUGEPAGE_MADVISE",
    "--enable LRU_GEN",
    "--enable LRU_GEN_ENABLED",
    "--enable VIRTIO_NET",
    "--enable BLK_DEV_NVME",
]:
    assert required in config

# Generic cloud guests must not build consumer device subsystems, while
# core virtual networking and fallback physical Ethernet remain available.
for feature in [
    "DRM_I915", "DRM_XE", "DRM_AMDGPU", "DRM_RADEON",
    "DRM_NOUVEAU", "DRM_GMA500", "SOUND", "MEDIA_SUPPORT",
    "BT", "WLAN", "NFC", "CAN", "HAMRADIO", "IEEE802154",
    "FIREWIRE", "PARPORT", "PCMCIA", "THUNDERBOLT",
    "USB_GADGET", "INPUT_JOYSTICK", "RC_CORE",
]:
    assert f"--disable {feature}" in config
for feature in [
    "REALTEK_PHY", "TIGON3", "E100", "R8169", "SCSI_VIRTIO",
    "ENA_ETHERNET", "GVE", "HYPERV_NET", "HYPERV_STORAGE",
    "XEN_NETDEV_FRONTEND", "XEN_BLKDEV_FRONTEND",
]:
    assert f"--module {feature}" in config
for feature in ["VIRTIO_NET", "VIRTIO_BLK", "VIRTIO_PCI", "BLK_DEV_NVME", "BLK_DEV_SD"]:
    assert f"--enable {feature}" in config
for feature in ["REALTEK_PHY", "TIGON3", "E100", "R8169"]:
    assert feature in config
assert 'cloud_disabled=(' in config
assert 'for feature in "${cloud_disabled[@]}"; do' in config
assert 'for driver in REALTEK_PHY TIGON3 E100 R8169; do' in config
assert config.index('make "${make_args[@]}" olddefconfig') < config.index('cloud_disabled=(')

for required in [
    'name: Build Linux Aggressive Kernel',
    'make -j"$(nproc)" LLVM=1 bindeb-pkg',
    'make -j"$(nproc)" LLVM=1 binrpm-pkg',
    'profile: "linux-aggressive-bbr-v1"',
    'schema: 2',
    'LOCALVERSION: -aggressive',
    'metadata/aggressive-bbr.env',
    'scripts/apply-aggressive-bbr.py',
    'scripts/apply-fq-tuning.py',
    'scripts/resolve-stable-kernel.sh',
    'Apply high-BDP fq qdisc defaults',
    'Compile Aggressive BBR with GCC',
    'Compile Aggressive BBR with Clang',
    'Build DEB packages',
    'Build RPM packages',
    'deb_contains_kernel()',
    'rpm_contains_kernel()',
    'build/linux-aggressive-kernel-*.deb',
    'build/linux-aggressive-kernel-*.rpm',
]:
    assert required in workflow

# Manifest generation consumes all provenance sources explicitly so `set -u`
# cannot fail only after expensive kernel builds complete.
assert (
    "source metadata/aggressive-bbr.env\n"
    "          source build/linux-source-provenance.env\n"
    "          source build/bbr-tuning.env\n"
    "          source build/fq-tuning.env"
) in workflow

# Package-content validation runs under `set -o pipefail`. Do not use `grep -q`
# on a package-reader pipeline: it exits after the first match, closes the pipe
# early and can make dpkg-deb/tar or rpm report a broken stdout pipe.
assert 'dpkg-deb --contents "$image_deb" | grep -q' not in workflow
assert 'rpm -qpl "$rpm_file" | grep -q' not in workflow
assert '| grep -q' not in installer
assert '| grep -q' not in installer_proxy

# Release image packages are identified by their actual contents and architecture,
# not by distro-specific filename or package-name assumptions.
assert '-name "linux-image-${kernel_release}_*.deb"' not in workflow
assert "== kernel" not in workflow
assert 'kernel_release="$(make -s -C build/linux LLVM=1 kernelrelease)"' in workflow
assert 'kernel_release="${UPSTREAM_KERNEL_VERSION}${LOCALVERSION}"' not in workflow

expected_sysctl = [
    "net.core.default_qdisc = fq",
    "net.ipv4.tcp_congestion_control = bbr",
    "net.core.rmem_max = 67108864",
    "net.core.wmem_max = 67108864",
    "net.ipv4.tcp_rmem = 4096 1048576 67108864",
    "net.ipv4.tcp_wmem = 4096 1048576 67108864",
    "net.ipv4.tcp_keepalive_time = 600",
    "net.ipv4.tcp_keepalive_intvl = 30",
    "net.ipv4.tcp_keepalive_probes = 10",
    "net.ipv4.tcp_slow_start_after_idle = 0",
    "net.ipv4.tcp_thin_linear_timeouts = 1",
    "net.ipv4.tcp_mtu_probing = 1",
    "net.ipv4.tcp_ecn = 0",
]

for script_text in (installer, installer_proxy):
    assert 'KERNEL_REPO="${KERNEL_REPO:-gamesofts/linux-aggressive-kernel}"' in script_text
    assert 'readonly SYSCTL_FILE="/etc/sysctl.d/99-sysctl.conf"' in script_text
    assert "PACKAGE_SYSTEM=deb" in script_text
    assert "PACKAGE_SYSTEM=rpm" in script_text
    assert "dpkg-deb" in script_text
    assert "rpm -qp" in script_text
    assert "remove_old_deb_kernels" in script_text
    assert "remove_old_rpm_kernels" in script_text
    assert '(manifest.get("schema"), manifest.get("profile")) != (2, "linux-aggressive-bbr-v1")' in script_text
    assert 'if not re.fullmatch(r"[0-9]+\\.[0-9]+(?:\\.[0-9]+)?", upstream_version):' in script_text
    assert 'f"{upstream_version}.0" if upstream_version.count(".") == 1 else upstream_version' in script_text
    assert "if kernel_release != expected_kernel_release:" in script_text

    sysctl_match = re.search(
        r"cat > \"\$SYSCTL_FILE\" <<'SYSCTL'\n(.*?)\nSYSCTL",
        script_text,
        re.S,
    )
    assert sysctl_match
    assert sysctl_match.group(1).splitlines() == expected_sysctl

print("Linux Aggressive Kernel project contracts: ok")

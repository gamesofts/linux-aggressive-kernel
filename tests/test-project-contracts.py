#!/usr/bin/env python3
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
workflow = (root / ".github/workflows/build-aggressive-kernel.yml").read_text()
installer = (root / "kernel.sh").read_text()
config = (root / "scripts/prepare-kernel-config.sh").read_text()
patcher = (root / "scripts/apply-aggressive-bbr.py").read_text()
metadata = (root / "metadata/aggressive-bbr.env").read_text()
resolver = (root / "scripts/resolve-stable-kernel.sh").read_text()

for required in [
    "bbr_pixie_gain",
    "bbr_apply_pixie_gain",
    "bbr_update_pixie_feedback",
    "bbr_reset_pixie_feedback",
    "bbr_u32_add_sat",
    "bbr_pixie_max_gain",
    "BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1",
    "BBR_PIXIE_FEEDBACK_EXIT_RTTS=4",
    "BBR_PIXIE_MIN_SAMPLES=32",
    "BBR_PIXIE_MAX_GAIN_PERCENT=150",
]:
    assert required in patcher

for required in [
    "PROFILE_NAME=linux-aggressive-bbr-v1",
    "BBR_TUNING_REVISION=5",
    "BBR_BW_RTTS=10",
    "BBR_PIXIE_FEEDBACK_ENTRY_RTTS=1",
    "BBR_PIXIE_FEEDBACK_EXIT_RTTS=4",
    "BBR_PIXIE_MIN_SAMPLES=32",
    "BBR_PIXIE_MAX_GAIN_PERCENT=150",
]:
    assert required in metadata

assert "https://www.kernel.org/releases.json" in resolver
assert "latest_stable" in resolver

for required in [
    "make defconfig",
    "--enable TCP_CONG_BBR",
    "--enable DEFAULT_BBR",
    "--set-str DEFAULT_TCP_CONG bbr",
    "--enable NET_SCH_FQ",
    "--enable DEFAULT_FQ",
    "--set-str DEFAULT_NET_SCH fq",
    "--enable EXT4_FS",
    "--enable BLK_DEV_INITRD",
    "--enable VIRTIO_NET",
    "--enable BLK_DEV_NVME",
]:
    assert required in config

for required in [
    'name: Build Linux Aggressive Kernel',
    'make -j"$(nproc)" bindeb-pkg',
    'make -j"$(nproc)" binrpm-pkg',
    'profile: "linux-aggressive-bbr-v1"',
    'schema: 2',
    'LOCALVERSION: -aggressive',
    'metadata/aggressive-bbr.env',
    'scripts/apply-aggressive-bbr.py',
    'scripts/resolve-stable-kernel.sh',
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

# Manifest generation consumes three different classes of build metadata:
# static tuning revision/profile, source provenance, and actual patch output.
# Keep all three sources explicit so `set -u` cannot expose a missing variable
# only after the expensive kernel package builds have completed.
assert "source metadata/aggressive-bbr.env\n          source build/linux-source-provenance.env\n          source build/bbr-tuning.env" in workflow

# Package-content validation runs under `set -o pipefail`. Do not use `grep -q`
# on a package-reader pipeline: it exits after the first match, closes the pipe
# early and can make dpkg-deb/tar or rpm report a broken stdout pipe.
assert 'dpkg-deb --contents "$image_deb" | grep -q' not in workflow
assert 'rpm -qpl "$rpm_file" | grep -q' not in workflow
assert '| grep -q' not in installer

# Release image packages are identified by their actual contents and architecture,
# not by distro-specific filename or package-name assumptions.
assert '-name "linux-image-${kernel_release}_*.deb"' not in workflow
assert "== kernel" not in workflow
assert 'kernel_release="$(make -s -C build/linux kernelrelease)"' in workflow
assert 'kernel_release="${UPSTREAM_KERNEL_VERSION}${LOCALVERSION}"' not in workflow

assert 'KERNEL_REPO="${KERNEL_REPO:-gamesofts/linux-aggressive-kernel}"' in installer
assert 'readonly SYSCTL_FILE="/etc/sysctl.d/99-sysctl.conf"' in installer
assert "PACKAGE_SYSTEM=deb" in installer
assert "PACKAGE_SYSTEM=rpm" in installer
assert "dpkg-deb" in installer
assert "rpm -qp" in installer
assert "remove_old_deb_kernels" in installer
assert "remove_old_rpm_kernels" in installer
assert '(manifest.get("schema"), manifest.get("profile")) != (2, "linux-aggressive-bbr-v1")' in installer
assert 'if not re.fullmatch(r"[0-9]+\\.[0-9]+(?:\\.[0-9]+)?", upstream_version):' in installer
assert 'f"{upstream_version}.0" if upstream_version.count(".") == 1 else upstream_version' in installer
assert "if kernel_release != expected_kernel_release:" in installer

sysctl_match = re.search(
    r"cat > \"\$SYSCTL_FILE\" <<'SYSCTL'\n(.*?)\nSYSCTL",
    installer,
    re.S,
)
assert sysctl_match
assert sysctl_match.group(1).splitlines() == [
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

print("Linux Aggressive Kernel project contracts: ok")

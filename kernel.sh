#!/usr/bin/env bash
set -euo pipefail

# Install the latest prebuilt Linux Aggressive Kernel release.
# Supports amd64/x86_64 and arm64/aarch64 on mainstream DEB- and RPM-based Linux distributions.

readonly KERNEL_REPO="${KERNEL_REPO:-gamesofts/linux-aggressive-kernel}"
readonly SYSCTL_FILE="/etc/sysctl.d/99-sysctl.conf"

log()  { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

package_version_is_installed() {
  local package_name="$1"
  local expected_version="$2"
  case "${PACKAGE_SYSTEM:-}" in
    deb)
      local installed_package_record
      installed_package_record="$(
        dpkg-query -W -f='${db:Status-Status}\t${Version}' "$package_name" 2>/dev/null || true
      )"
      [[ "$installed_package_record" == "installed"$'\t'"$expected_version" ]]
      ;;
    rpm)
      rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$package_name" 2>/dev/null \
        | grep -Fx -- "$expected_version" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

install_runtime_dependencies() {
  case "$PACKAGE_SYSTEM" in
    deb)
      local packages=(ca-certificates curl python3 procps initramfs-tools)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    rpm)
      local packages=(ca-certificates curl python3 procps-ng dracut)
      case "$RPM_FRONTEND" in
        dnf) dnf install -y "${packages[@]}" ;;
        yum) yum install -y "${packages[@]}" ;;
        zypper) zypper --non-interactive install "${packages[@]}" ;;
      esac
      ;;
  esac
}

install_kernel_package() {
  local package_path="$1"
  case "$PACKAGE_SYSTEM" in
    deb)
      if ! dpkg -i "$package_path"; then
        apt-get -f install -y
        dpkg -i "$package_path"
      fi
      ;;
    rpm)
      case "$RPM_FRONTEND" in
        dnf) dnf install -y "$package_path" ;;
        yum) yum install -y "$package_path" ;;
        zypper) zypper --non-interactive install --allow-unsigned-rpm "$package_path" ;;
      esac
      ;;
  esac
}

remove_old_deb_kernels() {
  local new_package="$1"
  local running_kernel="$2"
  local record package_name package_status package_version
  local fallback_package="" fallback_version=""
  local -a records=() old_packages=()

  mapfile -t records < <(
    dpkg-query -W -f='${Package}\t${db:Status-Status}\t${Version}\n' \
      'linux-image-[0-9]*' 2>/dev/null || true
  )

  for record in "${records[@]}"; do
    IFS=$'\t' read -r package_name package_status package_version <<< "$record"
    [[ "$package_status" == installed ]] || continue
    [[ "$package_name" != *-aggressive ]] || continue
    if [[ -z "$fallback_package" ]] || dpkg --compare-versions "$package_version" gt "$fallback_version"; then
      fallback_package="$package_name"
      fallback_version="$package_version"
    fi
  done

  warn "Retaining the new kernel, the currently running kernel, and the newest distribution fallback kernel"
  [[ -n "$fallback_package" ]] || warn "No distribution fallback kernel package was found"

  for record in "${records[@]}"; do
    IFS=$'\t' read -r package_name package_status package_version <<< "$record"
    [[ "$package_status" == installed ]] || continue
    [[ "$package_name" != "$new_package" ]] || continue
    [[ "$package_name" != "linux-image-$running_kernel" ]] || continue
    [[ -z "$fallback_package" || "$package_name" != "$fallback_package" ]] || continue
    old_packages+=("$package_name")
  done

  if ((${#old_packages[@]} > 0)); then
    log "Removing obsolete kernel packages: ${old_packages[*]}"
    apt-get purge -y "${old_packages[@]}"
    apt-get autoremove -y || true
  fi
}

remove_old_rpm_kernels() {
  local new_package="$1"
  local new_version="$2"
  local running_kernel="$3"
  local record package_name version release arch version_release package_id
  local running_record="" running_version="" running_release="" running_arch=""
  local fallback_package="" fallback_version=""
  local -a records=() old_packages=()

  running_record="$(
    rpm -qf "/lib/modules/$running_kernel" --qf '%{VERSION}\t%{RELEASE}\t%{ARCH}\n' 2>/dev/null \
      | head -n1 || true
  )"
  if [[ -z "$running_record" && -e "/boot/vmlinuz-$running_kernel" ]]; then
    running_record="$(
      rpm -qf "/boot/vmlinuz-$running_kernel" --qf '%{VERSION}\t%{RELEASE}\t%{ARCH}\n' 2>/dev/null \
        | head -n1 || true
    )"
  fi
  if [[ -n "$running_record" ]]; then
    IFS=$'\t' read -r running_version running_release running_arch <<< "$running_record"
  else
    warn "Could not resolve the RPM package owning the currently running kernel; no RPM kernels will be removed"
    return 0
  fi

  mapfile -t records < <(
    rpm -q kernel kernel-default --qf '%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\n' 2>/dev/null || true
  )

  for record in "${records[@]}"; do
    IFS=$'\t' read -r package_name version release arch <<< "$record"
    [[ -n "$package_name" && -n "$version" && -n "$release" && -n "$arch" ]] || continue
    version_release="$version-$release"
    [[ "$version" != *_aggressive* ]] || continue
    if [[ "$version" == "$running_version" && "$release" == "$running_release" && "$arch" == "$running_arch" ]]; then
      continue
    fi
    if [[ -z "$fallback_package" ]] || \
       [[ "$(printf '%s\n%s\n' "$fallback_version" "$version_release" | sort -V | tail -n1)" == "$version_release" ]]; then
      fallback_package="$package_name-$version_release.$arch"
      fallback_version="$version_release"
    fi
  done

  warn "Retaining the new kernel, the currently running kernel, and the newest distribution fallback kernel"
  [[ -n "$fallback_package" ]] || warn "No distribution fallback kernel package was found"

  for record in "${records[@]}"; do
    IFS=$'\t' read -r package_name version release arch <<< "$record"
    [[ -n "$package_name" && -n "$version" && -n "$release" && -n "$arch" ]] || continue
    version_release="$version-$release"
    package_id="$package_name-$version_release.$arch"
    if [[ "$package_name" == "$new_package" && "$version_release" == "$new_version" ]]; then
      continue
    fi
    if [[ "$version" == "$running_version" && "$release" == "$running_release" && "$arch" == "$running_arch" ]]; then
      continue
    fi
    [[ -z "$fallback_package" || "$package_id" != "$fallback_package" ]] || continue
    old_packages+=("$package_id")
  done

  if ((${#old_packages[@]} > 0)); then
    log "Removing obsolete kernel packages: ${old_packages[*]}"
    case "$RPM_FRONTEND" in
      dnf) dnf remove -y "${old_packages[@]}" ;;
      yum) yum remove -y "${old_packages[@]}" ;;
      zypper) zypper --non-interactive remove "${old_packages[@]}" ;;
    esac
  fi
}

[[ -n "${BASH_VERSION:-}" ]] || die "Run with bash"
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root"

machine_arch="$(uname -m)"
case "$machine_arch" in
  x86_64|amd64)
    host_arch=amd64
    rpm_arch=x86_64
    ;;
  aarch64|arm64)
    host_arch=arm64
    rpm_arch=aarch64
    ;;
  *) die "Only amd64/x86_64 and arm64/aarch64 are supported" ;;
esac

# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release
if command -v dpkg-query >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  PACKAGE_SYSTEM=deb
  RPM_FRONTEND=""
elif command -v rpm >/dev/null 2>&1; then
  PACKAGE_SYSTEM=rpm
  if command -v dnf >/dev/null 2>&1; then
    RPM_FRONTEND=dnf
  elif command -v yum >/dev/null 2>&1; then
    RPM_FRONTEND=yum
  elif command -v zypper >/dev/null 2>&1; then
    RPM_FRONTEND=zypper
  else
    die "RPM system detected, but dnf, yum, or zypper is required"
  fi
else
  die "Unsupported distribution: a DEB (apt/dpkg) or RPM (dnf/yum/zypper) system is required"
fi

install_runtime_dependencies
for command_name in curl python3 sha256sum sysctl; do
  command -v "$command_name" >/dev/null || die "$command_name is required"
done

case "$PACKAGE_SYSTEM" in
  deb) package_format=deb ;;
  rpm) package_format=rpm ;;
esac

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-aggressive-kernel.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
api_root="https://api.github.com/repos/$KERNEL_REPO"
release_api="$api_root/releases/latest"

curl_args=(
  --fail --silent --show-error --location
  --header 'Accept: application/vnd.github+json'
  --header 'X-GitHub-Api-Version: 2022-11-28'
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
fi

log "Reading latest release metadata from $KERNEL_REPO..."
curl "${curl_args[@]}" "$release_api" --output "$tmp_dir/release.json"

python3 - "$tmp_dir/release.json" "$tmp_dir/release.env" <<'PY'
import json, shlex, sys
from pathlib import Path
release = json.loads(Path(sys.argv[1]).read_text())
assets = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
manifest_url = assets.get("manifest.json")
if not manifest_url:
    raise SystemExit("Release has no manifest.json")
values = {"RELEASE_NAME": release.get("tag_name", ""), "MANIFEST_URL": manifest_url}
Path(sys.argv[2]).write_text("".join(f"{k}={shlex.quote(v)}\n" for k, v in values.items()))
PY
# shellcheck disable=SC1090
. "$tmp_dir/release.env"
curl --fail --silent --show-error --location "$MANIFEST_URL" --output "$tmp_dir/manifest.json"

python3 - "$tmp_dir/release.json" "$tmp_dir/manifest.json" "$host_arch" "$package_format" "$tmp_dir/package.env" <<'PY'
import json, re, shlex, sys
from pathlib import Path
release = json.loads(Path(sys.argv[1]).read_text())
manifest = json.loads(Path(sys.argv[2]).read_text())
host_arch, package_format = sys.argv[3], sys.argv[4]
if not release.get("tag_name") or manifest.get("release_tag") != release.get("tag_name"):
    raise SystemExit("Release tag does not match the manifest")
if (manifest.get("schema"), manifest.get("profile")) != (2, "linux-aggressive-bbr-v1"):
    raise SystemExit("Unsupported release manifest format")
algorithm = manifest.get("algorithm", {})
if algorithm.get("name") != "bbr" or algorithm.get("source") != "linux-mainline" or algorithm.get("source_file") != "net/ipv4/tcp_bbr.c":
    raise SystemExit("Unexpected congestion-control source metadata")
expected_tuning = {
    "revision": 5, "bw_rtts": 10, "feedback_entry_rtts": 1,
    "feedback_exit_rtts": 4, "min_samples": 32, "max_gain_percent": 150,
    "lt_loss_thresh": 96, "lt_bw_max_rtts": 24,
}
if algorithm.get("tuning") != expected_tuning:
    raise SystemExit("Unsupported BBRv1 Pixie tuning")
for field in ["source_sha256", "built_source_sha256", "linux_source_sha256", "recipe_sha256", "build_sha256"]:
    if not re.fullmatch(r"[0-9a-f]{64}", algorithm.get(field, "")):
        raise SystemExit(f"Invalid algorithm {field}")
if not re.fullmatch(r"[0-9A-F]{40}", algorithm.get("linux_signing_fingerprint", "")):
    raise SystemExit("Invalid Linux source signing fingerprint")
kernel = manifest.get("kernel", {})
upstream_version = kernel.get("upstream_version", "")
kernel_release = kernel.get("release", "")
if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", upstream_version):
    raise SystemExit("Invalid upstream kernel version")
normalized_upstream_version = (
    f"{upstream_version}.0" if upstream_version.count(".") == 1 else upstream_version
)
expected_kernel_release = f"{normalized_upstream_version}-aggressive"
if kernel_release != expected_kernel_release:
    raise SystemExit("Invalid kernel release")
package = manifest.get("assets", {}).get(host_arch, {}).get(package_format, {}).get("image", {})
name, digest, package_name, package_version = (package.get(k, "") for k in ("name", "sha256", "package", "version"))
urls = {a["name"]: a["browser_download_url"] for a in release.get("assets", [])}
expected_suffix = ".deb" if package_format == "deb" else ".rpm"
if not name.endswith(expected_suffix) or name not in urls or not package_name or not package_version or not re.fullmatch(r"[0-9a-f]{64}", digest):
    raise SystemExit("Invalid package asset metadata")
values = {
    "IMAGE_NAME": name, "IMAGE_URL": urls[name], "IMAGE_SHA256": digest,
    "IMAGE_PACKAGE": package_name, "IMAGE_VERSION": package_version,
    "UPSTREAM_KERNEL_VERSION": upstream_version, "KERNEL_RELEASE": kernel_release,
    "BBR_SOURCE_SHA256": algorithm["source_sha256"],
    "BBR_BUILT_SOURCE_SHA256": algorithm["built_source_sha256"],
    "BUILD_SHA256": algorithm["build_sha256"],
}
Path(sys.argv[5]).write_text("".join(f"{k}={shlex.quote(v)}\n" for k, v in values.items()))
PY
# shellcheck disable=SC1090
. "$tmp_dir/package.env"

if package_version_is_installed "$IMAGE_PACKAGE" "$IMAGE_VERSION" && [[ -d "/lib/modules/$KERNEL_RELEASE" ]]; then
  log "$IMAGE_PACKAGE ($IMAGE_VERSION) is already installed; skipping package installation"
else
  log "Downloading $IMAGE_NAME..."
  curl --fail --silent --show-error --location "$IMAGE_URL" --output "$tmp_dir/$IMAGE_NAME"
  printf '%s  %s\n' "$IMAGE_SHA256" "$tmp_dir/$IMAGE_NAME" | sha256sum --check --status \
    || die "Downloaded kernel checksum mismatch"

  if [[ "$PACKAGE_SYSTEM" == deb ]]; then
    [[ "$(dpkg-deb -f "$tmp_dir/$IMAGE_NAME" Architecture)" == "$host_arch" ]] || die "Downloaded package architecture mismatch"
    [[ "$(dpkg-deb -f "$tmp_dir/$IMAGE_NAME" Package)" == "$IMAGE_PACKAGE" ]] || die "Downloaded package name mismatch"
    [[ "$(dpkg-deb -f "$tmp_dir/$IMAGE_NAME" Version)" == "$IMAGE_VERSION" ]] || die "Downloaded package version mismatch"
    dpkg-deb --contents "$tmp_dir/$IMAGE_NAME" | grep -E "[./]boot/vmlinuz-${KERNEL_RELEASE}$" >/dev/null \
      || die "Downloaded package does not contain the expected kernel"
  else
    [[ "$(rpm -qp --qf '%{ARCH}' "$tmp_dir/$IMAGE_NAME")" == "$rpm_arch" ]] || die "Downloaded package architecture mismatch"
    [[ "$(rpm -qp --qf '%{NAME}' "$tmp_dir/$IMAGE_NAME")" == "$IMAGE_PACKAGE" ]] || die "Downloaded package name mismatch"
    [[ "$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$tmp_dir/$IMAGE_NAME")" == "$IMAGE_VERSION" ]] || die "Downloaded package version mismatch"
    rpm -qpl "$tmp_dir/$IMAGE_NAME" | grep -E "/lib/modules/${KERNEL_RELEASE}/vmlinuz$|/boot/vmlinuz-${KERNEL_RELEASE}$" >/dev/null \
      || die "Downloaded package does not contain the expected kernel"
  fi

  available_kb="$(df -Pk /boot 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$available_kb" =~ ^[0-9]+$ ]] && ((available_kb < 350 * 1024)); then
    die "/boot has less than 350 MiB free"
  fi

  log "Installing $IMAGE_PACKAGE ($IMAGE_VERSION)..."
  install_kernel_package "$tmp_dir/$IMAGE_NAME"
fi

[[ -d "/lib/modules/$KERNEL_RELEASE" ]] || die "Installed kernel modules are missing"
if [[ ! -f "/boot/initrd.img-$KERNEL_RELEASE" && ! -f "/boot/initramfs-$KERNEL_RELEASE.img" ]]; then
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -c -k "$KERNEL_RELEASE"
  elif command -v dracut >/dev/null 2>&1; then
    dracut --force "/boot/initramfs-$KERNEL_RELEASE.img" "$KERNEL_RELEASE"
  else
    warn "No initramfs generator found; ensure an initramfs exists before rebooting"
  fi
fi

log "Writing network parameters to $SYSCTL_FILE..."
cat > "$SYSCTL_FILE" <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
SYSCTL
if ! sysctl --system >/dev/null; then
  warn "The running kernel could not apply every new network parameter; the persistent configuration will be retried after reboot"
fi

if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub2 ]]; then
  grub2-mkconfig -o /boot/grub2/grub.cfg
elif command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
  grub-mkconfig -o /boot/grub/grub.cfg
else
  warn "No GRUB updater found; the package's kernel-install hook may already have updated the bootloader"
fi

running_kernel="$(uname -r)"
if [[ "$PACKAGE_SYSTEM" == deb ]]; then
  remove_old_deb_kernels "$IMAGE_PACKAGE" "$running_kernel"
else
  remove_old_rpm_kernels "$IMAGE_PACKAGE" "$IMAGE_VERSION" "$running_kernel"
fi

log "Release: $RELEASE_NAME"
log "Stable Linux base: $UPSTREAM_KERNEL_VERSION"
log "Upstream BBR source: $BBR_SOURCE_SHA256"
log "Aggressive BBR source: $BBR_BUILT_SOURCE_SHA256"
log "Build: $BUILD_SHA256"
warn "Installed kernel: $KERNEL_RELEASE"
warn "Running kernel remains: $running_kernel"
warn "Reboot, then verify: uname -r; sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc"

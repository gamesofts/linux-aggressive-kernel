#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for function_name in remove_old_deb_kernels remove_old_rpm_kernels; do
  function_source="$(sed -n "/^${function_name}()/,/^}/p" "$repo_root/kernel.sh")"
  [[ -n "$function_source" ]]
  eval "$function_source"
done

log() { :; }
warn() { :; }

# DEB: preserve the new kernel, current kernel, and newest distribution fallback.
dpkg_query_output=$'linux-image-7.1.7-aggressive\tinstalled\t7.1.7-1+aggressive.new\nlinux-image-7.1.6-aggressive\tinstalled\t7.1.6-1+aggressive.old\nlinux-image-6.12.2-amd64\tinstalled\t6.12.2-1\nlinux-image-6.12.1-amd64\tinstalled\t6.12.1-1\nlinux-image-6.11.0-amd64\tinstalled\t6.11.0-1\n'
dpkg-query() {
  printf '%s' "$dpkg_query_output"
}
apt_calls=""
apt-get() {
  apt_calls+="$*"$'\n'
}

remove_old_deb_kernels linux-image-7.1.7-aggressive 6.12.1-amd64

grep -Fq 'purge -y linux-image-7.1.6-aggressive linux-image-6.11.0-amd64' <<< "$apt_calls"
! grep -Fq 'linux-image-7.1.7-aggressive' <<< "$(grep '^purge ' <<< "$apt_calls")"
! grep -Fq 'linux-image-6.12.1-amd64' <<< "$(grep '^purge ' <<< "$apt_calls")"
! grep -Fq 'linux-image-6.12.2-amd64' <<< "$(grep '^purge ' <<< "$apt_calls")"

# RPM: resolve the running kernel by package ownership rather than uname/RPM
# string formatting, then preserve it and the newest distribution fallback.
rpm_query_output=$'kernel\t7.1.7_aggressive\t1\tx86_64\nkernel\t7.1.6_aggressive\t1\tx86_64\nkernel\t7.1.5_aggressive\t1\tx86_64\nkernel\t6.12.2\t100.el9\tx86_64\nkernel\t6.12.1\t100.el9\tx86_64\nkernel\t6.11.0\t100.el9\tx86_64\n'
rpm() {
  if [[ "$1" == -qf ]]; then
    printf '7.1.6_aggressive\t1\tx86_64\n'
    return 0
  fi
  if [[ "$1" == -q ]]; then
    printf '%s' "$rpm_query_output"
    return 0
  fi
  return 1
}
RPM_FRONTEND=dnf
dnf_calls=""
dnf() {
  dnf_calls+="$*"$'\n'
}

remove_old_rpm_kernels kernel 7.1.7_aggressive-1 7.1.6-aggressive

grep -Fq 'remove -y kernel-7.1.5_aggressive-1.x86_64 kernel-6.12.1-100.el9.x86_64 kernel-6.11.0-100.el9.x86_64' <<< "$dnf_calls"
! grep -Fq 'kernel-7.1.7_aggressive-1.x86_64' <<< "$dnf_calls"
! grep -Fq 'kernel-7.1.6_aggressive-1.x86_64' <<< "$dnf_calls"
! grep -Fq 'kernel-6.12.2-100.el9.x86_64' <<< "$dnf_calls"

# If ownership of the running RPM kernel cannot be resolved, remove nothing.
rpm() {
  if [[ "$1" == -qf ]]; then
    return 1
  fi
  if [[ "$1" == -q ]]; then
    printf '%s' "$rpm_query_output"
    return 0
  fi
  return 1
}
dnf_calls=""
remove_old_rpm_kernels kernel 7.1.7_aggressive-1 unknown-running-kernel
[[ -z "$dnf_calls" ]]

printf 'kernel cleanup policy: ok\n'

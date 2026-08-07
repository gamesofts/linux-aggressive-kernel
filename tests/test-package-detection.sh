#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper_source="$(sed -n '/^package_version_is_installed()/,/^}/p' "$repo_root/kernel.sh")"
[[ -n "$helper_source" ]]
eval "$helper_source"

PACKAGE_SYSTEM=deb
query_record=""
dpkg-query() { printf '%s' "$query_record"; }
query_record=$'installed\t7.1.7-1+aggressive.0123456789ab'
package_version_is_installed linux-image-7.1.7-aggressive 7.1.7-1+aggressive.0123456789ab
query_record=$'installed\t7.1.7-1+aggressive.ffffffffffff'
if package_version_is_installed linux-image-7.1.7-aggressive 7.1.7-1+aggressive.0123456789ab; then
  printf 'DEB package version mismatch was accepted.\n' >&2
  exit 1
fi

PACKAGE_SYSTEM=rpm
rpm_records=""
rpm() { printf '%s' "$rpm_records"; }
rpm_records=$'7.1.7_aggressive-1\n6.18.0-100.el10\n'
package_version_is_installed kernel 7.1.7_aggressive-1
if package_version_is_installed kernel 7.1.7_aggressive-2; then
  printf 'RPM package version mismatch was accepted.\n' >&2
  exit 1
fi

printf 'package detection: ok\n'

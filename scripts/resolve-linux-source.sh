#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| { printf 'Usage: %s KERNEL_VERSION\n' "$0" >&2; exit 2; }

kernel_major="${version%%.*}"
filename="linux-${version}.tar.xz"
checksums_url="https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x/sha256sums.asc"
checksums="$(curl --fail --silent --show-error --location "$checksums_url")"
source_sha256="$({
	printf '%s\n' "$checksums" | awk -v filename="$filename" '
		$2 == filename && $1 ~ /^[0-9a-f]{64}$/ { print $1 }
	'
} | sort -u)"

[[ "$source_sha256" =~ ^[0-9a-f]{64}$ ]] \
	|| { printf 'No unique kernel.org checksum for %s.\n' "$filename" >&2; exit 1; }

printf 'LINUX_SOURCE_FILENAME=%q\n' "$filename"
printf 'LINUX_SOURCE_SHA256=%q\n' "$source_sha256"
printf 'LINUX_SOURCE_CHECKSUMS_URL=%q\n' "$checksums_url"

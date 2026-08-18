#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
output_file="${2:-}"
provenance_file="${3:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && -n "$output_file" ]] \
	|| { printf 'Usage: %s KERNEL_VERSION OUTPUT_TAR_XZ [PROVENANCE_FILE]\n' "$0" >&2; exit 2; }

for command_name in curl gpg sha256sum xz; do
	command -v "$command_name" >/dev/null \
		|| { printf 'fetch-verified-linux: %s is required\n' "$command_name" >&2; exit 1; }
done

kernel_major="${version%%.*}"
base_url="https://cdn.kernel.org/pub/linux/kernel/v${kernel_major}.x"
filename="linux-${version}.tar.xz"
signature_name="linux-${version}.tar.sign"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/linux-signature.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
gpg_home="$tmp_dir/gnupg"
mkdir -m 0700 "$gpg_home"

# kernel.org documents WKD as its TLS-authenticated TOFU mechanism. Stable
# releases are signed by Greg Kroah-Hartman or Sasha Levin. A fresh keyring
# prevents unrelated local keys from satisfying this verification.
gpg --batch --homedir "$gpg_home" --auto-key-locate clear,wkd \
	--locate-keys gregkh@kernel.org sashal@kernel.org >/dev/null 2>&1
gpg --batch --homedir "$gpg_home" --with-colons --fingerprint --fingerprint \
	| awk -F: '$1 == "fpr" { print $10 }' | sort -u > "$tmp_dir/trusted-fingerprints"
[[ -s "$tmp_dir/trusted-fingerprints" ]] \
	|| { printf 'fetch-verified-linux: no kernel.org maintainer keys found\n' >&2; exit 1; }

curl --fail --silent --show-error --location "$base_url/$filename" \
	--output "$output_file"
curl --fail --silent --show-error --location "$base_url/$signature_name" \
	--output "$tmp_dir/$signature_name"

if ! xz -cd "$output_file" | gpg --batch --homedir "$gpg_home" \
	--status-fd=1 --verify "$tmp_dir/$signature_name" - \
	> "$tmp_dir/verify.status" 2> "$tmp_dir/verify.log"; then
	cat "$tmp_dir/verify.log" >&2
	printf 'fetch-verified-linux: bad developer signature for %s\n' "$filename" >&2
	exit 1
fi
signing_fingerprint="$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $3 }' \
	"$tmp_dir/verify.status" | sort -u)"
[[ "$signing_fingerprint" =~ ^[0-9A-F]{40}$ ]] \
	|| { printf 'fetch-verified-linux: missing valid signing fingerprint\n' >&2; exit 1; }
grep -Fqx "$signing_fingerprint" "$tmp_dir/trusted-fingerprints" \
	|| { printf 'fetch-verified-linux: signature is not from an imported kernel.org maintainer key\n' >&2; exit 1; }

source_sha256="$(sha256sum "$output_file" | awk '{ print $1 }')"
[[ "$source_sha256" =~ ^[0-9a-f]{64}$ ]]
if [[ -n "$provenance_file" ]]; then
	{
		printf 'LINUX_SOURCE_FILENAME=%s\n' "$filename"
		printf 'LINUX_SOURCE_SHA256=%s\n' "$source_sha256"
		printf 'LINUX_SOURCE_SIGNING_FINGERPRINT=%s\n' "$signing_fingerprint"
		printf 'LINUX_SOURCE_URL=%s/%s\n' "$base_url" "$filename"
		printf 'LINUX_SOURCE_SIGNATURE_URL=%s/%s\n' "$base_url" "$signature_name"
	} > "$provenance_file"
fi

printf 'Verified Linux %s developer signature (%s).\n' \
	"$version" "$signing_fingerprint"

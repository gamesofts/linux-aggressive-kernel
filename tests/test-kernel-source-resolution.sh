#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/kernel-source-resolution-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir "$tmp_dir/bin"

checksum="f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3"
fingerprint="0123456789ABCDEF0123456789ABCDEF01234567"

cat > "$tmp_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
output_file=""
while (($#)); do
	if [[ "$1" == --output ]]; then
		output_file="$2"
		shift 2
	else
		shift
	fi
done
if [[ -n "$output_file" ]]; then
	printf 'mock kernel source or signature\n' > "$output_file"
else
	printf '%s  linux-7.2.tar.xz\n' "$MOCK_SOURCE_SHA256"
fi
MOCK

cat > "$tmp_dir/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
if [[ " $* " == *" --with-colons "* ]]; then
	printf 'fpr:::::::::%s:\n' "$MOCK_SIGNING_FINGERPRINT"
elif [[ " $* " == *" --verify "* ]]; then
	cat >/dev/null
	printf '[GNUPG:] VALIDSIG %s 2026-08-17 0 4 0 1 10 00 %s\n' \
		"$MOCK_SIGNING_FINGERPRINT" "$MOCK_SIGNING_FINGERPRINT"
fi
MOCK

cat > "$tmp_dir/bin/xz" <<'MOCK'
#!/usr/bin/env bash
cat "${@: -1}"
MOCK

cat > "$tmp_dir/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
printf '%s  %s\n' "$MOCK_SOURCE_SHA256" "$1"
MOCK

chmod +x "$tmp_dir/bin/"*
export MOCK_SOURCE_SHA256="$checksum"
export MOCK_SIGNING_FINGERPRINT="$fingerprint"

output="$(PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/resolve-linux-source.sh" 7.2)"
grep -qx 'LINUX_SOURCE_FILENAME=linux-7.2.tar.xz' <<< "$output"
grep -qx "LINUX_SOURCE_SHA256=$checksum" <<< "$output"
grep -qx 'LINUX_SOURCE_CHECKSUMS_URL=https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc' <<< "$output"

PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/fetch-verified-linux.sh" \
	7.2 "$tmp_dir/linux-7.2.tar.xz" "$tmp_dir/provenance.env" >/dev/null
grep -qx 'LINUX_SOURCE_FILENAME=linux-7.2.tar.xz' "$tmp_dir/provenance.env"
grep -qx "LINUX_SOURCE_SHA256=$checksum" "$tmp_dir/provenance.env"
grep -qx "LINUX_SOURCE_SIGNING_FINGERPRINT=$fingerprint" "$tmp_dir/provenance.env"
grep -qx 'LINUX_SOURCE_URL=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz' "$tmp_dir/provenance.env"
grep -qx 'LINUX_SOURCE_SIGNATURE_URL=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.sign' "$tmp_dir/provenance.env"

printf 'kernel source resolution: ok\n'

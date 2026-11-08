#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/stable-kernel-resolution-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir "$tmp_dir/bin"

cat > "$tmp_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
cat "$MOCK_RELEASES_JSON"
MOCK
chmod +x "$tmp_dir/bin/curl"

resolve_fixture() {
	local fixture="$1"
	MOCK_RELEASES_JSON="$fixture" PATH="$tmp_dir/bin:$PATH" \
		bash "$repo_root/scripts/resolve-stable-kernel.sh"
}

cat > "$tmp_dir/two-part.json" <<'JSON'
{
  "releases": [
    {"moniker":"mainline","version":"7.2-rc6"},
    {"moniker":"stable","version":"7.1.8"},
    {"moniker":"longterm","version":"6.18.43"}
  ],
  "latest_stable": {"version":"7.2"}
}
JSON

output="$(resolve_fixture "$tmp_dir/two-part.json")"
grep -qx 'UPSTREAM_KERNEL_VERSION=7.2' <<< "$output"
grep -qx 'KERNEL_SERIES=7.2' <<< "$output"

cat > "$tmp_dir/three-part.json" <<'JSON'
{
  "releases": [
    {"moniker":"stable","version":"7.2.1"},
    {"moniker":"longterm","version":"6.18.43"}
  ],
  "latest_stable": {"version":"7.2.1"}
}
JSON

output="$(resolve_fixture "$tmp_dir/three-part.json")"
grep -qx 'UPSTREAM_KERNEL_VERSION=7.2.1' <<< "$output"
grep -qx 'KERNEL_SERIES=7.2' <<< "$output"

printf 'stable kernel resolution: ok\n'

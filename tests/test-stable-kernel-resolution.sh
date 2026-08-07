#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/stable-kernel-resolution-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir "$tmp_dir/bin"

cat > "$tmp_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{
  "releases": [
    {"moniker":"mainline","version":"7.2-rc6"},
    {"moniker":"stable","version":"7.1.7"},
    {"moniker":"longterm","version":"6.18.43"}
  ],
  "latest_stable": {"version":"7.1.7"}
}
JSON
MOCK
chmod +x "$tmp_dir/bin/curl"

output="$(PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/resolve-stable-kernel.sh")"
grep -qx 'UPSTREAM_KERNEL_VERSION=7.1.7' <<< "$output"
grep -qx 'KERNEL_SERIES=7.1' <<< "$output"

printf 'stable kernel resolution: ok\n'

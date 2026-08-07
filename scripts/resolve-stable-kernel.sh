#!/usr/bin/env bash
set -euo pipefail

for command_name in curl python3; do
  command -v "$command_name" >/dev/null || {
    printf 'resolve-stable-kernel: %s is required\n' "$command_name" >&2
    exit 1
  }
done

releases_url="${KERNEL_RELEASES_URL:-https://www.kernel.org/releases.json}"
json="$(curl --fail --silent --show-error --location "$releases_url")"

python3 -c '
import json, re, sys
payload = json.load(sys.stdin)
version = str(payload.get("latest_stable", {}).get("version", ""))
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    stable = [r.get("version", "") for r in payload.get("releases", []) if r.get("moniker") == "stable"]
    version = stable[0] if stable else ""
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("No valid latest stable kernel version found")
print(f"UPSTREAM_KERNEL_VERSION={version}")
print(f"KERNEL_SERIES={version.rsplit(chr(46), 1)[0]}")
' <<< "$json"

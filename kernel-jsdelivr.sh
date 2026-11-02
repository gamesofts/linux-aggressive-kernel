#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the unchanged kernel.sh through jsDelivr, and proxy its GitHub
# release/API downloads. jsDelivr cannot serve GitHub Release attachments.
# Use GITHUB_PROXY=https://your-proxy.example to select your own HTTPS proxy.
# The proxy must accept /https://github.com/... and /https://api.github.com/...

log()  { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

[[ -n "${BASH_VERSION:-}" ]] || die 'Run with bash'
command -v curl >/dev/null 2>&1 || die 'curl is required to fetch kernel.sh from jsDelivr'

if [[ -n "${GITHUB_PROXY:-}" ]]; then
  proxies=("${GITHUB_PROXY%/}")
else
  # These are third-party GitHub proxies; availability may vary by network.
  proxies=(https://gh.llkk.cc https://gh-proxy.org)
fi
for proxy in "${proxies[@]}"; do
  [[ "$proxy" == https://* ]] || die "Proxy must use HTTPS: $proxy"
done

# Never forward a private API credential to a third-party mirror.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  warn 'GITHUB_TOKEN is ignored to avoid exposing it to a third-party proxy'
  unset GITHUB_TOKEN
fi

# curl is a shell function so that a sourced, unmodified kernel.sh uses it.
# Only GitHub URLs are rewritten; other curl requests are passed through.
curl() {
  local -a args=("$@")
  local url='' output='' proxy='' index=-1 i
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*)
        url="${args[i]}"
        index="$i"
        ;;
      --output|-o)
        if ((i + 1 < ${#args[@]})); then output="${args[i+1]}"; fi
        ;;
    esac
  done
  if ((index == -1)); then
    command curl "$@"
    return $?
  fi

  # The installer must never be redirected to a different GitHub repository.
  local repo="${KERNEL_REPO:-gamesofts/linux-aggressive-kernel}"
  case "$url" in
    "https://api.github.com/repos/$repo/"*|"https://github.com/$repo/"*|"https://raw.githubusercontent.com/$repo/"*) ;;
    *) die "Unexpected GitHub URL: $url" ;;
  esac

  [[ -n "$output" ]] || die 'GitHub proxy downloads require --output'
  for proxy in "${proxies[@]}"; do
    args[index]="${proxy%/}/$url"
    log "Downloading through ${proxy%/}: ${url##*/}"
    if ! command curl --retry 2 --retry-delay 1 --connect-timeout 15 "${args[@]}"; then
      warn "Download failed via $proxy; trying the next proxy"
      continue
    fi

    # A proxy may return HTML with HTTP 200; reject it before installing.
    if [[ "$url" == https://api.github.com/* || "$url" == */manifest.json ]]; then
      if ! python3 - "$output" "$url" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        obj = json.load(stream)
    if sys.argv[2].startswith('https://api.github.com/'):
        if not (isinstance(obj, dict) and isinstance(obj.get('tag_name'), str)
                and obj['tag_name'] and isinstance(obj.get('assets'), list) and obj['assets']):
            raise ValueError('invalid release metadata')
    else:
        if not (isinstance(obj, dict) and isinstance(obj.get('release_tag'), str)
                and obj['release_tag'] and isinstance(obj.get('assets'), dict)):
            raise ValueError('invalid manifest')
except (OSError, ValueError, AssertionError, AttributeError, TypeError):
    sys.exit(1)
PY
      then
        warn "Invalid JSON from $proxy; trying the next proxy"
        continue
      fi
    elif [[ -n "${IMAGE_NAME:-}" && -n "${IMAGE_SHA256:-}" && "${output##*/}" == "$IMAGE_NAME" ]]; then
      if ! printf '%s  %s\n' "$IMAGE_SHA256" "$output" | sha256sum --check --status; then
        warn "SHA256 mismatch from $proxy; trying the next proxy"
        continue
      fi
    fi
    return 0
  done
  die "All GitHub proxies failed for $url"
}

cdn_url='https://cdn.jsdelivr.net/gh/gamesofts/linux-aggressive-kernel@main/kernel.sh'
log 'Fetching upstream kernel.sh from jsDelivr...'
installer="$(command curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 "$cdn_url")" \
  || die 'Unable to download kernel.sh via jsDelivr'
[[ "$installer" == '#!/usr/bin/env bash'* ]] || die 'Unexpected installer content from jsDelivr'

# Source in the current Bash process so the curl() wrapper remains in scope.
# No installer copy or temporary script file is left on disk.
source <(printf '%s\n' "$installer")

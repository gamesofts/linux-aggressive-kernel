#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$repo_root/kernel.sh" "$repo_root"/scripts/*.sh "$repo_root"/tests/*.sh
python3 -m py_compile "$repo_root/scripts/apply-aggressive-bbr.py" "$repo_root/tests/test-project-contracts.py"
python3 "$repo_root/tests/test-project-contracts.py"
python3 "$repo_root/tests/test-installer-manifest.py"
bash "$repo_root/tests/test-stable-kernel-resolution.sh"
bash "$repo_root/tests/test-kernel-source-resolution.sh"
bash "$repo_root/tests/test-package-detection.sh"
bash "$repo_root/tests/test-kernel-cleanup.sh"
bash "$repo_root/tests/test-bbr-tuning.sh"

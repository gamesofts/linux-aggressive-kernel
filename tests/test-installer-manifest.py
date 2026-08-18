#!/usr/bin/env python3
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
installer = (root / "kernel.sh").read_text()
python_blocks = re.findall(r"<<'PY'\n(.*?)\nPY", installer, re.S)
assert python_blocks
for index, block in enumerate(python_blocks):
    compile(block, f"kernel.sh embedded Python block {index}", "exec")

manifest_validator = next(
    block for block in python_blocks if "expected_kernel_release" in block
)
digest = "0" * 64
fingerprint = "A" * 40
tuning = {
    "revision": 5,
    "bw_rtts": 10,
    "feedback_entry_rtts": 1,
    "feedback_exit_rtts": 4,
    "min_samples": 32,
    "max_gain_percent": 150,
    "lt_loss_thresh": 96,
    "lt_bw_max_rtts": 24,
}


def validate(upstream_version, kernel_release):
    release_tag = f"v{upstream_version}-test"
    image_name = f"linux-aggressive-kernel-{upstream_version}-amd64.deb"
    release = {
        "tag_name": release_tag,
        "assets": [
            {
                "name": "manifest.json",
                "browser_download_url": "https://example.invalid/manifest.json",
            },
            {
                "name": image_name,
                "browser_download_url": f"https://example.invalid/{image_name}",
            },
        ],
    }
    manifest = {
        "schema": 2,
        "profile": "linux-aggressive-bbr-v1",
        "release_tag": release_tag,
        "kernel": {"upstream_version": upstream_version, "release": kernel_release},
        "algorithm": {
            "name": "bbr",
            "source": "linux-mainline",
            "source_file": "net/ipv4/tcp_bbr.c",
            "tuning": tuning,
            "source_sha256": digest,
            "built_source_sha256": digest,
            "linux_source_sha256": digest,
            "recipe_sha256": digest,
            "build_sha256": digest,
            "linux_signing_fingerprint": fingerprint,
        },
        "assets": {
            "amd64": {
                "deb": {
                    "image": {
                        "name": image_name,
                        "sha256": digest,
                        "package": f"linux-image-{kernel_release}",
                        "version": "1-test",
                    }
                }
            }
        },
    }
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)
        release_path = tmp_path / "release.json"
        manifest_path = tmp_path / "manifest.json"
        output_path = tmp_path / "package.env"
        release_path.write_text(json.dumps(release))
        manifest_path.write_text(json.dumps(manifest))
        return subprocess.run(
            [
                sys.executable,
                "-c",
                manifest_validator,
                str(release_path),
                str(manifest_path),
                "amd64",
                "deb",
                str(output_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )


assert validate("7.2", "7.2.0-aggressive").returncode == 0
assert validate("7.2.1", "7.2.1-aggressive").returncode == 0
invalid = validate("7.2", "7.2-aggressive")
assert invalid.returncode != 0
assert "Invalid kernel release" in invalid.stderr

print("installer manifest validation: ok")

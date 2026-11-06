#!/usr/bin/env python3
"""Generate all injection themes from palettes."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PALETTES = ROOT / "themes" / "palettes"
OUT = ROOT / "themes" / "injection"
MANIFEST = ROOT / "themes" / "preset-manifest.json"


def _load_manifest() -> list[dict]:
    with open(MANIFEST, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError(f"{MANIFEST} must contain a JSON array")
    return data


def main() -> int:
    presets = _load_manifest()
    for preset in presets:
        slug = preset["slug"]
        palette_name = preset.get("palette", slug)
        pal = PALETTES / f"{palette_name}.json"
        if not pal.is_file():
            print(f"missing palette for {slug}: {pal}", file=sys.stderr)
            return 1
        pal_data = json.loads(pal.read_text())
        if pal_data.get("slug", pal.stem) != slug:
            print(
                f"palette slug mismatch for {slug}: {pal} has {pal_data.get('slug')}",
                file=sys.stderr,
            )
            return 1
        out = OUT / f"{slug}.json"
        rc = subprocess.call(
            [sys.executable, str(ROOT / "tools" / "expand_theme.py"), str(pal), "-o", str(out)]
        )
        if rc != 0:
            return rc
    print(f"generated {len(presets)} manifest themes → {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

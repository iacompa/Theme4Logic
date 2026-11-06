#!/usr/bin/env python3
"""CLI: expand a palette JSON into a full injection theme."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from t4l.expand import expand_palette  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description="Expand palette → injection theme JSON")
    p.add_argument("palette", type=Path, help="themes/palettes/<name>.json")
    p.add_argument("-o", "--output", type=Path, required=True)
    args = p.parse_args()

    with open(args.palette, encoding="utf-8") as f:
        palette = json.load(f)
    theme = expand_palette(palette)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(theme, f, indent=2)
        f.write("\n")
    print(f"wrote {args.output} ({len(theme['colors'])} colors, {len(theme['mixer'])} mixer)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

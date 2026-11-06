#!/usr/bin/env python3
"""Validate live Logic screenshot baselines against preset palettes.

This is intentionally dependency-free: it parses 8-bit PNG screenshots with the
stdlib so the visual gate can run on a clean macOS developer machine.
"""

from __future__ import annotations

import argparse
import colorsys
import json
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "themes" / "preset-manifest.json"
INJECTION = ROOT / "themes" / "injection"
DEFAULT_SCREENSHOTS = ROOT / "docs" / "screenshots" / "live"
DEFAULT_REPORT = ROOT / "tools" / "audit-output" / "visual-baselines.json"
VISUAL_CONTRACT = ROOT / "themes" / "visual-contracts" / "logic-12.json"
DEFAULT_SURFACES = ("arrange", "mixer", "library", "new-track", "editor")
STALE_COLORS_BY_SLUG = {
    "ableton-classic": {"#2f2925"},
    "ableton-dark": {"#2f2925"},
    "fl-studio-fruity": {"#0a0a0c", "#e8eaf5", "#ffffff2b", "#c8cdf0"},
}


class PngError(ValueError):
    pass


def _hex_to_rgb(value: str) -> tuple[int, int, int] | None:
    h = value.strip().lower().lstrip("#")
    if len(h) == 8:
        h = h[:6]
    if len(h) != 6:
        return None
    try:
        return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]
    except ValueError:
        return None


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png_rgb(path: Path) -> tuple[int, int, list[tuple[int, int, int]]]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PngError(f"{path} is not a PNG")
    pos = 8
    width = height = color_type = bit_depth = None
    compressed = bytearray()
    while pos < len(data):
        if pos + 8 > len(data):
            raise PngError(f"{path} has a truncated chunk header")
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        payload = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _comp, _filter, _interlace = struct.unpack(
                ">IIBBBBB", payload
            )
        elif ctype == b"IDAT":
            compressed.extend(payload)
        elif ctype == b"IEND":
            break

    if width is None or height is None or bit_depth != 8 or color_type not in (2, 6):
        raise PngError(f"{path} must be an 8-bit RGB/RGBA PNG")
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    rows: list[bytearray] = []
    offset = 0
    prev = bytearray(stride)
    for _y in range(height):
        filter_type = raw[offset]
        offset += 1
        row = bytearray(raw[offset : offset + stride])
        offset += stride
        for i, value in enumerate(row):
            left = row[i - channels] if i >= channels else 0
            up = prev[i]
            upper_left = prev[i - channels] if i >= channels else 0
            if filter_type == 0:
                recon = value
            elif filter_type == 1:
                recon = value + left
            elif filter_type == 2:
                recon = value + up
            elif filter_type == 3:
                recon = value + ((left + up) // 2)
            elif filter_type == 4:
                recon = value + _paeth(left, up, upper_left)
            else:
                raise PngError(f"{path} uses unsupported PNG filter {filter_type}")
            row[i] = recon & 0xFF
        rows.append(row)
        prev = row

    pixels: list[tuple[int, int, int]] = []
    for row in rows:
        for x in range(width):
            i = x * channels
            pixels.append((row[i], row[i + 1], row[i + 2]))
    return width, height, pixels


def _distance(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def _theme_palette(theme: dict, manifest_entry: dict) -> list[tuple[int, int, int]]:
    colors: list[tuple[int, int, int]] = []
    for value in list(theme.get("colors", {}).values()) + list(theme.get("mixer", {}).values()):
        if isinstance(value, str):
            rgb = _hex_to_rgb(value)
            if rgb and rgb not in colors:
                colors.append(rgb)
    for value in theme.get("region_palette", []):
        rgb = _hex_to_rgb(str(value))
        if rgb and rgb not in colors:
            colors.append(rgb)
    accent = _hex_to_rgb(str(theme.get("colors", {}).get("AccentColor", manifest_entry.get("accent", ""))))
    if accent and accent not in colors:
        colors.append(accent)
    return colors


def _sample_pixels(pixels: list[tuple[int, int, int]], max_samples: int) -> list[tuple[int, int, int]]:
    if len(pixels) <= max_samples:
        return pixels
    step = max(1, len(pixels) // max_samples)
    return pixels[::step][:max_samples]


def _load_visual_contract(root: Path) -> dict:
    path = root / "themes" / "visual-contracts" / "logic-12.json"
    data = json.loads(path.read_text())
    runtime = data.get("runtime", {})
    if (
        data.get("schemaVersion") != 1
        or runtime.get("product") != "Logic Pro"
        or "12.3" not in runtime.get("supportedVersions", [])
        or runtime.get("enforcement") != "manifest-gated"
    ):
        raise ValueError(f"invalid visual contract: {path}")
    return data


def _normalized_crop(
    width: int,
    height: int,
    pixels: list[tuple[int, int, int]],
    bounds: list[float],
) -> list[tuple[int, int, int]]:
    if len(bounds) != 4:
        raise ValueError("visual-region bounds must contain four normalized values")
    left, top, right, bottom = bounds
    if not (0 <= left < right <= 1 and 0 <= top < bottom <= 1):
        raise ValueError("visual-region bounds must be normalized and non-empty")
    x0, x1 = round(left * width), round(right * width)
    y0, y1 = round(top * height), round(bottom * height)
    return [pixels[y * width + x] for y in range(y0, y1) for x in range(x0, x1)]


def _region_hue_metrics(
    width: int,
    height: int,
    pixels: list[tuple[int, int, int]],
    policy: dict,
    max_samples: int,
    accent: tuple[int, int, int] | None,
    tolerance: float,
) -> list[dict]:
    crop = _sample_pixels(_normalized_crop(width, height, pixels, policy["bounds"]), max_samples)
    min_saturation = float(policy.get("minimumSaturation", 0.0))
    min_value = float(policy.get("minimumValue", 0.0))
    total = max(1, len(crop))
    entries = []
    for rule in policy.get("forbiddenHueRanges", []):
        minimum, maximum = float(rule["minimum"]), float(rule["maximum"])
        hits = 0
        for red, green, blue in crop:
            hue, saturation, value = colorsys.rgb_to_hsv(red / 255.0, green / 255.0, blue / 255.0)
            hue *= 360.0
            if minimum <= hue <= maximum and saturation >= min_saturation and value >= min_value:
                hits += 1
        entries.append(
            {
                "kind": "maximum",
                "name": rule["name"],
                "samples": total,
                "hits": hits,
                "ratio": hits / total,
                "maximumRatio": float(policy.get("maximumRatio", 0.0)),
            }
        )
    if "minimumAccentRatio" in policy:
        accent_hits = (
            sum(1 for pixel in crop if accent and _distance(pixel, accent) <= tolerance)
            if accent
            else 0
        )
        entries.append(
            {
                "kind": "minimum",
                "name": "selected-state-accent",
                "samples": total,
                "hits": accent_hits,
                "ratio": accent_hits / total,
                "minimumRatio": float(policy["minimumAccentRatio"]),
            }
        )
    return entries


def analyze_image(
    path: Path,
    palette: list[tuple[int, int, int]],
    accent: tuple[int, int, int] | None,
    stale_colors: list[tuple[int, int, int]],
    *,
    tolerance: float,
    max_samples: int,
    visual_region: dict | None = None,
) -> dict:
    width, height, pixels = read_png_rgb(path)
    sample = _sample_pixels(pixels, max_samples)
    palette_hits = 0
    stock_hits = 0
    accent_hits = 0
    stale_tolerance = min(tolerance, 8.0)
    for px in sample:
        if any(_distance(px, c) <= tolerance for c in palette):
            palette_hits += 1
        if any(_distance(px, c) <= stale_tolerance for c in stale_colors):
            stock_hits += 1
        if accent and _distance(px, accent) <= tolerance:
            accent_hits += 1
    total = max(1, len(sample))
    out = {
        "path": str(path),
        "width": width,
        "height": height,
        "samples": total,
        "paletteHitRatio": palette_hits / total,
        "stockLeakRatio": stock_hits / total,
        "accentRatio": accent_hits / total,
    }
    if visual_region:
        out["regions"] = _region_hue_metrics(
            width, height, pixels, visual_region, max_samples, accent, tolerance
        )
    return out


def validate_baselines(
    *,
    root: Path = ROOT,
    screenshots_dir: Path = DEFAULT_SCREENSHOTS,
    surfaces: list[str],
    allow_missing: bool,
    min_palette_hit_ratio: float,
    max_stock_leak_ratio: float,
    min_accent_ratio: float,
    tolerance: float,
    max_samples: int,
    slugs: set[str] | None = None,
) -> tuple[bool, dict]:
    manifest = json.loads((root / "themes" / "preset-manifest.json").read_text())
    failures: list[str] = []
    entries: list[dict] = []
    known_slugs = {preset["slug"] for preset in manifest}
    selected_slugs = set(slugs) if slugs is not None else known_slugs
    contract = _load_visual_contract(root)
    unknown_slugs = selected_slugs - known_slugs
    if slugs is not None and not selected_slugs:
        failures.append("at least one preset slug is required")
    if unknown_slugs:
        failures.append(f"unknown preset slug(s): {', '.join(sorted(unknown_slugs))}")
    if not surfaces:
        failures.append("at least one screenshot surface is required")

    for preset in manifest:
        slug = preset["slug"]
        if slug not in selected_slugs:
            continue
        theme_path = root / "themes" / "injection" / f"{slug}.json"
        theme = json.loads(theme_path.read_text())
        palette = _theme_palette(theme, preset)
        accent = _hex_to_rgb(str(theme.get("colors", {}).get("AccentColor", preset.get("accent", ""))))
        stale_colors = [
            rgb
            for rgb in (_hex_to_rgb(c) for c in STALE_COLORS_BY_SLUG.get(slug, set()))
            if rgb and rgb not in palette
        ]
        for surface in surfaces:
            shot = screenshots_dir / slug / f"{surface}.png"
            if not shot.is_file():
                message = f"missing screenshot: {shot}"
                entries.append({"slug": slug, "surface": surface, "missing": True, "path": str(shot)})
                if not allow_missing:
                    failures.append(message)
                continue
            try:
                metrics = analyze_image(
                    shot,
                    palette,
                    accent,
                    stale_colors,
                    tolerance=tolerance,
                    max_samples=max_samples,
                    visual_region=contract.get("visualRegions", {}).get(surface),
                )
            except (OSError, PngError, struct.error, zlib.error) as exc:
                failures.append(f"{slug}/{surface} unreadable screenshot: {exc}")
                entries.append(
                    {
                        "slug": slug,
                        "surface": surface,
                        "missing": False,
                        "invalid": True,
                        "path": str(shot),
                        "error": str(exc),
                    }
                )
                continue
            metrics.update(slug=slug, surface=surface, missing=False)
            entries.append(metrics)
            if metrics["paletteHitRatio"] < min_palette_hit_ratio:
                failures.append(
                    f"{slug}/{surface} palette hit ratio too low: "
                    f"{metrics['paletteHitRatio']:.3f} < {min_palette_hit_ratio:.3f}"
                )
            if metrics["stockLeakRatio"] > max_stock_leak_ratio:
                failures.append(
                    f"{slug}/{surface} stock leakage too high: "
                    f"{metrics['stockLeakRatio']:.3f} > {max_stock_leak_ratio:.3f}"
                )
            if metrics["accentRatio"] < min_accent_ratio:
                failures.append(
                    f"{slug}/{surface} accent visibility too low: "
                    f"{metrics['accentRatio']:.3f} < {min_accent_ratio:.3f}"
                )
            for region in metrics.get("regions", []):
                if region["kind"] == "maximum" and region["ratio"] > region["maximumRatio"]:
                    failures.append(
                        f"{slug}/{surface} {region['name']} leak too high: "
                        f"{region['ratio']:.3f} > {region['maximumRatio']:.3f}"
                    )
                if region["kind"] == "minimum" and region["ratio"] < region["minimumRatio"]:
                    failures.append(
                        f"{slug}/{surface} {region['name']} too low: "
                        f"{region['ratio']:.3f} < {region['minimumRatio']:.3f}"
                    )

    report = {
        "screenshotsDir": str(screenshots_dir),
        "surfaces": surfaces,
        "slugs": sorted(selected_slugs),
        "allowMissing": allow_missing,
        "visualContract": str(root / "themes" / "visual-contracts" / "logic-12.json"),
        "entries": entries,
        "failures": failures,
    }
    return not failures, report


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate live preset screenshot baselines")
    parser.add_argument("--screenshots-dir", type=Path, default=DEFAULT_SCREENSHOTS)
    parser.add_argument("--surfaces", default=",".join(DEFAULT_SURFACES), help="comma-separated screenshot names")
    parser.add_argument("--slugs", help="comma-separated preset slugs; defaults to every manifest preset")
    parser.add_argument("--allow-missing", action="store_true", help="report missing baselines without failing")
    parser.add_argument("--min-palette-hit-ratio", type=float, default=0.22)
    parser.add_argument("--max-stock-leak-ratio", type=float, default=0.08)
    parser.add_argument("--min-accent-ratio", type=float, default=0.001)
    parser.add_argument("--tolerance", type=float, default=28.0)
    parser.add_argument("--max-samples", type=int, default=20000)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    surfaces = [s.strip() for s in args.surfaces.split(",") if s.strip()]
    slugs = {s.strip() for s in args.slugs.split(",") if s.strip()} if args.slugs else None
    ok, report = validate_baselines(
        screenshots_dir=args.screenshots_dir,
        surfaces=surfaces,
        allow_missing=args.allow_missing,
        min_palette_hit_ratio=args.min_palette_hit_ratio,
        max_stock_leak_ratio=args.max_stock_leak_ratio,
        min_accent_ratio=args.min_accent_ratio,
        tolerance=args.tolerance,
        max_samples=args.max_samples,
        slugs=slugs,
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not ok:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

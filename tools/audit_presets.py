#!/usr/bin/env python3
"""Mechanical audit: compare presets, palettes, and generated themes."""

from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from t4l.expand import (  # noqa: E402
    accent_hue_delta,
    contrast_ratio,
    expand_palette,
    find_forbidden_hardcodes,
    load_template,
)

OUT = ROOT / "tools" / "audit-output"
SUPPORT = Path.home() / "Library/Application Support/Theme4Logic"
MAIN_M = ROOT / "app" / "main.m"
MANIFEST = ROOT / "themes" / "preset-manifest.json"
VISUAL_CONTRACT = ROOT / "themes" / "visual-contracts" / "logic-12.json"
FORBIDDEN = ["#e8eaf5", "#ffffff2b", "#c8cdf0"]
UNMAPPED_LIMIT = int(os.environ.get("THEME4LOGIC_AUDIT_UNMAPPED_LIMIT", "25"))
NAVIGATION_TEXT_KEYS = (
    "Browser/Chevron",
    "Browser/ControlSecondary",
    "LibraryControlColorStage1",
    "TableView Scondary Cell Title Color",
)

def _parse_main_presets() -> dict[str, dict]:
    text = MAIN_M.read_text(encoding="utf-8")
    out: dict[str, dict] = {}
    for m in re.finditer(
        r'@\{@"title": @"([^"]+)".*?@"slug": @"([^"]+)".*?@"accent": @"([^"]+)"',
        text,
        re.DOTALL,
    ):
        out[m.group(1)] = {"slug": m.group(2), "accent": m.group(3)}
    return out


def _load_manifest() -> list[dict]:
    with open(MANIFEST, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError(f"{MANIFEST} must contain a JSON array")
    return data


def _load_visual_contract() -> dict:
    with open(VISUAL_CONTRACT, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{VISUAL_CONTRACT} must contain a JSON object")
    runtime = data.get("runtime")
    if (
        data.get("schemaVersion") != 1
        or not isinstance(runtime, dict)
        or runtime.get("product") != "Logic Pro"
        or "12.3" not in runtime.get("supportedVersions", [])
        or runtime.get("enforcement") != "manifest-gated"
    ):
        raise ValueError(f"{VISUAL_CONTRACT} is not a Logic 12 manifest-gated contract")
    return data


def _theme_keys(theme: dict) -> set[str]:
    keys = set(theme.get("colors", {}))
    for k in theme.get("mixer", {}):
        keys.add(f"mixer.{k}")
    return keys


def _top_unmapped(seen_path: Path, theme: dict, n: int = 50) -> list[tuple[str, int]]:
    if not seen_path.is_file():
        return []
    names = [ln.strip() for ln in seen_path.read_text().splitlines() if ln.strip()]
    freq = Counter(names)
    theme_keys = set(theme.get("colors", {}))
    missing: list[tuple[str, int]] = []
    for name, count in freq.most_common(200):
        leaf = name.split("/")[-1]
        dotted = name.replace("Colors/", "").replace("Colors.", "")
        if name in theme_keys or leaf in theme_keys or dotted in theme_keys:
            continue
        missing.append((name, count))
        if len(missing) >= n:
            break
    return missing


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    template = load_template()
    template_n = len(template.get("colors", {})) + len(template.get("mixer", {}))
    lines: list[str] = ["# Preset audit report\n"]
    failures: list[str] = []

    legacy = _parse_main_presets()
    manifest = _load_manifest()
    contract = _load_visual_contract()
    manifest_by_title = {p.get("title"): p for p in manifest}
    manifest_slugs = {p.get("slug") for p in manifest}
    if set(contract.get("presetSlugs", [])) != manifest_slugs:
        failures.append("visual contract preset slugs do not match preset manifest")
    if legacy:
        lines.append("## App fallback presets vs manifest\n")
        for name, vals in legacy.items():
            preset = manifest_by_title.get(name)
            state = (
                "ok"
                if preset
                and preset.get("slug") == vals["slug"]
                and preset.get("accent") == vals["accent"]
                else "DRIFT"
            )
            if state != "ok":
                failures.append(f"app fallback preset drift: {name}")
            lines.append(
                f"- **{name}**: slug `{vals['slug']}` accent `{vals['accent']}` ({state})"
            )
        lines.append("")

    injection_dir = ROOT / "themes" / "injection"
    palettes_dir = ROOT / "themes" / "palettes"

    extra_themes = {
        path.stem for path in injection_dir.glob("*.json")
    } - {str(s) for s in manifest_slugs if s}
    for slug in sorted(extra_themes):
        failures.append(f"injection preset not in manifest: {slug}")

    lines.append("## Manifest injection themes\n")
    lines.append("| Preset | colors | mixer | generated | forbidden | accent Δ° | bg match |")
    lines.append("|--------|--------|-------|-----------|-------------|-----------|----------|")

    for preset in manifest:
        slug = preset.get("slug")
        palette_name = preset.get("palette", slug)
        pal_path = palettes_dir / f"{palette_name}.json"
        if not slug:
            failures.append(f"manifest entry missing slug: {preset}")
            continue
        if not pal_path.is_file():
            failures.append(f"missing palette for {slug}: {pal_path}")
            lines.append(f"| {slug} | MISSING PALETTE | | | | | |")
            continue
        pal = json.loads(pal_path.read_text())
        if pal.get("slug", pal_path.stem) != slug:
            failures.append(f"palette slug mismatch for {slug}: {pal_path}")
        if str(preset.get("accent", "")).lower() != str(pal.get("accent", "")).lower():
            failures.append(
                f"manifest accent mismatch in {slug}: "
                f"manifest={preset.get('accent')} palette={pal.get('accent')}"
            )
        theme_path = injection_dir / f"{slug}.json"
        if not theme_path.is_file():
            failures.append(f"missing generated injection theme: {slug}")
            lines.append(f"| {slug} | MISSING THEME | | | | | |")
            continue
        theme = json.loads(theme_path.read_text())
        if len(theme.get("region_palette", [])) != 12 or len(theme.get("region_palette_hues", [])) != 12:
            failures.append(f"incomplete region palette in {slug}")
        expected = expand_palette(pal, template=template)
        generated_ok = theme == expected
        if not generated_ok:
            failures.append(f"stale generated injection theme: {slug}")
        tone = pal.get("tone", "neutral")
        hardcoded_forbidden = find_forbidden_hardcodes(theme, tone)
        for bad in FORBIDDEN:
            if bad.lower() in json.dumps(theme).lower() and tone != "cool":
                if bad not in hardcoded_forbidden:
                    hardcoded_forbidden.append(bad)
        if hardcoded_forbidden:
            failures.append(f"forbidden hard-coded colors in {slug}: {hardcoded_forbidden}")
        n_c = len(theme.get("colors", {}))
        n_m = len(theme.get("mixer", {}))
        if n_c + n_m < template_n:
            failures.append(f"partial key coverage in {slug}: {n_c + n_m}/{template_n}")
        delta = accent_hue_delta(theme, pal)
        want_bg = pal["colors"]["Arrange.Background"].lower()
        got_bg = theme["colors"].get("ArrangeWorkspaceColor", "").lower()
        bg_ok = "yes" if want_bg == got_bg else f"no ({got_bg})"
        if want_bg != got_bg:
            failures.append(f"background mismatch in {slug}: got {got_bg}, want {want_bg}")
        accent = theme["colors"].get("AccentColor", "").lower()
        navigation = contract["neutralNavigationRoles"]
        navigation_values = {
            theme["colors"].get(key, "").lower() for key in navigation["colors"]
        }
        if "" in navigation_values:
            failures.append(f"missing navigation text color in {slug}")
        elif navigation.get("mustUseSameNeutral") and len(navigation_values) != 1:
            failures.append(f"inconsistent navigation text colors in {slug}: {sorted(navigation_values)}")
        elif navigation.get("mustNotUsePaletteAccent") and accent in navigation_values:
            failures.append(f"navigation text uses accent color in {slug}: {accent}")
        allowed_accent_roles = {
            f"colors.{key}" for key in contract["allowedAccentRoles"]["colors"]
        } | {f"mixer.{key}" for key in contract["allowedAccentRoles"]["mixer"]}
        normal_ui_forbidden = {value.lower() for value in contract["forbiddenNormalUiColors"]}
        for section in ("colors", "mixer"):
            for key, value in theme[section].items():
                location = f"{section}.{key}"
                if value.lower() == accent and location not in allowed_accent_roles:
                    failures.append(f"palette accent leaked to normal UI in {slug}: {location}")
                if value.lower() in normal_ui_forbidden and location not in allowed_accent_roles:
                    failures.append(f"forbidden normal UI color in {slug}: {location}={value}")
        for surface, sections in contract["requiredSurfaces"].items():
            for section, keys in sections.items():
                for key in keys:
                    if key not in theme[section]:
                        failures.append(f"missing {surface} visual contract key in {slug}: {section}.{key}")
        window = theme["colors"].get("MainWindowColor", "#000000")
        light_window = contrast_ratio(window, "#000000") > contrast_ratio(window, "#ffffff")
        for pair in contract["accessibility"]["pairs"]:
            if pair.get("darkWindowOnly") and light_window:
                continue  # transport labels sit on the always-dark display
            fg_ref, bg_ref = pair["foreground"], pair["background"]
            minimum_ratio = pair.get(
                "minimumContrastRatio", contract["accessibility"]["minimumContrastRatio"]
            )
            ratio = contrast_ratio(
                theme[fg_ref["section"]][fg_ref["key"]],
                theme[bg_ref["section"]][bg_ref["key"]],
            )
            if ratio < minimum_ratio:
                failures.append(
                    f"contrast failure in {slug}/{pair['name']}: "
                    f"{ratio:.2f}:1 < {minimum_ratio:.2f}:1"
                )
        lines.append(
            f"| {slug} | {n_c} | {n_m} | {'yes' if generated_ok else 'STALE'} | "
            f"{hardcoded_forbidden or 'none'} | {delta:.1f} | {bg_ok} |"
        )

    lines.append(f"\nTemplate key count: {template_n}\n")

    seen = SUPPORT / "seen-live.txt"
    if seen.is_file():
        lines.append(f"## Runtime discovery coverage (limit: {UNMAPPED_LIMIT})\n")
        for preset in manifest:
            slug = preset.get("slug")
            if not slug:
                continue
            theme_path = injection_dir / f"{slug}.json"
            if not theme_path.is_file():
                continue
            theme = json.loads(theme_path.read_text())
            unmapped = _top_unmapped(seen, theme, 1000)
            lines.append(f"- **{slug}**: {len(unmapped)} unmapped")
            if len(unmapped) > UNMAPPED_LIMIT:
                failures.append(
                    f"runtime unmapped color count above limit for {slug}: "
                    f"{len(unmapped)}/{UNMAPPED_LIMIT}"
                )
        lines.append("\nTop unmapped runtime colors:")
        first_slug = manifest[0].get("slug", "midnight") if manifest else "midnight"
        first_theme = json.loads((injection_dir / f"{first_slug}.json").read_text())
        for name, count in _top_unmapped(seen, first_theme, 20):
            lines.append(f"- `{name}` ({count}x)")
        lines.append("")

    report = "\n".join(lines) + "\n"
    (OUT / "report.md").write_text(report, encoding="utf-8")
    print(report)
    if failures:
        print("Preset audit failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from t4l.expand import expand_palette, load_template  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
THEMES = ROOT / "themes" / "injection"
PALETTES = ROOT / "themes" / "palettes"
MANIFEST = ROOT / "themes" / "preset-manifest.json"
APP_MAIN = ROOT / "app" / "main.m"
BUILD_APP = ROOT / "app" / "build_app.sh"
ENGINE = ROOT / "poc" / "colorize.m"


def _manifest() -> list[dict]:
    return json.loads(MANIFEST.read_text())


def _fallback_presets() -> dict[str, dict]:
    text = APP_MAIN.read_text()
    out: dict[str, dict] = {}
    for m in re.finditer(
        r'@\{@"title": @"([^"]+)".*?@"slug": @"([^"]+)".*?@"accent": @"([^"]+)"',
        text,
        re.DOTALL,
    ):
        out[m.group(2)] = {"title": m.group(1), "accent": m.group(3)}
    return out


class InjectionPresetTest(unittest.TestCase):
    def test_sheet_icon_recolor_is_scoped_to_attached_sheets(self):
        engine = ENGINE.read_text()
        self.assertIn("fc_isCreateNewTrackSheetView", engine)
        self.assertIn("w.sheetParent", engine)
        self.assertIn('rangeOfString:@"Create New Track"', engine)
        self.assertIn("fc_viewTreeContainsText", engine)
        self.assertIn("BOOL sheetIcon=fc_isCreateNewTrackSheetView(view)", engine)
        self.assertIn("fc_sheetIconTint", engine)

    def test_region_palette_is_applied_before_stock_core_graphics_fills(self):
        engine = ENGINE.read_text()
        self.assertIn("gRegionPalette", engine)
        self.assertIn("fc_stockRegionColor", engine)
        self.assertIn("fc_regionReplacement", engine)
        self.assertIn('j[@"region_palette"]', engine)

    def test_hook_manifest_schema_is_runtime_gated(self):
        engine = ENGINE.read_text()
        self.assertIn('NSNumber *schemaVersion = manifest[@"schemaVersion"]', engine)
        self.assertIn('schemaVersion.integerValue != 2', engine)
        self.assertIn('[manifestBundle isKindOfClass:[NSString class]]', engine)

    def test_scroll_documents_use_instance_flipped_coordinates(self):
        app_main = APP_MAIN.read_text()
        self.assertNotIn("+ (BOOL)isFlipped { return YES; }", app_main)
        for class_name in ("FlippedDocView", "PresetsListView"):
            with self.subTest(class_name=class_name):
                match = re.search(
                    rf"@implementation {class_name}\b(?P<body>.*?)@end",
                    app_main,
                    re.DOTALL,
                )
                self.assertIsNotNone(match)
                self.assertIn("- (BOOL)isFlipped { return YES; }", match.group("body"))

    def test_manifest_presets_exist(self):
        slugs = {p["slug"] for p in _manifest()}
        self.assertIn("angst-robot", slugs)
        self.assertIn("ableton-dark", slugs)
        for preset in _manifest():
            with self.subTest(slug=preset["slug"]):
                self.assertTrue((THEMES / f"{preset['slug']}.json").is_file())
                self.assertTrue((PALETTES / f"{preset['palette']}.json").is_file())

    def test_manifest_matches_app_fallback_and_build_bundle(self):
        manifest = {p["slug"]: p for p in _manifest()}
        fallback = _fallback_presets()

        self.assertEqual(set(fallback), set(manifest))
        for slug, preset in manifest.items():
            with self.subTest(slug=slug):
                self.assertEqual(fallback[slug]["title"], preset["title"])
                self.assertEqual(fallback[slug]["accent"], preset["accent"])

        app_main = APP_MAIN.read_text()
        self.assertIn('pathForResource:@"preset-manifest"', app_main)
        self.assertIn("preset-manifest.json", BUILD_APP.read_text())

    def test_manifest_themes_are_generated_and_full_coverage(self):
        template = load_template()
        expected_color_count = len(template.get("colors", {}))
        expected_mixer_count = len(template.get("mixer", {}))

        for preset in _manifest():
            with self.subTest(slug=preset["slug"]):
                palette = json.loads((PALETTES / f"{preset['palette']}.json").read_text())
                self.assertEqual(palette.get("slug"), preset["slug"])
                self.assertEqual(palette.get("accent", "").lower(), preset["accent"].lower())
                theme = json.loads((THEMES / f"{preset['slug']}.json").read_text())
                self.assertEqual(theme, expand_palette(palette, template=template))
                self.assertGreaterEqual(len(theme.get("colors", {})), expected_color_count)
                self.assertGreaterEqual(len(theme.get("mixer", {})), expected_mixer_count)

    def test_every_injection_preset_has_launch_theme_shape(self):
        manifest_slugs = {p["slug"] for p in _manifest()}
        self.assertEqual({p.stem for p in THEMES.glob("*.json")}, manifest_slugs)
        for path in sorted(THEMES.glob("*.json")):
            with self.subTest(path=path.name):
                theme = json.loads(path.read_text())
                self.assertIsInstance(theme.get("name"), str)
                self.assertIsInstance(theme.get("colors"), dict)
                self.assertIsInstance(theme.get("mixer"), dict)
                self.assertEqual(len(theme.get("region_palette", [])), 12)
                self.assertEqual(len(theme.get("region_palette_hues", [])), 12)
                for key in [
                    "ArrangeWorkspaceColor",
                    "MainWindowColor",
                    "PanelBackgroundColor",
                    "PanelHeaderColor",
                    "TrackHeader/Background",
                    "ArrangeWorkspaceBrightColor",
                    "TableViewHeaderTextColor",
                    "ToolbarTextColor",
                ]:
                    self.assertIn(key, theme["colors"])


if __name__ == "__main__":
    unittest.main()

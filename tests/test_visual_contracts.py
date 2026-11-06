import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = ROOT / "themes" / "visual-contracts" / "logic-12.json"
MANIFEST_PATH = ROOT / "themes" / "preset-manifest.json"
PALETTES = ROOT / "themes" / "palettes"
INJECTION = ROOT / "themes" / "injection"
EXPECTED_SLUGS = {
    "midnight",
    "ableton-classic",
    "ableton-dark",
    "angst-robot",
    "fl-studio-fruity",
    "pro-tools",
    "studio-one",
    "reaper",
    "voice-memos",
    "dawnamite-dark",
    "dawnamite-light",
    "dawnamite-high-contrast",
    "dawnamite-safe",
}


def _load_json(path: Path) -> dict | list:
    return json.loads(path.read_text(encoding="utf-8"))


def _hex_to_rgb(value: str) -> tuple[int, int, int]:
    normalized = value.strip().lstrip("#")
    if len(normalized) != 6:
        raise ValueError(f"expected #RRGGBB, got {value!r}")
    return tuple(int(normalized[index : index + 2], 16) for index in (0, 2, 4))


def _relative_luminance(value: str) -> float:
    def linearize(channel: int) -> float:
        normalized = channel / 255
        return normalized / 12.92 if normalized <= 0.04045 else ((normalized + 0.055) / 1.055) ** 2.4

    red, green, blue = (linearize(channel) for channel in _hex_to_rgb(value))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def _contrast_ratio(foreground: str, background: str) -> float:
    lighter = max(_relative_luminance(foreground), _relative_luminance(background))
    darker = min(_relative_luminance(foreground), _relative_luminance(background))
    return (lighter + 0.05) / (darker + 0.05)


class VisualContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contract = _load_json(CONTRACT_PATH)
        cls.manifest = _load_json(MANIFEST_PATH)
        assert isinstance(cls.contract, dict)
        assert isinstance(cls.manifest, list)
        cls.manifest_by_slug = {preset["slug"]: preset for preset in cls.manifest}

    def _theme(self, slug: str) -> dict:
        theme = _load_json(INJECTION / f"{slug}.json")
        self.assertIsInstance(theme, dict)
        return theme

    def _palette(self, slug: str) -> dict:
        palette = _load_json(PALETTES / f"{self.manifest_by_slug[slug]['palette']}.json")
        self.assertIsInstance(palette, dict)
        return palette

    def test_contract_is_manifest_gated_for_logic_12_3(self):
        self.assertEqual(self.contract["schemaVersion"], 1)
        self.assertEqual(self.contract["runtime"]["product"], "Logic Pro")
        self.assertEqual(self.contract["runtime"]["supportedVersions"], ["12.3", "12.4"])
        self.assertEqual(self.contract["runtime"]["enforcement"], "manifest-gated")

    def test_contract_and_manifest_cover_every_preset(self):
        contract_slugs = set(self.contract["presetSlugs"])
        manifest_slugs = set(self.manifest_by_slug)
        self.assertEqual(contract_slugs, EXPECTED_SLUGS)
        self.assertEqual(manifest_slugs, EXPECTED_SLUGS)
        self.assertEqual(len(self.contract["presetSlugs"]), len(EXPECTED_SLUGS))

    def test_every_preset_has_all_required_surfaces(self):
        for slug in self.contract["presetSlugs"]:
            with self.subTest(slug=slug):
                theme = self._theme(slug)
                for surface, sections in self.contract["requiredSurfaces"].items():
                    for section, keys in sections.items():
                        values = theme[section]
                        for key in keys:
                            with self.subTest(slug=slug, surface=surface, section=section, key=key):
                                self.assertIn(key, values)
                                self.assertIsInstance(values[key], str)
                                _hex_to_rgb(values[key])

    def test_navigation_roles_are_shared_neutral_values(self):
        navigation = self.contract["neutralNavigationRoles"]
        for slug in self.contract["presetSlugs"]:
            with self.subTest(slug=slug):
                theme = self._theme(slug)
                palette_accent = self._palette(slug)["accent"].lower()
                values = [theme["colors"][key].lower() for key in navigation["colors"]]
                if navigation["mustNotUsePaletteAccent"]:
                    self.assertNotIn(palette_accent, values)
                if navigation["mustUseSameNeutral"]:
                    self.assertEqual(len(set(values)), 1)

    def test_palette_accents_are_limited_to_allowed_roles(self):
        allowed = {
            f"colors.{key}" for key in self.contract["allowedAccentRoles"]["colors"]
        } | {f"mixer.{key}" for key in self.contract["allowedAccentRoles"]["mixer"]}

        for slug in self.contract["presetSlugs"]:
            with self.subTest(slug=slug):
                theme = self._theme(slug)
                palette_accent = self._palette(slug)["accent"].lower()
                self.assertEqual(theme["colors"]["AccentColor"].lower(), palette_accent)
                self.assertEqual(theme["colors"]["CustomAccentColor"].lower(), palette_accent)
                for section, roles in self.contract["allowedAccentRoles"].items():
                    for key in roles:
                        self.assertIn(key, theme[section])
                for section in ("colors", "mixer"):
                    for key, value in theme[section].items():
                        if value.lower() == palette_accent:
                            self.assertIn(f"{section}.{key}", allowed)

    def test_forbidden_colors_do_not_appear_in_normal_ui_roles(self):
        allowed = {
            f"colors.{key}" for key in self.contract["allowedAccentRoles"]["colors"]
        } | {f"mixer.{key}" for key in self.contract["allowedAccentRoles"]["mixer"]}
        forbidden = {value.lower() for value in self.contract["forbiddenNormalUiColors"]}

        for slug in self.contract["presetSlugs"]:
            with self.subTest(slug=slug):
                theme = self._theme(slug)
                for section in ("colors", "mixer"):
                    for key, value in theme[section].items():
                        if f"{section}.{key}" not in allowed:
                            self.assertNotIn(value.lower(), forbidden)

    def test_accessibility_pairs_meet_the_contrast_floor(self):
        accessibility = self.contract["accessibility"]
        floor = accessibility["minimumContrastRatio"]
        for slug in self.contract["presetSlugs"]:
            theme = self._theme(slug)
            window = theme["colors"]["MainWindowColor"]
            light_window = _contrast_ratio(window, "#000000") > _contrast_ratio(window, "#ffffff")
            for pair in accessibility["pairs"]:
                if pair.get("darkWindowOnly") and light_window:
                    continue  # transport labels sit on the always-dark display
                with self.subTest(slug=slug, pair=pair["name"]):
                    foreground = theme[pair["foreground"]["section"]][pair["foreground"]["key"]]
                    background = theme[pair["background"]["section"]][pair["background"]["key"]]
                    ratio = _contrast_ratio(foreground, background)
                    self.assertGreaterEqual(
                        ratio,
                        pair.get("minimumContrastRatio", floor),
                        f"{foreground} on {background} is {ratio:.2f}:1; expected "
                        f"{pair.get('minimumContrastRatio', floor)}:1",
                    )

    def test_every_preset_has_a_theme_specific_region_palette(self):
        for slug in self.contract["presetSlugs"]:
            with self.subTest(slug=slug):
                palette = self._palette(slug)
                theme = self._theme(slug)
                region_palette = palette["region_palette"]
                self.assertEqual(theme["region_palette"], region_palette)
                self.assertEqual(len(region_palette), 12)
                self.assertEqual(len(theme["region_palette_hues"]), 12)


if __name__ == "__main__":
    unittest.main()

"""Tests for t4l/expand.py — palette → injection theme invariants."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from t4l.expand import (  # noqa: E402
    _DARK_WINDOW_ONLY_PAIRS,
    _TEXT_CONTRAST_PAIRS,
    _composite,
    _contrast_adjusted,
    _hue,
    _relative_luminance,
    _surface_value,
    accent_hue_delta,
    auto_remap,
    contrast_ratio,
    expand_palette,
    find_forbidden_hardcodes,
    load_template,
    text_pair_contrast,
)


class ExpandTest(unittest.TestCase):
    def _pal(self, name: str) -> dict:
        return json.loads((ROOT / "themes" / "palettes" / name).read_text())

    def test_ableton_anchor_colors(self):
        pal = self._pal("ableton.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#1e1e1e")
        self.assertEqual(c["ArrangeWorkspaceBrightColor"].lower(), "#ff8c00")
        h = _hue(c["ArrangeWorkspaceBrightColor"])
        self.assertGreaterEqual(h, 25)
        self.assertLessEqual(h, 40)
        self.assertEqual(c["MainWindowColor"].lower(), "#2a2a2a")
        self.assertEqual(c["TextColor"].lower(), "#d4d4d4")
        self.assertEqual(c["TransportDisplay/Text"].lower(), "#d4d4d4")
        self.assertEqual(c["TransportDisplay/Label"].lower(), "#b0b0b0")
        self.assertEqual(c["Browser/SelectionPrimary"].lower(), "#3d454d")
        self.assertEqual(c["TabBackgroundSelectedColor"].lower(), "#353535")
        self.assertEqual(c["EditorGridLinePrimary"].lower(), "#3a3a3a")
        self.assertNotEqual(c["Browser/SelectionPrimary"].lower(), "#ff8c00")
        self.assertNotIn("#5c4828", json.dumps(t).lower())
        self.assertNotIn("#6a4e2b", json.dumps(t).lower())
        self.assertNotIn("#6c4f2a", json.dumps(t).lower())
        bg = c["ArrangeWorkspaceColor"]
        r, g, b = int(bg[1:3], 16), int(bg[3:5], 16), int(bg[5:7], 16)
        self.assertAlmostEqual(r, g, delta=3)
        self.assertAlmostEqual(g, b, delta=3)

    def test_fl_warm_not_cold_black(self):
        pal = self._pal("fl-studio.json")
        t = expand_palette(pal)
        bg = t["colors"]["ArrangeWorkspaceColor"]
        r, g, b = int(bg[1:3], 16), int(bg[3:5], 16), int(bg[5:7], 16)
        self.assertGreater(r, 20)
        self.assertGreater(g, 15)
        self.assertNotEqual(bg.lower(), "#0a0a0c")

    def test_fl_warm_ruler_toolbar_anchors(self):
        pal = self._pal("fl-studio.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceBrightColor"].lower(), "#e87820")
        self.assertEqual(c["TextColor"].lower(), "#b6ada4")
        self.assertNotIn("#e8eaf5", json.dumps(t).lower())
        # Warm orange-brown selection (not stock light grey #b5b5b5)
        sel = c["RulerMarkerSelectedColor"]
        sr, sg, sb = int(sel[1:3], 16), int(sel[3:5], 16), int(sel[5:7], 16)
        self.assertGreater(sr, sg)
        self.assertGreater(sr, sb)
        self.assertEqual(c["defaultToolbarBackgroundColor"].lower(), "#1e1a16")
        self.assertEqual(c["BeatsEditor/SelectionHighlight"].lower(), sel.lower())
        self.assertEqual(c["BeatsEditor/DownmixWaveform"].lower(), "#1a1613")
        self.assertEqual(c["GIEditorContainerBackground"].lower(), "#1e1a16")

    def test_voice_memos_oled_red_accents(self):
        pal = self._pal("voice-memos.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#000000")
        self.assertEqual(c["TextColor"].lower(), "#f2f2f7")
        self.assertEqual(c["AccentColor"].lower(), "#ff3b30")
        self.assertEqual(c["CustomAccentColor"].lower(), "#ff3b30")
        self.assertEqual(c["TabBackgroundSelectedColor"].lower(), "#8c2820")
        self.assertEqual(c["Browser/SelectionPrimary"].lower(), "#331110")
        self.assertEqual(c["ListRowA"].lower(), "#000000")
        self.assertEqual(c["ListRowB"].lower(), "#0a0a0a")
        self.assertEqual(c["SelectionColor"].lower(), "#331110")
        self.assertEqual(c["TransportDisplay/Text"].lower(), "#f2f2f7")
        self.assertEqual(c["TransportDisplay/Label"].lower(), "#ff3b30")
        self.assertEqual(c["TransportDisplay/SelectedText"].lower(), "#ffffff")
        self.assertEqual(c["MainWindowColor"].lower(), "#1c1c1e")
        self.assertEqual(c["PanelBackgroundColor"].lower(), "#1c1c1e")
        self.assertEqual(c["PianoRoll/BackgroundWhiteKey"].lower(), "#1c1c1e")
        self.assertNotEqual(c["Browser/SelectionPrimary"].lower(), "#007aff")
        strip_delta = int(c["ListRowB"][1:3], 16) - int(c["ListRowA"][1:3], 16)
        self.assertLessEqual(strip_delta, 12)
        m = t["mixer"]
        self.assertEqual(m["ScaleLabel"].lower(), "#f2f2f7")
        self.assertEqual(m["ButtonBackground"].lower(), "#48484a")
        self.assertEqual(m["Knob"].lower(), "#48484a")
        self.assertEqual(m["KnobIndicator"].lower(), "#aeaeb2")
        self.assertNotEqual(m["ScaleLabel"].lower(), c["AccentColor"].lower())

    def test_reaper_contrast_readability(self):
        pal = self._pal("reaper.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#333333")
        self.assertEqual(c["MainWindowColor"].lower(), "#454545")
        self.assertEqual(c["PanelBackgroundColor"].lower(), "#454545")
        self.assertEqual(c["TextColor"].lower(), "#e8e8e8")
        self.assertEqual(c["ToolbarGlyphColor"].lower(), "#e8e8e8")
        self.assertEqual(c["ControlTextTitleColor"].lower(), "#e8e8e8")
        self.assertEqual(c["GraphPanel/Grid"].lower(), "#555555")
        self.assertEqual(c["GraphPanel/AxisLabel"].lower(), "#e8e8e8")
        self.assertEqual(c["EditorGridLinePrimary"].lower(), "#555555")
        self.assertEqual(c["gridColor"].lower(), "#555555")
        self.assertEqual(c["DividerPrimaryColor"].lower(), "#666666")
        self.assertEqual(c["TrackHeader/BottomLine"].lower(), "#555555")
        self.assertEqual(c["ListRowA"].lower(), "#333333")
        self.assertEqual(c["ListRowB"].lower(), "#3d3d3d")
        self.assertEqual(c["ArrangeWorkspaceBrightColor"].lower(), "#339887")
        self.assertEqual(c["AccentColor"].lower(), "#339887")
        self.assertEqual(c["TrackHeader/LeftArea_SelectedBackground"].lower(), "#3d7568")
        strip_delta = int(c["ListRowB"][1:3], 16) - int(c["ListRowA"][1:3], 16)
        self.assertGreaterEqual(strip_delta, 8)
        panel_delta = int(c["MainWindowColor"][1:3], 16) - int(c["ArrangeWorkspaceColor"][1:3], 16)
        self.assertGreaterEqual(panel_delta, 16)
        grid_delta = int(c["EditorGridLinePrimary"][1:3], 16) - int(c["ArrangeWorkspaceColor"][1:3], 16)
        self.assertGreaterEqual(grid_delta, 30)
        self.assertNotIn("#e8eaf5", json.dumps(t).lower())
        self.assertNotIn("#d6d9dd", json.dumps(t).lower())
        self.assertNotIn("#44b8a6", json.dumps(t).lower())

    def test_angst_robot_purple_cyberpunk(self):
        pal = self._pal("angst-robot.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#1a1528")
        self.assertEqual(c["MainWindowColor"].lower(), "#1e1a30")
        self.assertEqual(c["PanelBackgroundColor"].lower(), "#252038")
        self.assertEqual(c["TextColor"].lower(), "#e8e8f0")
        self.assertEqual(c["ToolbarTextColor"].lower(), "#ffffff")
        self.assertEqual(c["ArrangeWorkspaceBrightColor"].lower(), "#7b68ee")
        self.assertEqual(c["Browser/SelectionPrimary"].lower(), "#3d3560")
        self.assertEqual(c["EditorGridLinePrimary"].lower(), "#3a3555")
        self.assertEqual(c["Browser/Chevron"], c["Browser/ControlSecondary"])
        self.assertNotEqual(c["Browser/Chevron"], c["AccentColor"])
        self.assertEqual(c["FocusRingColor"].lower(), "#a99cff")
        self.assertEqual(c["RulerCycleColor"].lower(), "#7b68ee")
        self.assertNotIn("#ffff00", json.dumps(t).lower())
        self.assertEqual(c["TransportDisplay/Text"].lower(), "#f0f0f5")
        self.assertEqual(c["TransportDisplay/SelectedText"].lower(), "#ffffff")
        bg = c["ArrangeWorkspaceColor"]
        r, g, b = int(bg[1:3], 16), int(bg[3:5], 16), int(bg[5:7], 16)
        self.assertGreater(b, r)
        self.assertGreater(b, g)

    def test_studio_one_presonus_cool_grey(self):
        pal = self._pal("studio-one.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#191a1e")
        self.assertEqual(c["MainWindowColor"].lower(), "#26282c")
        self.assertEqual(c["PanelBackgroundColor"].lower(), "#26282c")
        self.assertEqual(c["TextColor"].lower(), "#cccccc")
        self.assertEqual(c["ArrangeWorkspaceBrightColor"].lower(), "#2478ba")
        self.assertEqual(c["TabBackgroundSelectedColor"].lower(), "#2e4a62")
        self.assertEqual(c["Browser/SelectionPrimary"].lower(), "#2a4558")
        self.assertEqual(c["FocusRingColor"].lower(), "#1e88e5")
        self.assertEqual(c["Browser/Chevron"], c["Browser/ControlSecondary"])
        self.assertNotEqual(c["Browser/Chevron"], c["AccentColor"])
        self.assertEqual(c["TransportDisplay/Label"].lower(), "#4a9ad8")
        self.assertNotIn("#e8eaf5", json.dumps(t).lower())
        self.assertNotEqual(c["Browser/SelectionPrimary"].lower(), "#2478ba")

    def test_pro_tools_dark_charcoal_and_lcd_green(self):
        pal = self._pal("pro-tools.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#2b2b2b")
        self.assertEqual(c["TrackHeader/Background"].lower(), "#262626")
        self.assertEqual(c["TextColor"].lower(), "#d6d9dd")
        self.assertNotIn("#e8eaf5", json.dumps(t).lower())
        self.assertNotIn("#394b57", json.dumps(t).lower())
        self.assertNotIn("#7eb8d4", json.dumps(t).lower())
        self.assertEqual(c["TransportDisplay/Text"].lower(), "#39ff14")
        self.assertEqual(c["TransportDisplay/Label"].lower(), "#3399ee")
        self.assertEqual(c["TransportDisplay/SelectedText"].lower(), "#39ff14")
        self.assertEqual(c["TabBackgroundSelectedColor"].lower(), "#333333")
        self.assertEqual(c["Browser/SelectionPrimary"].lower(), "#404040")
        self.assertEqual(c["ListRowB"].lower(), "#222222")
        self.assertEqual(c["ArrangeWorkspaceBrightColor"].lower(), "#0078d7")
        self.assertEqual(c["BeatsEditor/SelectionHighlight"].lower(), "#3a3a3a")
        self.assertEqual(c["TransportDisplay/RollOver"].lower(), "#3a3a3a")
        self.assertNotEqual(c["Browser/SelectionPrimary"].lower(), "#0078d7")
        bg = c["ArrangeWorkspaceColor"]
        r, g, b = int(bg[1:3], 16), int(bg[3:5], 16), int(bg[5:7], 16)
        self.assertAlmostEqual(r, g, delta=3)
        self.assertAlmostEqual(g, b, delta=3)

    def test_track_editor_graph_panel_keys(self):
        pal = self._pal("ableton.json")
        t = expand_palette(pal)
        c = t["colors"]
        for key in (
            "BeatsEditor/DownmixWaveform",
            "GraphPanel/Grid",
            "GraphPanel/Graph",
            "GraphPanel/AxisLabel",
            "GIEditorContainerBackground",
            "GIEditorViewBackground1",
            "GIEditorViewBackground2",
            "EditorGridLinePrimary",
            "RulerSelectionBarEditors",
        ):
            self.assertIn(key, c)
            self.assertTrue(c[key].startswith("#"))

    def test_midnight_hand_tuned_anchors(self):
        pal = self._pal("midnight.json")
        t = expand_palette(pal)
        c = t["colors"]
        self.assertEqual(c["ArrangeWorkspaceColor"].lower(), "#15151f")
        self.assertEqual(c["GIEditorContainerBackground"].lower(), "#1a1d2e")
        self.assertEqual(c["TabBackgroundSelectedColor"].lower(), "#34406e")
        self.assertEqual(c["TransportDisplay/PerformanceMeterAverage"].lower(), "#5a8acb")
        self.assertEqual(t["mixer"]["Meter"].lower(), "#d18a4a")
        self.assertIn("hand-tuned", t["_note"].lower())

    def test_neutral_no_midnight_blue_text(self):
        for fname in ("ableton.json", "reaper.json"):
            pal = self._pal(fname)
            t = expand_palette(pal)
            self.assertEqual(find_forbidden_hardcodes(t, pal["tone"]), [])

    def test_cool_presets_may_use_light_text(self):
        pal = self._pal("midnight.json")
        t = expand_palette(pal)
        self.assertEqual(t["colors"]["TextColor"].lower(), "#e8eaf5")

    def test_key_count_matches_roles(self):
        roles = json.loads((ROOT / "themes" / "roles.json").read_text())
        pal = self._pal("ableton.json")
        t = expand_palette(pal)
        self.assertEqual(len(t["colors"]), len(roles["colors"]))
        self.assertEqual(len(t["mixer"]), len(roles["mixer"]))

    def test_navigation_text_roles_are_neutral_in_every_preset(self):
        # These are ordinary browser/table labels, not active selection indicators.
        # Rendering them with a preset accent was the source of the neon menu text.
        keys = (
            "Browser/Chevron",
            "Browser/ControlSecondary",
            "LibraryControlColorStage1",
            "TableView Scondary Cell Title Color",
        )
        for path in sorted((ROOT / "themes" / "palettes").glob("*.json")):
            with self.subTest(palette=path.name):
                theme = expand_palette(self._pal(path.name))
                colors = theme["colors"]
                values = {colors[key].lower() for key in keys}
                self.assertEqual(len(values), 1)
                self.assertNotEqual(colors["AccentColor"].lower(), values.pop())

    def test_every_palette_declares_complete_semantic_color_roles(self):
        required = {
            "text_primary", "text_secondary", "icon_neutral", "selection", "focus",
            "warning", "record", "record_dim", "meter", "meter_peak",
        }
        for path in sorted((ROOT / "themes" / "palettes").glob("*.json")):
            with self.subTest(palette=path.name):
                palette = self._pal(path.name)
                self.assertEqual(set(palette["semantics"]), required)
                for value in palette["semantics"].values():
                    self.assertTrue(value.startswith("#"))

    def test_semantic_text_meets_minimum_dark_surface_contrast(self):
        for path in sorted((ROOT / "themes" / "palettes").glob("*.json")):
            with self.subTest(palette=path.name):
                theme = expand_palette(self._pal(path.name))
                self.assertGreaterEqual(
                    contrast_ratio(
                        theme["colors"]["TextColor"],
                        theme["colors"]["ArrangeWorkspaceColor"],
                    ),
                    4.5,
                )

    def test_secondary_and_tertiary_text_are_explicit_and_readable(self):
        for path in sorted((ROOT / "themes" / "palettes").glob("*.json")):
            with self.subTest(palette=path.name):
                theme = expand_palette(self._pal(path.name))
                colors = theme["colors"]
                self.assertGreaterEqual(
                    contrast_ratio(colors["TextSecondaryColor"], colors["PanelBackgroundColor"]),
                    4.5,
                )
                self.assertGreaterEqual(
                    contrast_ratio(colors["TextTertiaryColor"], colors["PanelBackgroundColor"]),
                    3.0,
                )
                self.assertGreaterEqual(
                    contrast_ratio(colors["TextMutedColor"], colors["PanelBackgroundColor"]),
                    3.0,
                )

    def test_audited_text_pairs_reach_minimum_contrast_in_every_preset(self):
        # Text/surface pairs audited against Logic 12's stock asset catalogs.
        # Surfaces without a theme key are resolved through the preset's auto
        # ramp / accent remap, the same way the engine paints them.
        manifest = json.loads((ROOT / "themes" / "preset-manifest.json").read_text())
        self.assertEqual(len(manifest), 13)
        self.assertGreaterEqual(len(_TEXT_CONTRAST_PAIRS), 50)
        for preset in manifest:
            theme = json.loads(
                (ROOT / "themes" / "injection" / f"{preset['slug']}.json").read_text()
            )
            window = theme["colors"]["MainWindowColor"]
            light_window = contrast_ratio(window, "#000000") > contrast_ratio(window, "#ffffff")
            for foreground, background, minimum in _TEXT_CONTRAST_PAIRS:
                if light_window and (foreground, background) in _DARK_WINDOW_ONLY_PAIRS:
                    continue  # drawn on the always-dark transport display, not the window
                with self.subTest(slug=preset["slug"], text=foreground, surface=background):
                    self.assertIn(foreground, theme["colors"])
                    ratio = text_pair_contrast(theme, foreground, background)
                    self.assertIsNotNone(ratio)
                    self.assertGreaterEqual(
                        ratio,
                        minimum,
                        f"{foreground} on {background} is {ratio:.2f}:1 in {preset['slug']}",
                    )

    def test_light_tone_draws_dark_text_on_light_surfaces(self):
        theme = json.loads((ROOT / "themes" / "injection" / "dawnamite-light.json").read_text())
        backdrop = theme["colors"]["ArrangeWorkspaceColor"]
        for foreground, background, _minimum in _TEXT_CONTRAST_PAIRS:
            with self.subTest(text=foreground, surface=background):
                surface = _composite(_surface_value(theme, background), backdrop)
                ink = _composite(_surface_value(theme, foreground), surface)
                if _relative_luminance(surface) >= 0.18:
                    self.assertLess(_relative_luminance(ink), _relative_luminance(surface))
        # Stock near-black Logic 12 surfaces (rulers, global tracks, track
        # headers, LCD) must land on the light side of the ramp, while pure
        # black ink stays dark.
        for stock in ("#0e0e0f", "#0e1012", "#151517"):
            self.assertGreater(_relative_luminance(auto_remap(stock, theme["auto"])), 0.5)
        self.assertLess(_relative_luminance(auto_remap("#000000", theme["auto"])), 0.05)

    def test_bright_text_roles_are_dark_ink_on_light_tone_and_white_on_dark(self):
        # text_bright / text_bright_dim used to be fixed white in every tone,
        # which made ControlLabelColor, EditorScaleEmphesized, the selected
        # global-track labels, LiveLoops selected glyphs, the plugin toolbar
        # highlight and SpotErase white-on-light in Dawnamite Light.
        roles = json.loads((ROOT / "themes" / "roles.json").read_text())["colors"]
        bright_keys = sorted(k for k, r in roles.items() if r in ("text_bright", "text_bright_dim"))
        self.assertIn("ControlLabelColor", bright_keys)
        self.assertIn("ControlTextTitleSegmentedControlOffColor", bright_keys)
        for slug in ("dawnamite-light",):
            theme = json.loads((ROOT / "themes" / "injection" / f"{slug}.json").read_text())
            panel = theme["colors"]["PanelBackgroundColor"]
            for key in bright_keys:
                with self.subTest(slug=slug, key=key):
                    value = theme["colors"][key]
                    self.assertFalse(value.lower().startswith("#ffffff"))
                    self.assertGreaterEqual(contrast_ratio(_composite(value, panel), panel), 4.5)
        dark = expand_palette(self._pal("dawnamite-dark.json"))
        for key in bright_keys:
            with self.subTest(slug="dawnamite-dark", key=key):
                self.assertTrue(dark["colors"][key].lower().startswith("#ffffff"))

    def test_contrast_repair_heads_toward_the_readable_extreme(self):
        # Mid-grey light-theme fills (luminance ~0.3) need dark text; the old
        # 0.5 luminance split pushed text toward white and gave up at ~3:1.
        repaired = _contrast_adjusted("#ffffff", "#8f9091", 4.5)
        self.assertGreaterEqual(contrast_ratio(repaired, "#8f9091"), 4.5)

    def test_region_palette_is_theme_specific_and_complete(self):
        for path in sorted((ROOT / "themes" / "palettes").glob("*.json")):
            with self.subTest(palette=path.name):
                palette = self._pal(path.name)
                theme = expand_palette(palette)
                self.assertEqual(len(palette["region_palette"]), 12)
                self.assertEqual(theme["region_palette"], palette["region_palette"])
                self.assertEqual(theme["region_palette_hues"], palette["region_palette_hues"])

    def test_channelstrip_catalog_and_mixer_agree(self):
        pal = self._pal("ableton.json")
        t = expand_palette(pal)
        self.assertEqual(
            t["colors"]["ChannelstripColor"].lower(),
            t["mixer"]["ChannelstripBackground"].lower(),
        )

    def test_accent_hue_within_15_degrees(self):
        for fname in ("ableton.json", "fl-studio.json", "pro-tools.json"):
            pal = self._pal(fname)
            t = expand_palette(pal)
            self.assertLess(accent_hue_delta(t, pal), 1.0)

    def test_piano_roll_keys_set(self):
        pal = self._pal("ableton.json")
        t = expand_palette(pal)
        self.assertEqual(t["colors"]["PianoRoll/BackgroundWhiteKey"].lower(), "#333333")
        self.assertEqual(t["colors"]["PianoRoll/BackgroundBlackKey"].lower(), "#1e1e1e")


if __name__ == "__main__":
    unittest.main()

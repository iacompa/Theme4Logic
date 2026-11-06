"""Expand small palette files into full injection theme JSON.

Clones the Midnight template key structure and derives values from an 8-surface
palette + accent using roles defined in themes/roles.json.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_PATH = ROOT / "poc" / "theme.json"
ROLES_PATH = ROOT / "themes" / "roles.json"
MIDNIGHT_HAND_TUNED_PATH = ROOT / "poc" / "theme.json"

FORBIDDEN_IN_NEUTRAL = {"#e8eaf5", "#c8cdf0", "#ffffff2b", "#ffffff1a"}
SEMANTIC_COLOR_KEYS = {
    "text_primary",
    "text_secondary",
    "icon_neutral",
    "selection",
    "focus",
    "warning",
    "record",
    "record_dim",
    "meter",
    "meter_peak",
}


# These are the text/surface relationships that are visible across Logic's
# arrange, mixer, browser, editor, and table views.  Keep this list here (and
# mirror it in the visual contract) so a palette override cannot silently make
# an otherwise valid preset unreadable.
_TEXT_CONTRAST_PAIRS = (
    ("TextColor", "ArrangeWorkspaceColor", 4.5),
    ("ControlTextTitleColor", "MainWindowColor", 4.5),
    ("TableViewHeaderTextColor", "TableviewColor", 4.5),
    ("Browser/Chevron", "LibraryColor", 4.5),
    ("LibraryControlColorHeader", "LibraryColorHeaderBackground", 4.5),
    ("LibraryControlColorStage1", "LibraryColor", 4.5),
    ("LibraryControlColorStage2", "LibraryColorStageBackground", 3.0),
    ("ToolbarGlyphColor", "defaultToolbarBackgroundColor", 4.5),
    ("TransportDisplay/Label", "MainWindowColor", 3.0),
    ("EditorInspectorLabelColor", "PianoRoll/InlineInspectorBackground", 4.5),
    ("TableView Primary Cell Title Color", "TableviewColor", 4.5),
    ("TextSecondaryColor", "PanelBackgroundColor", 4.5),
    ("TextTertiaryColor", "PanelBackgroundColor", 3.0),
    ("TextMutedColor", "PanelBackgroundColor", 3.0),
    # Audited against Logic 12's stock catalogs: each text key is drawn on the
    # surface it is paired with, and the stock pair is readable (>= 3:1).
    # Backgrounds that no theme key names are resolved through the theme's
    # auto ramp from _STOCK_SURFACES, exactly as the engine recolors them.
    ("TrackHeaderLabelTrackName", "TrackHeaderBackground", 4.5),
    ("TrackHeaderLabelTrackName", "TrackHeader/Background", 4.5),
    ("TrackHeaderLabelTrackNameSelected", "TrackHeaderBackgroundSelected", 4.5),
    ("TrackHeaderLabelTrackNameSelected", "TrackHeader/SelectedBackground", 4.5),
    ("TrackHeaderLabelTrackNumber", "TrackHeaderBackground", 3.0),
    ("TrackHeaderLabelTrackNumberSelected", "TrackHeaderBackgroundSelected", 3.0),
    ("GlobalTracksLabelHeader", "GlobalTracksHeaderBackground", 4.5),
    ("GlobalTracksLabelMarkerName", "GlobalTracksMarker", 4.5),
    ("GlobalTracksLabelMarkerNameSelected", "GlobalTracksMarkerSelected", 4.5),
    ("GlobalTracksRulerLabel", "GlobalTracksBackground", 4.5),
    ("GlobalTracksLabelChordNameLoop", "GlobalTracksBackground", 3.0),
    ("RulerLabelNormal", "RulerBackground", 3.0),
    ("RulerLabelNormal", "RulerColor", 3.0),
    ("RulerLabelCycleOff", "RulerCycleOffBackground", 3.0),
    ("RulerLabelCycleSkipOff", "RulerCycleOffBackground", 3.0),
    ("RulerLabelCycleOn", "RulerCycleOnBackground", 4.5),
    ("TransportDisplay/Text", "TransportDisplayBackgroundNormal", 4.5),
    ("TransportDisplay/SelectedText", "TransportDisplayBackgroundNormal", 4.5),
    ("TransportDisplay/TextDark", "TransportDisplayBackgroundNormal", 3.0),
    ("TransportDisplay/Label", "TransportDisplayBackgroundNormal", 3.0),
    ("TransportDisplay/Text_record", "TransportDisplayBackgroundRecord", 4.5),
    ("TransportDisplay/Label_record", "TransportDisplayBackgroundRecord", 3.0),
    ("Browser/ControlPrimary", "Browser/Background", 4.5),
    ("TableViewHeaderTextColor", "TableviewHeaderColor", 4.5),
    ("EditorInspectorValueColor", "PianoRoll/InlineInspectorBackground", 4.5),
    ("StepSequencerInspector/SegmentedControlText", "InspectorColor", 4.5),
    ("ControlTextTitleColor", "InspectorColor", 4.5),
    ("ControlLabelColor", "PanelBackgroundColor", 3.0),
    ("ControlTextTitleSegmentedControlOffColor", "PanelBackgroundColor", 3.0),
    ("ToolbarTextColor", "defaultToolbarBackgroundColor", 4.5),
    ("Header/GlyphColor", "PanelHeaderColor", 3.0),
    ("LiveLoopsDividerBarGlyphColor", "LiveLoopsDividerBarBackgroundColor", 3.0),
    ("LiveLoopsDividerBarGlyphColor", "LiveLoopsDividerBarHeaderColor", 3.0),
    ("LiveLoopsDividerBarGlyphSelectedColor", "LiveLoopsDividerBarMouseoverSelectedColor", 3.0),
    ("LiveLoopsDividerBarGlyphSelectedColor", "LiveLoopsDividerBarPressedSelectedColor", 3.0),
    ("GraphPanel/DotText", "GraphPanel/Dot", 3.0),
    ("EditorScaleEmphesized", "GIEditorViewBackground1", 3.0),
    ("BeatsEditor/RulerText", "RulerColor", 4.5),
    ("GIEditorControlButtonLabelOff", "GIEditorControlButtonOff", 4.5),
    ("DarkButtonLabel", "DarkButtonBackground", 4.5),
    ("RegionRecordingTitle", "RegionRecordingBackground", 4.5),
)

# Stock Logic 12 (dark appearance) values of surfaces that carry audited text
# but have no theme key.  The engine recolors them through ``auto`` (ramp for
# neutrals, accent remap for the blue/yellow families), so contrast checks
# resolve them the same way.  Values come from `assetutil --info` on
# Logic.framework/Resources/Assets.car.
_STOCK_SURFACES = {
    "TrackHeaderBackground": "#151517",
    "TrackHeaderBackgroundSelected": "#262629",
    "GlobalTracksHeaderBackground": "#151517",
    "GlobalTracksBackground": "#0e0e0f",
    "RulerBackground": "#0e0e0f",
    "RulerCycleOffBackground": "#262629cc",
    "RulerCycleOnBackground": "#d9b000",
    "TransportDisplayBackgroundNormal": "#0e1012",
    "TransportDisplayBackgroundRecord": "#1a0b0a",
    "GIEditorControlButtonOff": "#474747",
    "DarkButtonBackground": "#585858",
    "RegionRecordingBackground": "#6c211d",
}

# Surfaces Logic paints outside every hooked path: they stay stock in every
# theme (measured on Logic 12.4), so text on them is checked against the stock
# color, never a theme remap. The transport display stays dark even in a
# light theme.
_UNTHEMED_SURFACES = {
    "TransportDisplayBackgroundNormal": "#23262e",
    "TransportDisplayBackgroundRecord": "#1a0b0a",
}

# Pairs that only apply when the main window is dark. The transport labels are
# drawn on the (always dark) display, so a light theme must not darken them to
# suit its light window color.
_DARK_WINDOW_ONLY_PAIRS = {("TransportDisplay/Label", "MainWindowColor")}


def _parse_hex(hex_str: str) -> tuple[int, int, int]:
    h = hex_str.strip().lstrip("#")
    if len(h) == 8:
        h = h[:6]
    if len(h) != 6:
        raise ValueError(f"bad hex: {hex_str!r}")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _fmt_hex(r: int, g: int, b: int) -> str:
    return f"#{r:02x}{g:02x}{b:02x}"


def _clamp(v: float) -> int:
    return max(0, min(255, round(v)))


def _lighten(hex_str: str, amount: float) -> str:
    r, g, b = _parse_hex(hex_str)
    return _fmt_hex(_clamp(r + 255 * amount), _clamp(g + 255 * amount), _clamp(b + 255 * amount))


def _darken(hex_str: str, amount: float) -> str:
    r, g, b = _parse_hex(hex_str)
    return _fmt_hex(_clamp(r * (1 - amount)), _clamp(g * (1 - amount)), _clamp(b * (1 - amount)))


def _mix(a: str, b: str, t: float) -> str:
    ar, ag, ab = _parse_hex(a)
    br, bg, bb = _parse_hex(b)
    return _fmt_hex(
        _clamp(ar + (br - ar) * t),
        _clamp(ag + (bg - ag) * t),
        _clamp(ab + (bb - ab) * t),
    )


def _hue(hex_str: str) -> float:
    r, g, b = [x / 255.0 for x in _parse_hex(hex_str)]
    mx, mn = max(r, g, b), min(r, g, b)
    if mx == mn:
        return 0.0
    d = mx - mn
    if mx == r:
        h = (g - b) / d + (6 if g < b else 0)
    elif mx == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    return h * 60


def _contrast_adjusted(foreground: str, background: str, minimum: float) -> str:
    """Move a foreground toward white/black until it clears ``minimum``.

    Palette authors still control the initial color.  This is only a safety
    net for overrides that would otherwise create dark-on-dark or light-on-
    light text.  The binary search changes the color by the smallest practical
    amount and keeps the original hue as long as possible.
    """
    if contrast_ratio(foreground, background) >= minimum:
        return foreground

    # Head for whichever extreme reads better on this surface.  A fixed 0.5
    # luminance split sent text on mid-grey light-theme controls (luminance
    # 0.2-0.5) toward white, where it can never reach 4.5:1.
    if contrast_ratio("#ffffff", background) >= contrast_ratio("#000000", background):
        target = "#ffffff"
    else:
        target = "#000000"
    if contrast_ratio(target, background) < minimum:
        return target

    low, high = 0.0, 1.0
    for _ in range(24):
        middle = (low + high) / 2.0
        candidate = _mix(foreground, target, middle)
        if contrast_ratio(candidate, background) >= minimum:
            high = middle
        else:
            low = middle
    return _mix(foreground, target, high)


def _relative_luminance(value: str) -> float:
    channels = []
    for channel in _parse_hex(value):
        normalized = channel / 255.0
        channels.append(
            normalized / 12.92
            if normalized <= 0.04045
            else ((normalized + 0.055) / 1.055) ** 2.4
        )
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def load_template(path: Path | None = None) -> dict:
    with open(path or TEMPLATE_PATH, encoding="utf-8") as f:
        return json.load(f)


def load_roles(path: Path | None = None) -> dict:
    with open(path or ROLES_PATH, encoding="utf-8") as f:
        return json.load(f)


def _surfaces(palette: dict) -> dict[str, str]:
    c = palette.get("colors", {})
    accent = palette.get("accent", "#9097cc")
    overrides = palette.get("overrides", {})
    surf: dict[str, str] = {
        "bg": c["Arrange.Background"],
        "mixer_top": c["Mixer.ChannelStrip_BG_top"],
        "mixer_bottom": c["Mixer.ChannelStrip_BG_bottom"],
        "mixer_selected": c["Mixer.ChannelStrip_Selected"],
        "track_header": c["TrackHeader.Background"],
        "piano_white": c["PianoRoll.BackgroundWhiteKey"],
        "piano_black": c["PianoRoll.BackgroundBlackKey"],
        "grid_lines": c.get("Arrange.ArrangeGrid_BarLines", _lighten(c["Arrange.Background"], 0.08)),
        "accent": accent,
        "transport_lcd": palette.get("transport_lcd"),
        "selection_override": palette.get("selection"),
    }
    semantics = palette.get("semantics", {})
    if semantics is not None and not isinstance(semantics, dict):
        raise ValueError("palette semantics must be an object")
    for key, value in semantics.items():
        if key not in SEMANTIC_COLOR_KEYS:
            raise ValueError(f"unknown palette semantic color: {key}")
        if not isinstance(value, str):
            raise ValueError(f"palette semantic {key} must be a hex string")
        _parse_hex(value)
        surf[key] = value
    if overrides.get("TextColor"):
        surf["text_primary"] = overrides["TextColor"]
    if overrides.get("EditorGridLinePrimary"):
        surf["editor_grid"] = overrides["EditorGridLinePrimary"]
    if overrides.get("DividerPrimaryColor"):
        surf["divider_primary"] = overrides["DividerPrimaryColor"]
    if overrides.get("DividerSecondaryColor"):
        surf["divider_secondary"] = overrides["DividerSecondaryColor"]
    return surf


def _merge_midnight_hand_tuned(theme: dict) -> None:
    """Layer poc/theme.json hand-tuned anchors over generated Midnight."""
    with open(MIDNIGHT_HAND_TUNED_PATH, encoding="utf-8") as f:
        hand = json.load(f)
    theme["colors"].update(hand.get("colors", {}))
    theme["mixer"].update(hand.get("mixer", {}))
    theme["name"] = hand.get("name", theme["name"])
    theme["_note"] = "Generated from palette (cool tone) + poc/theme.json hand-tuned anchors."


def _raise(color: str, amount: float, tone: str) -> str:
    """Make a surface stand out from its neighbor: lighter on dark themes, darker on light ones."""
    return _darken(color, amount * 4.0) if tone == "light" else _lighten(color, amount)


def _resolve_role(role: str, surf: dict, tone: str) -> str:
    bg = surf["bg"]
    panel = surf["mixer_top"]
    accent = surf["accent"]

    if role == "bg":
        return bg
    if role == "mixer_top":
        return panel
    if role == "mixer_bottom":
        return surf["mixer_bottom"]
    if role == "mixer_selected":
        return surf["mixer_selected"]
    if role == "track_header":
        return surf["track_header"]
    if role == "piano_white":
        return surf["piano_white"]
    if role == "piano_black":
        return surf["piano_black"]
    if role == "accent":
        return accent
    if role == "accent_dark":
        return _darken(accent, 0.12)
    if role == "accent_lighten_20":
        return _lighten(accent, 0.20)
    if role == "icon_neutral":
        return surf.get("icon_neutral") or _resolve_role("text_primary", surf, tone)
    if role == "focus":
        return surf.get("focus") or _lighten(accent, 0.20)
    if role == "warning":
        return surf.get("warning") or "#d9a441"
    if role == "record":
        return surf.get("record") or "#f0d0d0"
    if role == "record_dim":
        return surf.get("record_dim") or "#caa0a0"
    if role == "meter":
        return surf.get("meter") or accent
    if role == "meter_peak":
        return surf.get("meter_peak") or _lighten(_resolve_role("meter", surf, tone), 0.18)
    if role == "selection":
        if surf.get("selection"):
            return surf["selection"]
        if surf.get("selection_override"):
            return surf["selection_override"]
        if tone == "high_contrast":
            return _mix(bg, accent, 0.20)
        if tone == "cool":
            return _mix(surf["mixer_selected"], accent, 0.28)
        if tone == "warm":
            return _mix(panel, accent, 0.30)
        return _mix(panel, accent, 0.25)
    if role == "tab_selected":
        if tone == "high_contrast":
            return _mix(bg, accent, 0.22)
        if tone == "cool":
            return _mix(surf["mixer_selected"], accent, 0.25)
        if tone == "warm":
            return surf["mixer_selected"]
        if tone == "neutral":
            return _mix(surf["mixer_selected"], accent, 0.14)
        return surf["mixer_selected"]
    if role == "bg_lighten_strip":
        if tone == "cool":
            return _raise(bg, 0.014, tone)
        if tone == "warm":
            return _raise(bg, 0.042, tone)
        if tone == "high_contrast":
            return _raise(bg, 0.008, tone)
        return _raise(bg, 0.018, tone)
    if role == "browser_selection":
        if surf.get("selection_override"):
            return surf["selection_override"]
        if tone == "cool":
            return _mix(surf["mixer_selected"], accent, 0.24)
        if tone == "warm":
            return _mix(panel, accent, 0.22)
        if tone == "high_contrast":
            return _mix(bg, accent, 0.22)
        return _mix(panel, accent, 0.26)
    if role == "inspector_stripe":
        # Logic's stock inspector stripes are barely visible; keep them that way.
        return _mix(panel, _resolve_role("text_primary", surf, tone), 0.05)
    if role == "accent_area":
        return _mix(bg, accent, 0.10)
    if role == "accent_muted":
        return _mix(bg, accent, 0.35)
    if role == "editor_grid":
        if surf.get("editor_grid"):
            return surf["editor_grid"]
        return surf["grid_lines"]
    if role == "rubberband_fill":
        return _raise(bg, 0.03, tone)
    if role == "bg_darken":
        return _darken(bg, 0.15)
    if role == "bg_lighten_4":
        return _raise(bg, 0.045, tone)
    if role == "bg_lighten_2":
        return _raise(bg, 0.025, tone)
    if role == "grid_lines":
        return surf["grid_lines"]
    if role == "divider_primary_dark":
        return _darken(_resolve_role("divider_primary", surf, tone), 0.18)
    if role == "dragging_sel":
        return _mix(panel, accent, 0.18)
    if role == "drag_dest":
        return _mix(bg, accent, 0.15)
    if role == "shadow":
        return _darken(bg, 0.30)
    if role == "flex_outline":
        return _darken(bg, 0.20)
    if role == "flex_line":
        return _raise(bg, 0.08, tone)
    if role == "rubberband_area":
        return _mix(bg, accent, 0.35)
    if role.startswith("mixer_lighten_"):
        pct = int(role.split("_")[-1]) / 100.0
        return _raise(panel, pct, tone)
    if role == "text_bright":
        # Strongest text: white on dark themes, the primary ink on light ones
        # (white text on a light theme's selected rows/controls was unreadable).
        if tone == "light":
            return _resolve_role("text_primary", surf, tone)
        return "#ffffff"
    if role == "text_bright_dim":
        if tone == "light":
            return _resolve_role("text_secondary", surf, tone)
        return "#ffffffcc"
    if role == "text_white":
        # Text on stock saturated fills the theme does not recolor
        # (e.g. the red recording region), in every tone.
        return "#ffffff"
    if role == "text_on_accent":
        if contrast_ratio("#ffffff", accent) >= contrast_ratio("#000000", accent):
            return "#ffffff"
        return "#000000"
    if role == "text_record":
        return _resolve_role("record", surf, tone)
    if role == "text_record_dim":
        return _resolve_role("record_dim", surf, tone)
    if role == "transport_lcd":
        lcd = surf.get("transport_lcd")
        if lcd:
            return lcd
        return _resolve_role("text_primary", surf, tone)
    if role == "transport_lcd_sel":
        lcd = surf.get("transport_lcd")
        if lcd:
            return lcd
        return _resolve_role("text_bright", surf, tone)
    if role == "transport_lcd_dim":
        lcd = surf.get("transport_lcd")
        if lcd:
            return _mix(lcd, _resolve_role("text_primary", surf, tone), 0.35)
        return _resolve_role("text_primary", surf, tone)
    if role == "text_primary_light":
        return _lighten(_resolve_role("text_primary", surf, tone), 0.04)

    if role == "text_primary":
        if surf.get("text_primary"):
            return surf["text_primary"]
        if tone == "cool":
            return "#e8eaf5"
        if tone == "warm":
            return _lighten(panel, 0.55)
        if tone == "high_contrast":
            return "#f2f2f7"
        if tone == "light":
            return "#1b1d20"
        return "#d6d9dd"  # neutral

    if role == "text_secondary":
        # Library labels, disclosure arrows, and table sublabels describe navigation.
        # They need hierarchy, not a state color: deriving them from AccentColor made
        # every theme render ordinary menu text orange, green, red, or yellow.
        return surf.get("text_secondary") or _mix(panel, _resolve_role("text_primary", surf, tone), 0.70)

    if role == "text_tertiary":
        return _contrast_adjusted(
            _mix(bg, _resolve_role("text_secondary", surf, tone), 0.50),
            panel,
            3.0,
        )

    if role == "text_muted":
        return _contrast_adjusted(
            _mix(bg, _resolve_role("text_secondary", surf, tone), 0.35),
            panel,
            3.0,
        )

    if role == "divider_primary":
        if surf.get("divider_primary"):
            return surf["divider_primary"]
        if tone == "high_contrast":
            return surf["grid_lines"]
        if tone == "warm":
            return _raise(panel, 0.14, tone)
        if tone == "cool":
            return _raise(panel, 0.16, tone)
        return _raise(panel, 0.11, tone)

    if role == "divider_primary_darker":
        return _darken(_resolve_role("divider_primary", surf, tone), 0.15)

    if role == "divider_secondary":
        if surf.get("divider_secondary"):
            return surf["divider_secondary"]
        return _darken(_resolve_role("divider_primary", surf, tone), 0.08)

    raise KeyError(f"unknown role: {role}")


# Stock Logic neutrals sit at these luma values (gamma space); the engine maps every
# otherwise-unthemed neutral color along this ramp, so panels, lines, and text that
# no theme key names still follow the preset.
_AUTO_RAMP_LUMAS = (0.0, 0.08, 0.14, 0.21, 0.30, 0.45, 0.70, 0.90, 1.0)
# Light tone keeps pure black (shadows, divider tints, black glyph ink) dark at
# stop 0, but Logic 12 draws its main surfaces (rulers, global tracks, track
# headers, the LCD) at luma 0.05-0.08.  With the background stop at 0.08 those
# surfaces landed between near-black and the background, i.e. mid-grey, and
# dark text on them failed.  Pull the background stop down so every stock
# surface lands on the light side.
_AUTO_RAMP_LUMAS_LIGHT = (0.0, 0.03, 0.14, 0.21, 0.30, 0.45, 0.70, 0.90, 1.0)


def _saturation(hex_str: str) -> float:
    r, g, b = _parse_hex(hex_str)
    hi, lo = max(r, g, b), min(r, g, b)
    return 0.0 if hi == 0 else (hi - lo) / hi


# Stock mid-grey control fills (stops 0.30 and 0.45) carry primary text in
# Logic, e.g. the selected segment of a segmented control.  Their themed
# replacements must keep at least this contrast against the themed text.
_RAMP_CONTROL_MIN_CONTRAST = 3.0


def _sanitize_ramp(stops: list[str], tone: str) -> list[str]:
    """Keep the ramp monotonic and readable.

    Stops 0-2 (backgrounds) and 6-8 (text/icons) are trusted.  The middle
    stops come from roles (selection, divider, muted text) that some palettes
    set to loud or extreme colors, e.g. a white divider in a high-contrast
    theme.  A middle stop is kept only when it is not strongly saturated and
    its luminance continues the ramp's direction; otherwise it is replaced by
    a blend of the panel and secondary-text stops at the same position.
    """
    out = list(stops)
    lo, hi = out[2], out[6]
    rising = _relative_luminance(hi) >= _relative_luminance(lo)

    def beyond(a: str, b: str) -> bool:
        la, lb = _relative_luminance(a), _relative_luminance(b)
        return la > lb if rising else la < lb

    span = _AUTO_RAMP_LUMAS[6] - _AUTO_RAMP_LUMAS[2]
    for i in (3, 4, 5):
        candidate = out[i]
        valid = (
            _saturation(candidate) <= 0.6
            and beyond(candidate, out[i - 1])
            and beyond(hi, candidate)
        )
        if not valid:
            t = (_AUTO_RAMP_LUMAS[i] - _AUTO_RAMP_LUMAS[2]) / span
            candidate = _mix(lo, hi, t)
            if not beyond(candidate, out[i - 1]):
                candidate = _mix(out[i - 1], hi, 0.25)
        out[i] = candidate

    text = out[7]
    for i in (4, 5):
        steps = 0
        while contrast_ratio(text, out[i]) < _RAMP_CONTROL_MIN_CONTRAST and steps < 20:
            out[i] = _mix(out[i], lo, 0.1)
            steps += 1
    return out


def build_auto(theme_colors: dict, surf: dict, tone: str, palette: dict) -> dict:
    """Build the theme's ``auto`` block: lightness ramp + accent hue families."""
    custom = palette.get("auto")
    if isinstance(custom, dict) and custom.get("enabled") is False:
        return {"enabled": False}
    bg = surf["bg"]
    panel = surf["mixer_top"]
    text = _resolve_role("text_primary", surf, tone)
    stops = [
        _darken(bg, 0.55) if tone != "light" else "#14171a",
        bg,
        panel,
        surf["mixer_selected"] if tone != "light" else _mix(panel, bg, 0.5),
        _resolve_role("divider_primary", surf, tone),
        _resolve_role("text_muted", surf, tone),
        _resolve_role("text_secondary", surf, tone),
        text,
        surf.get("icon_neutral") or text,
    ]
    stops = _sanitize_ramp(stops, tone)
    lumas = _AUTO_RAMP_LUMAS_LIGHT if tone == "light" else _AUTO_RAMP_LUMAS
    block = {
        "enabled": True,
        "accent": surf["accent"],
        "accentHues": [[211, 32], [50, 14]],
        "neutralSaturation": 0.22,
        "ramp": [[luma, color] for luma, color in zip(lumas, stops)],
    }
    if isinstance(custom, dict):
        block.update({k: v for k, v in custom.items() if k in block})
    return block


def _rgba(value: str) -> tuple[float, float, float, float]:
    h = value.strip().lstrip("#")
    alpha = int(h[6:8], 16) / 255.0 if len(h) == 8 else 1.0
    r, g, b = _parse_hex(value)
    return r / 255.0, g / 255.0, b / 255.0, alpha


def _composite(foreground: str, background: str) -> str:
    """Flatten a (possibly #RRGGBBAA) foreground over an opaque background."""
    fr, fg, fb, fa = _rgba(foreground)
    br, bg, bb, _ = _rgba(background)
    return _fmt_hex(
        _clamp((fr * fa + br * (1 - fa)) * 255),
        _clamp((fg * fa + bg * (1 - fa)) * 255),
        _clamp((fb * fa + bb * (1 - fa)) * 255),
    )


def auto_remap(value: str, auto: dict) -> str:
    """Mirror the engine's ``fc_autoRemap`` for a stock color (keeps alpha).

    Neutrals move along the ramp by gamma-space luma; saturated colors in an
    accent hue family take the theme accent's hue; anything else is unchanged.
    """
    if not auto or not auto.get("enabled") or len(auto.get("ramp", [])) < 2:
        return value
    r, g, b, a = _rgba(value)
    alpha = value.strip().lstrip("#")[6:8]
    mx, mn = max(r, g, b), min(r, g, b)
    sat = (mx - mn) / mx if mx > 0 else 0.0
    if mx < 0.05 or sat < auto.get("neutralSaturation", 0.22) or (mx - mn) < 0.07:
        ramp = auto["ramp"]
        luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        i = 0
        while i < len(ramp) - 2 and luma > ramp[i + 1][0]:
            i += 1
        (lo_l, lo_c), (hi_l, hi_c) = ramp[i], ramp[i + 1]
        span = hi_l - lo_l
        t = max(0.0, min(1.0, (luma - lo_l) / span)) if span > 1e-6 else 0.0
        return _mix(lo_c, hi_c, t) + alpha
    accent = auto.get("accent")
    if accent and sat >= 0.35:
        hue = _hue(_fmt_hex(_clamp(r * 255), _clamp(g * 255), _clamp(b * 255)))
        for family_hue, tolerance in auto.get("accentHues", []):
            dh = abs(hue - family_hue)
            if min(dh, 360 - dh) <= tolerance:
                ar, ag, ab, _ = _rgba(accent)
                acc_v = max(ar, ag, ab)
                acc_s = (acc_v - min(ar, ag, ab)) / acc_v if acc_v > 0 else 0.0
                s = min(1.0, sat * acc_s / 0.9)
                v = min(1.0, mx * acc_v)
                h6 = _hue(accent) / 60.0
                c = v * s
                x = c * (1 - abs(h6 % 2.0 - 1))
                m = v - c
                rr, gg, bb = [
                    (c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)
                ][min(5, int(h6))]
                return _fmt_hex(
                    _clamp((rr + m) * 255), _clamp((gg + m) * 255), _clamp((bb + m) * 255)
                ) + alpha
    return value


def _surface_value(theme: dict, key: str) -> str | None:
    """The color the engine paints for ``key``: explicit key, else remapped stock."""
    colors = theme.get("colors", {})
    if key in colors:
        return colors[key]
    if key in _UNTHEMED_SURFACES:
        return _UNTHEMED_SURFACES[key]
    stock = _STOCK_SURFACES.get(key)
    if stock is None:
        return None
    return auto_remap(stock, theme.get("auto", {}))


def text_pair_contrast(theme: dict, foreground_key: str, background_key: str) -> float | None:
    """WCAG contrast of a text key over its surface as the engine renders it."""
    foreground = _surface_value(theme, foreground_key)
    background = _surface_value(theme, background_key)
    if foreground is None or background is None:
        return None
    backdrop = theme["colors"].get("ArrangeWorkspaceColor", "#000000")
    surface = _composite(background, backdrop)
    return contrast_ratio(_composite(foreground, surface), surface)


def _repair_text_contrast(theme: dict) -> None:
    """Nudge explicit text keys until every audited pair clears its minimum.

    Runs on the final theme (overrides and hand-tuned anchors applied), so a
    palette can never ship dark-on-dark or light-on-light text.  A text key
    that sits on more than one surface is re-checked until all pairs pass.
    """
    colors = theme["colors"]
    backdrop = colors.get("ArrangeWorkspaceColor", "#000000")
    window = colors.get("MainWindowColor")
    light_window = bool(window) and contrast_ratio(window, "#000000") > contrast_ratio(window, "#ffffff")
    for _ in range(4):
        changed = False
        for foreground_key, background_key, minimum in _TEXT_CONTRAST_PAIRS:
            if light_window and (foreground_key, background_key) in _DARK_WINDOW_ONLY_PAIRS:
                continue
            foreground = colors.get(foreground_key)
            background = _surface_value(theme, background_key)
            if not foreground or not background:
                continue
            surface = _composite(background, backdrop)
            flat = _composite(foreground, surface)
            if contrast_ratio(flat, surface) >= minimum:
                continue
            colors[foreground_key] = _contrast_adjusted(flat, surface, minimum)
            changed = True
        if not changed:
            return


def expand_palette(palette: dict, template: dict | None = None, roles: dict | None = None) -> dict:
    """Return full injection theme {name, colors, mixer}."""
    template = template or load_template()
    roles = roles or load_roles()
    tone = palette.get("tone", "neutral")
    surf = _surfaces(palette)

    out_colors: dict[str, str] = {}
    for key, role in roles.get("colors", {}).items():
        out_colors[key] = _resolve_role(role, surf, tone)

    out_mixer: dict[str, str] = {}
    for key, role in roles.get("mixer", {}).items():
        out_mixer[key] = _resolve_role(role, surf, tone)

    for key, value in palette.get("overrides", {}).items():
        if key in out_colors:
            out_colors[key] = value
        elif key in out_mixer:
            out_mixer[key] = value

    theme = {
        "name": palette.get("name", "Custom"),
        "author": "Theme4Logic",
        "_note": f"Generated from palette ({tone} tone).",
        "colors": out_colors,
        "mixer": out_mixer,
        "auto": build_auto(out_colors, surf, tone, palette),
    }

    if palette.get("slug") == "midnight":
        _merge_midnight_hand_tuned(theme)

    # Repair the final, override-applied theme rather than only validating the
    # palette inputs.  This catches the exact failure mode where one preset's
    # custom text token is close to a panel background.
    _repair_text_contrast(theme)

    region_palette = palette.get("region_palette")
    if region_palette is not None:
        if not isinstance(region_palette, list) or not region_palette:
            raise ValueError("palette region_palette must be a non-empty list")
        for color in region_palette:
            if not isinstance(color, str):
                raise ValueError("palette region_palette values must be hex strings")
            _parse_hex(color)
        theme["region_palette"] = region_palette

    region_hues = palette.get("region_palette_hues")
    if region_hues is not None:
        if not isinstance(region_hues, list):
            raise ValueError("palette region_palette_hues must be a list")
        for hue in region_hues:
            if isinstance(hue, bool) or not isinstance(hue, int) or not 1 <= hue <= 360:
                raise ValueError("palette region_palette_hues values must be integers from 1 to 360")
        theme["region_palette_hues"] = region_hues

    return theme


def accent_hue_delta(theme: dict, palette: dict) -> float:
    """Degrees between theme accent and palette accent."""
    got = theme["colors"].get("ArrangeWorkspaceBrightColor", "")
    want = palette.get("accent", "")
    if not got or not want:
        return 999.0
    return abs(_hue(got) - _hue(want))


def contrast_ratio(foreground: str, background: str) -> float:
    """Return WCAG contrast for two opaque hex colors."""

    def luminance(value: str) -> float:
        channels = []
        for channel in _parse_hex(value):
            normalized = channel / 255.0
            channels.append(
                normalized / 12.92
                if normalized <= 0.04045
                else ((normalized + 0.055) / 1.055) ** 2.4
            )
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

    light, dark = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def find_forbidden_hardcodes(theme: dict, tone: str) -> list[str]:
    """Cool-only hex values that must not appear in warm/neutral/high_contrast."""
    if tone == "cool":
        return []
    hits: list[str] = []
    blob = json.dumps(theme).lower()
    for bad in FORBIDDEN_IN_NEUTRAL:
        if bad.lower() in blob:
            hits.append(bad)
    return hits

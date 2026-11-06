# Preset visual audit

Snapshot from 2026-06-29, covering the original DAW-inspired presets. For the current report on all presets, run `python3 tools/audit_presets.py`.

## P0 — Arrange, accent, transport (automated)

| Preset | Arrange bg | Accent | Forbidden hardcodes | Status |
|--------|------------|--------|---------------------|--------|
| midnight | `#15151f` | `#9097cc` | none (cool tone) | PASS |
| ableton-classic | `#2E2E2E` | `#FF8C00` | none | PASS |
| fl-studio-fruity | `#1E1A16` | `#E87820` | none | PASS |
| pro-tools | `#1A1D20` | `#7EB8D4` | none | PASS |
| studio-one | `#191a1e` | `#2478ba` | none | PASS |
| reaper | `#333333` | `#339887` | none | PASS |
| voice-memos | `#000000` | `#ff3b30` | none | PASS |

## P1 — Track headers, mixer strips

| Preset | ChannelstripColor | Mixer strip bg | Selected strip | Status |
|--------|-------------------|----------------|----------------|--------|
| ableton-classic | `#393939` | `#393939` | `#4A4A4A` | PASS (catalog + mixer agree) |
| fl-studio-fruity | `#2A2118` | `#2A2118` | `#3D2F1E` | PASS |
| pro-tools | `#22272D` | `#22272D` | `#2A3040` | PASS |

Track-header bottom lines (`TrackHeader/BottomLine`, automation lanes) now mapped in all themes (100 color keys).

## P2 — Library, inspector, piano roll

| Preset | Piano white key | Piano black key | Text primary | Status |
|--------|-----------------|-----------------|--------------|--------|
| ableton-classic | `#3D3D3D` | `#272727` | `#d6d9dd` | PASS |
| fl-studio-fruity | `#2E2218` | `#1A1410` | warm derived | PASS |
| midnight | hand-tuned | hand-tuned | `#e8eaf5` | PASS |

## P3 — Buttons, striping, dividers

- List striping (`ListRowA`/`ListRowB`) derived from workspace bg on all presets.
- Dividers tone-aware: neutral `#4a4a4a`, warm lightened panel, cool lightened panel, high-contrast grid lines.
- No `#ffffff2b` white-alpha dividers on any preset.

## P4 — Known limitations (not blocking)

- Fader/knob **images** are tinted via `FaderTint`/`KnobTint`, not replaced `.tif` assets.
- Plugin insert slot auto-coloring not supported.
- Some rarely-used catalog colors may still fall through (see `tools/audit-output/report.md`).

## How to re-test live

```sh
# One preset
./tools/launch_preset.sh ableton-classic

# Rebuild app with bundled themes
cd app && ./build_app.sh
open "$HOME/Library/Application Support/Theme4Logic/build/Theme4Logic.app"
```

Confirm injection: `cat ~/Library/Application\ Support/Theme4Logic/colorize-status.json`

## Screenshot baseline gate

Live screenshot validation is intentionally separate from mechanical JSON checks because it launches Logic and requires human view setup.

```sh
THEME4LOGIC_ALLOW_LOGIC_LAUNCH=1 ./tools/capture_live_preset_screenshots.sh ableton-dark fl-studio-fruity voice-memos
python3 tools/validate_visual_baselines.py
```

Safe wiring check without launching Logic:

```sh
python3 tools/validate_visual_baselines.py --allow-missing
```

## Perceptual targets

- **Ableton**: neutral gray workspace, orange accents — not warm brown (`#2f2925` legacy removed).
- **FL Studio**: warm brown panels (`#1E1A16`), orange accent — not cold black (`#0a0a0c` legacy removed).
- **Pro Tools / Studio One**: cool gray + cyan/blue accents.
- **Reaper**: flat gray + teal accent.
- **Voice Memos**: OLED black + iOS red accent.

# Preset polish pass (2026-06-29)

Holistic visual refinement across all bundled presets. Each preset should feel **distinct and intentional** when switching in Theme4Logic — not "same dark theme, different accent."

## Cross-cutting changes (`t4l/expand.py`)

- **Grid lines** — `editor_grid` now uses the palette's `Arrange.ArrangeGrid_BarLines` surface instead of a generic bg-lighten; dividers derive from panel tone (warm/cool/neutral/high-contrast), not a flat `#4a4a4a`.
- **Selection & tabs** — accent-tinted per tone: warm orange-brown mixes, cool Presonus/cyan-blue mixes, neutral subtle accent wash, high-contrast dark red tints.
- **Striping** — softer `bg_lighten_strip` defaults (neutral 1.8%, cool 1.4%, warm 4.2%).
- **Transport** — `transport_lcd` only when set on the palette (`pro-tools`, `voice-memos`); all others use readable text on dark.
- **Midnight** — `expand_palette` merges `poc/theme.json` hand-tuned anchors (meters, browser hierarchy, mixer knobs) after generation.

---

## Midnight

Cool navy studio with soft periwinkle accents — the gold standard. Workspace `#15151f`, panels `#20243a`–`#262b44`, accent `#9097cc`, selection `#34406e`. Hand-tuned from `poc/theme.json`: warm meter peaks (`#d18a4a`), blue fader tints, layered browser text (`#c8cdf0` / `#aab0e0`), and piano-roll grid `#2a2f4a`. Switching away and back should feel like returning to a carefully lit control room.

## Ableton Classic

Neutral flat gray with punchy orange `#FF8C00` — Live's flat UI, not brown. Workspace `#2E2E2E`, panels `#393939`, grid `#454545`. Orange now reaches tabs (`#635340`), browser selection (`#6c4f2a`), cycle regions (`#5c4828`), and focus rings — cycle/loop rulers stay orange, never green. Dividers panel-derived `#555555` instead of stock `#4a4a4a`.

## Angst Robot

Deep indigo with periwinkle states, not neon navigation. Workspace `#1a1528`, panels `#252038`–`#1e1a30`, grid `#3a3555`, accent `#7b68ee`. Browser labels, chevrons, table sublabels, and Library controls are neutral lavender; periwinkle is reserved for focus, selection, meters, and editing state. This keeps the identity without turning routine text yellow or green.

## FL Studio Fruity

Warm chocolate studio — every panel in the brown family, zero grey islands. Workspace `#1E1A16`, panels `#2A2118`, grid `#3D3020`, accent `#E87820`. Inspector, GI editor, and table views forced to warm surfaces; selection is deep orange-brown (`#54341a`). Text is warm parchment `#b6ada4`, not cool blue-grey.

## Pro Tools Dark

Charcoal `#2B2B2B` with Avid green LCD `#39FF14` and blue `#0078D7` accents — not a blue wash. Browser/tab selection stays neutral grey (`#404040`, `#333333`); blue appears on chevrons, labels, and focus rings only. Dividers tightened to `#383838` / `#323232` on charcoal panels. Transport LCD is green; everything else reads as professional dark grey.

## Studio One

Presonus cool grey workspace with signature blue `#2478ba`. Workspace `#191a1e`, panels `#26282c`, readable text `#c4c4c4` (not icy `#e8eaf5`). Selected tabs and browser rows carry a blue tint (`#2e4a62`, `#2a4558`); grid `#2e3338` matches arrange bar lines. Feels like Studio One's native dark scheme, not generic Logic grey.

## Reaper

Flat high-contrast grey with teal `#339887` — Cockos utilitarian, not muddy. Workspace `#333333`, headers `#454545`, grid `#555555`, text `#e8e8e8`. Teal selection (`#3d7568`) on track headers, browser, and tabs (`#4a8a7a`); inspector alternating rows match headers at `#454545`. No cool-blue text leaks.

## Voice Memos

OLED black with surgical iOS red `#ff3b30` — record button energy, not a red UI. Pure black workspace, `#1c1c1e` charcoal panels, light transport text `#f2f2f7`. Red hits accents, labels, chevrons, and focus rings; selected tab is dark red `#8c2820` (not full-saturation bar); selection fills are near-black crimson `#331110`.

---

## Verification

```sh
python3 tools/generate_all_presets.py
python3 -m unittest discover -s tests -q
cd poc && ./build.sh
cd ../app && ./build_app.sh
./tools/launch_preset.sh studio-one   # eyes-on per preset
```

Confirm injection: `cat ~/Library/Application\ Support/Theme4Logic/colorize-status.json`

Live visual baselines:

```sh
THEME4LOGIC_ALLOW_LOGIC_LAUNCH=1 ./tools/capture_live_preset_screenshots.sh
python3 tools/validate_visual_baselines.py
```

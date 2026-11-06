# Theme4Logic Architecture

## Runtime path

Theme4Logic is a runtime theming app:

1. The native app (`app/main.m`) writes the selected theme to `~/Library/Application Support/Theme4Logic/theme.json`.
2. It stages `colorize.dylib` and the approved Logic hook manifests in the same support folder.
3. It launches Logic Pro with `DYLD_INSERT_LIBRARIES` pointing at that staged dylib, via `poc/launcher.m` (LaunchServices with a custom environment).
4. The injected engine (`poc/colorize.m`) reads `theme.json`. It checks the Logic version and build against `poc/hook-manifests/`, installs only the hooks approved for that build, and writes `colorize-status.json`.
5. The app waits for a fresh status marker before it reports success. The marker must carry the current launch token, the Logic pid, `ok=true`, a nonzero color count, and the required hooks.

The app does not edit `/Applications/Logic Pro.app` and does not re-sign Logic.

## Color pipelines inside the engine

| Pipeline | What it covers |
|---|---|
| `NSColor` class swizzles (`colorNamed:`, `colorNamed:bundle:`, `colorWithCatalogName:colorName:`, system colors) | AppKit-drawn UI that asks for named colors |
| `MAAssetManager colorWithName:` | The mixer and channel strips |
| `-[CUINamedColor cgColor]` | Every asset-catalog color, including SwiftUI panels such as Session Player |
| Logic view-node getters/setters | Track headers, editor canvas, and other custom-drawn views |
| `CGContextSetFillColorWithColor` / `CGContextSetRGBFillColor` interposes | Hard-coded fills (Logic's stock blue accent, selection greys, region colors when a preset defines a region palette). Exact colors the theme itself sets, such as its text color, are never re-mapped here. |
| `MAStripNode drawSlotTitle:frame:inContext:`, `MAEQThumbnailNode drawTitleInRect:inContext:` and `MASlotButtonNode drawLayer:inContext:` | The black placeholder captions of empty mixer slots ("EQ", "Audio FX", "Group"). In dark themes they are drawn in the theme's secondary text color. |

An explicit key in the theme's `colors` or `mixer` map always wins. Colors with no explicit key go through the theme's `auto` block:

- **Neutrals** (low saturation) are re-mapped along `auto.ramp`. Each `[stockLuma, themeColor]` stop maps a stock lightness to a theme color, and alpha is preserved.
- **Accent families** (`auto.accentHues`, by default Logic's blue and yellow) are moved to `auto.accent`. Exact colors the theme itself sets are never re-tinted.
- **Everything else** is left alone: record red, mute/solo, meters, and user track and region colors.

`t4l/expand.py` generates the `auto` block from the palette. It keeps the ramp monotonic and keeps mid-grey control fills readable against the theme's text color.

## Version safety

Each `poc/hook-manifests/logic-<version>-hooks.json` names an exact Logic version and build, and lists the AppKit, private, and interpose hooks verified on it. With no matching manifest, the engine installs nothing, writes `ok=false` with a reason, and Logic runs stock. `tests/scripts/verify_hook_version_safety.sh` enforces this.

New dialog hooks are not guessed. First run `tools/inspect_new_track_sheet.sh` with explicit launch opt-in and capture the concrete class and image hierarchy. Then add only verified selectors to the matching manifest.

## Presets

Palettes in `themes/palettes/` are expanded via `themes/roles.json` into full injection themes in `themes/injection/`, using `tools/generate_all_presets.py` and `themes/preset-manifest.json`. `themes/visual-contracts/logic-12.json` defines the required visual surfaces, neutral navigation roles, permitted accent roles, forbidden normal-UI colors, and contrast pairs. `tools/audit_presets.py` and the screenshot validator both enforce it.

## Required local gates

Run these before handing changes to users:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -q
python3 tools/audit_presets.py
python3 tools/validate_visual_baselines.py --allow-missing
./tests/scripts/verify_shell_safety.sh
./tests/scripts/verify_launch_safety.sh
./tests/scripts/verify_hook_version_safety.sh
./tests/scripts/verify_docs_architecture.sh
./tests/scripts/verify_visual_validation.sh
./app/build_app.sh
codesign --verify --deep --strict app/build/Theme4Logic.app
```

Live visual fidelity still requires a controlled Logic launch and screenshots for each preset. The manifest and audit gates prove generated coverage, not how closely a preset resembles the product that inspired it.

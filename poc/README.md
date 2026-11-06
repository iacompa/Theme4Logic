# Theme4Logic engine

The runtime pieces behind `Theme4Logic.app`. They recolor Logic Pro **at runtime**, with **zero changes to `Logic Pro.app`**: no file edits and no re-signing.

| File | Purpose |
|---|---|
| `colorize.m` → `colorize.dylib` | The theme engine, loaded into Logic with `DYLD_INSERT_LIBRARIES` |
| `launcher.m` → `launch_logic_injected` | Opens Logic, and optionally a project, with the engine loaded |
| `inject_probe.m` → `inject_probe.dylib` | Research probe: dumps Logic's color and draw methods for a new version |
| `hook-manifests/` | The exact Logic versions and builds the engine is allowed to hook |
| `theme.json` | A sample theme (the app writes the real one to Application Support) |
| `logic-12.2-colors.txt` | Reference list of Logic's catalog color names |

See [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) for the color pipelines and version gating.

## Prerequisite: an unmodified Logic

Injection relies on Logic's original Mac App Store signature. Check it:

```sh
codesign -dv "/Applications/Logic Pro.app" 2>&1 | grep -E "Authority=Apple|flags="
# expect: Authority=Apple..., flags=0x0(none)
```

If Logic shows a "damaged" dialog, it is not a clean install. Reinstall it from the App Store.

## Build

```sh
./build.sh   # builds colorize.dylib, inject_probe.dylib and the launcher (ad-hoc signed)
```

## Run a preset without the app

Quit Logic, then from the repository root:

```sh
./tools/launch_preset.sh dawnamite-dark
# open a specific project at the same time
THEME4LOGIC_PROJECT="$HOME/Music/Logic/My Song.logicx" ./tools/launch_preset.sh midnight
```

## Confirm it loaded

```sh
cat "$HOME/Library/Application Support/Theme4Logic/colorize-status.json"
```

Look for `"ok": true`, the expected `themeName`, and a nonzero `colors` count. For the system log:

```sh
log show --last 3m --predicate 'eventMessage CONTAINS "Theme4Logic"' --style compact
```

Launch with `THEME4LOGIC_DEBUG=1` to record every color name Logic requests in `seen-live.txt`, `seen-mixer.txt`, and `seen-catalog.txt`, next to the status file. Use these names to extend a theme.

## Probe a new Logic version

```sh
./launch_logic_injected "$PWD/inject_probe.dylib"
cat "$HOME/Library/Application Support/Theme4Logic/probe-"*.txt
```

A normal relaunch of Logic, without the launcher, is always stock.

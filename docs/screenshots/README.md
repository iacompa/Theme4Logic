# Live Screenshot Baselines

This folder holds intentional, human-captured Logic screenshots used to validate preset fidelity.

Expected layout:

```text
docs/screenshots/live/<preset-slug>/arrange.png
docs/screenshots/live/<preset-slug>/mixer.png
```

Capture is opt-in because it launches Logic:

```bash
THEME4LOGIC_ALLOW_LOGIC_LAUNCH=1 ./tools/capture_live_preset_screenshots.sh ableton-dark fl-studio-fruity voice-memos
```

Then run:

```bash
python3 tools/validate_visual_baselines.py
```

The validator checks that screenshots contain enough colors from the generated preset palette, do not leak known stale stock/legacy colors above threshold, and visibly include the preset accent. Missing baselines fail by default. During normal non-live CI, use `--allow-missing` only to verify the validator wiring without claiming visual fidelity.

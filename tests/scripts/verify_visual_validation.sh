#!/bin/sh
# Verifies visual-baseline tooling without launching Logic.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/theme4logic-visual.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/shots"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 "$ROOT/tools/validate_visual_baselines.py" --screenshots-dir "$TMP/shots" --allow-missing --report "$TMP/allow.json" >/dev/null

if python3 "$ROOT/tools/validate_visual_baselines.py" --screenshots-dir "$TMP/shots" --report "$TMP/strict.json" >"$TMP/strict.out" 2>"$TMP/strict.err"; then
  fail "visual baseline validator should fail when live screenshots are missing"
fi

grep -q 'THEME4LOGIC_ALLOW_LOGIC_LAUNCH' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must require explicit launch opt-in"
grep -q 'THEME4LOGIC_LAUNCH_TOKEN' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must correlate status to a launch token"
grep -q 'data.get("ok") is not True' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must reject unsuccessful injection status"
grep -q 'data.get("themeName") != slug' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must reject status for a different preset"
grep -q -- '--slugs "$slug_csv"' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must validate only requested presets"
grep -q '^set -f$' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must not pathname-expand preset names"
grep -q 'screencapture' "$ROOT/tools/capture_live_preset_screenshots.sh" || fail "capture tool must use macOS screenshot capture"
grep -q 'docs/screenshots/live' "$ROOT/docs/screenshots/README.md" || fail "screenshot docs must define baseline layout"

echo "visual validation verifier passed"

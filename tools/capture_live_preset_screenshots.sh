#!/bin/sh
# Opt-in live screenshot capture for preset visual baselines.
set -eu
set -f

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${THEME4LOGIC_SCREENSHOT_DIR:-$ROOT/docs/screenshots/live}"
SURFACES="${THEME4LOGIC_SCREENSHOT_SURFACES:-arrange mixer library new-track editor}"

if [ "${THEME4LOGIC_ALLOW_LOGIC_LAUNCH:-0}" != "1" ]; then
  cat >&2 <<EOF
Refusing to launch Logic without explicit opt-in.

This workflow stages themes, asks Logic to quit/relaunch, and captures screenshots.
Re-run with:

  THEME4LOGIC_ALLOW_LOGIC_LAUNCH=1 $0 [preset-slug...]

Before running, save/close important Logic projects.
EOF
  exit 2
fi

slugs="$*"
if [ -z "$slugs" ]; then
  slugs="$(python3 - "$ROOT/themes/preset-manifest.json" <<'PY'
import json
import sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
print(" ".join(p["slug"] for p in manifest))
PY
)"
fi

mkdir -p "$OUT"
slug_csv="$(python3 - "$slugs" <<'PY'
import sys

print(",".join(sys.argv[1].split()))
PY
)"

for slug in $slugs; do
  echo "Launching preset: $slug"
  token="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  export THEME4LOGIC_LAUNCH_TOKEN="$token"
  "$ROOT/tools/launch_preset.sh" "$slug"
  status="$HOME/Library/Application Support/Theme4Logic/colorize-status.json"
  attempts=0
  while ! python3 - "$status" "$token" "$slug" >/dev/null 2>&1 <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
token = sys.argv[2]
slug = sys.argv[3]
data = json.loads(path.read_text())
pid = data.get("pid")
if data.get("token") != token:
    raise SystemExit(1)
if data.get("themeName") != slug:
    raise SystemExit(1)
if data.get("state") != "active" or data.get("hooksAllowed") is not True:
    raise SystemExit(1)
if data.get("ok") is not True or not isinstance(data.get("colors"), int) or data["colors"] <= 0:
    raise SystemExit(1)
installed = set(data.get("installedAppKitHooks") or [])
expected = set(data.get("expectedAppKitHooks") or [])
if not expected or not expected.issubset(installed):
    raise SystemExit(1)
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(1)
os.kill(pid, 0)
PY
  do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      echo "Fresh successful injection status did not appear for $slug; refusing to capture." >&2
      if [ -f "$status" ]; then
        cat "$status" >&2
      fi
      exit 1
    fi
    sleep 1
  done
  if [ ! -f "$status" ]; then
    echo "No colorize-status.json after launch; refusing to capture $slug" >&2
    exit 1
  fi
  mkdir -p "$OUT/$slug"
  for surface in $SURFACES; do
    echo "Set Logic to the '$surface' view for $slug, press return, then click the Logic window."
    read _answer
    # Window-only capture: never record the rest of the desktop.
    screencapture -x -o -iW "$OUT/$slug/$surface.png"
    echo "captured $OUT/$slug/$surface.png"
  done
done

python3 "$ROOT/tools/validate_visual_baselines.py" --screenshots-dir "$OUT" --slugs "$slug_csv"

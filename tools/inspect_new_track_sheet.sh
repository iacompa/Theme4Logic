#!/bin/sh
# Capture debug-only evidence for the Create New Track sheet before approving new runtime hooks.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="${1:-ableton-dark}"
SUPPORT="$HOME/Library/Application Support/Theme4Logic"
OUT="$SUPPORT/sheet-hierarchy.txt"

if [ "${THEME4LOGIC_ALLOW_LOGIC_LAUNCH:-0}" != "1" ]; then
  cat >&2 <<'EOF'
Refusing to restart Logic without explicit opt-in.

Save/close any important project, then run:
  THEME4LOGIC_ALLOW_LOGIC_LAUNCH=1 tools/inspect_new_track_sheet.sh [preset-slug]
EOF
  exit 2
fi

rm -f "$OUT"
export THEME4LOGIC_DEBUG=1
"$ROOT/tools/launch_preset.sh" "$SLUG"

printf '%s\n' "Open Track > New Tracks... in Logic, wait for the Create New Track sheet, then press return here."
read _answer

if [ ! -s "$OUT" ]; then
  echo "No sheet hierarchy was captured. Confirm the Create New Track sheet is open and retry." >&2
  exit 1
fi

echo "captured: $OUT"
cat "$OUT"

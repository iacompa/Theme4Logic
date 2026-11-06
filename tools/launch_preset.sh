#!/bin/sh
# Stage a preset theme and launch Logic with injection.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="midnight"
THEME="$ROOT/themes/injection/${SLUG}.json"
SUPPORT="$HOME/Library/Application Support/Theme4Logic"
POC="$ROOT/poc"
FORCE_KILL_LOGIC=0
QUIT_TIMEOUT=30

usage() {
  cat <<EOF
usage: $0 [--force-kill-logic] [--quit-timeout seconds] [slug]

Stage a preset theme and launch Logic with injection. Logic is asked to quit
gracefully; force-killing requires the explicit --force-kill-logic flag.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force-kill-logic)
      FORCE_KILL_LOGIC=1
      ;;
    --quit-timeout)
      shift
      [ "$#" -gt 0 ] || { echo "--quit-timeout requires seconds" >&2; exit 2; }
      QUIT_TIMEOUT="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      SLUG="$1"
      ;;
  esac
  shift
done

case "$QUIT_TIMEOUT" in
  ''|*[!0-9]*)
    echo "--quit-timeout must be a non-negative integer" >&2
    exit 2
    ;;
esac
THEME="$ROOT/themes/injection/${SLUG}.json"

if [ ! -f "$THEME" ]; then
  echo "theme not found: $THEME" >&2
  echo "usage: $0 <slug>  e.g. ableton-classic, fl-studio-fruity" >&2
  exit 2
fi

echo "building dylib..."
if ! sh "$POC/build.sh"; then
  echo "build failed" >&2
  exit 1
fi

echo "quitting Logic if running..."
if pgrep -x "Logic Pro" >/dev/null 2>&1; then
  osascript -e 'tell application "Logic Pro" to quit' 2>/dev/null || true
  elapsed=0
  while pgrep -x "Logic Pro" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$QUIT_TIMEOUT" ]; then
      if [ "$FORCE_KILL_LOGIC" = "1" ]; then
        echo "force-killing Logic after ${QUIT_TIMEOUT}s because --force-kill-logic was set" >&2
        pkill -x "Logic Pro" 2>/dev/null || true
        break
      fi
      echo "Logic is still running after ${QUIT_TIMEOUT}s; save/close Logic and retry, or pass --force-kill-logic to terminate it." >&2
      exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
fi

mkdir -p "$SUPPORT"
if [ -z "${THEME4LOGIC_LAUNCH_TOKEN:-}" ]; then
  if command -v uuidgen >/dev/null 2>&1; then
    THEME4LOGIC_LAUNCH_TOKEN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    THEME4LOGIC_LAUNCH_TOKEN="theme4logic-$$-$(date +%s)"
  fi
fi
export THEME4LOGIC_LAUNCH_TOKEN
THEME4LOGIC_THEME_NAME="$SLUG"
export THEME4LOGIC_THEME_NAME
TMP_THEME="$SUPPORT/theme.json.$$.tmp"
TMP_DYLIB="$SUPPORT/colorize.dylib.$$.tmp"
TMP_MANIFESTS="$SUPPORT/hook-manifests.$$.tmp"
TMP_OLD_MANIFESTS="$SUPPORT/hook-manifests.$$.old"
cleanup_stage() {
  if [ -e "$TMP_OLD_MANIFESTS" ] && [ ! -e "$SUPPORT/hook-manifests" ]; then
    mv "$TMP_OLD_MANIFESTS" "$SUPPORT/hook-manifests" 2>/dev/null || true
  fi
  rm -rf "$TMP_THEME" "$TMP_DYLIB" "$TMP_MANIFESTS" "$TMP_OLD_MANIFESTS"
}
cleanup_stage_and_exit() {
  cleanup_stage
  exit 1
}
trap cleanup_stage EXIT
trap cleanup_stage_and_exit HUP INT TERM

cp "$THEME" "$TMP_THEME"
cp "$POC/colorize.dylib" "$TMP_DYLIB"
cp -R "$POC/hook-manifests" "$TMP_MANIFESTS"
mv -f "$TMP_DYLIB" "$SUPPORT/colorize.dylib"
if [ -e "$SUPPORT/hook-manifests" ]; then
  rm -rf "$TMP_OLD_MANIFESTS"
  mv "$SUPPORT/hook-manifests" "$TMP_OLD_MANIFESTS"
fi
mv "$TMP_MANIFESTS" "$SUPPORT/hook-manifests"
if [ ! -d "$SUPPORT/hook-manifests" ]; then
  if [ -e "$TMP_OLD_MANIFESTS" ]; then
    mv "$TMP_OLD_MANIFESTS" "$SUPPORT/hook-manifests" 2>/dev/null || true
  fi
  echo "Could not activate hook safety manifests; previous manifests restored." >&2
  exit 1
fi
rm -rf "$TMP_OLD_MANIFESTS"
mv -f "$TMP_THEME" "$SUPPORT/theme.json"
trap - EXIT HUP INT TERM
echo "staged $SLUG → $SUPPORT/theme.json"

rm -f "$SUPPORT/colorize-status.json" "$SUPPORT/colorize-active.txt"
# Optionally open a specific project (skips the Choose a Project window).
if [ -n "${THEME4LOGIC_PROJECT:-}" ]; then
  exec "$POC/launch_logic_injected" "$SUPPORT/colorize.dylib" "$THEME4LOGIC_PROJECT"
fi
exec "$POC/launch_logic_injected" "$SUPPORT/colorize.dylib"

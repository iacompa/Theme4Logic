#!/bin/sh
# Verify destructive build/launch safeguards without touching real support state or launching Logic.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/theme4logic-shell-safety.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_expect_fail() {
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    cat "$TMP/stdout" >&2 || true
    cat "$TMP/stderr" >&2 || true
    fail "command unexpectedly succeeded: $*"
  fi
}

run_expect_ok() {
  if ! "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    cat "$TMP/stdout" >&2 || true
    cat "$TMP/stderr" >&2 || true
    fail "command failed: $*"
  fi
}

# build_app.sh must reject dangerous env-selected app outputs before any rm -rf/build work.
run_expect_fail env THEME4LOGIC_APP="$HOME" sh "$ROOT/app/build_app.sh" --validate-only

run_expect_fail env THEME4LOGIC_APP="$TMP" sh "$ROOT/app/build_app.sh" --validate-only

run_expect_fail env THEME4LOGIC_APP="$TMP/not-theme.app" sh "$ROOT/app/build_app.sh" --validate-only
if ! grep -qi "Theme4Logic.app" "$TMP/stderr"; then
  fail "unsafe THEME4LOGIC_APP rejection did not explain Theme4Logic.app basename requirement"
fi

run_expect_fail env THEME4LOGIC_APP="$TMP/Theme4Logic.app" sh "$ROOT/app/build_app.sh" --validate-only
if ! grep -qi -- "--force-output" "$TMP/stderr"; then
  fail "custom output rejection did not mention explicit force flag"
fi

run_expect_ok env THEME4LOGIC_APP="$TMP/Theme4Logic.app" sh "$ROOT/app/build_app.sh" --force-output --validate-only
run_expect_ok env THEME4LOGIC_APP="$TMP/Theme4Logic.app/" sh "$ROOT/app/build_app.sh" --force-output --validate-only

mkdir -p "$TMP/symlink-target"
ln -s "$TMP/symlink-target" "$TMP/Theme4Logic.app"
run_expect_fail env THEME4LOGIC_APP="$TMP/Theme4Logic.app" sh "$ROOT/app/build_app.sh" --force-output --validate-only
if ! grep -qi "symlink" "$TMP/stderr"; then
  fail "symlink output rejection did not mention symlink"
fi

mkdir -p "$TMP/redirected-parent"
mkdir -p "$ROOT/app/build"
[ ! -e "$ROOT/app/build/symlink-parent" ] || [ -L "$ROOT/app/build/symlink-parent" ] || fail "test path already exists and is not a symlink: $ROOT/app/build/symlink-parent"
rm -f "$ROOT/app/build/symlink-parent"
ln -s "$TMP/redirected-parent" "$ROOT/app/build/symlink-parent"
trap 'rm -rf "$TMP"; rm -f "$ROOT/app/build/symlink-parent"' EXIT
run_expect_fail env THEME4LOGIC_APP="$ROOT/app/build/symlink-parent/Theme4Logic.app" sh "$ROOT/app/build_app.sh" --validate-only
if ! grep -qi "symlink parent" "$TMP/stderr"; then
  fail "symlink parent rejection did not mention symlink parent"
fi

# poc/build.sh must be build-only by default. Validation mode lets this run without compiling.
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
run_expect_ok env HOME="$FAKE_HOME" sh "$ROOT/poc/build.sh" --validate-only
run_expect_ok env HOME="$FAKE_HOME" sh "$ROOT/poc/build.sh" --validate-only --dylibs-only
if [ -e "$FAKE_HOME/Library/Application Support/Theme4Logic/theme.json" ]; then
  fail "poc/build.sh wrote support theme.json without an explicit install flag"
fi

run_expect_ok env HOME="$FAKE_HOME" sh "$ROOT/poc/build.sh" --install-sample-theme --validate-only
if [ ! -e "$FAKE_HOME/Library/Application Support/Theme4Logic/theme.json" ]; then
  fail "poc/build.sh --install-sample-theme did not stage sample theme in temp HOME"
fi

# launch_preset.sh must not have an unconditional/default pkill path.
if ! awk '
  /if \[ "\$FORCE_KILL_LOGIC" = "1" \]/ { in_force = 1 }
  in_force && /^[[:space:]]*fi[[:space:]]*$/ { in_force = 0 }
  /pkill -x "Logic Pro"/ && !in_force { bad = 1 }
  END { exit bad }
' "$ROOT/tools/launch_preset.sh"; then
  fail "launch_preset.sh still contains a default pkill path"
fi

run_expect_ok sh "$ROOT/tools/launch_preset.sh" --help

echo "shell safety verifier passed"

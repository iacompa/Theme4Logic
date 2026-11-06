#!/bin/sh
# Static launch-safety contract checks. Does not launch Logic.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app/main.m"
ENGINE="$ROOT/poc/colorize.m"
LAUNCHER="$ROOT/poc/launcher.m"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_in_file() {
  pattern="$1"
  file="$2"
  desc="$3"
  if ! grep -q "$pattern" "$file"; then
    fail "$desc"
  fi
}

require_in_file 'colorize-status.json' "$APP" 'app must read the structured activation status marker'
require_in_file 'colorize-status.json' "$ENGINE" 'engine must write the structured activation status marker'
require_in_file 'THEME4LOGIC_LAUNCH_TOKEN' "$APP" 'app must pass a per-launch activation token'
require_in_file 'THEME4LOGIC_LAUNCH_TOKEN' "$ENGINE" 'engine must write the per-launch activation token'
require_in_file 'waitForLogicExitThenLaunchURL' "$APP" 'app must wait for Logic to quit before launching'
require_in_file 'waitForActivationForApp' "$APP" 'app must wait for a fresh injected activation marker before reporting success'
require_in_file 'activationStatusNewerThan' "$APP" 'app must validate activation marker freshness'
require_in_file 'statusToken' "$APP" 'app must compare activation marker token to the current launch token'
require_in_file 'processIdentifier' "$APP" 'app must match activation status to the launched Logic pid'
require_in_file 'installedAppKitHooks' "$APP" 'app must validate the installed AppKit hook set'
require_in_file '@\"ok\"' "$APP" 'app must require an explicit ok status'
require_in_file '@\"ok\"' "$ENGINE" 'engine must write an explicit ok status'
require_in_file '@\"installedAppKitHooks\"' "$ENGINE" 'engine must write installed AppKit hook names'
require_in_file 'gInstalledAppKitHooks' "$ENGINE" 'engine must preserve AppKit hook state across mixer marker updates'
require_in_file 'HOOKCLS_REQUIRED("colorWithCatalogName:colorName:"' "$ENGINE" 'engine must report the full installed catalog selector name'
require_in_file 'Logic Pro launch did not return a running app' "$APP" 'nil LaunchServices app must be treated as failure'
require_in_file 'pid <= 0' "$APP" 'activation validation must reject invalid pids'
require_in_file 'ReplacePreparedItem' "$APP" 'app must stage engine files before replacing live support copies'
require_in_file 'colorize.dylib.%@.tmp' "$APP" 'app must copy dylib to a temp path before activating it'
require_in_file 'hook-manifests.%@.tmp' "$APP" 'app must copy hook manifests to a temp path before activating them'
require_in_file 'cleanup_stage_and_exit' "$ROOT/tools/launch_preset.sh" 'launch helper signal traps must clean up and exit'
require_in_file 'previous manifests restored' "$ROOT/tools/launch_preset.sh" 'launch helper must restore old manifests if activation fails'
require_in_file 'isEqualToString:staged' "$LAUNCHER" 'native launcher must not delete an already-staged dylib'
require_in_file 'replaceItemAtURL' "$LAUNCHER" 'native launcher must atomically replace an existing staged dylib'
require_in_file 'THEME4LOGIC_LAUNCH_TOKEN' "$LAUNCHER" 'native launcher must forward the activation token'
require_in_file 'THEME4LOGIC_LAUNCH_TOKEN' "$ROOT/tools/launch_preset.sh" 'launch helper must create an activation token'
require_in_file 'THEME4LOGIC_THEME_NAME' "$LAUNCHER" 'native launcher must forward the preset name'
require_in_file 'THEME4LOGIC_THEME_NAME' "$ROOT/tools/launch_preset.sh" 'launch helper must identify the staged preset'
require_in_file 'colorize-status.json' "$ROOT/tools/launch_preset.sh" 'launch helper must clear stale activation status before launch'
require_in_file 'hook-manifests.%@.tmp' "$LAUNCHER" 'native launcher must transactionally stage direct-launch hook manifests'
require_in_file 'Logic Pro did not respond within 20 seconds' "$LAUNCHER" 'native launcher must fail when LaunchServices times out'
require_in_file 'Logic Pro launch did not return a running app' "$LAUNCHER" 'native launcher must fail when LaunchServices returns no app'

if awk '
  /NSString \*staged =/ { in_stage = 1 }
  in_stage && /removeItemAtPath:staged/ { bad = 1 }
  in_stage && /dylib = staged/ { in_stage = 0 }
  END { exit bad }
' "$LAUNCHER"; then
  :
else
  fail 'native launcher still deletes its staged dylib before activating the replacement'
fi

if awk '
  /openApplicationAtURL/ { seen_open = 1 }
  /Logic Pro launched with/ && seen_open { bad = 1 }
  END { exit bad }
' "$APP"; then
  :
else
  fail 'app still reports themed success directly from LaunchServices completion'
fi

if grep -q 'dispatch_after.*1\.0 \* NSEC_PER_SEC' "$APP"; then
  fail 'app still uses a fixed one-second relaunch delay'
fi

if grep -q 'processIdentifier:(app ? app.processIdentifier : 0)' "$APP"; then
  fail 'app still disables pid validation when LaunchServices returns nil app'
fi

if grep -q 'if (pid > 0' "$APP"; then
  fail 'activation validation still treats pid validation as optional'
fi

if awk '
  /cleanup_stage\(\)/ { in_cleanup = 1 }
  in_cleanup && /\[ -e "\$TMP_OLD_MANIFESTS" \] && \[ ! -e "\$SUPPORT\/hook-manifests" \]/ { restores_without_flag = 1 }
  in_cleanup && /^}/ { in_cleanup = 0 }
  END { exit restores_without_flag ? 0 : 1 }
' "$ROOT/tools/launch_preset.sh"; then
  :
else
  fail 'launch helper cleanup must restore old manifests whenever live manifests are absent'
fi

if awk '
  /- \(void\)applyAndLaunch/ { in_apply = 1 }
  in_apply && /writeTheme:theme/ { seen_write = 1 }
  in_apply && /stageDylib:&dylib/ && !seen_write { staged_first = 1 }
  in_apply && /^}/ { in_apply = 0 }
  END { exit staged_first ? 0 : 1 }
' "$APP"; then
  :
else
  fail 'app must stage engine before writing the new support theme'
fi

if awk '
  /- \(BOOL\)stageDylib/ { in_stage = 1 }
  in_stage && /removeItemAtPath:staged/ { bad = 1 }
  in_stage && /removeItemAtPath:manifestDst/ { bad = 1 }
  in_stage && /^}/ { in_stage = 0 }
  END { exit bad }
' "$APP"; then
  :
else
  fail 'stageDylib still removes live support files before replacement is ready'
fi

echo "launch safety verifier passed"

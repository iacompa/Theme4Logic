#!/bin/sh
# Static hook-version safety checks. Does not launch Logic.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/app/main.m"
ENGINE="$ROOT/poc/colorize.m"
BUILD="$ROOT/app/build_app.sh"
MANIFEST_DIR="$ROOT/poc/hook-manifests"
MANIFEST="$MANIFEST_DIR/logic-12.3-hooks.json"

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

[ -f "$MANIFEST" ] || fail 'missing checked hook manifest for local Logic version 12.3'
python3 -m json.tool "$MANIFEST" >/dev/null || fail 'hook manifest is not valid JSON'

require_in_file 'hook-manifests' "$BUILD" 'app build must bundle hook manifests'
require_in_file 'validate_hook_manifests.py' "$BUILD" 'app build must lint hook manifests before bundling'
require_in_file 'hook-manifests' "$APP" 'app must stage hook manifests beside the dylib'
require_in_file 'THEME4LOGIC_HOOK_MANIFEST_DIR' "$APP" 'app must pass explicit hook manifest dir to Logic'
require_in_file 'CFBundleShortVersionString' "$ENGINE" 'engine must read Logic CFBundleShortVersionString'
require_in_file 'CFBundleVersion' "$ENGINE" 'engine must validate Logic CFBundleVersion'
require_in_file 'bundleIdentifier' "$ENGINE" 'engine must validate Logic bundle identifier'
require_in_file 'logic-.*-hooks.json' "$ENGINE" 'engine must select a per-version logic hooks manifest'
require_in_file 'fc_loadHookManifest' "$ENGINE" 'engine must load hook manifest before installing hooks'
require_in_file 'fc_hooksAllowed' "$ENGINE" 'engine must have an explicit hook allow gate'
require_in_file 'fc_hookAllowed' "$ENGINE" 'engine must check exact hook allowlist entries'
require_in_file 'schemaVersion.integerValue != 2' "$ENGINE" 'engine must reject incompatible manifest schemas at runtime'
require_in_file '[manifestBundle isKindOfClass:[NSString class]]' "$ENGINE" 'engine must validate manifest scalar types before comparing them'
require_in_file 'fc_hookAllowed(@"class", @"NSColor", @name)' "$ENGINE" 'every NSColor class hook must be manifest gated'
require_in_file 'fc_hookAllowed(@"instance", @"CALayer", @"setContents:")' "$ENGINE" 'CALayer setContents must be manifest gated'
require_in_file 'fc_hookAllowed(@"class", @"NSImage", @"imageNamed:")' "$ENGINE" 'NSImage imageNamed must be manifest gated'
require_in_file 'fc_hookAllowed(@"instance", @"NSImage", @"drawInRect:fromRect:operation:fraction:respectFlipped:hints:")' "$ENGINE" 'NSImage draw hook must be manifest gated'
require_in_file 'fc_hookAllowed(@"instance", @"CALayer", @"setBackgroundColor:")' "$ENGINE" 'CALayer background hook must be manifest gated'
require_in_file 'fc_writeDisabledMarker' "$ENGINE" 'engine must write a disabled marker on unknown/unsafe versions'
require_in_file '@"state"' "$ENGINE" 'engine status must include explicit state'
require_in_file 'disabledReason' "$ENGINE" 'engine status must include disabled reason'
require_in_file 'hooksAllowed' "$APP" 'app must validate disabled status schema'
require_in_file 'disabledReason' "$APP" 'app must surface disabled status to the user'

python3 "$ROOT/tools/validate_hook_manifests.py" "$MANIFEST_DIR" >/dev/null
for MANIFEST_FILE in "$MANIFEST_DIR"/logic-*-hooks.json; do
python3 - <<'PY' "$MANIFEST_FILE" "$ENGINE"
import json, re, sys
data = json.load(open(sys.argv[1]))
engine = open(sys.argv[2]).read()
assert data["schemaVersion"] == 2
assert data["logicBundleIdentifier"] == "com.apple.logic10"
assert sys.argv[1].endswith("logic-%s-hooks.json" % data["logicVersion"]), sys.argv[1]
assert re.fullmatch(r"\d+", data["logicBuild"]), data["logicBuild"]
assert data["appKitHooks"]
assert data["requiredAppKitHooks"]
assert set(data["requiredAppKitHooks"]) <= set(data["appKitHooks"])
engine_hooks = set(re.findall(r'(?:HOOKCLS(?:_REQUIRED)?|LCTOR)\("([^"]+)"', engine))
assert engine_hooks == set(data["appKitHooks"]), (engine_hooks, set(data["appKitHooks"]))
assert data["privateHooks"]
for hook in data["privateHooks"]:
    assert {"kind", "class", "selector"} <= set(hook), hook
PY
done

init_line=$(grep -n 'static void fc_init' "$ENGINE" | head -1 | cut -d: -f1)
load_line=$(grep -n 'fc_loadHookManifest' "$ENGINE" | head -1 | cut -d: -f1)
swizzle_line=$(grep -n 'fc_swizzleClass(nc' "$ENGINE" | head -1 | cut -d: -f1)
if [ -z "$init_line" ] || [ -z "$load_line" ] || [ -z "$swizzle_line" ]; then
  fail 'could not locate init/load/swizzle ordering in engine'
fi
if [ "$load_line" -gt "$swizzle_line" ]; then
  fail 'hook manifest is loaded after swizzling starts'
fi

if ! awk '
  /static void fc_init/ { in_init = 1 }
  in_init && /fc_writeDisabledMarker/ { saw_disabled = 1 }
  in_init && /fc_swizzleClass\(nc/ && !saw_disabled { bad = 1 }
  END { exit bad }
' "$ENGINE"; then
  fail 'fc_init can reach swizzling before the disabled fail-safe branch'
fi

echo "hook version safety verifier passed"

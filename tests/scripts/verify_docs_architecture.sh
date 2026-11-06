#!/bin/sh
# Documentation architecture contract checks.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

require_in_file 'runtime theming app' "$ROOT/docs/ARCHITECTURE.md" 'architecture doc must define the current runtime path'
require_in_file 'does not edit `/Applications/Logic Pro.app`' "$ROOT/docs/ARCHITECTURE.md" 'architecture doc must say the shipped app does not edit Logic'
require_in_file 'docs/ARCHITECTURE.md' "$ROOT/README.md" 'README must route developers to current architecture'
require_in_file 'colorize-status.json' "$ROOT/docs/PRESET_AUDIT.md" 'preset audit docs must use structured activation status'
require_in_file 'colorize-status.json' "$ROOT/docs/PRESET_POLISH.md" 'preset polish docs must use structured activation status'

echo "docs architecture verifier passed"

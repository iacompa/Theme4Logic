#!/bin/sh
# Build (if needed) and open the stable signed Application Support copy.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Library/Application Support/Theme4Logic/build/Theme4Logic.app"
sh "$ROOT/app/build_app.sh"
codesign --verify --deep --strict "$APP"
open "$APP"

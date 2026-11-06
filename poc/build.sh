#!/bin/sh
# Build the Theme4Logic injection PoC (universal, ad-hoc signed).
# Ad-hoc signing is sufficient: Logic has no Library Validation, so it loads an
# ad-hoc/unsigned dylib injected via DYLD_INSERT_LIBRARIES.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SAMPLE_THEME=0
VALIDATE_ONLY=0
BUILD_LAUNCHER=1
OUT_DIR="$DIR"

usage() {
  cat <<EOF
usage: $0 [--install-sample-theme] [--validate-only] [--dylibs-only] [--out-dir DIR]

Build Theme4Logic injection binaries. By default this is build-only and does
not write ~/Library/Application Support/Theme4Logic/theme.json.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-sample-theme)
      INSTALL_SAMPLE_THEME=1
      ;;
    --validate-only)
      VALIDATE_ONLY=1
      ;;
    --dylibs-only)
      BUILD_LAUNCHER=0
      ;;
    --out-dir)
      shift
      if [ "$#" -eq 0 ]; then
        echo "--out-dir requires a directory" >&2
        exit 2
      fi
      OUT_DIR="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

build_dylib() { # <src> <out>
  echo "  building $2 (arm64 + x86_64)..."
  mkdir -p "$OUT_DIR"
  clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
    -framework Foundation -framework AppKit -framework QuartzCore -framework CoreText \
    -o "$OUT_DIR/$2" "$DIR/$1"
  codesign -s - -f "$OUT_DIR/$2"
}

if [ "$VALIDATE_ONLY" != "1" ]; then
  echo "building dylibs..."
  build_dylib inject_probe.m inject_probe.dylib   # recon: proves injection + maps Logic's color methods
  build_dylib colorize.m     colorize.dylib       # the real thing: recolors via colorWithCatalogName:colorName:

  if [ "$BUILD_LAUNCHER" = "1" ]; then
    mkdir -p "$OUT_DIR"
    echo "building launcher..."
    clang -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
      -framework AppKit -framework Foundation \
      -o "$OUT_DIR/launch_logic_injected" "$DIR/launcher.m"
    codesign -s - -f "$OUT_DIR/launch_logic_injected"
    if [ "$OUT_DIR" != "$DIR" ]; then
      mkdir -p "$OUT_DIR/hook-manifests"
      cp -R "$DIR/hook-manifests/." "$OUT_DIR/hook-manifests"
    fi
  fi
fi

if [ "$INSTALL_SAMPLE_THEME" = "1" ]; then
  SUPPORT="$HOME/Library/Application Support/Theme4Logic"
  mkdir -p "$SUPPORT"
  if [ -f "$SUPPORT/theme.json" ]; then
    BACKUP="$(mktemp "$SUPPORT/theme.json.bak.XXXXXX")"
    cp "$SUPPORT/theme.json" "$BACKUP"
    echo "backed up existing theme.json -> $BACKUP"
  fi
  cp "$DIR/theme.json" "$SUPPORT/theme.json"
  echo "installed sample theme.json -> $SUPPORT/theme.json"
fi

echo "done:"
if [ "$VALIDATE_ONLY" != "1" ]; then
  ls -la "$OUT_DIR/inject_probe.dylib" "$OUT_DIR/colorize.dylib"
  if [ "$BUILD_LAUNCHER" = "1" ]; then
    ls -la "$OUT_DIR/launch_logic_injected"
    [ -d "$OUT_DIR/hook-manifests" ] && echo "  bundled hook manifests"
  fi
fi

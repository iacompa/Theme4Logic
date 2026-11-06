#!/bin/sh
# Build Theme4Logic.app (universal, ad-hoc signed) — bundles the engine dylib.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
POC="$DIR/../poc"
LOGO_DIR="$DIR/../Logo"
PROJECT_APP="$DIR/build/Theme4Logic.app"
SUPPORT_APP="$HOME/Library/Application Support/Theme4Logic/build/Theme4Logic.app"
FINAL_APP="${THEME4LOGIC_APP:-$PROJECT_APP}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/theme4logic-app.XXXXXX")"
APP="$BUILD_ROOT/Theme4Logic.app"
ENGINE_BUILD_DIR=""
cleanup_build() {
  rm -rf "$BUILD_ROOT"
  if [ -n "$ENGINE_BUILD_DIR" ]; then
    rm -rf "$ENGINE_BUILD_DIR"
  fi
}
trap cleanup_build EXIT
FORCE_OUTPUT=0
VALIDATE_ONLY=0

usage() {
  cat <<EOF
usage: $0 [--force-output] [--validate-only]

Build Theme4Logic.app. THEME4LOGIC_APP may override the output path, but
custom output paths outside the project/support build roots require
--force-output and must still end in Theme4Logic.app.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force-output)
      FORCE_OUTPUT=1
      ;;
    --validate-only)
      VALIDATE_ONLY=1
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

die() {
  echo "build_app.sh: $*" >&2
  exit 2
}

is_allowed_output_root() {
  case "$1" in
    "$DIR/build/Theme4Logic.app"|"$DIR/build"/*/Theme4Logic.app)
      return 0
      ;;
    "$HOME/Library/Application Support/Theme4Logic/build/Theme4Logic.app"|"$HOME/Library/Application Support/Theme4Logic/build"/*/Theme4Logic.app)
      return 0
      ;;
  esac
  return 1
}

reject_symlink_ancestors() {
  path="$1"
  dir="$(dirname "$path")"
  old_ifs="$IFS"
  IFS="/"
  cur=""
  for part in $dir; do
    [ -n "$part" ] || continue
    cur="$cur/$part"
    if [ -L "$cur" ]; then
      IFS="$old_ifs"
      die "refusing output path with symlink parent: $cur"
    fi
    if [ -e "$cur" ] && [ ! -d "$cur" ]; then
      IFS="$old_ifs"
      die "output parent exists but is not a directory: $cur"
    fi
  done
  IFS="$old_ifs"
}

validate_app_output() {
  path="${1%/}"
  force="$2"

  [ -n "$path" ] || die "empty output path"
  case "$path" in
    /*)
      ;;
    *)
      die "output path must be absolute: $path"
      ;;
  esac
  [ "$(basename "$path")" = "Theme4Logic.app" ] || die "output path must be a Theme4Logic.app bundle"
  case "$path" in
    "/"|"."|".."|"$HOME")
      die "refusing unsafe output path: $path"
      ;;
    *"/../"*|*"../"*|*"/./"*|*"./"*)
      die "output path must not contain . or .. segments: $path"
      ;;
  esac
  if [ -L "$path" ]; then
    die "refusing to replace symlink output path: $path"
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    die "output path exists but is not an app bundle directory: $path"
  fi

  if is_allowed_output_root "$path"; then
    reject_symlink_ancestors "$path"
    return 0
  fi
  [ "$force" = "1" ] || die "custom output path requires --force-output: $path"
}

validate_app_output "$FINAL_APP" "$FORCE_OUTPUT"
validate_app_output "$SUPPORT_APP" 0

if [ "$VALIDATE_ONLY" = "1" ]; then
  echo "validated output: $FINAL_APP"
  exit 0
fi

echo "building engine dylib..."
ENGINE_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/theme4logic-engine.XXXXXX")"
sh "$POC/build.sh" --dylibs-only --out-dir "$ENGINE_BUILD_DIR" >/dev/null 2>&1
python3 "$DIR/../tools/validate_hook_manifests.py" "$POC/hook-manifests" >/dev/null

scrub_app_metadata() {
  target="$1"
  find "$target" -name '._*' -delete 2>/dev/null || true
  xattr -cr "$target" 2>/dev/null || true
  /usr/sbin/dot_clean -m "$target" 2>/dev/null || true
  find "$target" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
  find "$target" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} \; 2>/dev/null || true
  find "$target" -exec xattr -d com.apple.macl {} \; 2>/dev/null || true
  find "$target" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$target" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$target" 2>/dev/null || true
  xattr -d com.apple.macl "$target" 2>/dev/null || true
  xattr -d com.apple.provenance "$target" 2>/dev/null || true
}

echo "assembling $FINAL_APP ..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Theme4Logic</string>
  <key>CFBundleIdentifier</key><string>com.theme4logic.app</string>
  <key>CFBundleName</key><string>Theme4Logic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDisplayName</key><string>Theme4Logic</string>
  <key>CFBundleIconFile</key><string>Theme4Logic</string>
  <key>NSHumanReadableCopyright</key><string>Free for Logic Pro users.</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

echo "compiling app..."
clang -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -framework Cocoa \
  -o "$APP/Contents/MacOS/Theme4Logic" "$DIR/main.m"

cp "$ENGINE_BUILD_DIR/colorize.dylib" "$APP/Contents/Resources/colorize.dylib"
mkdir -p "$APP/Contents/Resources/hook-manifests"
cp "$POC/hook-manifests/"*.json "$APP/Contents/Resources/hook-manifests/"

echo "bundling logo assets..."
cp "$LOGO_DIR/Theme4Logic-icon-512.png" "$APP/Contents/Resources/"
cp "$LOGO_DIR/Theme4Logic-text-only.png" "$APP/Contents/Resources/"
cp "$LOGO_DIR/Theme4Logic-icon-with-text.png" "$APP/Contents/Resources/"

echo "generating app icon..."
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/Theme4Logic.iconset"
mkdir -p "$ICONSET"
cp "$LOGO_DIR/Theme4Logic-icon-1024.png" "$ICON_TMP/icon-source.png"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$ICON_TMP/icon-source.png" \
    --out "$ICON_TMP/icon-${size}.png" >/dev/null
done
cp "$ICON_TMP/icon-16.png" "$ICONSET/icon_16x16.png"
cp "$ICON_TMP/icon-32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICON_TMP/icon-32.png" "$ICONSET/icon_32x32.png"
cp "$ICON_TMP/icon-64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICON_TMP/icon-128.png" "$ICONSET/icon_128x128.png"
cp "$ICON_TMP/icon-256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICON_TMP/icon-256.png" "$ICONSET/icon_256x256.png"
cp "$ICON_TMP/icon-512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICON_TMP/icon-512.png" "$ICONSET/icon_512x512.png"
cp "$ICON_TMP/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Theme4Logic.icns"
rm -rf "$ICON_TMP"

echo "bundling themes..."
mkdir -p "$APP/Contents/Resources/themes"
cp "$DIR/../themes/preset-manifest.json" "$APP/Contents/Resources/preset-manifest.json"
cp "$DIR/../themes/injection/"*.json "$APP/Contents/Resources/themes/"

# Clean AppleDouble + xattr detritus that breaks strict codesign (cloud-synced
# folders can stamp com.apple.FinderInfo onto files).
scrub_app_metadata "$APP"
codesign -s - -f --deep "$APP"
scrub_app_metadata "$APP"

mkdir -p "$(dirname "$FINAL_APP")"
rm -rf "$FINAL_APP"
ditto "$APP" "$FINAL_APP"
scrub_app_metadata "$FINAL_APP"
echo "done: $FINAL_APP"
VERIFY_APP="$FINAL_APP"

# Keep Application Support copy in sync when building the project-local app.
if [ "$FINAL_APP" = "$PROJECT_APP" ]; then
  mkdir -p "$(dirname "$SUPPORT_APP")"
  rm -rf "$SUPPORT_APP"
  ditto "$APP" "$SUPPORT_APP"
  scrub_app_metadata "$SUPPORT_APP"
  echo "synced: $SUPPORT_APP"
  VERIFY_APP="$SUPPORT_APP"
fi

for attempt in 1 2 3; do
  scrub_app_metadata "$VERIFY_APP"
  if codesign --verify --deep --strict "$VERIFY_APP" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = "3" ]; then
    codesign --verify --deep --strict "$VERIFY_APP"
  fi
  sleep 0.2
done

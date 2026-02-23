#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-即刻译}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-jikeyi-trans}"
BUNDLE_ID="${BUNDLE_ID:-cn.jikeyi.trans}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-13.0}"
ICON_NAME="${ICON_NAME:-AppIcon}"
ICON_ICNS_SOURCE="${ICON_ICNS_SOURCE:-$ROOT_DIR/AppIcons/$ICON_NAME.icns}"
ICON_PNG_SOURCE="${ICON_PNG_SOURCE:-$ROOT_DIR/AppIcons/Assets.xcassets/AppIcon.appiconset/1024.png}"

cd "$ROOT_DIR"

echo "==> Building release binary..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXECUTABLE_NAME"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "error: executable not found: $BIN_PATH" >&2
  exit 1
fi

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
PLIST_ICON_BLOCK=""

echo "==> Packaging app bundle: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [[ -f "$ICON_ICNS_SOURCE" ]]; then
  echo "==> Using icon: $ICON_ICNS_SOURCE"
  cp "$ICON_ICNS_SOURCE" "$RESOURCES_DIR/$ICON_NAME.icns"
  PLIST_ICON_BLOCK=$'  <key>CFBundleIconFile</key>\n  <string>'"$ICON_NAME"$'</string>'
elif [[ -f "$ICON_PNG_SOURCE" ]] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  echo "==> Generating .icns from: $ICON_PNG_SOURCE"
  TMP_ICONSET="$(mktemp -d)"
  TMP_ICONSET_DIR="$TMP_ICONSET/$ICON_NAME.iconset"
  mkdir -p "$TMP_ICONSET_DIR"

  sips -z 16 16   "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32   "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32   "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64   "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG_SOURCE" --out "$TMP_ICONSET_DIR/icon_512x512.png" >/dev/null
  cp "$ICON_PNG_SOURCE" "$TMP_ICONSET_DIR/icon_512x512@2x.png"

  iconutil -c icns "$TMP_ICONSET_DIR" -o "$RESOURCES_DIR/$ICON_NAME.icns"
  rm -rf "$TMP_ICONSET"

  PLIST_ICON_BLOCK=$'  <key>CFBundleIconFile</key>\n  <string>'"$ICON_NAME"$'</string>'
else
  echo "==> Icon not found, skip icon embedding"
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
${PLIST_ICON_BLOCK}
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing..."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Done"
echo "App: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""

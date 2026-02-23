#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-即刻译}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-notary.zip"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package-macos-app.sh"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"

SKIP_NOTARY=0
SKIP_DMG=0
SKIP_DMG_NOTARY=0
SKIP_APP_STAPLE=0
SKIP_DMG_STAPLE=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-macos.sh [options]

Options:
  --sign-identity "Developer ID Application: Your Name (TEAMID)"
      覆盖 SIGN_IDENTITY 环境变量。

  --keychain-profile "AC_NOTARY"
      覆盖 KEYCHAIN_PROFILE 环境变量（notarytool 配置名）。

  --skip-notary
      跳过 APP 公证（会同时跳过 DMG 公证）。

  --skip-dmg
      不生成 DMG。

  --skip-dmg-notary
      生成 DMG 但不公证 DMG。

  --skip-app-staple
      不对 APP 执行 stapler。

  --skip-dmg-staple
      不对 DMG 执行 stapler。

  -h, --help
      显示帮助。

Environment:
  SIGN_IDENTITY    Developer ID Application 证书名称（必填）
  KEYCHAIN_PROFILE notarytool keychain profile（公证时必填）
  APP_NAME         默认：即刻译

Examples:
  SIGN_IDENTITY="Developer ID Application: ACME INC (ABCDE12345)" \
  KEYCHAIN_PROFILE="AC_NOTARY" \
  ./scripts/release-macos.sh

  ./scripts/release-macos.sh \
    --sign-identity "Developer ID Application: ACME INC (ABCDE12345)" \
    --keychain-profile "AC_NOTARY"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign-identity)
      SIGN_IDENTITY="${2:-}"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="${2:-}"
      shift 2
      ;;
    --skip-notary)
      SKIP_NOTARY=1
      SKIP_DMG_NOTARY=1
      shift
      ;;
    --skip-dmg)
      SKIP_DMG=1
      SKIP_DMG_NOTARY=1
      SKIP_DMG_STAPLE=1
      shift
      ;;
    --skip-dmg-notary)
      SKIP_DMG_NOTARY=1
      shift
      ;;
    --skip-app-staple)
      SKIP_APP_STAPLE=1
      shift
      ;;
    --skip-dmg-staple)
      SKIP_DMG_STAPLE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: missing signing identity." >&2
  echo "set SIGN_IDENTITY or pass --sign-identity" >&2
  exit 1
fi

if [[ "$SKIP_NOTARY" -eq 0 && -z "$KEYCHAIN_PROFILE" ]]; then
  echo "error: missing keychain profile for notarization." >&2
  echo "set KEYCHAIN_PROFILE or pass --keychain-profile" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: command not found: $1" >&2
    exit 1
  fi
}

require_cmd codesign
require_cmd ditto
require_cmd xcrun
require_cmd hdiutil

if [[ ! -x "$PACKAGE_SCRIPT" ]]; then
  echo "error: package script not executable: $PACKAGE_SCRIPT" >&2
  exit 1
fi

cd "$ROOT_DIR"

echo "==> Packaging app bundle..."
"$PACKAGE_SCRIPT"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found: $APP_PATH" >&2
  exit 1
fi

echo "==> Signing app with Developer ID..."
codesign --force --deep --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"

echo "==> Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -t exec -vv "$APP_PATH" || true

if [[ "$SKIP_NOTARY" -eq 0 ]]; then
  echo "==> Creating notarization ZIP..."
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

  echo "==> Notarizing APP ZIP..."
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

  if [[ "$SKIP_APP_STAPLE" -eq 0 ]]; then
    echo "==> Stapling APP..."
    xcrun stapler staple "$APP_PATH"
  fi
else
  echo "==> Skip APP notarization"
fi

if [[ "$SKIP_DMG" -eq 0 ]]; then
  echo "==> Creating DMG..."
  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"

  echo "==> Signing DMG..."
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"

  if [[ "$SKIP_DMG_NOTARY" -eq 0 ]]; then
    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

    if [[ "$SKIP_DMG_STAPLE" -eq 0 ]]; then
      echo "==> Stapling DMG..."
      xcrun stapler staple "$DMG_PATH"
    fi
  else
    echo "==> Skip DMG notarization"
  fi
fi

echo "==> Release artifacts:"
echo "APP: $APP_PATH"
if [[ "$SKIP_NOTARY" -eq 0 ]]; then
  echo "ZIP: $ZIP_PATH"
fi
if [[ "$SKIP_DMG" -eq 0 ]]; then
  echo "DMG: $DMG_PATH"
fi

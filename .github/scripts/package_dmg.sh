#!/bin/zsh

set -euo pipefail

VERSION_SUFFIX="$1"
APP_PATH="${2:-build/Build/Products/Release/SimpView.app}"

if [[ ! -d "$APP_PATH" ]]; then
	echo "App bundle not found at $APP_PATH" >&2
	exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
PRODUCT_NAME="${APP_NAME%.app}"
BUILD_NAME="${PRODUCT_NAME}-${VERSION_SUFFIX}"
DMG_FILENAME="${BUILD_NAME}-macOS.dmg"
DIST_DIR="dist"
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_FILENAME"

if [[ -n "${APPLE_DEVID_APP_CERT_NAME:-}" ]]; then
	echo "Signing app bundle"
	codesign --sign "$APPLE_DEVID_APP_CERT_NAME" --deep --force --options runtime --timestamp "$APP_PATH"
fi

echo "Creating disk image"
hdiutil create -srcfolder "$APP_PATH" -volname "$BUILD_NAME" -format UDSB "temp.sparsebundle"
hdiutil convert "temp.sparsebundle" -format ULFO -o "$DIST_DIR/$DMG_FILENAME"
rm -rf "temp.sparsebundle"

if [[ -n "${APPLE_DEVID_APP_CERT_NAME:-}" ]]; then
	echo "Signing dmg file"
	codesign --sign "$APPLE_DEVID_APP_CERT_NAME" --timestamp --identifier "$APP_IDENTIFIER.dmg" "$DIST_DIR/$DMG_FILENAME"

	echo "Notarizing dmg file"
	xcrun notarytool submit "$DIST_DIR/$DMG_FILENAME" --apple-id "$APPLE_ID_USER" --password "$APPLE_ID_PASS" --team-id "${APPLE_DEVID_APP_CERT_NAME: -11:10}" --wait
	xcrun stapler staple "$DIST_DIR/$DMG_FILENAME"
	xcrun stapler validate "$DIST_DIR/$DMG_FILENAME"
fi

#!/bin/bash
# Build a signed release DMG with /Applications shortcut for drag-install.
# Re-signs with Developer ID Application for notarization compatibility.
set -e

PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
APP_NAME="BaoLianDeng"
SCHEME="BaoLianDeng"
DMG_DIR="/tmp/${APP_NAME}-dmg"
ARCHIVE_PATH="/tmp/${APP_NAME}.xcarchive"

cd "$PROJECT_DIR"

# Read version from Xcode project
VERSION=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk '/MARKETING_VERSION/ { print $3; exit }')
BUILD=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk '/CURRENT_PROJECT_VERSION/ { print $3; exit }')
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="/tmp/${DMG_NAME}.dmg"

# Find Developer ID Application identity
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
if [ -z "$IDENTITY" ]; then
  echo "ERROR: No Developer ID Application identity found in keychain"
  exit 1
fi

echo "=== Building ${APP_NAME} v${VERSION} (${BUILD}) ==="
echo "Signing: ${IDENTITY}"

echo "=== Step 1: Build framework ==="
make framework

echo "=== Step 2: Archive ==="
xcodebuild archive \
  -project ${APP_NAME}.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  | tail -3

echo "=== Step 3: Re-sign with Developer ID ==="
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: ${APP_PATH} not found in archive"
  exit 1
fi

# Extract existing entitlements from each binary, then re-sign with Developer ID
# Must sign from inside out: appex first, then main app

# Replace development provisioning profiles with Developer ID profiles
PROFILES_DIR="$HOME/.appstoreconnect/profiles"
APP_PROFILE="$PROFILES_DIR/BaoLianDeng_DevID.provisionprofile"
APPEX_PROFILE="$PROFILES_DIR/PacketTunnel_DevID.provisionprofile"

if [ ! -f "$APP_PROFILE" ] || [ ! -f "$APPEX_PROFILE" ]; then
  echo "ERROR: Developer ID provisioning profiles not found in $PROFILES_DIR"
  echo "Download them from App Store Connect and place as:"
  echo "  $APP_PROFILE"
  echo "  $APPEX_PROFILE"
  exit 1
fi

# Rewrite entitlements for Developer ID (systemextension variant)
rewrite_entitlements() {
  local binary="$1" output="$2"
  codesign -d --entitlements - --xml "$binary" 2>/dev/null > "$output"
  # Swap packet-tunnel-provider → packet-tunnel-provider-systemextension
  sed -i '' 's/packet-tunnel-provider/packet-tunnel-provider-systemextension/g' "$output"
}

APPEX_PATH="${APP_PATH}/Contents/PlugIns/PacketTunnel.appex"
if [ -d "$APPEX_PATH" ]; then
  echo "Embedding PacketTunnel profile and re-signing..."
  cp "$APPEX_PROFILE" "$APPEX_PATH/Contents/embedded.provisionprofile"
  rewrite_entitlements "$APPEX_PATH" /tmp/appex-ent.plist
  codesign --force --sign "$IDENTITY" --timestamp --options runtime \
    --entitlements /tmp/appex-ent.plist \
    "$APPEX_PATH"
fi

echo "Embedding app profile and re-signing..."
cp "$APP_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
rewrite_entitlements "$APP_PATH" /tmp/app-ent.plist
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  --entitlements /tmp/app-ent.plist \
  "$APP_PATH"

# Verify
echo "Verifying signature..."
codesign --verify --deep --strict "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep "Authority"
echo "Signature OK"

echo "=== Step 4: Create DMG ==="
rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"

cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_DIR"

echo "=== Step 5: Sign DMG ==="
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"
echo "DMG signed"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "=== Done ==="
echo "DMG: ${DMG_PATH} (${DMG_SIZE})"
echo "Version: ${VERSION} (${BUILD})"
echo ""
echo "To notarize:"
echo "  xcrun notarytool submit ${DMG_PATH} \\"
echo "    --key ~/.appstoreconnect/AuthKey_5MC8U9Z7P9.p8 \\"
echo "    --key-id 5MC8U9Z7P9 \\"
echo "    --issuer 1200242f-e066-47cc-9ac8-b3affd0eee32 \\"
echo "    --wait"
echo ""
echo "Then staple:"
echo "  xcrun stapler staple ${DMG_PATH}"

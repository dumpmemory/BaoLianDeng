#!/usr/bin/env bash
# Provision BaoLianDeng/GoogleService-Info.plist for CI builds.
#
# GoogleService-Info.plist is gitignored (contains API keys). This script
# either decodes the real file from the FIREBASE_PLIST_BASE64 env var, or
# writes a stub so xcodebuild can still include the resource in the bundle
# (builds without signing never run the app, so Firebase never reads it).
#
# To populate the secret once:
#   base64 -i BaoLianDeng/GoogleService-Info.plist | pbcopy
# then paste into GitHub → Settings → Secrets and variables → Actions
# as FIREBASE_PLIST_BASE64.

set -euo pipefail

DEST="BaoLianDeng/GoogleService-Info.plist"

if [[ -f "$DEST" ]]; then
    echo "provision-firebase: $DEST already exists, leaving untouched"
    exit 0
fi

if [[ -n "${FIREBASE_PLIST_BASE64:-}" ]]; then
    echo "$FIREBASE_PLIST_BASE64" | base64 --decode > "$DEST"
    echo "provision-firebase: decoded $DEST from FIREBASE_PLIST_BASE64"
else
    cat > "$DEST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>API_KEY</key>
	<string>stub</string>
	<key>BUNDLE_ID</key>
	<string>io.github.baoliandeng</string>
	<key>GCM_SENDER_ID</key>
	<string>000000000000</string>
	<key>GOOGLE_APP_ID</key>
	<string>1:000000000000:ios:0000000000000000</string>
	<key>IS_ADS_ENABLED</key>
	<false/>
	<key>IS_ANALYTICS_ENABLED</key>
	<false/>
	<key>IS_APPINVITE_ENABLED</key>
	<false/>
	<key>IS_GCM_ENABLED</key>
	<false/>
	<key>IS_SIGNIN_ENABLED</key>
	<false/>
	<key>PLIST_VERSION</key>
	<string>1</string>
	<key>PROJECT_ID</key>
	<string>stub</string>
	<key>STORAGE_BUCKET</key>
	<string>stub.appspot.com</string>
</dict>
</plist>
PLIST
    echo "provision-firebase: wrote stub $DEST (FIREBASE_PLIST_BASE64 not set)"
fi

#!/bin/zsh
# Builds a Release TrackEdge.app, signs it, and zips it into dist/.
#
#   scripts/package.sh                         # ad-hoc signature (local use only)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=my-profile scripts/package.sh   # + notarize & staple
#
# NOTARY_PROFILE is a keychain profile created with:
#   xcrun notarytool store-credentials my-profile --apple-id ... --team-id ... --password ...
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
ARCHIVE="build/TrackEdge.xcarchive"
DIST="dist"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

xcodebuild -project TrackEdge.xcodeproj -scheme TrackEdge -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData archive \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual | grep -E "error:|ARCHIVE" || true

APP="$ARCHIVE/Products/Applications/TrackEdge.app"
[[ -d "$APP" ]] || { echo "Archive failed"; exit 1; }

# Re-sign with hardened runtime + timestamp (required for notarization when using a real identity).
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --options runtime --timestamp --entitlements TrackEdge/Resources/TrackEdge.entitlements \
    --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

rm -rf "$DIST" && mkdir -p "$DIST"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$DIST/TrackEdge-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Packaged $ZIP"

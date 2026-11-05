#!/bin/zsh
# Builds a Release TrackEdge.app and packages it as both a .zip and a drag-to-install .dmg in dist/.
#
#   scripts/package.sh                         # ad-hoc signature (local use only)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=my-profile scripts/package.sh   # + notarize & staple app and DMG
#
# NOTARY_PROFILE is a keychain profile created with:
#   xcrun notarytool store-credentials my-profile --apple-id ... --team-id ... --password ...
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
ARCHIVE="build/TrackEdge.xcarchive"
DIST="dist"
NOTARIZE=0
[[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]] && NOTARIZE=1

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

# 1. Archive ad hoc (no team/provisioning needed); the real identity is applied below.
xcodebuild -project TrackEdge.xcodeproj -scheme TrackEdge -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData archive \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual | grep -E "error:|ARCHIVE" || true

APP="$ARCHIVE/Products/Applications/TrackEdge.app"
[[ -d "$APP" ]] || { echo "Archive failed"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# 2. Sign: hardened runtime + secure timestamp are both required for notarization.
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --options runtime --timestamp --entitlements TrackEdge/Resources/TrackEdge.entitlements \
    --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
if [[ "$IDENTITY" != "-" ]]; then
  codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier" || { echo "Not signed with a Developer ID"; exit 1; }
fi

rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/TrackEdge-$VERSION.zip"
DMG="$DIST/TrackEdge-$VERSION.dmg"

# 3. Notarize the app (submitted as a zip), then staple the ticket into the bundle.
ditto -c -k --keepParent "$APP" "$ZIP"
if (( NOTARIZE )); then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi

# 4. Styled drag-to-install DMG containing the stapled app.
scripts/make_dmg.sh "$APP" "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if (( NOTARIZE )); then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
fi
hdiutil verify -quiet "$DMG"

echo "Packaged:"
for f in "$ZIP" "$DMG"; do
  echo "  $f  $(shasum -a 256 "$f" | cut -d' ' -f1)"
done

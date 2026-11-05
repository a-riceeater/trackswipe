#!/bin/zsh
# Publishes what scripts/package.sh produced: creates the GitHub release with the DMG + zip attached,
# then commits and pushes appcast.xml so installed copies see the update.
#   scripts/publish_release.sh [notes.md]
# Order matters: the appcast is pushed only after the archives are downloadable.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/TrackEdge.xcarchive/Products/Applications/TrackEdge.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
TAG="${RELEASE_TAG:-$VERSION}"
ZIP="dist/TrackEdge-$VERSION.zip"
DMG="dist/TrackEdge-$VERSION.dmg"
NOTES="${1:-}"

[[ -f "$ZIP" && -f "$DMG" ]] || { echo "Run scripts/package.sh with signing + notarization first."; exit 1; }
grep -q "releases/download/$TAG/TrackEdge-$VERSION.zip" appcast.xml || { echo "appcast.xml has no entry for $VERSION"; exit 1; }
spctl -a -t open --context context:primary-signature "$DMG" || { echo "DMG is not notarized"; exit 1; }

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$ZIP" --clobber
else
  gh release create "$TAG" "$DMG" "$ZIP" --title "TrackEdge $VERSION" --target main \
    ${NOTES:+--notes-file "$NOTES"} ${NOTES:---generate-notes} --latest
fi

# Confirm the enclosure is reachable before telling installed apps about it.
URL="https://github.com/a-riceeater/trackswipe/releases/download/$TAG/TrackEdge-$VERSION.zip"
for _ in {1..10}; do
  curl -fsIL "$URL" >/dev/null && break
  sleep 3
done
curl -fsIL "$URL" >/dev/null || { echo "Release asset not reachable yet: $URL"; exit 1; }

git add appcast.xml
git commit -m "Publish TrackEdge $VERSION to the update feed"
git push origin main
echo "Published $VERSION. Installed copies will see it on their next update check."

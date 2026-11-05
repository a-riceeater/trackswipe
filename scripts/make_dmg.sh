#!/bin/zsh
# Builds a styled drag-to-install DMG (background art, fixed icon layout, custom volume icon).
#   scripts/make_dmg.sh <path/to/TrackEdge.app> <output.dmg>
# Signing/notarization of the resulting DMG is done by scripts/package.sh.
#
# The window layout is written by scripting Finder, which stores it in the volume's .DS_Store.
# The first run may ask to allow your terminal to control Finder (System Settings › Privacy & Security › Automation).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"
OUT="$2"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
VOLNAME="TrackEdge $VERSION"
WORK="build/dmg"
STAGE="$WORK/stage"
RW="$WORK/rw.dmg"

rm -rf "$WORK" && mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/TrackEdge.app"
ln -s /Applications "$STAGE/Applications"

# Background: 1x + 2x combined into one HiDPI TIFF so it is sharp on Retina displays.
swift scripts/dmg_background.swift "$WORK/bg" >/dev/null
tiffutil -cathidpicheck "$WORK/bg/background.png" "$WORK/bg/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# A previously opened copy with the same volume name would make Finder style the wrong disk.
for vol in /Volumes/"$VOLNAME"*(N); do hdiutil detach -quiet -force "$vol" || true; done

hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 60m -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/.*$')

osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "TrackEdge.app" of container window to {170, 200}
    set position of item "Applications" of container window to {470, 200}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

# Wait for Finder to flush the layout, then tidy and seal.
for _ in {1..20}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"

# Disk icon = app icon. Must come after the Finder step (Finder removes it) and can't go through
# hdiutil -srcfolder (which drops .VolumeIcon.icns).
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach -quiet "$MOUNT" || { sleep 2; hdiutil detach -force -quiet "$MOUNT"; }

hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
rm -f "$RW"
echo "Built $OUT"

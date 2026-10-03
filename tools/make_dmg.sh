#!/bin/sh
# Packs Backchannel.app into build/Backchannel-<version>.dmg with the branded
# window (tools/dmg/background.tiff, 660×400 at 1x + 2x; the window adds 28pt of title bar): the app on the left, an arrow,
# Applications on the right. Needs create-dmg (brew install create-dmg).
set -e
APP="${1:-build/Backchannel.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="$ROOT/build/Backchannel-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
create-dmg \
  --volname "Backchannel" \
  --background "$ROOT/tools/dmg/background.tiff" \
  --window-pos 200 120 \
  --window-size 660 428 \
  --icon-size 128 \
  --text-size 13 \
  --icon "Backchannel.app" 180 210 \
  --hide-extension "Backchannel.app" \
  --app-drop-link 480 210 \
  "$OUT" "$STAGE"
rm -rf "$STAGE"
# create-dmg registers its staging copy and the mounted volume with LaunchServices;
# drop them so build/Backchannel.app stays the only Backchannel the system knows.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# A path can be registered more than once (two mounts), so repeat until it's gone.
"$LSREG" -dump 2>/dev/null | grep -E "^path:.*Backchannel\.app \(0x" | sed -E 's/^path: +//; s/ \(0x[0-9a-f]+\)$//' | sort -u | while read -r p; do
  [ "$p" = "$ROOT/build/Backchannel.app" ] && continue
  for i in 1 2 3; do "$LSREG" -u "$p" 2>/dev/null || true; done
done
echo "built $OUT"

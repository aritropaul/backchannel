#!/bin/sh
# A signed, notarized release, published on GitHub:
#
#   make release VERSION=0.2.0
#   PUBLISH=0 make release VERSION=0.2.0   # everything but the GitHub release
#
# Signing uses the Developer ID that Xcode manages in the cloud for the team (the Apple ID
# signed in under Xcode › Settings › Accounts), and notarization goes through the same
# account, so there's no certificate file, password or secret to keep. The app is
# stapled, packed into the branded disk image and checked by Gatekeeper before anything
# is published. The release is tagged at the commit that was built, which has to be
# main as pushed. The appcast published with it is how installed copies find the update.
set -eu
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

VERSION="${VERSION:?usage: make release VERSION=0.2.0}"
TEAM="${TEAM:-2J3WW2KWBU}"
REPO="${REPO:-aritropaul/backchannel}"
PUBLISH="${PUBLISH:-1}"
TAG="v$VERSION"
OUT="$ROOT/build/release"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# GitHub as the repo's owner, whichever gh account is active.
GH_TOKEN="$(gh auth token --user "${REPO%%/*}" 2>/dev/null || gh auth token)"
export GH_TOKEN

if [ "$PUBLISH" = 1 ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit your changes first: a release is built from main as pushed."; exit 1; }
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD isn't origin/main. Push main (or check it out) first."; exit 1; }
  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then echo "$TAG is already released."; exit 1; fi
fi
BUILD="$(git rev-list --count HEAD)"
echo "Backchannel $VERSION ($BUILD)"

rm -rf "$OUT"
mkdir -p "$OUT"
make core project

# Xcode's archive copies are never meant to be opened; keep LaunchServices pointing at
# build/Backchannel.app only.
forget() { for p in "$@"; do "$LSREG" -u "$p" 2>/dev/null || true; done; }

echo "Archiving…"
xcodebuild -project app/Backchannel.xcodeproj -scheme Backchannel -configuration Release \
  -derivedDataPath "$OUT/dd" -archivePath "$OUT/Backchannel.xcarchive" -quiet archive \
  ARCHS=arm64 ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_ENTITLEMENTS=Backchannel.entitlements \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"
forget "$OUT/Backchannel.xcarchive/Products/Applications/Backchannel.app" \
  "$OUT/dd/Build/Intermediates.noindex/ArchiveIntermediates/Backchannel/InstallationBuildProductsLocation/Applications/Backchannel.app" \
  "$OUT/dd/Build/Intermediates.noindex/ArchiveIntermediates/Backchannel/InstallationBuildProductsLocation/Applications/Backchannel.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
# Sparkle's Updater.app copies in derived data, likewise.
find "$OUT/dd" -name Updater.app -prune -exec "$LSREG" -u {} \; 2>/dev/null || true

cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM</string>
	<key>destination</key><string>upload</string>
</dict>
</plist>
EOF

echo "Signing with Developer ID and sending to Apple's notary service…"
if ! xcodebuild -exportArchive -archivePath "$OUT/Backchannel.xcarchive" -exportPath "$OUT/upload" \
     -exportOptionsPlist "$OUT/export.plist" -allowProvisioningUpdates > "$OUT/upload.log" 2>&1; then
  tail -20 "$OUT/upload.log"
  exit 1
fi
grep -E "^Uploaded" "$OUT/upload.log"

echo "Waiting for notarization…"
i=0
until xcodebuild -exportNotarizedApp -archivePath "$OUT/Backchannel.xcarchive" -exportPath "$OUT/notarized" \
      > "$OUT/notarize.log" 2>&1; do
  i=$((i + 1))
  if grep -qiE "invalid|rejected" "$OUT/notarize.log"; then cat "$OUT/notarize.log"; exit 1; fi
  [ "$i" -lt 90 ] || { echo "Still not notarized after 30 minutes:"; tail -5 "$OUT/notarize.log"; exit 1; }
  sleep 20
done
APP="$OUT/notarized/Backchannel.app"
forget "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

tools/make_dmg.sh "$APP"
DMG="$ROOT/build/Backchannel-$VERSION.dmg"
( cd build && shasum -a 256 "Backchannel-$VERSION.dmg" | tee "Backchannel-$VERSION.dmg.sha256" )

# Installed copies update through Sparkle (app/Sources/Updates.swift): they read
# appcast.xml from the latest release and install the disk image only if its EdDSA
# signature matches the SUPublicEDKey they carry. The private key is in the login
# keychain (Sparkle's generate_keys, account "backchannel"); the first time, macOS asks
# whether sign_update may use it.
SPARKLE="$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"
PUBKEY="$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$APP/Contents/Info.plist")"
[ "$("$SPARKLE/generate_keys" --account backchannel -p)" = "$PUBKEY" ] || {
  echo "The keychain's update key (account backchannel) doesn't match SUPublicEDKey in Info.plist."; exit 1; }
SIGNATURE="$("$SPARKLE/sign_update" --account backchannel "$DMG")"
APPCAST="$ROOT/build/appcast.xml"
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Backchannel</title>
    <item>
      <title>Backchannel $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Backchannel-$VERSION.dmg" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$APPCAST"
echo "Appcast: build/appcast.xml ($SIGNATURE)"

if [ "$PUBLISH" != 1 ]; then
  echo "Built $DMG (not published)."
  exit 0
fi

NOTES="$OUT/notes.md"
{
  echo "Backchannel $VERSION for macOS 26 Tahoe on Apple silicon."
  echo
  echo "Unofficial. Not affiliated with WhatsApp or Meta."
  echo
  echo "Signed with Developer ID and notarized by Apple."
} > "$NOTES"
gh release create "$TAG" "$DMG" "$DMG.sha256" "$APPCAST" -R "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Backchannel $VERSION" --notes-file "$NOTES" --generate-notes
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"

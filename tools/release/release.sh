#!/bin/sh
# A signed, notarized release, published on GitHub. Releases come from GitHub Actions:
#
#   make release VERSION=0.3   # tags v0.3 and pushes the tag; .github/workflows/release.yml runs this
#
# and the same pipeline runs on this Mac too:
#
#   make release-local VERSION=0.3
#   PUBLISH=0 make release-local VERSION=0.3   # everything but the GitHub release
#
# Signing depends on where it runs:
# - SIGNING=keychain (CI): the Developer ID certificate the workflow imported into a
#   throwaway keychain ($KEYCHAIN), then notarytool with an App Store Connect API key
#   (NOTARY_KEY, the .p8 file, with NOTARY_KEY_ID and NOTARY_ISSUER). Apple doesn't let an
#   API key use the cloud-managed Developer ID, hence the certificate. The update key is
#   SPARKLE_PRIVATE_KEY.
# - SIGNING=xcode (here, the default): the Developer ID that Xcode manages in the cloud for
#   the team (the Apple ID under Xcode › Settings › Accounts), notarized through the same
#   account. The update key is in the login keychain (Sparkle's generate_keys, account
#   "backchannel"); the first time, macOS asks whether sign_update may use it.
# Either way the app is stapled, packed into the branded disk image and checked by
# Gatekeeper, and the image is signed for Sparkle and checked against the key the app
# carries. The release goes up with appcast.xml, which installed copies read to find it.
# It's built from a commit on main.
set -eu
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

VERSION="${VERSION:?usage: make release VERSION=0.3}"
TEAM="${TEAM:-2J3WW2KWBU}"
REPO="${REPO:-aritropaul/backchannel}"
PUBLISH="${PUBLISH:-1}"
SIGNING="${SIGNING:-xcode}"
IDENTITY="${IDENTITY:-Developer ID Application}"
TAG="v$VERSION"
OUT="$ROOT/build/release"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# GitHub as the repo's owner, whichever gh account is active (CI passes its token).
GH_TOKEN="${GH_TOKEN:-$(gh auth token --user "${REPO%%/*}" 2>/dev/null || gh auth token)}"
export GH_TOKEN

case "$SIGNING" in
  xcode) ;;
  keychain)
    [ -f "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ] || {
      echo "SIGNING=keychain needs NOTARY_KEY (an App Store Connect .p8), NOTARY_KEY_ID and NOTARY_ISSUER."; exit 1; }
    security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | grep -q "$IDENTITY" || {
      echo "No \"$IDENTITY\" signing identity in the keychain."; exit 1; } ;;
  *) echo "SIGNING is xcode or keychain, not $SIGNING."; exit 1 ;;
esac

if [ "$PUBLISH" = 1 ]; then
  [ -z "$(git status --porcelain)" ] || { echo "Commit your changes first: a release is built from main as pushed."; exit 1; }
  git fetch -q origin main
  if [ "$SIGNING" = keychain ]; then
    # CI builds the pushed tag, which has to be on main.
    git merge-base --is-ancestor HEAD origin/main || { echo "$TAG isn't on main."; exit 1; }
  else
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD isn't origin/main. Push main (or check it out) first."; exit 1; }
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then echo "$TAG is already released."; exit 1; fi
  fi
fi
BUILD="$(git rev-list --count HEAD)"
echo "Backchannel $VERSION ($BUILD), signed through $SIGNING"

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
ARCHIVED="$OUT/Backchannel.xcarchive/Products/Applications/Backchannel.app"
forget "$ARCHIVED" \
  "$OUT/dd/Build/Intermediates.noindex/ArchiveIntermediates/Backchannel/InstallationBuildProductsLocation/Applications/Backchannel.app" \
  "$OUT/dd/Build/Intermediates.noindex/ArchiveIntermediates/Backchannel/InstallationBuildProductsLocation/Applications/Backchannel.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
# Sparkle's Updater.app copies in derived data, likewise.
find "$OUT/dd" -name Updater.app -prune -exec "$LSREG" -u {} \; 2>/dev/null || true

if [ "$SIGNING" = xcode ]; then
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
else
  # Inside out, as Sparkle documents for signing outside Xcode: its XPC services (the
  # downloader keeps its entitlements), Autoupdate, Updater.app, the framework, then the
  # app with its own entitlements. Hardened runtime and a secure timestamp throughout,
  # which notarization requires.
  echo "Signing with ${IDENTITY}…"
  mkdir -p "$OUT/signed"
  ditto "$ARCHIVED" "$OUT/signed/Backchannel.app"
  APP="$OUT/signed/Backchannel.app"
  sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp ${KEYCHAIN:+--keychain "$KEYCHAIN"} "$@"; }
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  sign "$FW/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
  sign --entitlements "$ROOT/app/Backchannel.entitlements" "$APP"
  codesign --verify --deep --strict "$APP"

  echo "Sending to Apple's notary service…"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  set +e
  NOTARY="--key $NOTARY_KEY --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER"
  RESULT="$(xcrun notarytool submit "$OUT/notarize.zip" $NOTARY --wait --timeout 30m 2>&1)"
  STATUS=$?
  set -e
  echo "$RESULT"
  if ! echo "$RESULT" | grep -q "status: Accepted"; then
    ID="$(echo "$RESULT" | awk '$1 == "id:" { print $2; exit }')"
    [ -z "$ID" ] || xcrun notarytool log "$ID" $NOTARY || true
    echo "Not notarized (notarytool exited $STATUS)."
    exit 1
  fi
  xcrun stapler staple "$APP"
fi
forget "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

tools/make_dmg.sh "$APP"
DMG="$ROOT/build/Backchannel-$VERSION.dmg"
( cd build && shasum -a 256 "Backchannel-$VERSION.dmg" | tee "Backchannel-$VERSION.dmg.sha256" )

# Installed copies update through Sparkle (app/Sources/Updates.swift): they read
# appcast.xml from the latest release and install the disk image only if its EdDSA
# signature matches the SUPublicEDKey they carry, so the signature is checked against
# that key here before anything is published (OpenSSL 3; macOS's LibreSSL can't).
SPARKLE="$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE/sign_update" --ed-key-file - "$DMG")"
else
  SIGNATURE="$("$SPARKLE/sign_update" --account backchannel "$DMG")"
fi
OPENSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
[ -x "$OPENSSL" ] || { echo "Checking the update signature needs OpenSSL 3: brew install openssl@3"; exit 1; }
PUBKEY="$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$APP/Contents/Info.plist")"
# An Ed25519 public key in DER: the fixed SubjectPublicKeyInfo prefix, then the 32 key bytes.
{ printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s' "$PUBKEY" | base64 -d; } > "$OUT/update-key.der"
printf '%s' "$SIGNATURE" | sed -E 's/.*edSignature="([^"]+)".*/\1/' | base64 -d > "$OUT/update.sig"
"$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey "$OUT/update-key.der" -rawin -in "$DMG" -sigfile "$OUT/update.sig" >/dev/null || {
  echo "The disk image's update signature doesn't match SUPublicEDKey in Info.plist: wrong update key."; exit 1; }
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
echo "Appcast: build/appcast.xml ($SIGNATURE), checked against SUPublicEDKey"

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
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  # Only CI gets here: a re-run of a tag whose release went up half finished.
  gh release upload "$TAG" "$DMG" "$DMG.sha256" "$APPCAST" -R "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" "$DMG.sha256" "$APPCAST" -R "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Backchannel $VERSION" --notes-file "$NOTES" --generate-notes
fi
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"

#!/bin/zsh
# Builds the download version of Redpen Voice: a signed, notarized Redpen-Voice.dmg that opens on any Mac with macOS 26 or later,
# no Xcode or Homebrew needed. For maintainers; people building from source run ./build.sh instead.
#
# Needs, once:
#   1. A "Developer ID Application" certificate (Xcode > Settings > Accounts > Manage Certificates > +).
#   2. Notary credentials saved under the name "redpen":
#        xcrun notarytool store-credentials redpen --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for an app-specific password from account.apple.com).
#   3. The key that signs updates, saved in this Mac's keychain:
#        .build/artifacts/sparkle/Sparkle/bin/generate_keys
#      It prints the public key; put it in SPARKLE_PUBLIC_KEY in build.sh. Lose the private key and
#      copies already installed can never update again, so back it up (generate_keys -x <file>).
set -e
cd "${0:A:h}"
[[ -f .local.env ]] && source ./.local.env
ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
if [[ -z "$ID" ]]; then
  echo "No Developer ID Application certificate on this Mac. See the note at the top of release.sh."
  exit 1
fi
if ! xcrun notarytool history --keychain-profile redpen >/dev/null 2>&1; then
  echo "No notary credentials named \"redpen\". See the note at the top of release.sh."
  exit 1
fi

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift package resolve >/dev/null
if ! .build/artifacts/sparkle/Sparkle/bin/generate_keys -p >/dev/null 2>&1; then
  echo "No update signing key in this Mac's keychain. See the note at the top of release.sh."
  exit 1
fi
REDPEN_SIGN_ID="$ID" REDPEN_SKIP_INSTALL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/Redpen Voice.app/Contents/Info.plist")
STAGE=build/dmg
rm -rf "$STAGE" "build/Redpen-Voice-$VERSION.dmg"
mkdir -p "$STAGE"
cp -R "build/Redpen Voice.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Redpen Voice" -srcfolder "$STAGE" -format UDZO "build/Redpen-Voice-$VERSION.dmg" >/dev/null
codesign --force --timestamp --sign "$ID" "build/Redpen-Voice-$VERSION.dmg"

echo "Sending to Apple's notary service (a few minutes)..."
xcrun notarytool submit "build/Redpen-Voice-$VERSION.dmg" --keychain-profile redpen --wait
xcrun stapler staple "build/Redpen-Voice-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature -v "build/Redpen-Voice-$VERSION.dmg"
# The update feed. Every copy of Redpen reads it from the latest release, so it lists only this version.
# sign_update signs the download with the private key that `generate_keys` saved in this Mac's keychain.
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "build/Redpen-Voice-$VERSION.dmg")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "build/Redpen Voice.app/Contents/Info.plist")
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Redpen Voice</title>
    <item>
      <title>Redpen Voice $VERSION</title>
      <link>https://github.com/cjaynewton/redpen-voice-mac/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure url="https://github.com/cjaynewton/redpen-voice-mac/releases/download/v$VERSION/Redpen-Voice-$VERSION.dmg" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "Ready: build/Redpen-Voice-$VERSION.dmg and build/appcast.xml"
echo "Publish both as a GitHub release: gh release create v$VERSION build/Redpen-Voice-$VERSION.dmg build/appcast.xml"

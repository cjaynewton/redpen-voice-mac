#!/bin/zsh
# Builds Redpen Voice.app and installs it to ~/Applications.
# Optional, in a .local.env next to this script (not committed):
#   REDPEN_SIGN_ID="Apple Development"       # sign with your certificate so Accessibility survives rebuilds
#   REDPEN_VOICE_BUNDLE_ID="com.example.redpen-voice"
# Installation stops if the installed app's signing team differs, to preserve macOS permissions.
# Match REDPEN_SIGN_ID to the installed app, or explicitly override with REDPEN_FORCE_INSTALL=1.
set -e
cd "${0:A:h}"
# A signing identity passed in (release.sh passes the Developer ID) wins over the one in .local.env.
PASSED_SIGN_ID="$REDPEN_SIGN_ID"
[[ -f .local.env ]] && source ./.local.env
[[ -n "$PASSED_SIGN_ID" ]] && REDPEN_SIGN_ID="$PASSED_SIGN_ID"
BUNDLE_ID="${REDPEN_VOICE_BUNDLE_ID:-io.github.redpen-voice.RedpenVoice}"
SIGN_ID="${REDPEN_SIGN_ID:--}"
# The public half of the key that signs each update (the private half stays in the maintainer's keychain).
SPARKLE_PUBLIC_KEY="W6ZRcpaIC2RR+xBtiP1ixtreKsoX+MptojZaqzyg+ZU="
if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Redpen Voice needs Xcode (free from the Mac App Store). Install it, open it once, then run this again."; exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product RedpenVoice
OUT=.build/out/Products/Release
[[ -d "$OUT" ]] || OUT=.build/release
APP="build/Redpen Voice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$OUT/RedpenVoice" "$APP/Contents/MacOS/RedpenVoice"
# Sparkle, for one-click updates. Not sandboxed, so Sparkle's two helper services for sandboxed apps are left out.
cp -R "$OUT/Sparkle.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# The approved Gloock "r" and three bars (Resources/Icon/icon-source.html is the drawing).
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Redpen Voice</string>
  <key>CFBundleExecutable</key><string>RedpenVoice</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.12.2</string>
  <key>CFBundleVersion</key><string>14</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>SUFeedURL</key><string>https://github.com/cjaynewton/redpen-voice-mac/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Redpen Voice keeps the microphone on while it's open, holding only the last 0.6 seconds in memory so your first word isn't cut. Nothing is kept until you press the talk key.</string>
  <key>NSAudioCaptureUsageDescription</key><string>When a video or song is playing as you start talking, Redpen Voice listens to that app for about a second, to pause it and to take its words off the start of your dictation. It's held in memory only and never saved.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Redpen Voice turns your speech into text on this Mac.</string>
</dict></plist>
PLIST
SP="$APP/Contents/Frameworks/Sparkle.framework"
if [[ "$SIGN_ID" == Developer\ ID* ]]; then
  # A download for other Macs: hardened runtime, a secure timestamp (Apple's notary service requires both), and the
  # one exception the hardened runtime needs here, the microphone. Inside out: Sparkle's helpers, Sparkle, the app.
  for part in "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$part"
  done
  codesign --force --options runtime --timestamp --entitlements Resources/RedpenVoice.entitlements \
    --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
  for part in "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do codesign --force --sign "$SIGN_ID" "$part"; done
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
fi
[[ "$SIGN_ID" == "-" ]] && echo "Note: ad-hoc signed. macOS may ask you to allow Accessibility again after each rebuild."
[[ -n "$REDPEN_SKIP_INSTALL" ]] && exit 0
# Compare actual signatures before touching the installed copy. Ad-hoc and unsigned copies have no team.
signing_team() {
  local details team
  details=$(codesign -dv "$1" 2>&1) || { print -r -- "-"; return; }
  team=$(print -r -- "$details" | sed -n 's/^TeamIdentifier=//p')
  if [[ -n "$team" && "$team" != "not set" ]]; then print -r -- "$team"; else print -r -- "-"; fi
}
INSTALLED_APP="$HOME/Applications/Redpen Voice.app"
if [[ -e "$INSTALLED_APP" ]]; then
  INSTALLED_TEAM=$(signing_team "$INSTALLED_APP")
  BUILD_TEAM=$(signing_team "$APP")
  if [[ "$INSTALLED_TEAM" != "$BUILD_TEAM" ]]; then
    if [[ "$REDPEN_FORCE_INSTALL" != "1" ]]; then
      print -r -- "The installed Redpen Voice is signed by team $INSTALLED_TEAM, this build by team $BUILD_TEAM. Installing it would make macOS forget its permissions. Set REDPEN_SIGN_ID in .local.env to match, or set REDPEN_FORCE_INSTALL=1."
      exit 1
    fi
    print -r -- "REDPEN_FORCE_INSTALL=1: installing despite signing team change ($INSTALLED_TEAM to $BUILD_TEAM)."
  else
    print -r -- "Signing team matches installed Redpen Voice ($BUILD_TEAM)."
  fi
fi
mkdir -p ~/Applications
rm -rf ~/Applications/"Redpen Voice.app"
cp -R "$APP" ~/Applications/"Redpen Voice.app"
echo "Installed ~/Applications/Redpen Voice.app"
if pgrep -x RedpenVoice >/dev/null; then
  # Never restart while a dictation or a test recording is in flight: the log's last line says which.
  LOG=~/Library/Logs/RedpenVoice.log
  for i in {1..120}; do
    last=$(tail -1 "$LOG" 2>/dev/null)
    [[ "$last" == *"recording from"* || "$last" == *"test: recording"* ]] || break
    sleep 1
  done
  # A rebuild is a normal quit: leave the note so the crash watchdog doesn't reopen the old copy.
  for p in $(pgrep -f "$HOME/Applications/Redpen Voice.app/Contents/MacOS/RedpenVoice" ); do
    touch "$HOME/Library/Application Support/Redpen Voice/clean-quit-$p"
  done
  pkill -f "$HOME/Applications/Redpen Voice.app/Contents/MacOS/RedpenVoice"; sleep 1; open ~/Applications/"Redpen Voice.app"; echo "Restarted"
fi

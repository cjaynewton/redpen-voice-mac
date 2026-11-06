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
# Better summary on this Mac (D-1010) runs on Apple's MLX, whose GPU code is compiled with Xcode's Metal Toolchain,
# a separate download from Apple since Xcode 26.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Redpen Voice needs Xcode's Metal Toolchain. Run: xcodebuild -downloadComponent MetalToolchain, then run this again."; exit 1
fi
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
# MLX's compiled GPU code (default.metallib), found in Resources at run time, and the tokenizers' bundle, whose
# accessor stops the app if the bundle is missing (D-1010).
if [[ ! -f "$OUT/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  echo "MLX's GPU code wasn't built ($OUT/mlx-swift_Cmlx.bundle). Build with Xcode's Swift Build and its Metal Toolchain."; exit 1
fi
cp -R "$OUT/mlx-swift_Cmlx.bundle" "$OUT/swift-transformers_Hub.bundle" "$APP/Contents/Resources/"
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
  <key>NSMicrophoneUsageDescription</key><string>Redpen Voice keeps the microphone on while it's open, holding only the last 0.6 seconds in memory so your first word isn't cut. Nothing is kept until you press the talk key. When you start meeting notes, it records your microphone and saves it in your meetings folder on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key><string>When a video or song is playing as you start talking, Redpen Voice listens to that app for about a second, to pause it and to take its words off the start of your dictation. That is held in memory only and never saved. When you start meeting notes, it records what the Mac plays and saves it in your meetings folder on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>When a Chrome video is playing as you start talking, Redpen Voice asks that tab to pause it, and plays it again when you stop. With several video tabs open, the play/pause key can start the wrong one.</string>
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
# Never replace or restart the app while Cedric is talking to it. Reads the log since the app last launched:
# a dictation, test recording or meeting that started and hasn't ended yet means busy. A dictation only counts
# while the log is still being written (hands-free writes every few seconds), so a missed end line can't block
# installs for long. Recording and summary state are separate, so an older summary cannot clear a new recording.
# A summary stays busy for six minutes of log silence, longer than the helper's five-minute limit.
voice_busy() {
  local log=~/Library/Logs/RedpenVoice.log
  pgrep -x RedpenVoice >/dev/null && [[ -f $log ]] || return 0
  local age=$(( $(date +%s) - $(stat -f %m "$log") ))
  awk -v age="$age" '
    / launched [0-9]/ { dictation = 0; recording = 0; summary = 0 }
    / recording from / || / test: recording to / { dictation = 1 }
    / dictation [0-9]+s, / || / cancelled: / || / no words, / || / test: saved / || / test: cannot / { dictation = 0 }
    / meeting: recording, / { recording = 1 }
    / meeting: stopped, / { recording = 0; summary = 1 }
    / meeting: (summary from|summary failed|notes saved|notes failed|notes save failed)/ { summary = 0 }
    / meeting: (could not start|mic failed)/ { recording = 0 }
    END {
      if (recording) print "meeting notes"
      else if (summary && age < 360) print "a meeting summary"
      else if (dictation && age < 120) print "a dictation"
    }
  ' "$log"
}
busy=$(voice_busy)
if [[ -n "$busy" && "$REDPEN_INSTALL_WHILE_RECORDING" != "1" ]]; then
  echo "Redpen Voice is in the middle of $busy. Waiting up to a minute for it to finish..."
  for i in {1..60}; do sleep 1; busy=$(voice_busy); [[ -z "$busy" ]] && break; done
  if [[ -n "$busy" ]]; then
    echo "Built but NOT installed: Redpen Voice is still in the middle of $busy. Run this again when it's done (or set REDPEN_INSTALL_WHILE_RECORDING=1)."
    exit 0
  fi
fi
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
# Signing and the earlier wait take time. Re-check immediately before replacing the installed app.
busy=$(voice_busy)
if [[ -n "$busy" && "$REDPEN_INSTALL_WHILE_RECORDING" != "1" ]]; then
  echo "Built but NOT installed: Redpen Voice started $busy before replacement. Run this again when it's done."
  exit 0
fi
rm -rf ~/Applications/"Redpen Voice.app"
cp -R "$APP" ~/Applications/"Redpen Voice.app"
echo "Installed ~/Applications/Redpen Voice.app"
if pgrep -x RedpenVoice >/dev/null; then
  # The busy check above already waited for any dictation or meeting to finish before the copy was replaced.
  # A rebuild is a normal quit: leave the note so the crash watchdog doesn't reopen the old copy.
  for p in $(pgrep -f "$HOME/Applications/Redpen Voice.app/Contents/MacOS/RedpenVoice" ); do
    touch "$HOME/Library/Application Support/Redpen Voice/clean-quit-$p"
  done
  pkill -f "$HOME/Applications/Redpen Voice.app/Contents/MacOS/RedpenVoice"; sleep 1; open ~/Applications/"Redpen Voice.app"; echo "Restarted"
fi

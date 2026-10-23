#!/bin/zsh
# Builds Redpen Voice.app and installs it to ~/Applications.
# Optional, in a .local.env next to this script (not committed):
#   REDPEN_SIGN_ID="Apple Development"       # sign with your certificate so Accessibility survives rebuilds
#   REDPEN_VOICE_BUNDLE_ID="com.example.redpen-voice"
set -e
cd "${0:A:h}"
[[ -f .local.env ]] && source ./.local.env
BUNDLE_ID="${REDPEN_VOICE_BUNDLE_ID:-io.github.redpen-voice.RedpenVoice}"
SIGN_ID="${REDPEN_SIGN_ID:--}"
if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Redpen Voice needs Xcode (free from the Mac App Store). Install it, open it once, then run this again."; exit 1
fi
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product RedpenVoice
APP="build/Redpen Voice.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RedpenVoice "$APP/Contents/MacOS/RedpenVoice"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Redpen Voice</string>
  <key>CFBundleExecutable</key><string>RedpenVoice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Redpen Voice listens while you hold the key, and only then.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Redpen Voice checks for a split second whether a video or song is playing, so it can pause it while you talk. Nothing is recorded or kept.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Redpen Voice turns your speech into text on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
[[ "$SIGN_ID" == "-" ]] && echo "Note: ad-hoc signed. macOS may ask you to allow Accessibility again after each rebuild."
[[ -n "$REDPEN_SKIP_INSTALL" ]] && exit 0
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
  pkill -f "$HOME/Applications/Redpen Voice.app/Contents/MacOS/RedpenVoice"; sleep 1; open ~/Applications/"Redpen Voice.app"; echo "Restarted"
fi

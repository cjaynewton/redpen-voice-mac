# Project notes

## 2026-10-29 [codex] Hands-free media pause collision

- A second tap can arrive during the first tap's 0.25-second SoundTap listen. Returning nil when busy made the second press skip pause, while the first press's result belonged to its cancelled session.
- SoundTap now queues overlapping listens through VoiceCore's MediaListenQueue. Busy never produces a loudness result. Each request keeps its own recording and callback, and the next listen starts after the previous tap is destroyed.
- The same queue prevents resume checks from being dropped as failed and waitForQuiet checks from treating contention as quiet. Actual tap failure still skips resume. The 0.3-second pause guard and D-817 media-audio removal path remain unchanged.
- Verification used `swift run -c release redpen-voice-test` with 183 passed, 0 failed, then `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; ./build.sh`. Live video playback was not exercised because the brief prohibited playing media or pressing media keys.

## 2026-10-29 [codex] Extra taps after stopping hands-free

- Confirmed the 04:35 and 04:45 log sequences against HoldKey and end(). A new quick press advanced delivery, then cancel() dropped its session without giving delivery back, so the previous dictation was incorrectly kept for paste. The same path applies after an ordinary hold.
- DictationDelivery now separates insertion ownership from the monotonically increasing microphone press. A cancelled press shorter than HoldKey's existing 0.4-second threshold restores the prior delivery and its paused draft checks. If finishing beats that tap's release, insertion waits for the remaining classification time and re-checks. Real holds still record immediately; double-tap start is unchanged.
- The log explicitly says `hold key: tap after stop ignored; finishing dictation keeps its insertion`. The HUD also finishes when every live piece was already typed, limits click-wait messages to three seconds, and prevents older completion messages from replacing a newer dictation's bar.
- Verification used `swift run -c release redpen-voice-test` with 203 passed, 0 failed (20 new delivery checks), then `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; ./build.sh`. Installed and built executable hashes match, strict deep signature verification passes, and the restarted app log reports the Whisper engine ready and the Scarlett mic warm. Live gesture/audio insertion was not exercised, per the brief. Existing compiler warnings were left unchanged.

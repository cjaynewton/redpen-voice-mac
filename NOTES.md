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

## 2026-10-29 [codex] Starting-box fingerprint and own draft edits

- Live diagnostics narrowed an observed miss to the text value. At 06:10:30 UTC the same AX element and actual window matched, title and conversation URL were unchanged, but the expected text had 1 UTF-16 unit and the current value had 30. No Voice draft had been typed in that session. Historical logs did not record individual fingerprint fields, so they cannot identify each older miss.
- Read-only AX inspection confirmed T3 exposes a thread-specific `t3code://app/#/...` URL. The matcher now checks that URL independently of the window title, checks the actual AX window, tolerates the same element growing/moving, and allows small geometry changes for recreated elements. Without a URL, a changed title remains ambiguous and is held for paste.
- The expected full value advances only through known Voice insertions and draft replacements, including edits in the middle of a box and UTF-16 ranges. Sent/cleared, user-edited, and different-conversation boxes fail. Hardware typing in the captured box also invalidates delivery, including a message typed and sent after starting from empty. Diagnostics name failed and changed fields and lengths, never message text or URLs.
- Follow-up outside this brief: `defaults read com.apple.HIToolbox AppleFnUsageType` returned `3`. Existing `FnKey.swift` identifies that as Fn also starting Apple's dictation. Competing system dictation is a plausible cause of text changing before Voice types, but was not directly observed and no system setting was changed.
- Verification: `swift run -c release redpen-voice-test` passed 226 checks, 0 failed (23 added), then the requested Xcode `./build.sh` installed and restarted Voice. Installed/build executable SHA-256 values match; strict deep signature verification passes. No app windows were shown and no keys/media were triggered by this work. Live log observations came from Cedric's existing work.

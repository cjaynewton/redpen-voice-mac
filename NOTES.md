# Project notes

## 2026-10-29 [codex] Hands-free media pause collision

- A second tap can arrive during the first tap's 0.25-second SoundTap listen. Returning nil when busy made the second press skip pause, while the first press's result belonged to its cancelled session.
- SoundTap now queues overlapping listens through VoiceCore's MediaListenQueue. Busy never produces a loudness result. Each request keeps its own recording and callback, and the next listen starts after the previous tap is destroyed.
- The same queue prevents resume checks from being dropped as failed and waitForQuiet checks from treating contention as quiet. Actual tap failure still skips resume. The 0.3-second pause guard and D-817 media-audio removal path remain unchanged.
- Verification used `swift run -c release redpen-voice-test` with 183 passed, 0 failed, then `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; ./build.sh`. Live video playback was not exercised because the brief prohibited playing media or pressing media keys.

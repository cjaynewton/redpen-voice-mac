# Voice bar clicks and idle visibility

Implementation for the Nov 12 brief and Cedric's fourth-fix addition. Build and test only.

- Branch `t3/bar-click-fixes`.
- Base `t3/combined-2026-11-12`, `8cd81f30786faeb4134b69a95d63fb678d6ec7cc`.
- Worktree `/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes`.
- Implementation commit is recorded in the final handoff message. No install, push, merge, tag or release. `build.sh` was never run. No `.local.env` copy was needed.

## Result

1. Every local mouse down in Voice, including its bar, native buttons and menus, records its uptime and button. Hardware samples ignore matching own-window downs within 50 ms. Real external clicks remain recorded even after a later own-window click becomes the newest HID event. The asynchronous guard gives the local monitor the same two 5 ms turns used for delayed input evidence. Real keys still stop typing.
2. A real click can finish the draft already being posted only in the same unsent text box, with no user edit, selection or moved caret, and an exact read of the prefix posted so far. Otherwise posting stops. `Insert.typedCount` bounds the recoverable UTF-16 prefix. Reconciliation adopts only that literal prefix at its recorded position, with unchanged surrounding text and the existing element, window, conversation, cursor and send checks. Incomplete arrivals, extra spaces, edits and invalid UTF-16 boundaries are refused.
3. Stopped or paused typing no longer shows a sentence above the bar. The listening timer and signal remain, and the word count is retained for Writing. The corresponding stopped-typing sentence during Writing is also suppressed. Clicks are recorded as clicked, rather than typed. Paste-last, no-sound, suggestion and recovery messages remain.
4. Idle hides the panel by default. Done retains its existing 300 ms tick settle and 450 ms fade, then hides. Flash expiry and paste-notice dismissal use the same idle behavior. The listening menu adds `Keep bar on screen`, off by default and saved as optional `Config.keepBarOnScreen`. On restores the previous Resting tab. Drag position remains in `talkingBarPositionR3`, and the existing initial-show ordering path remains immediate.

## Changes by file

| File | Change |
| --- | --- |
| [Sources/VoiceCore/OwnWindowClicks.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/VoiceCore/OwnWindowClicks.swift) | Bounded, locked own-window timestamp ledger and button-aware 50 ms matching. |
| [Sources/VoiceCore/DraftSafety.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/VoiceCore/DraftSafety.swift) | Own-click filtering, sticky external-click evidence and bounded listener reconciliation. |
| [Sources/VoiceCore/DictationEnding.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/VoiceCore/DictationEnding.swift) | Explicit posted-prefix record and literal reconciliation for keyboard delivery. Existing AX-attempt reconciliation retained. |
| [Sources/RedpenVoice/Insert.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/RedpenVoice/Insert.swift) | Exact prefix from posted UTF-16 count, continuation proof at the original caret, and filtered finishing guards. |
| [Sources/RedpenVoice/main.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/RedpenVoice/main.swift) | Own/local and external click monitors, draft/ending guard wiring, click reason, and saved idle preference wiring. |
| [Sources/RedpenVoice/HUD.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/RedpenVoice/HUD.swift) | Hidden idle default, optional Resting tab, caption suppression, menu toggle and expanded native capture/behavior checks. |
| [Sources/RedpenVoice/TalkingBarView.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/RedpenVoice/TalkingBarView.swift) | Listening menu row, its space and separator placement. |
| [Sources/RedpenVoice/Config.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/RedpenVoice/Config.swift) | Optional backward-compatible `keepBarOnScreen`, interpreted as false when absent. |
| [Sources/redpen-voice-test/BarClickChecks.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/redpen-voice-test/BarClickChecks.swift) | 34 pure checks for clicks, exact posted prefixes, the synthetic incident ending and sent-box protection. |
| [Sources/redpen-voice-test/main.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/Sources/redpen-voice-test/main.swift) | Runs the new pure checks. |
| [tools/bar-click-harness.swift](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/tools/bar-click-harness.swift) | Synthetic editor/input fixtures for actual production draft guard and insertion adapters. |
| [tools/check-first-words.py](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/tools/check-first-words.py) | Extracts and executes the production guards with those fixtures; adds wiring checks and shared pure tests. |
| [NOTES.md](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/NOTES.md) | Appended implementation and verification facts in this worktree only. |
| [artifacts/bar-click-fixes/](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/artifacts/bar-click-fixes) | Logs, invariant comparison, native captures, verification JSON and this report. |

## Verification

All commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

| Check | Result |
| --- | --- |
| `swift run -c release redpen-voice-test` | 1,822 passed, 0 failed, up from 1,788. |
| [python3 tools/check-first-words.py](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/python3 tools/check-first-words.py) | 669 passed, up from 605. Includes 113 source contracts and 556 synthetic runtime checks. |
| `swift test` | 5 passed, 0 failed. |
| `swift build -c release --product RedpenVoice` | Passed on the final source. |
| [python3 tools/package-review-app.py](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/python3 tools/package-review-app.py) | Passed, including strict deep signature verification of the local review bundle. |
| Review app `--talking-bar-shots artifacts/bar-click-fixes/screenshots` | 280 passed, 0 failed, up from 251. Saved 41 captures. |
| `git diff --check` | Passed. |

The integration checks execute production `draftQuiet`, `draftBlocked`, `Insert.text`, continuation proof, replacement and finishing insertion against inert input and editors. They cover delayed own-click classification, real clicks in the same box, moved caret/selection, focus loss, keys, sends, conversation changes, cancellation and a newer dictation. The 06:00:44 case uses invented words and proves that the exact posted prefix can be replaced by the full ending without touching the original heading. It is a synthetic replay, not a replay against live T3.

`FinishInBox.swift` is byte-identical to the base. The bodies of both app/core `wasSent`, core `looksSent` and `typesNow` are identical. See [safeguards.txt](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/bar-click-fixes/artifacts/bar-click-fixes/safeguards.txt).

The native capture entry point runs before AppDelegate construction, with a separate preferences suite and test log. It starts no microphone, ASR or media operations and posts no input. Most checks render offscreen. One brief nonactivating review-panel ordering check verifies that `rest()` actually orders a visible panel out. The review process shuts itself down. The installed app was not launched, quit or restarted.

The four `*-hidden.png` files are transparent state renderings, backed by visibility checks. They are not desktop screenshots. Resting captures show the explicit opt-in setting. The menu, stopped-typing and hidden-state images were visually inspected; the added row's separator was corrected and now has a regression check.

Saved log copies have trailing whitespace trimmed from compiler excerpts. Evidence is saved alongside this report in `core.log`, `integration.log`, `swift-test.log`, `build.log`, `package.log`, `native.log` and `screenshots/verification.json`.

## Open risks and handoff

- Real T3/Chrome insertion, physical bar dragging, loaded-machine event timing and cross-display behavior remain untested. The exact-read safeguards intentionally keep the words for Paste last if the box cannot be proved.
- No speech-accuracy or end-to-end latency result is claimed. The change does not address the separate Chrome pause duration or add new bar sizing behavior.
- Existing Swift concurrency/deprecation warnings remain in unrelated code and test infrastructure. The release build and required tests pass.
- Owner review is pending. An install would require Cedric's separate authorization and the usual handshake. This report grants none.

Nothing from this implementation is left running after checks finish. Saved in the isolated worktree. No action is needed from Cedric while the owner reviews it.

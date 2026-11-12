# Talking bar round 3 implementation

Built and tested only. Ready for lead review, not approved for installation or release.

Branch `t3/talking-bar-r3` in the Swift repository. Base `54e308862e7201dcf6966a349dbe8f90701d5352` (`resume-fix`, the installed build). Worktree is `/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3`.

Implemented by Codex, GPT-6 Astra at high effort. No delegated work or web research was used. The approved HTML, RESULT-r3.md, LOOK.md, supplied R3 shots and existing source were the references.

## What changed

| File | Change |
| --- | --- |
| Sources/RedpenVoice/HUD.swift | One native nonactivating panel for Resting, Listening, Writing, Needs you, Done, messages and an upward-growing menu. Preserves flash text, captions, progress, stopped-typing reasons, word suggestions and Copy/Throw away callbacks. Adds saved drag position, display-removal recovery, dismissal, reduced motion and isolated captures. |
| Sources/RedpenVoice/TalkingBarView.swift | Native drawing and buttons, the six-square grip, square corners, Instrument Sans, Raised #25272B, brighter #EF5045 only in the signal, all five styles, neutral microphone/tick and menu. |
| Sources/VoiceCore/TalkingBar.swift | State dimensions and whole-window clamping to one surviving display, including negative coordinates and gaps between displays. |
| Sources/RedpenVoice/HoldKey.swift | Nine-line UI entry point that calls the existing start, confirm and hands-free callbacks. Does not post any key. |
| Sources/VoiceCore/TalkKeyState.swift | Nine-line mouse-start entry to the existing confirmed hands-free state. The configured talk key can finish it. Existing key transitions are unchanged. |
| Sources/RedpenVoice/main.swift | Callback wiring at setup, Esc dismissal before the existing Esc-twice route, and the isolated capture command before AppDelegate construction. No ending-code edits. |
| Sources/redpen-voice-test/main.swift | 29 focused checks of display geometry and the mouse-start/key-finish state path. |
| Resources/Fonts/InstrumentSans-*.ttf | Approved regular and medium font files copied from the iPhone source, with its OFL and provenance. No system font installation. |
| tools/package-review-app.py | Packages and ad hoc signs a separate local review app from release products. Does not build, install or start it. |
| NOTES.md | Append-only implementation and verification record. |

MenuPanel.swift did not need a visual rewrite. The talking bar has its own menu in the same panel. Its callback wiring also dismisses the existing menu-bar popover. Insert.swift, capture/recognition, typing and media implementations are unchanged.

## Verification

- Original baseline on the supplied base, Xcode toolchain. **1,688 passed, 0 failed**.
- Final `swift run -c release redpen-voice-test`. **1,717 passed, 0 failed**.
- Final native HUD harness. **251 passed, 0 failed**. It renders the actual native view and checks sizes, opaque square corners, encoded surface colour, red confined to the signal, native button dispatch, first-click acceptance, no focus taking, dismissal, message preservation, count handling, silence recovery, Done timing, stale completion cancellation, long-name wrapping and position persistence across HUD instances.
- `swift build -c release --product RedpenVoice` succeeded with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `codesign --verify --deep --strict 'build/Redpen Voice Review.app'` succeeded.
- `git diff --check` passed. The build has existing warnings outside the changed HUD/control files. No new warnings were reported in those files.
- **36 native PNG captures**, all at 2x. A separate comparison image places cropped approved shots beside the native versions. The comparison enlarges the 1x reference crops, so those look softer.

The harness runs before AppDelegate exists. It uses an isolated temporary preferences suite and no input monitors. No microphone, ASR, real typing, media operation, update check or installed-app launch was exercised. It never posts the synthetic test events.

## Match and deliberate limits

- Canonical closed sizes match the spec. Resting 182x40, Listening 314x52, Writing 282x52, Needs you 328x52, Done 78x40. Dot uses 142, 174 and 306 widths. Menu sizes are 236x177 at rest and 314x217 while listening.
- The surface stays #25272B. The red is #EF5045, the brighter round-2 value chosen in D-1566, overriding LOOK.md's darker #C42B23. No red identity dot or nib was added. The optional dot line style remains available.
- Existing captions and warnings can add a wrapped area above the rail. This is intentional preservation of existing messages, which the compact mockup does not contain. Very long microphone names use that same area, rather than colliding with the arrow or leaving the screen.
- The unsupported `⌥M` hint is omitted from Meeting notes. The button opens the existing notes action. No new system-wide shortcut was introduced by this visual change.
- Finish and Cancel are disabled when no capture is active, including Writing. The existing ending implementation does not offer cancellation at that point. This avoids a menu action that claims to cancel a committed ending.
- AppKit supplies the window shadow. The cropped offscreen PNGs do not include the compositor's external shadow. They are native view renders, not screenshots of the installed app over a real chat window.
- Live waveforms follow microphone levels and history. Their exact sample shape differs from the HTML's invented audio. Writing uses the specified settling pen path and real counts already supplied through HUD captions; it does not invent a rising counter.

## Open risks for review

No live dictation or insertion acceptance is claimed. Test click-start, Fn stop, menu Finish, Esc, media resumption and target focus during the separately authorized integration trial. Display removal is covered by synthetic three-display geometry, not an actual cable disconnect. Motion and shadows should also be inspected in the running app. The renderer implements 280ms shape changes, 260ms content settling after 60ms, the 850ms pen draw, breathing silence and the 300ms/450ms Done sequence, with reduced motion support.

The parallel box fix must integrate the three small main.swift hunks. Its ending code was not edited here. The new mouse control entry should be included in the lead's integration review because it exposes an existing hands-free path through a new control.

## Reproduce without installing

From this worktree:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run -c release redpen-voice-test
swift build -c release --product RedpenVoice
```

The saved local review app is `/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/build/Redpen Voice Review.app`. Its bundle identity is `io.github.redpen-voice.talking-bar-review`, ad hoc signed, with automatic update checks disabled. The packaging script expects its output not to exist. `build.sh` was not run and `.local.env` was not needed.

Run only its isolated capture mode for this verification:

```sh
'build/Redpen Voice Review.app/Contents/MacOS/RedpenVoice' --talking-bar-shots artifacts/talking-bar-r3
```

## Evidence and screenshots

- [Before and after comparison](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/comparison.png)
- [Native verification and capture dimensions](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/verification.json)
- [Core test log](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/core-tests.log)
- [Native test log](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/native-tests.log)
- [Build log](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/build.log)

Every native screenshot path follows. These are local files, not published previews.

- [r3-pen-resting.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-pen-resting.png)
- [r3-pen-listening.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-pen-listening.png)
- [r3-pen-writing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-pen-writing.png)
- [r3-pen-needs.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-pen-needs.png)
- [r3-pen-done.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-pen-done.png)
- [r3-bars-resting.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-bars-resting.png)
- [r3-bars-listening.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-bars-listening.png)
- [r3-bars-writing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-bars-writing.png)
- [r3-bars-needs.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-bars-needs.png)
- [r3-bars-done.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-bars-done.png)
- [r3-tape-resting.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-tape-resting.png)
- [r3-tape-listening.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-tape-listening.png)
- [r3-tape-writing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-tape-writing.png)
- [r3-tape-needs.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-tape-needs.png)
- [r3-tape-done.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-tape-done.png)
- [r3-dot-resting.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-dot-resting.png)
- [r3-dot-listening.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-dot-listening.png)
- [r3-dot-writing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-dot-writing.png)
- [r3-dot-needs.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-dot-needs.png)
- [r3-dot-done.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-dot-done.png)
- [r3-classic-resting.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-classic-resting.png)
- [r3-classic-listening.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-classic-listening.png)
- [r3-classic-writing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-classic-writing.png)
- [r3-classic-needs.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-classic-needs.png)
- [r3-classic-done.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-classic-done.png)
- [r3-menu-resting.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-menu-resting.png)
- [r3-menu-listening.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-menu-listening.png)
- [r3-recovery-question.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-recovery-question.png)
- [r3-word-suggestion.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-word-suggestion.png)
- [r3-warning.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-warning.png)
- [r3-progress.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-progress.png)
- [r3-caption.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-caption.png)
- [r3-stopped-typing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-stopped-typing.png)
- [r3-writing-note.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-writing-note.png)
- [r3-long-mic-name.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-long-mic-name.png)
- [r3-reduced-motion-writing.png](/Users/cnatkinson/Developer/Redpen-Suite/Voice/code/.claude/worktrees/talking-bar-r3/artifacts/talking-bar-r3/r3-reduced-motion-writing.png)

Saved in this worktree. No service or review app is left running. No install, merge, push, tag or release was performed. Lead review is the next step; Cedric has no action for this implementation handoff.

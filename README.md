<img src="docs/icon.png" alt="Redpen Voice app icon" width="96" height="96">

# Redpen Voice for Mac

A free, private dictation app for macOS, from the Redpen family of writing tools. Hold a key, talk, let go, and your words land where the cursor is, in almost any app.

Everything runs on your Mac. Your voice is never sent anywhere.

**[Download Redpen Voice for Mac](https://github.com/cjaynewton/redpen-voice-mac/releases/latest)** (free, macOS 26, Apple silicon)

<p align="center">
  <img src="docs/screenshots/bar-live.png" alt="The talking bar at the bottom of the screen: a red pen line moving with your voice, the time, and your words as you say them" width="514">
</p>

## How it works

1. **Hold Fn or right Option and talk.** A small bar at the bottom of the screen moves with your voice, so you know it's listening. With the Instant engine, your words show in it as you talk.
2. **Let go.** The words go into the box you started in, without touching your clipboard. If Voice can't see them arrive, the bar says so. Click into a text box and press Control-Option-V to paste them.

   <img src="docs/screenshots/bar-typed.png" alt="The bar after letting go: a green tick and Typed into Notes, where you started" width="287">

3. **Moved somewhere else while it wrote?** Voice checks the box you started in. If that box still matches, the words go there when the app allows it, or wait until you return. If the box changed or Voice can't be sure, Paste last keeps the words.

   <img src="docs/screenshots/bar-saved.png" alt="The bar saying the words are saved for Chrome and go in when you are back in that box, or with Control-Option-V" width="612">

Tap the talk key twice to start hands-free. Tap once to stop. Extra taps just after stopping, or while the words are still being written, are ignored. If the Mac misses a key release, Voice checks whether the key is really up and ends the hold.

### Pick the bar you like

<table>
<tr>
<td valign="top"><img src="docs/screenshots/bar-pen.png" alt="Red pen line" width="236"><br><b>Red pen line</b><br>A pen line that moves with your voice, and the time.</td>
<td valign="top"><img src="docs/screenshots/bar-tape.png" alt="Rolling tape" width="270"><br><b>Rolling tape</b><br>Your voice scrolling past, with a recording dot.</td>
</tr>
<tr>
<td valign="top"><img src="docs/screenshots/bar-bars.png" alt="Bars from the middle" width="162"><br><b>Bars from the middle</b><br>Bars that grow from the centre.</td>
<td valign="top"><img src="docs/screenshots/bar-classic.png" alt="Classic bars" width="160"><br><b>Classic bars</b><br>A level meter, like a recorder.</td>
</tr>
<tr>
<td valign="top"><img src="docs/screenshots/bar-dot.png" alt="Breathing dot" width="112"><br><b>Breathing dot</b><br>Just a dot that breathes, and the time.</td>
<td valign="top">Or turn the bar off in Settings.</td>
</tr>
</table>

## What it does

- **Any key you like.** Fn, right Option, or a key you pick in Settings.
- **Words appear as you talk.** With Instant, your words show in the bar while you talk and go into the box right after you let go. With Whisper, each stretch is written at your next pause, so a one-minute dictation lands about 2 seconds after you stop; in a text box the words are typed as you go.
- **Your words, as said.** By default nothing is rewritten. Two switches change that:
  - **Take out ums and uhs** removes only the sounds. Every word stays.
  - **Tidy it up** also takes out repeats and false starts and fixes punctuation, using Apple's on-device model. It can change a word now and then.
- **Three engines, named for what they do.**
  - **Most accurate** is Whisper, OpenAI's model: the fewest mistakes, words about 2 seconds after you stop, a one-time 626 MB download.
  - **Instant** is Parakeet Unified, NVIDIA's model: it writes while you talk, so there's no wait for writing (about 0.05 seconds), with about 1 more word in 100 wrong than Whisper. It is English only and weaker when other people talk over you. It needs a one-time 600 MB download.
  - **Mac built-in** is Apple's engine, built into macOS (if the speech files for your language aren't on the Mac yet, they download from Apple once), with the most mistakes of the three.
- **Words it gets wrong.** A plain list, one per line. `claw code = Claude Code` fixes what it hears. A name on its own keeps that spelling when the engine hears it. For Whisper, you can also turn on spelling hints in Settings; these can add to the wait.
- **Learns your names.** Fix a name by hand after a dictation ("so well" to "Sowell") and the second time you make the same fix, it goes into your list. Only names and terms are learned, never everyday words, and the list stays a plain file you can edit.
- **Learns how you talk.** Like a driving app that learns how you drive, it learns your pace and how long you pause, and uses that to decide where a thought ends. Only the numbers are kept.
- **Goes back to the box you started in.** Voice checks the window, the conversation when the app exposes it, and the text it expects in that box. The same chat box can grow or move while you talk. If you switch apps, words go straight into the original box when that app allows it, or wait until you return. If you edited or sent the box, or Voice can't tell whether it still matches, Paste last has the words. On a web page or video, nothing is typed there. Voice asks you to click into a box. If there is no typing target, the bar says the words are kept for Control-Option-V.
- **Fits the sentence.** Dictate into the middle of a sentence and the first word starts lowercase ("and then and we go"), except "I" and names from your list; right before a word, the closing full stop goes. Only in boxes that tell Voice what's around the cursor.
- **Paste last.** Click into a text box, press Control-Option-V, then release the keys. Voice waits for the keys to come up, pastes, and checks for the words or the expected cursor movement. The bar says "Pasted" only after that check. If it can't confirm the paste, it says so and leaves the words on the clipboard for Command-V, unless you copied something new meanwhile. Paste last dictation in the menu uses the same check. Dictations are also in History for as long as you choose to keep them.
- **Take it back.** Control-Option-Z removes the last dictation, only when it is still the last thing typed.
- **Pauses your music and video** when you hold to talk or start hands-free, only when something is actually playing. It starts them again after the words are finished. Turn off "Play again when I stop talking" in Settings to leave them paused.
- **Transcribe a file.** Turn an audio or video file the Mac can read into text, saved beside the file, or on the Desktop if that folder can't be written to.

## The menu

Click the Voice icon in the menu bar for today's words, your speed and the minutes they saved you, with an all-time line under them; the two switches; Paste last dictation, History, Stats, Transcribe a file, Settings and Check for updates.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-dark.png">
  <img src="docs/screenshots/menu-light.png" alt="The menu bar panel with sample numbers: status, words today, speed and minutes saved, an all-time line, two switches, paste last dictation, history, stats, transcribe a file, settings, check for updates" width="300">
</picture>
</p>

## Settings

Every choice on one page: the engine, how your words come out, the key you talk with, your microphone, the bar, your list of words it gets wrong, and your typing speed for time saved. Settings shows a real sentence heard by Whisper and the Mac built-in engine, so you can compare them before downloading Whisper.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-dark.png">
  <img src="docs/screenshots/settings-light.png" alt="Settings with sample numbers for time saved: engines named Most accurate, Instant and Mac built-in, what you get, talking, words it gets wrong, and what is kept on this Mac" width="360">
</picture>
</p>

## The first time you open it

One window, three parts, and Done waits until each one works:

1. **How your words come out:** raw, ums taken out, or tidied.
2. **Set up:** the microphone, with its name and a live level so a silent or wrong mic shows now; Accessibility, so it can type into other apps and see your talk key; the speech engine, ready before you start; and, if you talk with Fn, the Mac's own Fn setting, which has to be off (or switch to right Option).
3. **Try it:** say one sentence into the window and see your own words before you leave.

The setup buttons open the matching Microphone, Accessibility or Keyboard page in System Settings. If you use Fn, set "Press 🌐 key to" to Do Nothing in Keyboard settings. Otherwise a double tap can start Apple's dictation too, or open the emoji picker, depending on that setting.

macOS also asks for:

- **Speech Recognition**, when the app first opens, for Apple's own engine.
- **System audio**, the first time a video or song is playing when you start talking, so Voice can tell it's playing and take its words off the start of your dictation.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/firstrun-dark.png">
  <img src="docs/screenshots/firstrun-light.png" alt="First run: how your words come out, then the microphone with its level, Accessibility and the speech engine, then a practice sentence shown in the window" width="480">
</picture>
</p>

## History

Every dictation, newest first: search them, copy one, delete one. Choose how long they're kept: the last 2,000, the last week, or nothing at all. Open it from the menu.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/history-dark.png">
  <img src="docs/screenshots/history-light.png" alt="The history window: search, then each dictation with its time, the app it went into, Copy and Delete, and a Keep choice" width="480">
</picture>
</p>

## Stats

This week, the last 30 days and all time show your words, minutes saved, average speed and number of dictations. Below them are your words a day for the last 30 days and your speed over time.

**Fun facts** compares your all-time words with books, shows your longest day by word count, and adds up your total talking time. The book comparisons are rounded and always say "about". The [word counts and sources](docs/book-word-counts.md) come from specific Standard Ebooks editions. Your longest day combines all engines used that day.

Minutes saved are compared with typing at 40 words a minute; set your own typing speed in Settings. Open Stats from the menu. Stats are numbers only and stay when the history is cleared; Reset stats sets them back to zero.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/stats-dark.png">
  <img src="docs/screenshots/stats-light.png" alt="The stats window with sample numbers: totals, words a day, speed over time, and Fun facts with book comparisons, the longest day and total talking time" width="480">
</picture>
</p>

## How accurate is it

All three engines were run on [WildSpeech-Bench](https://huggingface.co/datasets/tencent/WildSpeech-Bench), 1,100 public recordings of people asking questions: some in quiet rooms, some on the street, some with others talking.

| Engine | Words wrong | Engine's part after the audio ends |
|---|---|---|
| Most accurate (Whisper) | 7.8% | about 2 s |
| Instant (Parakeet Unified) | 9.2% | about 0.05 s |
| Mac built-in | 12.0% | |

The Instant figure is the model fed in pieces as a microphone would, the way the app runs it. The last column is only the engine's part, measured on an M1 Max. On top of it, Voice keeps listening 0.1 seconds after you let go (0.5 seconds if you were still talking) and then types the words: across 19 real dictations that part took a median 0.58 seconds (0.17 seconds when you'd already stopped talking). So with Instant, words land about 0.6 seconds after you let go.

### FluidVoice's engines, on the same recordings

[FluidVoice](https://github.com/altic-dev/FluidVoice) is another free, on-device dictation app for Mac. Its default engine on Apple silicon is Parakeet TDT v3, run on the whole recording when you let go; Flash (Parakeet EOU) is one of its options. We ran both through [FluidAudio](https://github.com/FluidInference/FluidAudio), the open library it builds on, the way FluidVoice runs them, on an M1 Max.

| Engine | Words wrong, WildSpeech (275 recordings) | Words wrong, one-minute dictations (30) | Engine's part after the audio ends | Peak memory |
|---|---|---|---|---|
| Most accurate (Whisper), Redpen Voice | 7.8% | 3.5% | about 1.2 s for the last stretch | |
| Instant (Parakeet Unified), Redpen Voice | 9.9% | 3.4% | 0.03 s at any length | 51 MB |
| Parakeet TDT v3, FluidVoice's default | 10.3% | 5.3% | 0.12 s for a short dictation, 0.73 s for a minute | 104 MB |
| Flash (Parakeet EOU), a FluidVoice option | 22.1% | not run | 0.02 s | |

How it was tested: the WildSpeech column is every fourth recording of the 1,100 (Whisper scores 7.8% on these and on all of them), scored with the same text normalizer as the table above. The one-minute dictations are 30 LibriSpeech recordings of read speech, about a minute each. Times are the engine's work after the last of the audio, not the whole wait after you let go. These are the engines, not the apps: FluidVoice uses its own build of FluidAudio, and for recordings over 15 seconds its own way of splitting them, which we didn't reproduce. Peak memory is the test program's, measured by macOS; Whisper's is left blank because it was only measured inside the whole app (about 220 MB).

On [TORGO](https://www.cs.toronto.edu/~complingweb/data/TORGO/torgo.html), recordings of slurred speech from people with dysarthria, Whisper got 32.2% of words wrong and the built-in engine 39.4%. On the clear speech in the same set, 2.2% and 7.7%.

## Privacy

- Speech is turned into text on your Mac, by every engine. Nothing you say or write is sent anywhere.
- **What is kept, and where.** In `~/Library/Application Support/Redpen Voice/` on this Mac:
  - `history.jsonl`: the text of your last 2,000 dictations (what was heard and, if you use a tidy option, what went in), with when, how long and which app. Never the sound. This is what Paste last reads when history is kept. You can delete it any time. This file is readable only by your account.
  - `stats.json`: numbers only, never your words. For each day and engine: how many words, how many seconds of talking, and how many dictations. Kept whatever you choose for the history; Reset stats in the Stats window clears it. This file is readable only by your account.
  - `config.json` holds your settings. `names.txt` is your plain word list. `talk.json` holds your pace and pauses, numbers only. `learned.json` holds counts of the name fixes it has seen, stored as fingerprints, not words.
  - The log in `~/Library/Logs/RedpenVoice.log` holds timings, app names and counts, never your words.
- **The microphone stays on while Voice is open**, so the Mac's orange microphone dot stays lit. Between dictations it holds only the last 0.6 seconds in memory, overwritten continuously, so the word you say as the key goes down isn't cut. During a dictation, the sound is held in memory for the engine. Normal dictations never save an audio file. "Record a test" in Settings saves a recording to the Desktop when you ask for one.
- **Text boxes.** It reads the box you're dictating into on your Mac, to keep the words tied to that box, check delivery and learn the names you fix. The surrounding box text is not saved. Learned fixes go in your word list.
- **Clipboard.** Ordinary dictation leaves your clipboard alone. Paste last marks its text so clipboard managers can skip it. Voice puts back every original clipboard item and format only after confirming the paste, unless you copied something new meanwhile. It waits up to 1.2 seconds for the shortcut keys to come up and up to 2 seconds after posting the paste. If delivery can't be confirmed, the words stay on the clipboard for Command-V. A second Paste last is refused while one is in progress and for 1.5 seconds after it finishes. An app can still accept a paste late, so check the box before pasting again.
- **How long dictations are kept** is your choice in the History window: the last 2,000, the last week, or nothing (Paste last then works until Voice quits).
- **Videos.** When it pauses a video, it listens to that app's sound for about a second, in memory only. Whisper uses those words to remove the video's speech from the start; the other engines leave out the opening sound instead. While the pause is held, Voice also checks short samples for unexpected playback. No system audio is saved.
- **Network.** The Whisper or Instant model downloads once from Hugging Face if you choose one; Apple's speech files for your language download once from Apple if the Mac doesn't have them yet; and the app checks GitHub once a day for a newer version.

## Install

Download the `.dmg` from the [latest release](https://github.com/cjaynewton/redpen-voice-mac/releases/latest), open it and drag Redpen Voice to Applications. It needs macOS 26 on a Mac with Apple silicon, and updates itself.

First run asks for the microphone and Accessibility (to type into other apps and see the Fn key); macOS also asks for Speech Recognition, and for system audio the first time a video is playing when you talk. If you talk with Fn, set "Press 🌐 key to" to Do Nothing in Keyboard settings, or the Mac also opens its own dictation or the emoji picker.

### Build from source

Needs macOS 26 and Xcode (free from the Mac App Store; open it once before building).

```sh
git clone https://github.com/cjaynewton/redpen-voice-mac.git
cd redpen-voice-mac
./build.sh
```

This builds `Redpen Voice.app` and installs it to `~/Applications` if the signing-team check passes. On first launch it asks for the microphone and Accessibility (needed to type into other apps and to see the Fn key).

To keep Accessibility permission across rebuilds, sign with your own certificate. Create a `.local.env` beside `build.sh` with `REDPEN_SIGN_ID="Apple Development"`, or set it to the full name of your signing identity. Without one, the build uses an ad-hoc signature and macOS may ask for Accessibility again after each rebuild.

Before replacing an installed copy, `build.sh` compares its signing team with the new build's. If they differ, it stops to protect the app's permissions. Set `REDPEN_SIGN_ID` to an identity from the installed copy's team. If you mean to replace it with a different team or an ad-hoc build, run `REDPEN_FORCE_INSTALL=1 ./build.sh`. That override can make macOS forget the app's permissions, so you may need to grant them again.

## Checks

```sh
swift run redpen-voice-test
```

Runs checks that need no microphone or open windows. They cover the word list, history, stats and Fun facts, the ums filter, silence handling, media rules, recording cuts, pace and pauses, learning fixed names, screen hints, matching text boxes, talk-key gestures, missed releases, and paste timing and clipboard rules.

`"build/Redpen Voice.app/Contents/MacOS/RedpenVoice" --stream-test files.txt out.jsonl` writes each audio file whole and streamed, with the wait after release, for checking streaming against long recordings.

## Credits

- [Whisper](https://github.com/openai/whisper) by OpenAI (MIT), the Most accurate engine's model.
- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax runs Whisper on the Mac.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference (Apache 2.0) runs Parakeet on the Mac.
- [Parakeet Unified 0.6B](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) by NVIDIA, the Instant engine's model, under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), converted for the Mac by [Fluid Inference](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml).
- [Newsreader](https://fonts.google.com/specimen/Newsreader) by Production Type, under the SIL Open Font License 1.1.
- Sibling app: [Redpen Grammar for Mac](https://github.com/cjaynewton/redpen-grammar-mac).

## License

MIT. See [LICENSE](LICENSE).

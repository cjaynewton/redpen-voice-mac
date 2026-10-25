# Redpen Voice for Mac

A free, private dictation app for macOS, from the Redpen family of writing tools. Hold a key, talk, let go, and your words land where the cursor is, in almost any app.

Everything runs on your Mac. Your voice is never sent anywhere.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-dark.png">
  <img src="docs/screenshots/menu-light.png" alt="The menu bar panel: status, two switches, paste last dictation, transcribe a file, settings" width="300">
</picture>
</p>

## What it does

- **Hold to talk.** Hold Fn or right Option (or a key you pick), talk, let go. The words are typed at the cursor without touching your clipboard.
- **Double-tap for hands-free.** Tap the key twice and keep talking with your hands free. Tap once more to finish.
- **Words appear as you talk.** With Whisper, each stretch is written at your next pause, so when you finish only the last few seconds are left. A one-minute dictation that used to take about 12 seconds now lands about 2 seconds after you stop. Hands-free, the words are typed into the box as you go; holding the key, they show in the bar and go in when you let go.
- **Your words, as said.** By default nothing is rewritten. Two switches change that:
  - **Take out ums and uhs** removes only the sounds. Every word stays.
  - **Tidy it up** also takes out repeats and false starts and fixes punctuation, using Apple's on-device model. It can change a word now and then.
- **Two engines.** Whisper (OpenAI's model, a one-time 626 MB download, run on your Mac) or the Mac's built-in engine (already there, words appear a little sooner).
- **Words it gets wrong.** A plain list, one per line: `claw code = Claude Code` fixes what it hears, a single name tells it to listen for that name.
- **Learns your names.** Fix a name by hand after a dictation ("so well" to "Sowell") and the second time you make the same fix, it goes into your list. Only names and terms are learned, never everyday words, and the list stays a plain file you can edit.
- **Names on screen.** When you start talking, the names in the box you're typing in and the window title are given to Whisper as spelling hints. They are read once and kept nowhere.
- **Learns how you talk.** Like a driving app that learns how you drive, it learns your pace and how long you pause, and uses that to decide where a thought ends. Only the numbers are kept.
- **Lands where your cursor is.** The words go wherever your cursor is when they're ready. If it's on a web page or a video instead of a text box, nothing is typed there (on a video page, letters are shortcuts): the words wait for you to click into a box.
- **Nothing lost.** Every dictation is kept in a history file on your Mac. Press Control-Option-V to paste the last one again.
- **Take it back.** Control-Option-Z removes the last dictation, only when it is still the last thing typed.
- **Pauses your music and video** while you talk and starts them again after, only when something is actually playing.
- **Transcribe a file.** Any audio or video file to text, saved beside the file.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-dark.png">
  <img src="docs/screenshots/settings-light.png" alt="Settings: engine, what you get, talking, words it gets wrong" width="360">
</picture>
</p>

## How accurate is it

Both engines were run on [WildSpeech-Bench](https://huggingface.co/datasets/tencent/WildSpeech-Bench), 1,100 public recordings of people asking questions: some in quiet rooms, some on the street, some with others talking.

| Engine | Words wrong |
|---|---|
| Whisper | 7.8% |
| Mac built-in | 12.0% |

On [TORGO](https://www.cs.toronto.edu/~complingweb/data/TORGO/torgo.html), recordings of slurred speech from people with dysarthria, Whisper got 32.2% of words wrong and the built-in engine 39.4%. On the clear speech in the same set, 2.2% and 7.7%.

## Privacy

- Speech is turned into text on your Mac, by either engine.
- The only download is the Whisper model, once, if you choose Whisper.
- History and your word list live in `~/Library/Application Support/Redpen Voice/`, with `talk.json` (your pace and pauses, numbers only) and `learned.json` (the name fixes it has seen). The log in `~/Library/Logs/RedpenVoice.log` holds timings and counts, never your words.
- To learn your fixes and spot names, it reads the text box you're dictating into, on your Mac, and keeps nothing from it but the fixed names.
- The download checks GitHub once a day for a newer version. Nothing you say or write is sent.

## Install

Download `Redpen-Voice-0.11.dmg` from the [latest release](https://github.com/cjaynewton/redpen-voice-mac/releases/latest), open it and drag Redpen Voice to Applications. It needs macOS 26 on a Mac with Apple silicon, and updates itself.

First run asks for the microphone and Accessibility (to type into other apps and see the Fn key). If you talk with Fn, set "Press 🌐 key to" to Do Nothing in Keyboard settings, or the Mac also opens its own dictation or the emoji picker.

### Build from source

Needs macOS 26 and Xcode (free from the Mac App Store; open it once before building).

```sh
git clone https://github.com/cjaynewton/redpen-voice-mac.git
cd redpen-voice-mac
./build.sh
```

This builds `Redpen Voice.app` and installs it to `~/Applications`. On first launch it asks for the microphone and Accessibility (needed to type into other apps and to see the Fn key).

To keep Accessibility permission across rebuilds, sign with your own certificate: create a `.local.env` beside `build.sh` with `REDPEN_SIGN_ID="Apple Development"`.

## Checks

```sh
swift run redpen-voice-test
```

Runs the checks for the parts that need no microphone: the word list, history, the ums filter, silence handling, the media pause, where a recording is cut while you talk, how-you-talk numbers, learning fixed names and screen hints.

`"Redpen Voice.app/Contents/MacOS/RedpenVoice" --stream-test files.txt out.jsonl` writes each audio file whole and streamed, with the wait after release, for checking streaming against long recordings.

## Credits

- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax runs Whisper on the Mac.
- [Newsreader](https://fonts.google.com/specimen/Newsreader) by Production Type, under the SIL Open Font License 1.1.
- Sibling app: [Redpen Grammar for Mac](https://github.com/cjaynewton/redpen-grammar-mac).

## License

MIT. See [LICENSE](LICENSE).

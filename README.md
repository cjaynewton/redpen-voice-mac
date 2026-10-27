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
- **Words appear as you talk.** With Instant, your words show in the bar while you talk and go into the box the moment you let go. With Whisper, each stretch is written at your next pause, so a one-minute dictation lands about 2 seconds after you stop; in a text box the words are typed as you go.
- **Your words, as said.** By default nothing is rewritten. Two switches change that:
  - **Take out ums and uhs** removes only the sounds. Every word stays.
  - **Tidy it up** also takes out repeats and false starts and fixes punctuation, using Apple's on-device model. It can change a word now and then.
- **Three engines, named for what they do.**
  - **Most accurate** is Whisper, OpenAI's model: the fewest mistakes, words about 2 seconds after you stop, a one-time 626 MB download.
  - **Instant** is Parakeet Unified, NVIDIA's model: it writes while you talk, so your words are ready about 0.05 seconds after you let go, with about 1 more word in 100 wrong than Whisper. English only, a one-time 600 MB download.
  - **Mac built-in** is already on your Mac, with the most mistakes of the three.
- **Words it gets wrong.** A plain list, one per line: `claw code = Claude Code` fixes what it hears, a single name tells it to listen for that name.
- **Learns your names.** Fix a name by hand after a dictation ("so well" to "Sowell") and the second time you make the same fix, it goes into your list. Only names and terms are learned, never everyday words, and the list stays a plain file you can edit.
- **Learns how you talk.** Like a driving app that learns how you drive, it learns your pace and how long you pause, and uses that to decide where a thought ends. Only the numbers are kept.
- **Goes back to the box you started in.** If you move to another app or box while the words are being written, they go into the box you started in, never into the one you moved to. When that app allows it they go straight in; otherwise they wait until you're back in that box. If that box was sent or changed meanwhile, nothing is typed and Paste last has the words. If you started on a web page or a video instead of a text box, nothing is typed there (on a video page, letters are shortcuts): the words wait for you to click into a box.
- **Fits the sentence.** Dictate into the middle of a sentence and the first word starts lowercase ("and then and we go"), except "I" and names from your list; right before a word, the closing full stop goes. Only in boxes that tell Voice what's around the cursor.
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

All three engines were run on [WildSpeech-Bench](https://huggingface.co/datasets/tencent/WildSpeech-Bench), 1,100 public recordings of people asking questions: some in quiet rooms, some on the street, some with others talking.

| Engine | Words wrong | Ready after you let go |
|---|---|---|
| Most accurate (Whisper) | 7.8% | about 2 s |
| Instant (Parakeet Unified) | 9.2% | about 0.05 s |
| Mac built-in | 12.0% | |

The Instant figure is the model fed in pieces as a microphone would, the way the app runs it. "Ready after you let go" is the engine's part, measured on an M1 Max; Voice also listens a moment longer for a last syllable before it finishes.

On [TORGO](https://www.cs.toronto.edu/~complingweb/data/TORGO/torgo.html), recordings of slurred speech from people with dysarthria, Whisper got 32.2% of words wrong and the built-in engine 39.4%. On the clear speech in the same set, 2.2% and 7.7%.

## Privacy

- Speech is turned into text on your Mac, by every engine. Nothing you say or write is sent anywhere.
- **What is kept, and where.** All in `~/Library/Application Support/Redpen Voice/`, readable only by your account on this Mac:
  - `history.jsonl`: the text of your last 2,000 dictations (what was heard and, if you use a tidy option, what went in), with when, how long and which app. Never the sound. This is what Paste last reads. You can delete it any time.
  - Your word list (a plain text file), `talk.json` (your pace and pauses, numbers only) and `learned.json` (counts of the name fixes it has seen, stored as fingerprints, not words).
  - The log in `~/Library/Logs/RedpenVoice.log` holds timings, app names and counts, never your words.
- **The microphone stays on while Voice is open**, so the Mac's orange microphone dot stays lit. It holds only the last 0.6 seconds in memory, so the word you say as the key goes down isn't cut, and that is overwritten continuously. Nothing is kept until you press the key.
- **Text boxes.** It reads the box you're dictating into, on your Mac: when you start (so the words go back to the right box) and after (to learn the names you fix). Only the fixed names are kept.
- **Videos.** When it pauses a video, it listens to that app's sound for about a second, in memory only, to take the video's words off the start of your dictation.
- **Network.** The Whisper or Instant model downloads once from Hugging Face if you choose one, and the app checks GitHub once a day for a newer version.

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
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference (Apache 2.0) runs Parakeet on the Mac.
- [Parakeet Unified 0.6B](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) by NVIDIA, the Instant engine's model, under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), converted for the Mac by [Fluid Inference](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml).
- [Newsreader](https://fonts.google.com/specimen/Newsreader) by Production Type, under the SIL Open Font License 1.1.
- Sibling app: [Redpen Grammar for Mac](https://github.com/cjaynewton/redpen-grammar-mac).

## License

MIT. See [LICENSE](LICENSE).

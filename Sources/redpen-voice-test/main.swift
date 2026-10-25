import Foundation
import VoiceCore

// Command-line checks for the parts that need no microphone. Run: swift run redpen-voice-test
var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1 } else { fail += 1; print("FAIL \(name) \(detail)") }
}

// Names: whole word, case-insensitive, longest first, punctuation kept, no clipboard, no partial words.
let names = Names(text: """
# names
claw code = Claude Code
Priya
kmf = KMF
redpen = Redpen
""")
check("names.count", names.entries.count == 4)
check("names.vocab", names.vocabulary.contains("Claude Code") && names.vocabulary.contains("Priya"))
check("names.replace", names.apply("open claw code now") == "open Claude Code now")
check("names.case", names.apply("Claw Code, please.") == "Claude Code, please.")
check("names.partial", names.apply("the clawed cat") == "the clawed cat")
check("names.keep", names.apply("priya said kmf") == "Priya said KMF")
check("names.punct", names.apply("Is redpen's build done?") == "Is Redpen's build done?")
check("names.start", names.apply("redpen. redpen!") == "Redpen. Redpen!")

// History: append, last, trim, nothing lost when inserted is false.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rv-test-\(UUID().uuidString)/history.jsonl")
let h = History(url: tmp)
check("history.empty", h.last() == nil)
h.append(Entry(raw: "first line", seconds: 3, app: "TextEdit", inserted: true))
h.append(Entry(raw: "second line here", cleaned: "Second line here.", seconds: 4, app: "Slack", inserted: false))
check("history.last", h.last()?.raw == "second line here")
check("history.text", h.last()?.text == "Second line here.")
check("history.words", h.last()?.words == 3)
h.append(Entry(raw: "", cleaned: nil, seconds: 1, app: "T", inserted: false))
check("history.lastSpoken.skipsEmpty", h.last()?.raw == "" && h.lastSpoken()?.raw == "second line here")
for i in 0..<20 { h.append(Entry(raw: "n \(i)", seconds: 1, app: "x", inserted: true)) }
h.trim(to: 5)
check("history.trim", h.all().count == 5 && h.all().last?.raw == "n 19")
try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

// Score: words per minute and minutes saved against a 40 wpm typist.
let s = Score(words: 400, seconds: 180, count: 3)
check("score.wpm", s.wordsPerMinute == 133, "\(s.wordsPerMinute)")
check("score.saved", s.minutesSaved == 7, "\(s.minutesSaved)")   // 10 min typed, 3 min spoken
check("score.zero", Score().wordsPerMinute == 0 && Score().minutesSaved == 0)
let old = Entry(date: Date(timeIntervalSinceNow: -2 * 86_400), raw: "a b c", seconds: 1, app: "x", inserted: true)
let new = Entry(raw: "a b", seconds: 1, app: "x", inserted: true)
check("score.today", Score.today([old, new]).words == 2)

// Media gate: never press play on a quiet Mac.
check("media.quiet", MediaGate.shouldPause(enabled: true, outputRunning: false) == false)
check("media.playing", MediaGate.shouldPause(enabled: true, outputRunning: true) == true)
check("media.off", MediaGate.shouldPause(enabled: false, outputRunning: true) == false)
check("media.router", MediaGate.isRouter("Boom 3D") && MediaGate.isRouter("SoundSource"))
check("media.silent", !MediaGate.isPlaying(peak: 0.0005) && !MediaGate.isPlaying(peak: nil))
check("media.loud", MediaGate.isPlaying(peak: 0.05))
check("media.chrome", !MediaGate.isRouter("Google Chrome Helper (Aperitif)"))
check("media.resume", MediaGate.shouldResume(paused: false) == false)
check("media.resume.ours", MediaGate.shouldResume(paused: true))
check("media.resume.newpress", !MediaGate.shouldResume(paused: true, recordingAgain: true))
check("media.resume.alreadyplaying", !MediaGate.shouldResume(paused: true, playingNow: true))
check("media.alerts", !MediaGate.isMedia("systemsoundserverd") && !MediaGate.isMedia("corespeechd") && !MediaGate.isMedia("Monologue"))
check("media.players", MediaGate.isMedia("Google Chrome Helper (Aperitif)") && MediaGate.isMedia("Music") && !MediaGate.isMedia("Boom 3D"))
func fk(_ r: String?, ed: Bool = false, set: Bool = false, web: Bool = false) -> FocusKind { FocusGate.kind(role: r, editableAncestor: ed, valueSettable: set, inBrowser: web) }
// Streaming cuts: only in a pause, never inside a word.
func tone(_ secs: Double) -> [Float] { (0..<Int(secs * 16000)).map { Float(sin(Double($0) * 0.05)) * 0.3 } }
func hush(_ secs: Double) -> [Float] { Array(repeating: 0.0005, count: Int(secs * 16000)) }
let ch = Chunker()
check("chunk.tooSoon", ch.cut(tone(2) + hush(1), from: 0) == nil)
let talk = tone(5) + hush(0.8) + tone(2)
if let c = ch.cut(talk, from: 0) { check("chunk.inPause", c > 5 * 16000 && c < Int(5.8 * 16000)) } else { check("chunk.inPause", false) }
check("chunk.shortGap", ch.cut(tone(5) + hush(0.2) + tone(2), from: 0) == nil)
let longTalk = tone(26)
if let c = ch.cut(longTalk, from: 0) { check("chunk.forced", c >= 4 * 16000 && c <= 25 * 16000) } else { check("chunk.forced", false) }
check("chunk.fromLastCut", ch.cut(talk + tone(1), from: 6 * 16000) == nil)
// How you talk: speech time and the pauses between stretches of speech.
var tp = TalkProfile()
tp.add(tone(2) + hush(0.3) + tone(2) + hush(1.0) + tone(1), words: 12)
check("talk.counted", tp.dictations == 1 && tp.words == 12 && abs(tp.speaking - 5) < 0.2)
check("talk.gaps", tp.gaps.reduce(0, +) == 2)
check("talk.default", tp.pauseSeconds == 0.5 && tp.wordsPerMinute == nil && tp.summary == nil)
var slow = TalkProfile()
for _ in 0..<25 { slow.add(tone(3) + hush(0.7) + tone(3) + hush(0.75) + tone(3) + hush(0.7) + tone(3), words: 25) }
check("talk.learnsSlowPauses", slow.pauseSeconds >= 0.7 && slow.pauseSeconds <= 1.0)
check("talk.wpm", slow.wordsPerMinute.map { $0 > 100 && $0 < 150 } == true)
var fast = TalkProfile()
for _ in 0..<25 { fast.add(tone(3) + hush(0.2) + tone(3) + hush(0.25) + tone(3) + hush(0.2) + tone(3), words: 40) }
check("talk.floor", fast.pauseSeconds == 0.4)
// Learning fixes: small word swaps only, learned the second time.
check("fix.name", Corrections.find(typed: "I was reading so well last night", now: "I was reading Sowell last night") == [Corrections.Fix(heard: "so well", fixed: "Sowell")])
check("fix.twoWords", Corrections.find(typed: "open claw code and run it", now: "Hey, open Claude Code and run it. Thanks") == [Corrections.Fix(heard: "claw code", fixed: "Claude Code")])
check("fix.caseOnly", Corrections.find(typed: "send it to monica today", now: "send it to Monica today.").isEmpty)
check("fix.rewrite", Corrections.find(typed: "can you look at the file and tell me", now: "please review the attached document thoroughly").isEmpty)
check("fix.untouched", Corrections.find(typed: "this stays the same", now: "this stays the same and more words after").isEmpty)
var learned = Learned()
let f = Corrections.Fix(heard: "so well", fixed: "Sowell")
check("learn.once", learned.see(f) == false)
check("learn.twice", learned.see(f) == true && learned.see(f) == false)
// Hints from the screen: names and code-like words, not ordinary words or sentence starts.
let screen = Hints.fromScreen("Ask Cedric about the plan. Then open Claude Code and check fb36e2f in redpen_voice/main.swift. The weather is nice.")
check("hints.names", screen.contains("Cedric") && screen.contains("Claude") && screen.contains("Code") && screen.contains("fb36e2f"))
check("hints.code", screen.contains("redpen_voice/main.swift"))
check("hints.notOrdinary", !screen.contains("Then") && !screen.contains("The") && !screen.contains("weather") && !screen.contains("Ask"))
check("hints.line", Hints.line(names: ["Sowell", "Claude Code"], screen: ["sowell", "T3"]) == "Sowell, Claude Code, T3")
check("names.spellings", Names(text: "claw code = Claude Code\nSowell").spellings == ["Claude Code", "Sowell"])
check("focus.textbox", fk("AXTextArea") == .text)
check("focus.contenteditable", fk("AXGroup", ed: true, web: true) == .text)
check("focus.webpage", fk("AXWebArea", web: true) == .notText)
check("focus.player", fk("AXGroup", web: true) == .notText)
check("focus.button", fk("AXButton") == .notText)
check("focus.none", fk(nil) == .unknown)
check("focus.word", fk("AXLayoutArea") == .unknown && fk("AXScrollArea") == .unknown && fk("AXGroup") == .unknown)
check("focus.slider", fk("AXSlider", set: true) == .notText)
check("focus.settableGroup", fk("AXGroup", set: true, web: true) == .text)

// Silence: sound labels and invented phrases from a quiet mic are dropped, real words are kept.
check("silence.label", Silence.clean("*Loud sound*", peak: 0.03) == "")
check("silence.brackets", Silence.clean("[Music] (upbeat music)", peak: 0.5) == "")
check("silence.thanks.quiet", Silence.clean("Thank you.", peak: 0.035) == "")
check("silence.thanks.said", Silence.clean("Thank you.", peak: 0.4) == "Thank you.")
check("silence.mixed", Silence.clean("Send it today *cough* please.", peak: 0.5) == "Send it today please.", Silence.clean("Send it today *cough* please.", peak: 0.5))
check("silence.sentence", Silence.clean("Thank you for the notes.", peak: 0.03) == "Thank you for the notes.")

// Fillers: only sounds come out, every real word stays.
check("fillers.commas", Fillers.strip("So, um, I think we, we should ship it Friday.") == "So, I think we, we should ship it Friday.", Fillers.strip("So, um, I think we, we should ship it Friday."))
check("fillers.start", Fillers.strip("Um, I like it.") == "I like it.", Fillers.strip("Um, I like it."))
check("fillers.end", Fillers.strip("we should ship it um.") == "we should ship it.", Fillers.strip("we should ship it um."))
check("fillers.mid", Fillers.strip("Is it uh ready? Uh, yes.") == "Is it ready? Yes.", Fillers.strip("Is it uh ready? Uh, yes."))
check("fillers.words", Fillers.strip("I mean, you know, I like the umbrella and Uhura.") == "I mean, you know, I like the umbrella and Uhura.")
check("fillers.only", Fillers.strip("Um.") == "")
check("fillers.trailing", Fillers.strip("Let me think, hmm") == "Let me think", Fillers.strip("Let me think, hmm"))

print("\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)

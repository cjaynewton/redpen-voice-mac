import Foundation
import VoiceCore

/// Settings live in ~/Library/Application Support/Redpen Voice/config.json so they can be read and edited by hand.
struct Config: Codable {
    /// REDPEN_VOICE_DIR points a test run at another folder (sample settings for screenshots); never set in use.
    static let dir = ProcessInfo.processInfo.environment["REDPEN_VOICE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Redpen Voice")
    static let url = dir.appendingPathComponent("config.json")
    static let namesURL = dir.appendingPathComponent("names.txt")
    static let historyURL = dir.appendingPathComponent("history.jsonl")
    static let suggestionsURL = dir.appendingPathComponent("word-suggestions.json")
    /// Daily counts, numbers only (D-837): its own file, so the history's keep choice never changes them.
    static let statsURL = dir.appendingPathComponent("stats.json")

    /// "raw": your words as spoken. "noUms": only sounds like "um" and "uh" taken out, every word kept.
    /// "rewrite": filler and false starts removed and punctuation added by Apple's on-device model.
    var mode = "raw"
    var firstRunDone = false
    /// Hold the Fn (globe) key to talk. Apple's own dictation key, so most hands already know it.
    var fnKey = true
    /// Hold the right Option key to talk, for hands that learned it elsewhere.
    var rightOptionKey = true
    /// The key you hold to talk: "fnOrOption", "fn", "rightOption", "rightCommand", "rightControl", or
    /// "key:<code>:<name>" for one picked with Other key. Older config files lack it, so fnKey and rightOptionKey decide.
    var talkKey: String?
    /// Tap the talk key twice to talk with your hands free; one more tap finishes. On unless turned off.
    var doubleTap: Bool?
    /// Enter stops and sends (D-1008): a plain Enter while you talk, or while the words are on their way, waits until
    /// every word is in (5 s at most) and then goes. On when missing.
    var enterSends: Bool?
    var talkKeyChoice: String { talkKey ?? (fnKey == rightOptionKey ? "fnOrOption" : fnKey ? "fn" : "rightOption") }
    /// Press the Mac's play/pause key when recording starts, only if something is playing, and again when it ends.
    var pauseMedia = true
    /// Press play again when you stop talking. Off means pause only: a video never starts by itself, and you press
    /// play when you want it. Older config files lack it, so it is optional and on when missing.
    var resumeMedia: Bool?
    /// The old "Words appear as I talk" switch. Since D-972 (Oct 31 2026) `wordsWhileTalking` decides; this is read
    /// only to keep an older file's choice, and Voice never changes it.
    var liveWords: Bool?
    /// While you talk (D-972): "box" types your words into the text box as you go, "bar" shows them on the bar and
    /// puts the whole checked text in once when you finish. Older files lack it; `whileTalking` keeps what they did.
    var wordsWhileTalking: String?
    var whileTalking: TalkingWords { TalkingWords.choice(saved: wordsWhileTalking, liveWords: liveWords, draftMode: draftMode) }
    /// Names from the list and near the cursor given to Whisper as spelling hints. Off when missing: each hint word
    /// costs time before Whisper starts (about 3 s for a 355-character list on an M1 Max).
    var screenHints: Bool?
    /// Fast draft, Whisper checks (D-764): Parakeet types a draft as you talk and Whisper quietly fixes it a moment
    /// later. Whisper only; off when missing, so Whisper alone stays as it was.
    var draftMode: Bool?
    /// Point out words to check (D-817, a test): where a second engine hears a "not", a number, a name or the first
    /// or last words differently, the bar shows it and ⌃⌥S swaps. Off when missing.
    var riskMarks: Bool?
    /// How long dictations are kept (D-825): "all" (the newest 2,000), "week", or "none". "all" when missing.
    var historyKeep: String?
    /// Offers recurring names after dictations, at most once a day. On when missing.
    var suggestWords: Bool?
    /// Meeting notes (D-951): the folder they go in. ~/Redpen Meetings when missing, never Documents or Desktop,
    /// which sync to iCloud on many Macs.
    var meetingsFolder: String?
    /// Keep each meeting's audio beside its notes, one file for you and one for the others. On when missing.
    var keepMeetingAudio: Bool?
    /// Live words for meetings (D-1290), off when missing. `liveWords` above is the legacy dictation choice.
    var meetingLiveWords: Bool?
    /// The first meeting's tip about telling people has been shown.
    var meetingTipShown: Bool?
    /// Better summary (D-956, D-1012): "claude", "chatgpt", "gemini" or "cursor" through the user's own plan,
    /// "command" for their own command line, or "mac", a writer downloaded to this Mac (D-1010); off when missing.
    var betterSummaryWith: String?
    /// The user's own command for Better summary: it gets the instructions and the transcript on stdin and prints the
    /// summary. Used only when Better summary is "command".
    var betterSummaryCommand: String?
    /// Voices in the room (D-1034): the microphone's lines told apart by voice after a meeting. Off when missing.
    var roomVoices: Bool?
    /// Know my voice (D-1034): learn the user's voiceprint from their dictations, so their lines in the room say Me.
    var knowMyVoice: Bool?
    /// The helpers the user has agreed to send a transcript to, after being told where it goes the first time; for
    /// their own command, "command:" and the command, so a new command asks again.
    var betterSummaryAgreed: [String]?
    /// Notes written by the user's own Claude account after every meeting (D-1272): true once they said yes to the
    /// one question after a meeting, false once they said no or turned it off; nil until asked. Only the meeting's
    /// text goes to Claude; the audio stays on the Mac.
    var claudeNotes: Bool?
    /// "claude" was added to `betterSummaryAgreed` by saying yes to notes by Claude, so turning those off takes it out
    /// again and Better summary with Claude asks its own question once more.
    var claudeAgreedByNotes: Bool?

    /// Notes by Claude on or off, with the agreement that goes with them (D-1272).
    mutating func setClaudeNotes(_ on: Bool) {
        claudeNotes = on
        var agreed = betterSummaryAgreed ?? []
        if on, !agreed.contains("claude") { agreed.append("claude"); claudeAgreedByNotes = true }
        if !on, claudeAgreedByNotes == true { agreed.removeAll { $0 == "claude" }; claudeAgreedByNotes = nil }
        betterSummaryAgreed = agreed.isEmpty ? nil : agreed
    }
    var meetingsDir: URL {
        meetingsFolder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Redpen Meetings", isDirectory: true)
    }

    /// The same plain list Settings opens. Preserve comments, fixes and existing spelling.
    @discardableResult
    static func addName(_ word: String) -> Bool {
        ensureNamesFile()
        guard var list = try? String(contentsOf: namesURL, encoding: .utf8) else { return false }
        guard !word.isEmpty, !word.contains(where: \.isNewline) else { return false }
        if Names(text: list).vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return true }
        if !list.isEmpty, !list.hasSuffix("\n") { list += "\n" }
        list += word + "\n"
        return (try? list.write(to: namesURL, atomically: true, encoding: .utf8)) != nil
    }
    /// Your typing speed in words a minute, the clock "minutes saved" is measured against (D-837). 40 when missing.
    var typingWPM: Int?
    /// Kept between 10 and 200 words a minute, whatever a hand-edited file says.
    var typingSpeed: Double { Double(min(200, max(10, typingWPM ?? 40))) }
    /// "dictation" (Apple's dictation model, tuned for talking to a text field), "transcription" (Apple's general
    /// model), "whisper" (OpenAI's Whisper, downloaded once and run on this Mac, the most accurate), "live" (Instant:
    /// NVIDIA's Parakeet Unified, downloaded once, writes while you talk) or "parakeet" (Parakeet v2 on the whole
    /// dictation at release; the old Fast engine, kept for tests and loaded as Instant from a saved setting).
    var engine = "dictation"
    var locale = "en-CA"
    /// Off by default: a click at every start gets old fast.
    var sounds = false
    /// The microphone to read, by its stable id. Empty means the Mac's current default input.
    var inputDevice = ""
    var showLevel = true
    /// The level bar's look: "pen", "bars", "tape", "dot" or "classic". Missing in older config files, so optional.
    var levelStyle: String?
    /// "light", "dark", or nil to match the Mac. Applies to every Redpen Voice window and the menu bar panel.
    var appearance: String?
    var levelLook: String { showLevel ? (levelStyle ?? "pen") : "off" }

    static func load() -> Config {
        if let d = try? Data(contentsOf: url), var c = try? JSONDecoder().decode(Config.self, from: d) {
            // The Fast engine (Parakeet v2, whole dictation at release) became Instant on Oct 26 2026: fewer mistakes
            // and no wait (D-816).
            if c.engine == "parakeet" { c.engine = "live" }
            return c
        }
        return Config()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Config.url, options: .atomic) }
    }

    static func loadNames() -> String {
        (try? String(contentsOf: namesURL, encoding: .utf8)) ?? ""
    }

    static func ensureNamesFile() {
        guard !FileManager.default.fileExists(atPath: namesURL.path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let starter = """
        # Words the engine gets wrong. One per line.
        #   heard = meant      replaces what it hears with what you meant, whole word, any case
        #   Word               a name to listen for and keep as written
        # Examples:
        # claw code = Claude Code
        # Priya

        """
        try? starter.write(to: namesURL, atomically: true, encoding: .utf8)
    }
}

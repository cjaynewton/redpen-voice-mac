import Foundation

/// Settings live in ~/Library/Application Support/Redpen Voice/config.json so they can be read and edited by hand.
struct Config: Codable {
    /// REDPEN_VOICE_DIR points a test run at another folder (sample settings for screenshots); never set in use.
    static let dir = ProcessInfo.processInfo.environment["REDPEN_VOICE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Redpen Voice")
    static let url = dir.appendingPathComponent("config.json")
    static let namesURL = dir.appendingPathComponent("names.txt")
    static let historyURL = dir.appendingPathComponent("history.jsonl")

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
    var talkKeyChoice: String { talkKey ?? (fnKey == rightOptionKey ? "fnOrOption" : fnKey ? "fn" : "rightOption") }
    /// Press the Mac's play/pause key when recording starts, only if something is playing, and again when it ends.
    var pauseMedia = true
    /// Press play again when you stop talking. Off means pause only: a video never starts by itself, and you press
    /// play when you want it. Older config files lack it, so it is optional and on when missing.
    var resumeMedia: Bool?
    /// Words appear as you talk (Whisper): typed into the box when talking hands-free, shown in the bar while you
    /// hold the key. On when missing.
    var liveWords: Bool?
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

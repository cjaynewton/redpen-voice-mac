import Foundation

/// Settings live in ~/Library/Application Support/Redpen Voice/config.json so they can be read and edited by hand.
public struct Config: Codable, Sendable {
    /// REDPEN_VOICE_DIR points a test run at another folder (sample settings for screenshots); never set in use.
    public static let dir = ProcessInfo.processInfo.environment["REDPEN_VOICE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Redpen Voice")
    public static let url = dir.appendingPathComponent("config.json")
    public static let namesURL = dir.appendingPathComponent("names.txt")
    public static let historyURL = dir.appendingPathComponent("history.jsonl")
    public static let suggestionsURL = dir.appendingPathComponent("word-suggestions.json")
    /// Daily counts, numbers only (D-837): its own file, so the history's keep choice never changes them.
    public static let statsURL = dir.appendingPathComponent("stats.json")

    /// "raw": your words as spoken. "noUms": only sounds like "um" and "uh" taken out, every word kept.
    /// "rewrite": filler and false starts removed and punctuation added by Apple's on-device model.
    public var mode = "raw"
    public var firstRunDone = false
    /// Hold the Fn (globe) key to talk. Apple's own dictation key, so most hands already know it.
    public var fnKey = true
    /// Hold the right Option key to talk, for hands that learned it elsewhere.
    public var rightOptionKey = true
    /// The key you hold to talk: "fnOrOption", "fn", "rightOption", "rightCommand", "rightControl", or
    /// "key:<code>:<name>" for one picked with Other key. Older config files lack it, so fnKey and rightOptionKey decide.
    public var talkKey: String?
    /// Tap the talk key twice to talk with your hands free; one more tap finishes. On unless turned off.
    public var doubleTap: Bool?
    public var talkKeyChoice: String { talkKey ?? (fnKey == rightOptionKey ? "fnOrOption" : fnKey ? "fn" : "rightOption") }
    /// Press the Mac's play/pause key when recording starts, only if something is playing, and again when it ends.
    public var pauseMedia = true
    /// Press play again when you stop talking. Off means pause only: a video never starts by itself, and you press
    /// play when you want it. Older config files lack it, so it is optional and on when missing.
    public var resumeMedia: Bool?
    /// Words appear as you talk (Whisper): typed into the box when talking hands-free, shown in the bar while you
    /// hold the key. On when missing.
    public var liveWords: Bool?
    /// Names from the list and near the cursor given to Whisper as spelling hints. Off when missing: each hint word
    /// costs time before Whisper starts (about 3 s for a 355-character list on an M1 Max).
    public var screenHints: Bool?
    /// Fast draft, Whisper checks (D-764): Parakeet types a draft as you talk and Whisper quietly fixes it a moment
    /// later. Whisper only; off when missing, so Whisper alone stays as it was.
    public var draftMode: Bool?
    /// Point out words to check (D-817, a test): where a second engine hears a "not", a number, a name or the first
    /// or last words differently, the bar shows it and ⌃⌥S swaps. Off when missing.
    public var riskMarks: Bool?
    /// How long dictations are kept (D-825): "all" (the newest 2,000), "week", or "none". "all" when missing.
    public var historyKeep: String?
    /// Offers recurring names after dictations, at most once a day. On when missing.
    public var suggestWords: Bool?

    /// The same plain list Settings opens. Preserve comments, fixes and existing spelling.
    @discardableResult
    public static func addName(_ word: String) -> Bool {
        ensureNamesFile()
        guard var list = try? String(contentsOf: namesURL, encoding: .utf8) else { return false }
        guard !word.isEmpty, !word.contains(where: \.isNewline) else { return false }
        if Names(text: list).vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return true }
        if !list.isEmpty, !list.hasSuffix("\n") { list += "\n" }
        list += word + "\n"
        return (try? list.write(to: namesURL, atomically: true, encoding: .utf8)) != nil
    }
    /// Your typing speed in words a minute, the clock "minutes saved" is measured against (D-837). 40 when missing.
    public var typingWPM: Int?
    /// Kept between 10 and 200 words a minute, whatever a hand-edited file says.
    public var typingSpeed: Double { Double(min(200, max(10, typingWPM ?? 40))) }
    /// "dictation" (Apple's dictation model, tuned for talking to a text field), "transcription" (Apple's general
    /// model), "whisper" (OpenAI's Whisper, downloaded once and run on this Mac, the most accurate), "live" (Instant:
    /// NVIDIA's Parakeet Unified, downloaded once, writes while you talk) or "parakeet" (Parakeet v2 on the whole
    /// dictation at release; the old Fast engine, kept for tests and loaded as Instant from a saved setting).
    public var engine = "dictation"
    public var locale = "en-CA"
    /// Off by default: a click at every start gets old fast.
    public var sounds = false
    /// The microphone to read, by its stable id. Empty means the Mac's current default input.
    public var inputDevice = ""
    public var showLevel = true
    /// The level bar's look: "pen", "bars", "tape", "dot" or "classic". Missing in older config files, so optional.
    public var levelStyle: String?
    /// "light", "dark", or nil to match the Mac. Applies to every Redpen Voice window and the menu bar panel.
    public var appearance: String?
    public var levelLook: String { showLevel ? (levelStyle ?? "pen") : "off" }

    public init() {}

    /// Reads every setting it can and keeps the default for the rest. The synthesized decoder failed the whole file
    /// when one key was missing or had the wrong type (a hand edit, or a file from an older version), and Voice
    /// then started from scratch and wrote the defaults over your settings at the next change.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        func maybe<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        let d = Config()
        mode = read(.mode, d.mode)
        firstRunDone = read(.firstRunDone, d.firstRunDone)
        fnKey = read(.fnKey, d.fnKey)
        rightOptionKey = read(.rightOptionKey, d.rightOptionKey)
        talkKey = maybe(.talkKey)
        doubleTap = maybe(.doubleTap)
        pauseMedia = read(.pauseMedia, d.pauseMedia)
        resumeMedia = maybe(.resumeMedia)
        liveWords = maybe(.liveWords)
        screenHints = maybe(.screenHints)
        draftMode = maybe(.draftMode)
        riskMarks = maybe(.riskMarks)
        historyKeep = maybe(.historyKeep)
        suggestWords = maybe(.suggestWords)
        typingWPM = maybe(.typingWPM)
        engine = read(.engine, d.engine)
        locale = read(.locale, d.locale)
        sounds = read(.sounds, d.sounds)
        inputDevice = read(.inputDevice, d.inputDevice)
        showLevel = read(.showLevel, d.showLevel)
        levelStyle = maybe(.levelStyle)
        appearance = maybe(.appearance)
    }

    public static func load() -> Config { load(from: url) }

    /// A file that isn't JSON at all is moved aside to config.damaged-<time>.json before the defaults are used, so
    /// the next save never writes over what you typed.
    public static func load(from file: URL, now: Date = Date()) -> Config {
        guard let d = try? Data(contentsOf: file) else { return Config() }
        if var c = try? JSONDecoder().decode(Config.self, from: d) {
            // The Fast engine (Parakeet v2, whole dictation at release) became Instant on Oct 26 2026: fewer mistakes
            // and no wait (D-816).
            if c.engine == "parakeet" { c.engine = "live" }
            return c
        }
        let aside = file.deletingLastPathComponent().appendingPathComponent("config.damaged-\(Int(now.timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return Config()
    }

    public func save() { save(to: Config.url) }

    public func save(to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: file, options: .atomic) }
    }

    public static func loadNames() -> String {
        (try? String(contentsOf: namesURL, encoding: .utf8)) ?? ""
    }

    public static func ensureNamesFile() {
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

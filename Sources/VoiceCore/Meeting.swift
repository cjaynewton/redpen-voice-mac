import Foundation

/// Meeting notes (D-951): the parts with no microphone, tap or model in them. Two tracks, "Me" from the microphone
/// and "Others" from what the Mac plays, so there are two speakers without any voiceprint. In the room (D-1034) the
/// microphone's voices are told apart too: Me and "Person 2", "Person 3", or the names the user gives them.
public struct Speaker: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let me = Speaker(rawValue: "Me"), others = Speaker(rawValue: "Others"), pause = Speaker(rawValue: "Paused")
    /// The n-th voice told apart on the microphone: "Person 2".
    public static func person(_ n: Int) -> Speaker { Speaker(rawValue: "Person \(n)") }
}

/// One stretch of one voice on the microphone, in seconds from the start of the meeting; voices are numbered from 0
/// in the order they first talk.
public struct RoomTurn: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var voice: Int
    public init(start: Double, end: Double, voice: Int) { self.start = start; self.end = end; self.voice = voice }
}

/// A stretch of one track the engine wrote, in seconds from the start of the meeting.
public struct MeetingSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// One line of the transcript: `[04:12] Me: ...`.
public struct MeetingLine: Equatable, Sendable {
    public var start: Double
    public var speaker: Speaker
    public var text: String
    /// When the line stops; the start when not known.
    public var end: Double
    public init(start: Double, speaker: Speaker, text: String, end: Double? = nil) {
        self.start = start; self.speaker = speaker; self.text = text; self.end = max(start, end ?? start)
    }
    public var markdown: String {
        speaker == .pause ? "[\(Meeting.clock(start))] [\(text)]" : "[\(Meeting.clock(start))] \(speaker.rawValue): \(text)"
    }
}

/// A stretch of a meeting that was paused, in seconds from its start. Nothing is recorded in it: both tracks hold
/// silence there, so every time in the notes stays true to the clock and to the audio files.
public struct MeetingPause: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = max(start, end) }
    public var seconds: Double { end - start }
}

/// Pause and resume while a meeting records, and the time the bar shows: recorded time, which stands still while paused.
public struct MeetingPauses: Codable, Equatable, Sendable {
    public private(set) var done: [MeetingPause] = []
    /// When the pause in progress began, if one is.
    public private(set) var pausedAt: Double?
    public init() {}
    public var isPaused: Bool { pausedAt != nil }

    public mutating func pause(at t: Double) { if pausedAt == nil { pausedAt = t } }
    public mutating func resume(at t: Double) {
        guard let p = pausedAt else { return }
        done.append(MeetingPause(start: p, end: max(p, t))); pausedAt = nil
    }
    /// Every pause, the one in progress closed at `now` (a stop or a crash while paused).
    public func all(closingAt now: Double) -> [MeetingPause] {
        done + (pausedAt.map { [MeetingPause(start: $0, end: max($0, now))] } ?? [])
    }
    /// Seconds recorded by `now`: the time since the start less every pause.
    public func recorded(at now: Double) -> Double {
        max(0, now - all(closingAt: now).reduce(0) { $0 + $1.seconds })
    }
}

/// A word with its time, from engines that give words rather than phrases (Parakeet).
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(_ text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public enum Meeting {
    /// `04:12`, or `1:04:12` from an hour on.
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// The bar's timer: `0:21`, `12:34`, `1:02:10`, whole seconds so far.
    public static func clockShort(_ seconds: Double) -> String { span(Double(Int(max(0, seconds)))) }

    /// `2:10`, `0:05`, or `1:02:10`: how long a pause lasted.
    public static func span(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Lines with each pause marked where it began, `[12:34] [paused 2:10]`, and nothing the engines wrote inside a
    /// pause (silence there can only give Whisper's inventions). Pauses shorter than a second are left unmarked.
    public static func withPauses(_ lines: [MeetingLine], _ pauses: [MeetingPause]) -> [MeetingLine] {
        let real = pauses.filter { $0.seconds >= 1 }
        let kept = lines.filter { l in
            let mid = (l.start + l.end) / 2
            return !real.contains { mid > $0.start && mid < $0.end }
        }
        let marks = real.map { MeetingLine(start: $0.start, speaker: .pause, text: "paused \(span($0.seconds))", end: $0.end) }
        return (kept + marks).enumerated().sorted {
            $0.element.start != $1.element.start ? $0.element.start < $1.element.start
                : ($0.element.speaker == .pause) != ($1.element.speaker == .pause) ? $0.element.speaker == .pause : $0.offset < $1.offset
        }.map(\.element)
    }

    /// `42 min`, `1 h 5 min`, or `40 s` for a short test.
    public static func length(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = Int((Double(s) / 60).rounded())
        return m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min")
    }

    /// `2026-10-30 1415 Meeting`, the name the notes and audio share. Local time.
    public static func baseName(_ start: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        return String(format: "%04d-%02d-%02d %02d%02d Meeting", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// The base name, with " 2", " 3" added when a meeting already has that name, so nothing is written over.
    public static func uniqueBase(_ base: String, taken: (String) -> Bool) -> String {
        if !taken(base) { return base }
        var n = 2
        while taken("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Words grouped into lines: a new line at a pause of `gap` seconds or more, after a sentence ends once the line
    /// has a few seconds in it, and never longer than `maxSeconds`.
    public static func group(_ words: [TimedWord], gap: Double = 0.8, maxSeconds: Double = 20) -> [MeetingSegment] {
        var out: [MeetingSegment] = []
        var cur: [TimedWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            let text = cur.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(MeetingSegment(start: f.start, end: l.end, text: text)) }
            cur = []
        }
        for w in words where !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let l = cur.last, let f = cur.first {
                let ended = l.text.last.map { ".?!".contains($0) } ?? false
                if w.start - l.end >= gap || w.end - f.start > maxSeconds || (ended && l.end - f.start >= 4) { flush() }
            }
            cur.append(TimedWord(w.text.trimmingCharacters(in: .whitespaces), start: w.start, end: w.end))
        }
        flush()
        return out
    }

    // MARK: Echo

    static func keys(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
    }

    /// Words of `a` found in order in `b` (longest common subsequence).
    static func inOrder(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count { cur[j] = x == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]) }
            prev = cur
        }
        return prev[b.count]
    }

    /// On laptop speakers the microphone hears the others too, so their words come back as "Me". A Me line is
    /// dropped when the Others lines within `slack` seconds of it hold most of its words in the same order: 60% for
    /// three words or more, every word for one or two ("Yeah."). Returns the Me lines kept and how many went.
    public static func dropEcho(me: [MeetingSegment], others: [MeetingSegment], slack: Double = 2) -> (kept: [MeetingSegment], dropped: Int) {
        var kept: [MeetingSegment] = [], dropped = 0
        for m in me {
            let mine = keys(m.text)
            guard !mine.isEmpty else { continue }
            let near = others.filter { $0.end >= m.start - slack && $0.start <= m.end + slack }.sorted { $0.start < $1.start }
            let theirs = near.flatMap { keys($0.text) }
            let shared = inOrder(mine, theirs)
            let echo = mine.count >= 3 ? Double(shared) >= Double(mine.count) * 0.6 : shared == mine.count
            if echo { dropped += 1 } else { kept.append(m) }
        }
        return (kept, dropped)
    }

    /// Both tracks, by time. At the same moment Others comes first: the question before the answer. `voices` names
    /// the microphone's lines one by one when the voices in the room were told apart (D-1034); otherwise all are Me.
    public static func merge(me: [MeetingSegment], others: [MeetingSegment], voices: [Speaker]? = nil) -> [MeetingLine] {
        let a = me.enumerated().map { i, s in
            MeetingLine(start: s.start, speaker: voices.flatMap { i < $0.count ? $0[i] : nil } ?? .me, text: s.text, end: s.end)
        }
        let b = others.map { MeetingLine(start: $0.start, speaker: .others, text: $0.text, end: $0.end) }
        return (b + a).enumerated().sorted {
            $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset
        }.map(\.element)
    }

    /// Whisper sometimes writes the same short line twice ("Okay." "Okay."). A line is dropped when it is exactly
    /// the same words (case and punctuation aside) as the same speaker's line before it, starting within `within`
    /// seconds of that line's end.
    public static func dropRepeats(_ lines: [MeetingLine], within: Double = 2) -> [MeetingLine] {
        var last: [Speaker: MeetingLine] = [:], out: [MeetingLine] = []
        for l in lines {
            if let p = last[l.speaker], !keys(l.text).isEmpty, keys(p.text) == keys(l.text), l.start - p.end <= within {
                last[l.speaker]?.end = max(p.end, l.end)
                continue
            }
            out.append(l); last[l.speaker] = l
        }
        return out
    }

    /// One paragraph per turn: lines from the same speaker in a row are joined under the first one's time, and a
    /// new paragraph starts when the speaker changes, after a pause of `gap` seconds, or once a paragraph has run
    /// `most` seconds. That cap keeps a long turn (or a call where everyone is Others) in parts a time can point at.
    public static func paragraphs(_ lines: [MeetingLine], gap: Double = 3, most: Double = 45) -> [MeetingLine] {
        var out: [MeetingLine] = []
        for l in lines {
            if var p = out.last, p.speaker == l.speaker, l.start - p.end <= gap, l.start - p.start < most {
                p.text += " " + l.text
                p.end = max(p.end, l.end)
                out[out.count - 1] = p
            } else { out.append(l) }
        }
        return out
    }

    // MARK: The file

    /// The notes: date, start and length, where the audio is, then the transcript, one line per paragraph so any
    /// Markdown reader keeps them apart.
    public static func markdown(start: Date, seconds: Double, lines: [MeetingLine], audio: [String], echoDropped: Int,
                                engine: String, notes: [String] = [], paused: Double = 0, room: [Speaker] = [], calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_CA")) -> String {
        let day = DateFormatter(); day.locale = locale; day.calendar = calendar; day.timeZone = calendar.timeZone
        day.dateFormat = "EEEE d MMMM yyyy"
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.calendar = calendar; iso.timeZone = calendar.timeZone
        iso.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.locale = Locale(identifier: "en_US_POSIX"); time.calendar = calendar; time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        var out = "# Meeting notes, \(day.string(from: start))\n\n"
        out += "- Date: \(iso.string(from: start))\n"
        out += "- Started: \(time.string(from: start))\n"
        out += "- Length: \(length(seconds))\n"
        if paused >= 1 { out += "- Paused: \(length(paused)), nothing recorded then\n" }
        out += "- Written by: \(engine), on this Mac\n"
        if !audio.isEmpty { out += "- Audio: " + audio.map { "[\($0)](<\($0)>)" }.joined(separator: ", ") + "\n" }
        out += "\n"
        if echoDropped > 0 {
            out += "Me is your microphone and Others is what the Mac played. \(echoDropped) Me \(echoDropped == 1 ? "line was" : "lines were") left out because the microphone picked up the others from the speakers.\n\n"
        } else {
            out += "Me is your microphone and Others is what the Mac played.\n\n"
        }
        if let r = roomNote(room) { out += r + "\n\n" }
        for n in notes { out += n + "\n\n" }
        out += "## Transcript\n\n"
        out += lines.isEmpty ? "Nothing was heard.\n" : lines.map(\.markdown).joined(separator: "\n\n") + "\n"
        return out
    }

    // MARK: Voices in the room (D-1034)

    /// Which voice is the user's, from how close each voice is to their voiceprint (cosine): the closest, when it is
    /// close (0.5 or more) and clearly closer than any other (by 0.25). On two bench meetings the user's own voice
    /// scored 0.72 and 0.81 and no one else above 0.18. Nil when it isn't clear: then no voice is called Me.
    public static func whichIsMe(_ closeness: [Float], least: Float = 0.5, margin: Float = 0.25) -> Int? {
        guard let best = closeness.indices.max(by: { closeness[$0] < closeness[$1] }), closeness[best] >= least else { return nil }
        let next = closeness.indices.filter { $0 != best }.map { closeness[$0] }.max() ?? -1
        return closeness[best] - next >= margin ? best : nil
    }

    /// The labels for `count` voices: one voice is simply Me; with the user's own voice known it is Me and the rest
    /// are Person 2, Person 3 in the order they first talk; with no voice known they are Person 1, Person 2 and so on.
    public static func roomNames(count: Int, me: Int?) -> [Speaker] {
        guard count > 1 else { return [Speaker](repeating: .me, count: max(count, 0)) }
        guard let me, me < count else { return (0..<count).map { .person($0 + 1) } }
        var n = 1
        return (0..<count).map { i in
            if i == me { return .me }
            n += 1
            return .person(n)
        }
    }

    /// Each microphone line gets the voice heard most while it was said, or the nearest voice within 2 seconds when
    /// none was heard during it; with nothing near, Me.
    public static func voices(for lines: [MeetingSegment], turns: [RoomTurn], names: [Speaker]) -> [Speaker] {
        lines.map { l in
            var heard: [Int: Double] = [:]
            for t in turns where t.end > l.start && t.start < l.end {
                heard[t.voice, default: 0] += min(t.end, l.end) - max(t.start, l.start)
            }
            let voice = heard.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
                ?? turns.map { t in (t.voice, max(t.start - l.end, l.start - t.end, 0)) }.filter { $0.1 <= 2 }.min { $0.1 < $1.1 }?.0
            return voice.flatMap { $0 < names.count ? names[$0] : nil } ?? .me
        }
    }

    /// How the line about the voices ends, so a rename can find it and say it again.
    static let roomNoteEnd = " To give them names, choose Name the voices in the menu."

    /// The line under the header when the microphone's voices were told apart.
    public static func roomNote(_ names: [Speaker]) -> String? {
        let people = names.filter { $0 != .me }.map(\.rawValue)
        guard !people.isEmpty else { return nil }
        let list = people.count == 1 ? people[0] : people.dropLast().joined(separator: ", ") + " and " + people.last!
        let me = names.contains(.me) ? "Me is your own voice and \(list) " + (people.count == 1 ? "is another voice" : "are other voices")
                                     : "\(list) are the voices"
        return "\(me) on your microphone, told apart on this Mac." + roomNoteEnd
    }

    /// A voice's label changed everywhere in a notes file: its transcript lines and the summary's owners. Nil when
    /// the new name can't be a speaker (empty, too long, or holding the characters lines are built from).
    public static func renaming(_ from: Speaker, to name: String, in file: String) -> String? {
        renaming([(from, name)], in: file)
    }

    /// Several voices renamed at once, so swapping two names, or giving Person 1 the name Person 2 had, comes out
    /// right: each goes to a placeholder first, then to its new name. Only labels change: the speaker at the start
    /// of a transcript line and the owner at the start of a to-do, never what anyone said. The line under the
    /// header naming the voices is written again. Nil when any new name can't be a speaker.
    public static func renaming(_ changes: [(Speaker, String)], in file: String) -> String? {
        let names = changes.map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy(canName) else { return nil }
        var out = file
        let held = changes.indices.map { "\u{E000}\($0)\u{E000}" }
        for (i, c) in changes.enumerated() where c.0.rawValue != names[i] { out = relabel(c.0.rawValue, to: held[i], in: out) }
        for (i, c) in changes.enumerated() where c.0.rawValue != names[i] { out = relabel(held[i], to: names[i], in: out) }
        // The header's line about the voices, said again with the new names.
        if let note = out.components(separatedBy: "\n").first(where: { $0.hasSuffix(roomNoteEnd) }) {
            out = out.replacingOccurrences(of: note, with: roomNote(voices(inFile: out)) ?? "")
        }
        return out
    }

    /// A name a voice can take: a speaker label (as `said` reads one), without the characters headings and bold are
    /// made of, and not Others or Paused, which mean something else.
    public static func canName(_ name: String) -> Bool {
        isSpeaker(name) && name.rangeOfCharacter(from: CharacterSet(charactersIn: "#*")) == nil
            && ![Speaker.others.rawValue, Speaker.pause.rawValue].contains(name)
    }

    /// A label changed where labels are: `[12:34] Name: ` at the start of a transcript line, and `- Name: ` at the
    /// start of a to-do in the summary.
    private static func relabel(_ from: String, to: String, in file: String) -> String {
        let f = NSRegularExpression.escapedPattern(for: from), t = NSRegularExpression.escapedTemplate(for: to)
        var out = file
        for (pattern, template) in [("(?m)^(\\[[0-9:]+\\] )" + f + ": ", "$1" + t + ": "), ("(?m)^- " + f + ": ", "- " + t + ": ")] {
            guard let r = try? NSRegularExpression(pattern: pattern) else { continue }
            if pattern.hasPrefix("(?m)^- ") {
                // To-dos only: everything before the transcript, under a To-dos heading.
                out = byTodoSections(out) { r.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: template) }
            } else {
                out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
            }
        }
        return out
    }

    /// `change` applied to each To-dos list before the transcript, and nothing else.
    private static func byTodoSections(_ file: String, _ change: (String) -> String) -> String {
        var lines = file.components(separatedBy: "\n"), inTodos = false
        for i in lines.indices {
            let l = lines[i]
            if l.hasPrefix("## Transcript") { break }
            if l.hasPrefix("#") { inTodos = l.hasPrefix("### To-dos"); continue }
            if inTodos { lines[i] = change(l) }
        }
        return lines.joined(separator: "\n")
    }

    /// The voices a notes file's transcript has, other than Others, in the order they first talk.
    public static func voices(inFile file: String) -> [Speaker] {
        var out: [Speaker] = []
        for s in said(transcript(inFile: file)) where s.speaker != Speaker.others.rawValue && !out.contains(Speaker(rawValue: s.speaker)) {
            out.append(Speaker(rawValue: s.speaker))
        }
        return out
    }

    /// For the meeting chat, from the menu or the first meeting's tip.
    public static let notice = "Heads up: I'm taking notes on this call with Redpen. It runs on my Mac and nothing is sent anywhere."

    public static let savingWarning = "Recording stopped saving. The disk may be full."
    public static func savingNote(at seconds: Double) -> String {
        "Recording stopped saving at \(clock(seconds)) from the start. Nothing after it was kept. The disk may be full."
    }

    /// The effective automatic writer, without invoking a helper or asking the after-transcript question.
    public static func notice(claudeNotes: Bool?, claudeInstalled: Bool) -> String {
        guard claudeNotes == true, claudeInstalled else { return notice }
        return "Heads up: I'm taking notes on this call with Redpen. The audio stays on my Mac. The meeting's text goes to Claude under my own account to write the notes."
    }

    /// Under the header when the Mac's sound was silent the whole meeting: most likely the permission is off.
    public static let silentMacNote = "The Mac's sound was silent for the whole meeting, so only your microphone is here. If others were talking, allow Redpen Voice under System Audio Recording in Privacy & Security, then try again."

    /// The same, when the microphone's voices were told apart (D-1034): most likely a meeting in person, but a
    /// call with the permission off looks the same, so it is still said.
    public static let roomSilentNote = "The Mac played nothing, so this was taken as a meeting in person. If it was a call, allow Redpen Voice under System Audio Recording in Privacy & Security."

    // MARK: The summary

    /// The transcript in pieces of at most `maxChars`, whole lines only, so each fits the on-device model's window.
    /// A single line longer than that is cut at a space.
    public static func pieces(_ lines: [String], maxChars: Int) -> [String] {
        var out: [String] = [], cur = ""
        for var line in lines {
            while line.count > maxChars {
                let head = line.prefix(maxChars)
                let cut = head.lastIndex(of: " ") ?? head.endIndex
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(line[..<cut]))
                line = String(line[cut...]).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }
            if !cur.isEmpty, cur.count + 1 + line.count > maxChars { out.append(cur); cur = "" }
            cur += cur.isEmpty ? line : "\n" + line
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Who said they would do it, only as the transcript has it: Me, Others, a voice the transcript names (Person 2,
    /// or the name it was given; D-1034), or a name said in the meeting. Anything else (a name the model made up)
    /// becomes "Not clear".
    public static func who(_ name: String, transcript: String) -> String {
        // Only stray marks at the ends go: "Rima (VMC)" keeps its bracket.
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?\"'*-")))
        if !n.isEmpty, n != Speaker.me.rawValue, n != Speaker.others.rawValue, transcript.contains("] \(n): ") { return n }
        // Me or Others only when that track says anything at all: with a silent microphone, nothing is Me's.
        if n.caseInsensitiveCompare("me") == .orderedSame || n.caseInsensitiveCompare("I") == .orderedSame {
            return transcript.contains("] Me: ") ? "Me" : "Not clear"
        }
        if n.caseInsensitiveCompare("others") == .orderedSame || n.caseInsensitiveCompare("other") == .orderedSame {
            return transcript.contains("] Others: ") ? "Others" : "Not clear"
        }
        // A voice's label counts only where it marks lines (above); as a name said aloud, only what people said
        // counts, never the labels themselves, so a made-up "Person 3" isn't backed by "Person 2" lines.
        if n.range(of: "^Person [0-9]+$", options: .regularExpression) != nil { return "Not clear" }
        let spoken = said(transcript).map(\.text)
        let said = Set(keys(spoken.isEmpty ? transcript : spoken.joined(separator: " ")))
        let parts = keys(n)
        if !parts.isEmpty, parts.allSatisfy(said.contains) { return n }
        return "Not clear"
    }

    /// Names in the summary (capitalised words inside a sentence) that are nowhere in the transcript.
    public static func unknownNames(_ summary: String, transcript: String) -> [String] {
        // "Hogan's" and "IDs" in either text are Hogan and ID.
        let plain = { (k: String) in k.count > 2 && k.hasSuffix("s") ? String(k.dropLast()) : k }
        let said = Set(keys(transcript).flatMap { [$0, plain($0)] })
        let known: Set<String> = ["me", "others", "i", "not", "clear", "am", "pm"]
        var seen = Set<String>(), out: [String] = []
        for sentence in summary.components(separatedBy: CharacterSet(charactersIn: ".!?:\n")) {
            let words = sentence.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            for w in words.dropFirst() {
                // "Friday's" is Friday.
                let bare = (w.hasSuffix("'s") ? w.dropLast(2) : w[...]).filter { $0.isLetter || $0.isNumber }
                guard let f = bare.first, f.isUppercase, bare.count > 1 else { continue }
                let k = bare.lowercased()
                if !said.contains(k), !said.contains(plain(k)), !known.contains(k), seen.insert(k).inserted { out.append(String(bare)) }
            }
        }
        return out
    }

    /// The summary left out, with one plain line saying why.
    public static func noSummary(_ why: String) -> String { "## Summary\n\nNo summary was written. \(why)\n" }

    // MARK: Long audio

    /// Stretches of at least `minimum` seconds with no line in them, between 0 and `length`: where Whisper may have
    /// judged real talk to be silence and skipped it. Trimmed by `pad` at each side, clear of the lines around it.
    public static func gaps(_ segments: [MeetingSegment], length: Double, minimum: Double, pad: Double = 0.2) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = [], from = 0.0
        for s in segments.sorted(by: { $0.start < $1.start }) + [MeetingSegment(start: length, end: length, text: "")] {
            if s.start - from >= minimum { out.append((from + pad)...(max(from + pad, s.start - pad))) }
            from = max(from, s.end)
        }
        return out
    }

    /// Seconds of `samples` (16 kHz) loud enough to be someone talking: 30 ms stretches at `level` or above.
    public static func talkSeconds(_ samples: ArraySlice<Float>, level: Float = 0.01) -> Double {
        let frame = 480
        var n = 0, i = samples.startIndex
        while i + frame <= samples.endIndex {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            if (sum / Float(frame)).squareRoot() >= level { n += 1 }
            i += frame
        }
        return Double(n * frame) / 16_000
    }

    /// Where to end a piece of a long track: the quietest 30 ms in the `search` samples before `target`, so a word
    /// is never cut in two. `samples` starts at the piece's start.
    public static func cutPoint(_ samples: [Float], target: Int, search: Int) -> Int {
        guard target < samples.count else { return samples.count }
        let frame = 480
        let from = max(0, target - search)
        var best = target, quietest = Float.greatestFiniteMagnitude
        var i = from
        while i + frame <= target {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            if sum < quietest { quietest = sum; best = i + frame / 2 }
            i += frame
        }
        return best
    }

    /// A folder whose files may leave the Mac: Documents and Desktop sync to iCloud on many Macs, and the iCloud and
    /// cloud-storage folders always do.
    public static func mightSync(_ path: String, home: String) -> Bool {
        let p = (path as NSString).standardizingPath, h = (home as NSString).standardizingPath
        let risky = ["Documents", "Desktop", "Library/Mobile Documents", "Library/CloudStorage", "Dropbox", "Google Drive", "OneDrive"]
        return risky.contains { p == h + "/" + $0 || p.hasPrefix(h + "/" + $0 + "/") }
    }
}

/// What a meeting in progress leaves on disk next to its two raw tracks, so a quit or crash loses nothing: the next
/// launch reads it and offers to write the notes.
public struct MeetingManifest: Codable, Equatable, Sendable {
    public var started: Date
    /// Seconds from `started` to each track's first sample (the microphone's includes its 0.6 s pre-roll).
    public var meOffset: Double?
    public var othersOffset: Double?
    public var stopped: Date?
    /// First failed audio save, shared by both tracks. Nothing at or after this time is kept.
    public var savingStopped: Date?
    /// Set once the transcript is saved, so a second try finishes the same file instead of writing another.
    public var notesFile: String?
    /// Pauses, with the one in progress if the app stopped while paused.
    public var pauses: MeetingPauses?
    public init(started: Date) { self.started = started }

    public static let meFile = "me.pcm", othersFile = "others.pcm", file = "meeting.json"
    /// The raw tracks: 16 kHz, mono, 16-bit little-endian, appended as they record.
    public static let rate = 16_000

    public static func samples(bytes: Int) -> Int { bytes / 2 }
}

/// Both tracks stop accepting audio on the first failed write or flush.
public final class MeetingSaving: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Date?
    public init() {}
    public var stopped: Date? { lock.withLock { failure } }
    @discardableResult public func fail(at time: Date) -> Bool {
        lock.withLock {
            guard failure == nil else { return false }
            failure = time
            return true
        }
    }
}

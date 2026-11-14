import Foundation

/// Words the engine gets wrong on every model: names, products, your own terms. Each line in the list is
/// `heard = meant` ("claw code = Claude Code") or just a word to keep as written. Replacement is whole-word
/// and ignores case, so "claw code" in the middle of a sentence becomes "Claude Code" and "clawed" is left alone.
///
/// Names of two or more words are also matched by sound (Nov 13 2026): "Red Fan voice" and "red plan grammar"
/// become Redpen Voice and Redpen Grammar when those names are in the list. The rules are the ones Redpen Grammar
/// tested against the same list (its RedpenCore/Names.swift), kept narrow because Voice changes the words
/// without asking. A one-word name is still matched only as written: "red pan" and "red fan" are real phrases.
public struct Names: Equatable {
    public struct Entry: Equatable { public let heard: String; public let meant: String }
    public private(set) var entries: [Entry] = []
    /// Names of two or more words that are long and plain enough to be told apart from ordinary words by sound.
    private var soundNames: [SoundName] = []
    /// Every listed spelling in lower case. A run of spoken words that is on the list is right as it stands.
    private var listed: Set<String> = []

    struct SoundName: Equatable { let spelling: String; let words: Int; let letters: String; let key: String }

    public init(text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { entries.append(Entry(heard: parts[0], meant: parts[1])) }
            else if parts.count == 1 { entries.append(Entry(heard: parts[0], meant: parts[0])) }
        }
        listed = Set(entries.flatMap { [$0.heard.lowercased(), $0.meant.lowercased()] })
        for spelling in spellings {
            let words = spelling.split(separator: " ").count
            guard words >= 2, let letters = Self.soundable(spelling) else { continue }
            let key = Self.soundKey(letters)
            if key.count >= 3 { soundNames.append(SoundName(spelling: spelling, words: words, letters: letters, key: key)) }
        }
    }

    /// The words the engine should listen for. Both halves of every entry, so the engine has a chance to
    /// get the real name first and the replacement is only a net.
    public var vocabulary: [String] { Array(Set(entries.flatMap { [$0.heard, $0.meant] })).sorted() }
    /// Only the right spellings, for Whisper's hint: telling it the misheard form would teach it the wrong one.
    public var spellings: [String] { var seen = Set<String>(); return entries.map(\.meant).filter { seen.insert($0.lowercased()).inserted } }

    /// A bare line written all in lower case ("store brand") is a phrase to leave alone, not a spelling to
    /// enforce: applying it could only take capitals away, such as the one that starts a sentence. It still
    /// counts as listed, so it is never taken for a name that sounds like it.
    static func protects(_ e: Entry) -> Bool { e.heard == e.meant && e.heard == e.heard.lowercased() }

    public func apply(_ text: String) -> String {
        var out = text
        // What the list itself wrote into the text. Exact entries win first: sound never rewrites these.
        var written: [NSRange] = []
        // Longest first, so "claw code" wins over "claw".
        for e in entries.sorted(by: { $0.heard.count > $1.heard.count }) where !Self.protects(e) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: e.heard) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let meant = e.meant as NSString
            // Right to left, so the places still to do keep their positions.
            for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                out = (out as NSString).replacingCharacters(in: m.range, with: e.meant)
                let delta = meant.length - m.range.length
                written = written.map { $0.location >= NSMaxRange(m.range) ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
                written.append(NSRange(location: m.range.location, length: meant.length))
            }
        }
        guard !soundNames.isEmpty else { return out }
        for m in soundMatches(in: out, avoiding: written).reversed() {
            out = (out as NSString).replacingCharacters(in: m.range, with: m.name)
        }
        return out
    }

    // MARK: Names heard wrong, by sound

    /// A name is matched by sound only when it is long and plain enough to be told apart from ordinary words:
    /// six letters or more, letters and spaces only, no run of capitals ("ChatGPT", "MMK Retail" and "QMD" are out).
    static func soundable(_ name: String) -> String? {
        guard name.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == " " }) else { return nil }
        guard name.range(of: "[A-Z]{3,}|\\b[A-Z]{2,}\\b", options: .regularExpression) == nil else { return nil }
        let letters = name.lowercased().filter { $0 != " " }
        return letters.count >= 6 ? letters : nil
    }

    /// Whole plain words only. A word with an apostrophe ("Penn's", "don't") is never part of a name heard wrong.
    private static let word = try! NSRegularExpression(pattern: "(?<![A-Za-z'\u{2019}])[A-Za-z]{2,}(?![A-Za-z'\u{2019}])")

    /// Runs of spoken words that sound like a listed name of two or more words, in reading order, none
    /// overlapping. The run has the name's word count, give or take one, and never fewer than two words.
    func soundMatches(in text: String, avoiding written: [NSRange] = []) -> [(range: NSRange, name: String)] {
        let ns = text as NSString
        // Every word with its place. Words on either side of punctuation are never joined: "the red. Pen" is two
        // thoughts.
        let words = Self.word.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let sizes = Array(Set(soundNames.flatMap { [$0.words - 1, $0.words, $0.words + 1] }).filter { $0 >= 2 }).sorted(by: >)
        var out: [(NSRange, String)] = []
        var i = 0
        while i < words.count {
            var matched = false
            for size in sizes where i + size <= words.count {
                let run = Array(words[i..<(i + size)])
                // Single spaces only between the words.
                guard zip(run, run.dropFirst()).allSatisfy({ $1.location - NSMaxRange($0) == 1 && ns.substring(with: NSRange(location: NSMaxRange($0), length: 1)) == " " }) else { continue }
                let range = NSRange(location: run[0].location, length: NSMaxRange(run[size - 1]) - run[0].location)
                guard !written.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let lower = ns.substring(with: range).lowercased()
                // Anything on the list is right as spoken, and so is its plural: listing "store brand" keeps it
                // from ever being taken for a name.
                if listed.contains(lower) || (lower.hasSuffix("s") && listed.contains(String(lower.dropLast()))) { continue }
                let letters = lower.filter { $0 != " " }
                let key = Self.soundKey(letters)
                guard let hit = soundNames.first(where: { abs($0.words - size) <= 1 && Self.sounds(letters, key, like: $0.letters, $0.key) }) else { continue }
                // Already the name, apart from capitals: leave it.
                if lower == hit.spelling.lowercased() { continue }
                // The name is already there, said right, with a neighbour: leave it.
                let said = lower.split(separator: " "), want = hit.spelling.lowercased().split(separator: " ")
                if want.count < said.count, (0...(said.count - want.count)).contains(where: { Array(said[$0..<($0 + want.count)]) == Array(want) }) { continue }
                // One word of the name said right and the other a different real word ("Claude copy" beside Claude
                // Code): only a word that sounds the same ("fare" for Fair) is a mishearing. Found in a sweep of
                // 360,000 words of notes, Nov 13 2026. This is narrower than Grammar's rule on purpose.
                if said.count == want.count {
                    let differing = zip(said, want).filter { $0 != $1 }
                    if differing.count == 1, Self.soundKey(String(differing[0].0)) != Self.soundKey(String(differing[0].1)) { continue }
                }
                out.append((range, hit.spelling))
                i += size; matched = true
                break
            }
            if !matched { i += 1 }
        }
        return out
    }

    /// The same letters run together or spaced apart ("red pen voice" for Redpen Voice), or close in both sound
    /// and spelling ("red fan voice", "red plan grammar"). Both tests must pass, and the first two letters must
    /// agree.
    static func sounds(_ letters: String, _ key: String, like name: String, _ nameKey: String) -> Bool {
        if letters == name { return true }
        // A plural is the speaker's own word, not a mishearing.
        if letters == name + "s" || letters + "s" == name { return false }
        guard letters.prefix(2) == name.prefix(2), abs(letters.count - name.count) <= 2 else { return false }
        guard key == nameKey || distance(Array(key), Array(nameKey)) == 1 else { return false }
        return distance(Array(letters), Array(name)) <= 2
    }

    /// Consonants by where the mouth makes them, vowels dropped after the first letter, repeats run together.
    /// "redpen", "redben" and "redfan" all come out RTPN.
    static func soundKey(_ lowercaseLetters: String) -> String {
        let s = Array(lowercaseLetters)
        var out: [Character] = []
        func push(_ c: Character) { if out.last != c { out.append(c) } }
        var i = 0
        while i < s.count {
            let c = s[i], next: Character? = i + 1 < s.count ? s[i + 1] : nil
            switch c {
            case "a", "e", "i", "o", "u", "y":
                if i == 0 { out.append("A") }
            case "h", "w": break
            case "b", "p", "f", "v": push("P")
            case "d", "t": push("T")
            case "c":
                if let n = next, "eiy".contains(n) { push("S") } else { push("K") }
            case "g":
                if next == "h" { i += 1 } else { push("K") }
            case "k", "q": push("K")
            case "x": push("K"); push("S")
            case "s", "z": push("S")
            case "j": push("J")
            case "m", "n": push("N")
            case "l": push("L")
            case "r": push("R")
            default: break
            }
            i += 1
        }
        return String(out)
    }

    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = a[i - 1] == b[j - 1] ? prev : min(prev, row[j - 1], cur) + 1
                prev = cur
            }
        }
        return row[b.count]
    }
}

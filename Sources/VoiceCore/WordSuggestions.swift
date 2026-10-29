import CryptoKit
import Foundation

/// Local word sightings only. No sentences, surrounding text or audio are retained.
public final class WordSuggestions {
    public static let cap = 256
    public struct Candidate: Codable, Equatable {
        public var word: String
        public var count: Int
        public var firstDay: String
        public var lastDay: String
        public var multipleDays: Bool
    }
    private struct File: Codable {
        var candidates: [String: Candidate] = [:]
        var dismissed: Set<String> = [] // fingerprints, including words explicitly added
        var lastOfferDay: String?
    }
    public let url: URL
    private var file = File()
    public var candidates: [Candidate] { file.candidates.values.sorted { $0.word < $1.word } }

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(File.self, from: data) { file = saved }
    }

    private static func key(_ word: String) -> String { word.lowercased().replacingOccurrences(of: "’", with: "'") }
    private static func fingerprint(_ word: String) -> String {
        SHA256.hash(data: Data(key(word).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static let tokens = try! NSRegularExpression(pattern: "[\\p{L}]+(?:['’\\-][\\p{L}]+)*")

    /// Conservative English stop words, calendar words and ordinary dictation/UI vocabulary. Case-insensitive.
    private static let common: Set<String> = Set("""
    a about above across act action actually add after again against age ago agree air all allow almost alone along already also although always am among amount an and another answer any anyone anything anyway appear app application are area around as ask at away back bad bar base be because become been before begin behind being believe below best better between big bit black blue body book both box bring build business but buy by call came can cannot can't car care case change check child children choose clear click close code cold colour come common company complete computer consider control could couldn't count country course create current cut day days decide did didn't different do does doesn't doing done don't door down during each early easy edit else end engine enough even ever every everybody everyone everything example eye face fact failed fall family far fast father feel few field file final find fine first five fix follow following food for form found four free friend from front full game gave general get gets getting girl give given go goes going gone good got great green group grow guess guy had half hand happen hard has hasn't have haven't having he head hear heard help her here hers herself hey hi high him himself his history hold home hope hour house how however hundred i i'd i'll i'm i've idea if important in include information inside instead interest into is isn't it its it's itself job just keep kept key kind knew know known large last late later learn least leave left less let let's letter life light like line list little live local long look lot love low made main make man many mark may maybe me mean means meant media might mind minute miss mode model moment money month more morning most mother move much must my myself name near need never new next nice night no none nor normal north not note nothing now number of off often oh okay old on once one only open or order other others our out outside over own page paper part past pause people per person phone pick place play please point possible power pretty probably problem program put question quite rather read ready real really reason red remember rest result right room rule run said same saw say says school screen second section see seem seen self send sentence set setting several she short should show side since small so some somebody someone something sometimes song soon sorry sort sound south space speak start state stay still stop story such sure switch system table take talk tell ten test text than thank thanks that that's the their theirs them themselves then there there's these they they'd they'll they're they've thing think third this those though thought three through time to today together told tomorrow too took top toward tried true try turn two type under understand until up us use used user using usual value very video voice wait want was wasn't watch water way we we'd we'll we're we've week well went were weren't what what's whatever when where whether which while white who whole whom whose why will window wish with within without woman women won't word work world would wouldn't write wrong year yes yet you you'd you'll you're you've young your yours yourself yourselves zero monday tuesday wednesday thursday friday saturday sunday january february march april may june july august september october november december english french canadian american hello goodbye welcome morning afternoon evening settings control option command shift return enter accessibility microphone most accurate instant raw whisper
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static func listed(_ names: Names) -> Set<String> {
        Set(names.vocabulary.flatMap { text in
            tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range, in: text).map { key(String(text[$0])) }
            }
        })
    }

    public static func words(in text: String, names: Names, lowConfidence: [String] = []) -> [String] {
        let listed = listed(names), uncertain = Set(lowConfidence.map(key))
        var seen = Set<String>(), out: [String] = [], previousEnd = text.startIndex, first = true
        for match in tokens.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let gap = text[previousEnd..<range.lowerBound]
            let sentenceStart = first || gap.contains { ".!?\n\r\u{2028}\u{2029}".contains($0) }
            var word = String(text[range])
            if word.hasSuffix("'s") || word.hasSuffix("’s") { word.removeLast(2) }
            previousEnd = range.upperBound; first = false
            let k = key(word)
            let ordinary = common.contains(k) || (k.hasSuffix("s") && common.contains(String(k.dropLast())))
            guard (3...40).contains(word.count), !ordinary, !listed.contains(k),
                  (word.first?.isUppercase == true && !sentenceStart) || uncertain.contains(k),
                  seen.insert(k).inserted else { continue }
            out.append(word)
        }
        return out
    }

    /// One sighting per finished dictation. Repeating a name in one sentence cannot reach the threshold.
    public func observe(_ text: String, names: Names, enabled: Bool = true, keep: String = "all",
                        date: Date = Date(), calendar: Calendar = .current, lowConfidence: [String] = []) {
        guard keep != "none" else { clear(); return }
        guard enabled else { return }
        let day = StatsStore.key(date, calendar: calendar)
        let listed = Self.listed(names)
        file.candidates = file.candidates.filter { !listed.contains($0.key) }
        for word in Self.words(in: text, names: names, lowConfidence: lowConfidence) {
            let k = Self.key(word)
            guard !file.dismissed.contains(Self.fingerprint(word)) else { continue }
            var c = file.candidates[k] ?? Candidate(word: word, count: 0, firstDay: day, lastDay: day, multipleDays: false)
            c.count = min(3, c.count + 1)
            c.multipleDays = c.multipleDays || c.firstDay != day
            c.lastDay = day
            file.candidates[k] = c
        }
        if file.candidates.count > Self.cap {
            let kept = file.candidates.sorted {
                if $0.value.lastDay != $1.value.lastDay { return $0.value.lastDay > $1.value.lastDay }
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.key < $1.key
            }.prefix(Self.cap)
            file.candidates = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        save()
    }

    public func next(names: Names, date: Date = Date(), calendar: Calendar = .current) -> String? {
        guard file.lastOfferDay != StatsStore.key(date, calendar: calendar) else { return nil }
        let listed = Self.listed(names)
        return file.candidates.values.filter {
            $0.count >= 3 && $0.multipleDays && !listed.contains(Self.key($0.word)) && !file.dismissed.contains(Self.fingerprint($0.word))
        }.sorted {
            if $0.firstDay != $1.firstDay { return $0.firstDay < $1.firstDay }
            return $0.word < $1.word
        }.first?.word
    }

    public func offered(date: Date = Date(), calendar: Calendar = .current) {
        file.lastOfferDay = StatsStore.key(date, calendar: calendar); save()
    }

    public func dismiss(_ word: String) {
        file.dismissed.insert(Self.fingerprint(word)); file.candidates.removeValue(forKey: Self.key(word)); save()
    }

    public func clear() {
        file = File()
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(file) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

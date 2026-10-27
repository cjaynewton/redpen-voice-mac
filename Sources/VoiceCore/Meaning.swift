import Foundation

/// Guards "Tidy it up" (D-817): a tidy that adds or drops a "not", or changes a number, changed what you meant, so
/// the raw words go in instead. A word count alone let a dropped "not" through.
public enum Meaning {
    static let negations: Set<String> = ["not", "never", "no", "without", "none", "nobody", "nothing", "nor", "neither", "nowhere", "cannot"]
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
        "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90", "hundred": "100", "thousand": "1000",
        "million": "1000000", "billion": "1000000000", "half": "0.5", "first": "1st", "second": "2nd", "third": "3rd",
    ]

    static func words(_ s: String) -> [String] {
        let text = s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "−", with: "-")
        let keep: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "." || $0 == "," || $0 == "-" }
        var out: [String] = []
        for raw in text.split(whereSeparator: { !keep($0) }) {
            let t = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,'"))
            // A leading minus before a digit stays ("-5"); any other hyphen splits ("twenty-one" is "twenty", "one").
            if t.hasPrefix("-"), t.dropFirst().first?.isNumber == true { out.append(t); continue }
            let parts = t.split(separator: "-").map(String.init).filter { !$0.isEmpty }
            // All digits ("2026-10-11", "555-1234"): one number, kept whole so its order counts.
            if parts.count > 1, parts.allSatisfy({ $0.allSatisfy { $0.isNumber || $0 == "." || $0 == "," } }) { out.append(t); continue }
            out += parts
        }
        return out
    }

    /// How many negations: the words above plus every "n't" ("don't", "isn't", "won't").
    static func negationCount(_ s: String) -> Int {
        words(s).filter { negations.contains($0) || $0.hasSuffix("n't") }.count
    }

    /// The numbers said, as digits where a word names one, sorted, so "5" and "five" count the same.
    static func numbers(_ s: String) -> [String] {
        words(s).compactMap { w -> String? in
            let digits = w.replacingOccurrences(of: ",", with: "")
            // A minus sign counts: "-5" and "5" are different numbers.
            if digits.first?.isNumber == true || (digits.hasPrefix("-") && digits.dropFirst().first?.isNumber == true) { return digits }
            return numberWords[w.trimmingCharacters(in: CharacterSet(charactersIn: "-"))]
        }.sorted()
    }

    /// Why the tidy changed the meaning ("negation" or "number"), or nil when it kept it.
    public static func changed(_ raw: String, _ tidy: String) -> String? {
        if negationCount(raw) != negationCount(tidy) { return "negation" }
        if numbers(raw) != numbers(tidy) { return "number" }
        return nil
    }
}

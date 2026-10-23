import Foundation

/// Takes out sounds that are not words: "um", "uh", "erm", "hmm". Nothing else is touched, so the meaning cannot
/// change. "Like", "you know" and repeated words stay, because sometimes they mean something ("I like it").
public enum Fillers {
    static let sounds: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "uhmm", "erm", "er", "hmm", "hmmm", "mm", "mmm"]

    public static func strip(_ text: String) -> String {
        var out: [String] = []
        // Capitals move only where a sound started a sentence ("Uh, yes." becomes "Yes.").
        var sentenceStart = true, capNext = false, endedOnSound = false
        for token in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let core = token.trimmingCharacters(in: CharacterSet.punctuationCharacters).lowercased()
            endedOnSound = sounds.contains(core)
            if endedOnSound {
                // A sentence end on the sound ("ship it um.") moves to the word before it.
                if let end = token.last(where: { ".?!".contains($0) }), var prev = out.popLast() {
                    while let c = prev.last, ",;:".contains(c) { prev.removeLast() }
                    out.append(prev + String(end)); sentenceStart = true; capNext = false
                } else if sentenceStart { capNext = true }
                continue
            }
            var word = token
            if capNext, let first = word.first, first.isLowercase { word = first.uppercased() + word.dropFirst() }
            capNext = false
            sentenceStart = token.last.map { ".?!".contains($0) } ?? false
            out.append(word)
        }
        // "So, um, I" leaves "So, I"; a sound that ended the text leaves a stray comma.
        if endedOnSound, var last = out.popLast() { while let c = last.last, ",;:".contains(c) { last.removeLast() }; if !last.isEmpty { out.append(last) } }
        return out.joined(separator: " ")
    }
}

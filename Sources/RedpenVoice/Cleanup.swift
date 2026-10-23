import Foundation
import FoundationModels

/// The optional rewrite, on Apple's on-device model. It takes out "um", false starts and repeated words and adds
/// punctuation. It is told to keep every word choice, and the raw text always wins when the model wanders.
enum Cleanup {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static let instructions = """
    You tidy dictated speech into written text. Remove filler words (um, uh, like, you know), false starts, and \
    words repeated by accident. Keep the speaker's own words, order and meaning; do not improve style, do not add \
    anything, do not summarize, do not answer questions in the text. Add sentence punctuation and capitals. \
    Reply with the tidied text only.
    """

    static func run(_ raw: String) async -> String? {
        guard isAvailable, raw.split(separator: " ").count >= 3 else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        guard let out = try? await session.respond(to: raw, options: GenerationOptions(temperature: 0)).content else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Half the words gone or half again added means it rewrote, not tidied.
        let rw = Double(raw.split(separator: " ").count), tw = Double(t.split(separator: " ").count)
        guard tw >= rw * 0.5, tw <= rw * 1.3, !t.isEmpty else { Log.note("cleanup: rejected (\(Int(rw)) -> \(Int(tw)) words)"); return nil }
        return t
    }
}

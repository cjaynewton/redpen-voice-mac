import Foundation

/// Text typed as key events goes out in small pieces of UTF-16 units. A piece must never end inside a character:
/// half of an emoji's surrogate pair, or a letter without its accent, arrives as a broken character.
public enum TypingChunks {
    /// Pieces of at most `units` UTF-16 units, cut only between whole characters. A single character longer than
    /// `units` (a long emoji sequence) goes out whole in its own piece.
    public static func split(_ text: String, units: Int = 20) -> [[UInt16]] {
        let limit = max(1, units)
        var out: [[UInt16]] = []
        var piece: [UInt16] = []
        for character in text {
            let u = Array(String(character).utf16)
            if !piece.isEmpty, piece.count + u.count > limit {
                out.append(piece)
                piece = []
            }
            piece += u
        }
        if !piece.isEmpty { out.append(piece) }
        return out
    }
}

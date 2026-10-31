import XCTest
import VoiceCore

/// Insert.type used to cut text every 20 UTF-16 units, which can split an emoji's surrogate pair or a letter from
/// its combining accent across two key events.
final class TypingChunksTests: XCTestCase {
    private func decoded(_ pieces: [[UInt16]]) -> [String?] {
        pieces.map { String(utf16CodeUnits: $0, count: $0.count) }
    }

    func testPlainTextStillGoesInTwentyUnitPieces() {
        let text = String(repeating: "a", count: 45)
        XCTAssertEqual(TypingChunks.split(text).map(\.count), [20, 20, 5])
    }

    func testEmojiAtThePieceEdgeIsNotSplit() {
        // 19 letters, then an emoji made of two UTF-16 units: the old cut fell between its halves.
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let pieces = TypingChunks.split(text)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 20 })
        for piece in pieces {
            // Every piece must decode on its own, with no lone surrogate.
            XCTAssertFalse(piece.contains { UTF16.isLeadSurrogate($0) } && !piece.contains { UTF16.isTrailSurrogate($0) })
            XCTAssertFalse(UTF16.isLeadSurrogate(piece.last!), "piece ends inside a surrogate pair")
            XCTAssertFalse(UTF16.isTrailSurrogate(piece.first!), "piece starts inside a surrogate pair")
        }
        XCTAssertEqual(decoded(pieces).compactMap { $0 }.joined(), text)
    }

    func testCombiningAccentStaysWithItsLetter() {
        let text = String(repeating: "a", count: 19) + "e\u{301}" + "z"
        let pieces = TypingChunks.split(text)
        XCTAssertEqual(pieces.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        XCTAssertFalse(pieces.contains { $0.first == 0x301 }, "an accent was cut from its letter")
    }

    func testLongEmojiSequenceGoesOutWhole() {
        let family = "👨‍👩‍👧‍👦"  // 11 UTF-16 units, one character
        let pieces = TypingChunks.split("ab" + family, units: 4)
        XCTAssertEqual(pieces.map { String(decoding: $0, as: UTF16.self) }, ["ab", family])
    }

    func testEmptyTextHasNoPieces() {
        XCTAssertTrue(TypingChunks.split("").isEmpty)
    }
}

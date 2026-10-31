import XCTest
import VoiceCore

final class ChunkerTests: XCTestCase {
    /// quietLevel indexed sorted[count - 1] with no check, which traps on an empty list (under 30 ms of audio).
    func testQuietLevelOfNoAudioIsTheFloor() {
        XCTAssertEqual(Chunker.quietLevel([]), 0.003)
    }

    func testHasSpeechWithLessThanOneFrameDoesNotCrash() {
        let samples = [Float](repeating: 0.5, count: 100)
        XCTAssertNoThrow(Chunker.hasSpeech(samples, from: 10, reference: 20))
        XCTAssertFalse(Chunker.endsQuiet(samples, from: 0))
    }

    func testQuietLevelStillFollowsTheLoudFrames() {
        let levels: [Float] = Array(repeating: 0.001, count: 10) + Array(repeating: 0.5, count: 10)
        XCTAssertEqual(Chunker.quietLevel(levels), 0.05, accuracy: 0.0001)
    }
}

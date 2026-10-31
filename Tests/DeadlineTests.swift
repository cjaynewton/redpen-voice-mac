import XCTest
import VoiceCore

/// The Whisper and Fast endings had no time limit. While a dictation is being written the talk key starts nothing
/// new (`writing == 0` is part of canBegin), so an engine that never answered left Voice deaf until it was quit.
final class DeadlineTests: XCTestCase {
    func testWorkThatAnswersInTimeReturnsItsValue() async {
        let outcome = await Deadline.run(seconds: 2) { "words" }
        guard case .value(let text) = outcome else { return XCTFail("expected a value, got \(outcome)") }
        XCTAssertEqual(text, "words")
    }

    func testWorkThatNeverAnswersTimesOut() async {
        let started = Date()
        let outcome = await Deadline.run(seconds: 0.2) { () async throws -> String in
            // An engine stuck for far longer than the deadline.
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "too late"
        }
        guard case .timedOut = outcome else { return XCTFail("expected a timeout, got \(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the caller must not wait for the stuck work")
    }

    func testErrorsComeBackAsFailures() async {
        struct EngineFailed: Error {}
        let outcome = await Deadline.run(seconds: 2) { () async throws -> String in throw EngineFailed() }
        guard case .failure(let error) = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertTrue(error is EngineFailed)
    }

    func testFinishDeadlineGrowsWithTheRecording() {
        XCTAssertEqual(Deadline.finishSeconds(recorded: 0), 30)
        XCTAssertGreaterThan(Deadline.finishSeconds(recorded: 600), Deadline.finishSeconds(recorded: 10))
        XCTAssertEqual(Deadline.finishSeconds(recorded: -.infinity), 30)
        XCTAssertEqual(Deadline.finishSeconds(recorded: .nan), 30)
    }
}

import XCTest
import VoiceCore

final class MediaPauseTests: XCTestCase {
    func testRestartReleasesPauseAndBlocksEveryResumePath() {
        var pause = MediaPauseOwnership()
        pause.hold()
        let pendingResume = pause.generation
        XCTAssertTrue(pause.relinquishIfPlaying(peak: 0.1))
        XCTAssertFalse(pause.paused)
        XCTAssertFalse(pause.owns(pendingResume))
        XCTAssertFalse(MediaGate.shouldResume(paused: pause.paused))
        XCTAssertFalse(MediaGate.shouldResume(paused: pause.paused, recordingAgain: true))
        XCTAssertFalse(pause.relinquishIfPlaying(peak: 0.1), "A restart is handled once")
    }

    func testSilenceAndUnavailableListenKeepPause() {
        var pause = MediaPauseOwnership()
        pause.hold()
        let pendingResume = pause.generation
        for peak: Float? in [nil, 0, 0.0005, MediaGate.audible] {
            XCTAssertFalse(pause.relinquishIfPlaying(peak: peak))
            XCTAssertTrue(pause.owns(pendingResume))
        }
        XCTAssertTrue(MediaGate.shouldResume(paused: pause.paused))
    }

    func testNextPressDecidesFreshAfterRestart() {
        var pause = MediaPauseOwnership()
        pause.hold()
        let oldResume = pause.generation
        XCTAssertTrue(pause.relinquishIfPlaying(peak: 0.1))
        XCTAssertFalse(pause.paused, "The next press cannot carry over the old pause")
        XCTAssertFalse(MediaGate.shouldPause(enabled: true, outputRunning: MediaGate.isPlaying(peak: 0)))
        XCTAssertTrue(MediaGate.shouldPause(enabled: true, outputRunning: MediaGate.isPlaying(peak: 0.1)))
        pause.hold()
        XCTAssertTrue(pause.paused)
        XCTAssertFalse(pause.owns(oldResume), "An old listen cannot resume or reclaim the new pause")
        XCTAssertTrue(pause.owns(pause.generation))
    }

    func testNewPressInvalidatesResumeListenWithoutLosingPause() {
        var pause = MediaPauseOwnership()
        pause.hold()
        let oldResume = pause.generation
        pause.hold()
        XCTAssertTrue(pause.paused)
        XCTAssertFalse(pause.owns(oldResume))
        XCTAssertTrue(pause.owns(pause.generation))
    }

    func testReleaseAndUnownedPlaybackCannotReclaimPause() {
        var pause = MediaPauseOwnership()
        XCTAssertFalse(pause.relinquishIfPlaying(peak: 0.1))
        pause.hold()
        let pendingResume = pause.generation
        pause.release()
        XCTAssertFalse(pause.owns(pendingResume))
        XCTAssertFalse(pause.relinquishIfPlaying(peak: 0.1))
        XCTAssertFalse(pause.paused)
    }
}

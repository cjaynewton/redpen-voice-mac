import XCTest
import VoiceCore

/// Shortcut keeps one action per Carbon hot-key id. Escape and Control-Option-S once both used id 3, so every
/// dictation's Escape replaced the swap action and Control-Option-S stopped working after the first dictation.
final class ShortcutIDTests: XCTestCase {
    func testEveryShortcutHasItsOwnID() {
        let ids = ShortcutID.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertNotEqual(ShortcutID.escape.rawValue, ShortcutID.swapRisky.rawValue)
    }

    func testIDsAreNonZero() {
        // Carbon treats 0 as "no id"; every registered shortcut needs a real one.
        XCTAssertFalse(ShortcutID.allCases.contains { $0.rawValue == 0 })
    }
}

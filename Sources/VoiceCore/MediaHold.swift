import Foundation

/// What one Chrome pause ask leaves behind (Nov 13 2026). Only a pause the page confirmed, or an older confirmed
/// pause this ask took over, is a hold: it alone makes the next press a takeover and it alone is played again.
/// A tab that was sent a pause and never answered is not a hold. It gets one look when the talking ends, in case
/// the pause landed late, and is then forgotten.
public struct MediaHold: Equatable, Sendable {
    /// Tabs where Voice's pause is in place, or may still be from the hold this ask took over.
    public let held: [Int]
    /// Tabs sent a pause that never answered.
    public let unanswered: [Int]

    public static let none = MediaHold(held: [], unanswered: [])

    public init(held: [Int], unanswered: [Int]) {
        var seen = Set<Int>()
        self.held = held.filter { seen.insert($0).inserted }
        self.unanswered = unanswered.filter { seen.insert($0).inserted }
    }

    public var holds: Bool { !held.isEmpty }
    /// Held tabs first, so a real video comes back before time goes to tabs that never answered.
    public var releaseTabs: [Int] { held + unanswered }

    /// The next press takes a pause over only when one is held, or an ask still running could yet confirm one.
    /// An ask that ended with nothing paused never makes a takeover: that press starts fresh.
    public static func nextPressTakesOver(_ hold: MediaHold, askRunning: Bool) -> Bool { hold.holds || askRunning }

    /// What is left of this hold while its one release pass runs. A tab that played, answered empty (closed or
    /// replaced) or timed out is finished with. Only tabs the pass has not reached yet remain, for a press that
    /// interrupts the pass. When the pass ends, nothing remains.
    public func remaining(after result: BrowserResumeOperation.Result) -> MediaHold {
        let waiting = result.waiting
        return MediaHold(held: held.filter(waiting.contains), unanswered: [])
    }
}

/// How long one Chrome ask may run, by what the quick sound listen heard.
public struct MediaPauseBudget: Equatable, Sendable {
    /// Seconds from the press.
    public let total: TimeInterval
    /// Whether a known tab that timed out is asked once more.
    public let retries: Bool

    public init(total: TimeInterval, retries: Bool) { self.total = total; self.retries = retries }

    /// Sound was heard, or the listen has not answered yet (D-1496): about eight seconds, one retry.
    public static let heard = MediaPauseBudget(total: 8, retries: true)
    /// The listen heard nothing (D-1446): Chrome is still asked, briefly, and never twice.
    public static let quiet = MediaPauseBudget(total: 2.5, retries: false)

    /// nil while the listen has not answered.
    public static func after(heardSound: Bool?) -> MediaPauseBudget { heardSound == false ? .quiet : .heard }

    /// The first live words wait for Chrome only while a video's sound may be in the opening audio. Once the
    /// listen has heard nothing, the opening is settled at once and Chrome's answer only decides the pause.
    public static func openingWaitsForChrome(heardSound: Bool?) -> Bool { heardSound != false }
}

/// Tabs left by asks that paused nothing, kept for one look when the talking ends. A pause script that timed
/// out can still run in its page until the ask's time is up. If it does, this look finds the video it marked
/// and plays it again, so a late pause is never left with nothing to undo it.
public struct MediaLooseEnds: Equatable, Sendable {
    public private(set) var tokens: [String] = []
    public private(set) var tabs: [Int] = []

    public init() {}

    public var isEmpty: Bool { tabs.isEmpty }

    public mutating func add(token: String, tabs new: [Int]) {
        guard !token.isEmpty, !new.isEmpty else { return }
        if !tokens.contains(token) { tokens.append(token) }
        for tab in new where !tabs.contains(tab) { tabs.append(tab) }
    }

    /// Hands everything over for the one pass and forgets it, whatever that pass then finds.
    public mutating func take() -> (token: String, inheriting: [String], tabs: [Int])? {
        guard let last = tokens.last, !tabs.isEmpty else { tokens = []; tabs = []; return nil }
        let out = (token: last, inheriting: Array(tokens.dropLast()), tabs: tabs)
        tokens = []; tabs = []
        return out
    }
}

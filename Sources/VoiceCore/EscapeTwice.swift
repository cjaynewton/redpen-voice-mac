import Foundation

/// Escape while you talk (D-987, Oct 31 2026). One press goes to the app in front as normal (leaving a full-screen
/// video, closing a pop-up), and the recording goes on. Two presses close together throw the recording away. One
/// press used to throw it away and never reached the app: three recordings were lost that way on Oct 30 and 31.
public struct EscapeTwice: Sendable {
    /// The Escape key (kVK_Escape).
    public static let keyCode = 53
    /// The second press must come this soon after the first.
    public static let window: Double = 0.5

    private var lastPress: Double?
    public init() {}

    /// A press at `time` (event time, seconds). True when it is the second of two close together; the pair is then
    /// used up, so a third press starts a new pair. Key repeats from a held Escape are not presses.
    public mutating func press(at time: Double, repeated: Bool = false) -> Bool {
        guard !repeated else { return false }
        if let last = lastPress, time >= last, time - last <= Self.window {
            lastPress = nil
            return true
        }
        lastPress = time
        return false
    }

    /// Escape reaches the box you are in now, but it types nothing there. It still stops typing while you talk, as
    /// any key does, but it doesn't mark the box as edited, so the ending can still go into it. Other keys do.
    public static func marksBoxEdited(keyCode: Int) -> Bool { keyCode != Self.keyCode }
}

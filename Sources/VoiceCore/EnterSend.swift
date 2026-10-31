import Foundation

/// Enter stops and sends (D-1008, Oct 31 2026). While you talk, or while the checked words are still on their way,
/// a plain Enter is held: Voice stops the dictation, waits for every word to land, then presses Enter for you. Fn
/// still stops without sending. It was a race: Enter pressed straight after stopping sent the message 2 to 5 s before
/// the checked ending came, so the last words were missing (D-965 log), and later typed again elsewhere (D-998).
///
/// The rules only, no event tap: which key presses Voice holds, and when a held press goes out. Exactly one Enter goes
/// out for each held press, when the words are in or at `cap`, whichever is first.
public struct EnterSend: Sendable {
    /// Return, and the Enter key on a number pad or Fn+Return.
    public static let keyCodes: Set<Int> = [36, 76]
    /// The longest a held Enter waits. Then it goes out with what's there and ⌃⌥V has the rest.
    public static let cap: Double = 5
    /// After the words land, a moment for the app to take them in before the Enter (chat apps read their box on Enter).
    public static let settle: Double = 0.15
    /// How long one arming lasts. Voice renews it while a dictation runs; if Voice ever stalls, Enter is ordinary again
    /// this soon after. Long enough to cover Voice typing a long draft, which keeps it from renewing.
    public static let armLength: Double = 3
    /// While the words are on their way, one arming covers the whole ending, which can keep Voice busy for seconds.
    public static let endingArmLength: Double = 20
    /// If Voice stalls, a held Enter still goes out this long after the cap, sent by the tap itself.
    public static let backstop: Double = 10

    /// The modifier flags, as plain bits (CGEventFlags raw values) so this stays testable without CoreGraphics.
    public static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000

    /// Which side's key is down, from the same flags (the Mac's device bits).
    static let leftControl: UInt64 = 0x1, leftCommand: UInt64 = 0x8, rightCommand: UInt64 = 0x10,
               leftOption: UInt64 = 0x20, rightOption: UInt64 = 0x40, rightControl: UInt64 = 0x2000

    /// Only a plain Enter. Shift+Enter and ⌘+Enter often make a new line or do something else; they are left alone,
    /// as are Option and Control. Fn doesn't count: Fn+Return is Enter on a Mac laptop. `talkKeys` holds the flag of a
    /// right-hand talk key (right Option, Command or Control): held to talk, only its own right-hand key down, it
    /// doesn't count either.
    public static func owns(keyCode: Int, flags: UInt64, talkKeys: UInt64 = 0) -> Bool {
        guard keyCodes.contains(keyCode) else { return false }
        var f = flags
        for (generic, right, left) in [(option, rightOption, leftOption), (command, rightCommand, leftCommand),
                                       (control, rightControl, leftControl)]
        where talkKeys & generic != 0 && f & right != 0 && f & left == 0 { f &= ~generic }
        return f & (shift | control | option | command) == 0
    }

    public enum Decision: Equatable, Sendable {
        /// Not Voice's: the key goes to the app as normal.
        case pass
        /// Held. A new press starts waiting with this id; Voice is told so it can stop the dictation.
        case hold(id: Int)
        /// Held, and it is a second Enter while one waits: the waiting one goes now; this one is held quietly.
        case sendNow(id: Int)
        /// Held quietly: a key repeat or the key-up of a held press.
        case swallow
    }

    private var armedUntil = 0.0
    private var waiting: (id: Int, deadline: Double, code: Int)?
    private var held: Set<Int> = []
    private var nextID = 0
    /// The flags of the right-hand talk keys, set when the talk keys change.
    public var talkKeys: UInt64 = 0

    public init() {}

    public var isWaiting: Bool { waiting != nil }
    public var waitingID: Int? { waiting?.id }

    /// Arming only ever lengthens; `disarm` ends it.
    public mutating func arm(now: Double, for length: Double = Self.armLength) { armedUntil = max(armedUntil, now + length) }
    public mutating func disarm() { armedUntil = 0 }
    public func armed(now: Double) -> Bool { now < armedUntil }

    /// A key-down. Voice's own presses (`own`) always pass, so the Enter Voice sends is never held again.
    public mutating func keyDown(code: Int, flags: UInt64, own: Bool, repeated: Bool, now: Double) -> Decision {
        guard !own, Self.owns(keyCode: code, flags: flags, talkKeys: talkKeys) else { return .pass }
        if let w = waiting {
            held.insert(code)
            if repeated { return .swallow }
            return .sendNow(id: w.id)
        }
        guard armed(now: now), !repeated else { return .pass }
        nextID += 1
        waiting = (nextID, now + Self.cap, code)
        held.insert(code)
        return .hold(id: nextID)
    }

    /// The key-up of a press that was held is held too, so the app never sees an up without its down.
    public mutating func keyUp(code: Int, own: Bool) -> Decision {
        guard !own, held.remove(code) != nil else { return .pass }
        return .swallow
    }

    /// The words are in, the dictation can't use the press, or the cap came: the key to send (the one you pressed),
    /// exactly once for each held press.
    public mutating func release(id: Int) -> Int? {
        guard let w = waiting, w.id == id else { return nil }
        waiting = nil
        return w.code
    }

    /// The cap: the key to send when this press is still waiting at its deadline.
    public mutating func capReached(id: Int, now: Double) -> Int? {
        guard let w = waiting, w.id == id, now >= w.deadline - 0.001 else { return nil }
        waiting = nil
        return w.code
    }

    /// The bar while a held Enter waits.
    public static let waitingNote = "Sends when your words are in"
}

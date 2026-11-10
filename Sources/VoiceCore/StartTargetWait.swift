/// Keeps transcription behind target protection while microphone audio accumulates independently.
public struct StartTargetWait {
    public enum Action { case wait, adopt, fallback, keepForPaste }
    public static let cap = 1.8
    public static let callTimeout = 0.4
    private let began: Double
    private var settled = false

    public init(at uptime: Double) { began = uptime }

    public mutating func result(found: Bool, unchanged: Bool, at now: Double) -> Action {
        guard !settled else { return .wait }
        guard unchanged else { settled = true; return .keepForPaste }
        if now >= began + Self.cap { settled = true; return .fallback }
        guard found else { return .wait }
        settled = true
        return .adopt
    }
}

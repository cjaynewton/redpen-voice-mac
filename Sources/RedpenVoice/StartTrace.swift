import Foundation
import VoiceCore

/// Enabled automatically for ten minutes after launch. No flag, words, app names or audio.
enum StartTrace {
    private static let lock = NSLock()
    private static let output = DispatchQueue(label: "redpen.voice.start-trace")
    private static var trace = TalkTimingTrace(at: ProcessInfo.processInfo.systemUptime)
    private static var next = 0
    static func launch() { lock.withLock { trace = TalkTimingTrace(at: ProcessInfo.processInfo.systemUptime) } }
    static func nextGesture() -> Int { lock.withLock { next += 1; return next } }
    static func note(_ event: TalkTimingTrace.Event, gesture: Int, capture: Int? = nil,
                     eventAt: Double? = nil, count: Int = 0, value: Int = 0) {
        let line = lock.withLock {
            trace.line(event, gesture: gesture, capture: capture ?? gesture, eventAt: eventAt,
                       count: count, value: value, at: ProcessInfo.processInfo.systemUptime)
        }
        if let line { output.async { Log.note(line) } }
    }
}

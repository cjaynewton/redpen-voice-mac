import Foundation

/// A closed vocabulary and numeric fields make it impossible to pass dictated text to this trace.
public struct TalkTimingTrace {
    public enum Event: Int, CaseIterable {
        case keyDown = 1, keyUp, barRequested, barOrdered, captureAttached, firstMicBuffer,
             firstSampleKept, handsFree, mediaStart, mediaEnd, chromeAnswer, quietResult,
             firstDraftReady, pendingTap, resumedTap, confirmedHold, cancelled, targetResult
    }
    public static let duration = 600.0
    private let began: Double
    public init(at uptime: Double) { began = uptime }
    public func line(_ event: Event, gesture: Int, capture: Int, eventAt: Double? = nil,
                     count: Int = 0, value: Int = 0, at uptime: Double) -> String? {
        guard uptime >= began, uptime - began < Self.duration else { return nil }
        let eventMS = eventAt.map { Int64(($0 * 1000).rounded()) } ?? -1
        return "fn-start: event=\(event.rawValue) gesture=\(gesture) capture=\(capture) mono_ms=\(Int64((uptime * 1000).rounded())) event_ms=\(eventMS) count=\(count) value=\(value)"
    }
}

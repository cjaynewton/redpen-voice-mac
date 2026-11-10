import AppKit
import ApplicationServices
import CoreGraphics
import VoiceCore

/// Background, deadline-bounded discovery. Never adopt a box after an app switch, key, click or stale reply.
enum StartTarget {
    struct Stamp: Equatable {
        let pid: pid_t
        let bundle: String
        let activation: Int
        let counters: [UInt32]
    }
    struct Snapshot {
        let element: AXUIElement
        let window: AXUIElement?
        let print: BoxPrint
        let windowFrame: CGRect?
    }
    private static let queue = DispatchQueue(label: "redpen.voice.start-target", qos: .userInitiated)
    private static let lock = NSLock()
    private static var activation = 0
    private static var observer: NSObjectProtocol?
    // Talk-key flags can advance the hardware key counter too. The caller's DraftInput tracks real typing
    // from first down, while these counters reject pointer navigation throughout the background snapshot.
    private static let events: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    @MainActor static func startWatching() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in lock.withLock { activation += 1 } }
    }
    @MainActor static func stamp() -> Stamp {
        let app = NSWorkspace.shared.frontmostApplication
        return Stamp(pid: app?.processIdentifier ?? 0, bundle: app?.bundleIdentifier ?? "",
                     activation: lock.withLock { activation },
                     counters: events.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) })
    }
    static func discover(_ stamp: Stamp, done: @escaping (Snapshot?) -> Void) {
        queue.async { done(read(stamp)) }
    }
    private static func read(_ stamp: Stamp) -> Snapshot? {
        guard stamp.pid > 0, stamp.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var expired = false
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { expired = true; return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.025, left)))
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if ProcessInfo.processInfo.systemUptime >= deadline || result == .cannotComplete { expired = true }
            return result == .success ? value : nil
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func frame(_ el: AXUIElement) -> CGRect? {
            guard let position = attr(el, kAXPositionAttribute), let size = attr(el, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
            return CGRect(origin: p, size: s)
        }
        let app = AXUIElementCreateApplication(stamp.pid)
        guard let focused = element(attr(app, kAXFocusedUIElementAttribute)) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        guard pid == stamp.pid else { return nil }
        let role = attr(focused, kAXRoleAttribute) as? String
        // No Accessibility writes to wake Electron on the start path. An unreadable box is left unclaimed.
        let editable = attr(focused, "AXEditableAncestor") != nil
        var settable = DarwinBoolean(false)
        if !expired, ProcessInfo.processInfo.systemUptime < deadline {
            AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        }
        guard FocusGate.kind(role: role, editableAncestor: editable, valueSettable: settable.boolValue,
                             inBrowser: FocusGate.browsers.contains(stamp.bundle)) == .text else { return nil }
        let window = element(attr(focused, kAXWindowAttribute))
        func fingerprint() -> BoxPrint {
            let text = attr(focused, kAXValueAttribute) as? String
            let title = window.flatMap { attr($0, kAXTitleAttribute) as? String }
            var url: String?
            var node: AXUIElement? = focused
            for _ in 0..<40 {
                guard let current = node, !expired else { break }
                if (attr(current, kAXRoleAttribute) as? String) == "AXWebArea" {
                    let value = attr(current, kAXURLAttribute)
                    url = (value as? URL)?.absoluteString ?? (value as? String)
                    break
                }
                node = element(attr(current, kAXParentAttribute))
            }
            return BoxPrint(role: role, identifier: attr(focused, kAXIdentifierAttribute) as? String,
                            frame: frame(focused), text: text, title: title?.isEmpty == false ? title : nil,
                            url: url?.isEmpty == false ? url : nil)
        }
        let first = fingerprint()
        let windowFrame = window.flatMap(frame)
        guard let current = element(attr(app, kAXFocusedUIElementAttribute)), CFEqual(current, focused),
              let currentWindow = element(attr(current, kAXWindowAttribute)), let window, CFEqual(currentWindow, window),
              first == fingerprint(), !expired,
              stamp.activation == lock.withLock({ activation }),
              stamp.counters == events.map({ CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }) else { return nil }
        return Snapshot(element: focused, window: window, print: first, windowFrame: windowFrame)
    }
}

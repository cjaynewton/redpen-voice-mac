import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceCore

/// Puts text where the cursor is, in whatever app is in front, without touching the clipboard.
/// First through Accessibility (replace the selection, which is empty at a plain cursor), checked by reading the
/// cursor back; when an app says yes and does nothing, the text is typed instead, as key events.
enum Insert {
    /// `joining`: the dictation this text belongs to, when it is typed in pieces, so Take back removes all of it.
    static func text(_ text: String, joining: Int? = nil) -> Bool {
        typedSome = false; typedCount = 0; typedPadding = 0
        guard !text.isEmpty else { return true }  // nothing to type; replacing the selection with "" would delete it
        dictation = joining
        defer { dictation = nil }
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let hasFocus = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success
        guard hasFocus, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            Log.note("insert: no focused element, typing")
            let p = leadingSpace(text); typedPadding = p.utf16.count - text.utf16.count
            return type(p)
        }
        let el = focusedRef as! AXUIElement
        wakeElectron(el)
        let padded = spaced(text, before: el)
        typedPadding = padded.utf16.count - text.utf16.count
        if let before = selectedRange(el), AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, padded as CFString) == .success {
            // Moved by the length of the text: it landed. Otherwise the app said yes and did nothing.
            if let after = selectedRange(el), after.location == before.location + (padded as NSString).length || after.location > before.location {
                remember(padded); return true
            }
            Log.note("insert: accessibility accepted but cursor did not move, typing")
        }
        // Focus can move between the check and here: never type into a page or a video.
        guard focus().kind != .notText else { Log.note("insert: focus left the text box, not typed"); return false }
        let ok = type(padded)
        if ok { remember(padded) }
        return ok
    }

    /// What kind of place the cursor is in right now, and the focused element's role for the log.
    static func focus() -> (kind: FocusKind, role: String) {
        if let app = NSWorkspace.shared.frontmostApplication { wakeElectron(pid: app.processIdentifier) }
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
              CFGetTypeID(f) == AXUIElementGetTypeID() else { return (.unknown, "none") }
        let el = f as! AXUIElement
        var v: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success ? (v as? String) : nil
        let editable = AXUIElementCopyAttributeValue(el, "AXEditableAncestor" as CFString, &v) == .success && v != nil
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let browser = FocusGate.browsers.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        let kind = FocusGate.kind(role: role, editableAncestor: editable, valueSettable: settable.boolValue, inBrowser: browser)
        return (kind, role ?? "?")
    }

    /// The focused element and its app, for watching a box after the words went in.
    static func focusedElement() -> (AXUIElement, pid_t)? {
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
              CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return (el, pid)
    }

    /// A box's whole text, or nil when the app won't say.
    static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: Taking back the last dictation

    /// What the last dictation put in, where, and when. Cleared once you type anything yourself.
    private(set) static var last: (text: String, pid: pid_t, at: Date)?
    static var typedSince = false

    /// The dictation being typed now, when it goes in pieces; pieces of the same one join up for Take back.
    private static var dictation: Int?
    private static var lastDictation: Int?
    /// True when the last call typed part of its text before stopping (the app or the box changed).
    private(set) static var typedSome = false
    /// How much of the text went in (UTF-16 units) when typing stopped partway.
    private(set) static var typedCount = 0
    /// The space put in front of the text (0 or 1 unit), so typedCount can be matched back to the text itself.
    private(set) static var typedPadding = 0

    private static func remember(_ text: String) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if let d = dictation, d == lastDictation, let l = last, l.pid == pid, !typedSince { last = (l.text + text, pid, Date()) }
        else { last = (text, pid, Date()) }
        lastDictation = dictation
        typedSince = false
    }

    /// Removes the last dictation if it is provably the last thing before the cursor. Returns nil when done, or the
    /// reason it would not, so it never deletes words you typed yourself.
    static func undoLast() -> String? {
        guard let l = last else { return "Nothing to take back" }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == l.pid else { return "Go back to the app it went into" }
        guard Date().timeIntervalSince(l.at) < 600 else { return "Too long ago, use Command-Z" }
        let n = (l.text as NSString).length
        // Best: the app tells us what sits before the cursor, and it matches exactly.
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
           CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            if let r = selectedRange(el), r.length == 0, r.location >= n {
                var cf = CFRange(location: r.location - n, length: n)
                var v: CFTypeRef?
                if let param = AXValueCreate(.cfRange, &cf),
                   AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success,
                   let before = v as? String {
                    guard before == l.text else { return "The text has changed, use Command-Z" }
                    backspace(l.text.count); last = nil; return nil
                }
            }
        }
        // The app will not say (Electron apps often will not): only if you have typed nothing since.
        guard !typedSince else { return "You typed since, use Command-Z" }
        backspace(l.text.count); last = nil
        return nil
    }

    private static func backspace(_ count: Int) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)?.post(tap: .cghidEventTap)
            usleep(1_500)
        }
    }

    private static func selectedRange(_ el: AXUIElement) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        // Some apps (Messages) answer "not found", a huge number; adding to it crashed the app (Oct 22 2026).
        guard r.location >= 0, r.location < 100_000_000, r.length >= 0, r.length < 100_000_000 else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    /// A space before the text when the cursor sits right after a word, so two dictations do not run together.
    /// When the app will not say what is before the cursor (Electron apps often will not), the space goes in anyway:
    /// a stray space at the start of a box is a smaller wrong than "likeIt".
    private static func spaced(_ text: String, before el: AXUIElement) -> String {
        guard let first = text.first, !first.isWhitespace else { return text }
        guard let r = selectedRange(el) else { return leadingSpace(text) }
        guard r.location > 0 else { return text }
        var cf = CFRange(location: r.location - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &cf) else { return leadingSpace(text) }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success,
              let prev = (v as? String)?.last else { return leadingSpace(text) }
        if prev.isWhitespace || "([{\"'“‘/-".contains(prev) { return text }
        return " " + text
    }

    private static func leadingSpace(_ text: String) -> String {
        guard let first = text.first, first.isLetter || first.isNumber else { return text }
        return " " + text
    }

    /// Chromium and Electron apps hide their text fields from Accessibility until asked.
    private static func wakeElectron(_ el: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        wakeElectron(pid: pid)
    }

    private static func wakeElectron(pid: pid_t) {
        guard pid > 0 else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Types the text as keyboard events, 20 characters at a time. Slower than a paste and works everywhere.
    /// Stops if you switch apps partway, so the rest never lands somewhere else.
    static func type(_ text: String) -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var ok = false
        for chunk in Array(text.utf16).chunks(of: 20) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app { Log.note("insert: app changed while typing, stopped"); return false }
            // A tab change keeps the same app: check the place itself too, so the rest never become page shortcuts.
            if focus().kind == .notText { Log.note("insert: focus left the text box while typing, stopped"); return false }
            var units = chunk
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return ok }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            // No modifiers: with Fn or Option held to talk, the letters would otherwise arrive as Fn or Option
            // shortcuts (Fn-E opens emoji, Option-letters type accents).
            down.flags = []; up.flags = []
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            ok = true; typedSome = true; typedCount += units.count
            usleep(4_000)
        }
        return ok
    }
}

private extension Array {
    func chunks(of n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}

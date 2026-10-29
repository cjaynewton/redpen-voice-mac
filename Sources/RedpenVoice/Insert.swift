import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceCore

/// Puts text where the cursor is, in whatever app is in front, without touching the clipboard.
/// First through Accessibility (replace the selection, which is empty at a plain cursor), checked by reading the
/// cursor back; when an app says yes and does nothing, the text is typed instead, as key events.
enum Insert {
    /// `joining`: the dictation this text belongs to, when it is typed in pieces, so Take back removes all of it.
    static func text(_ text: String, joining: Int? = nil, confirmed: Bool = false, while still: () -> Bool = { true }) -> Bool {
        typedSome = false; typedCount = 0; typedPadding = 0; unconfirmed = false; lastEdit = nil
        guard !text.isEmpty else { return true }  // nothing to type; replacing the selection with "" would delete it
        guard !ownWindowInFront else { Log.note("insert: a Redpen Voice window is in front, not typed"); return false }
        dictation = joining
        defer { dictation = nil }
        let sys = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let hasFocus = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success
        guard hasFocus, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            Log.note("insert: no focused element, kept for Paste last")
            return false
        }
        let el = focusedRef as! AXUIElement
        wakeElectron(el)
        // A whole dictation fits the sentence it lands in; pieces typed while you talk keep their exact text.
        let fitted = joining == nil ? fit(text, in: el) : text
        let padded = spaced(fitted, before: el)
        typedPadding = padded.utf16.count - fitted.utf16.count
        let oldValue = value(el), oldRange = selectedRange(el)
        let expected = oldValue.flatMap { value in oldRange.flatMap { range -> String? in
            guard range.location <= value.utf16.count, range.length <= value.utf16.count - range.location else { return nil }
            return (value as NSString).replacingCharacters(in: range, with: padded)
        } }
        // Draft bookkeeping needs readable evidence, rather than a successful event post.
        if confirmed, expected == nil { Log.note("insert: draft target unreadable, kept for Paste last"); return false }
        func recordEdit(_ inserted: String) {
            guard let oldValue, let oldRange, oldRange.location <= oldValue.utf16.count,
                  oldRange.length <= oldValue.utf16.count - oldRange.location else { return }
            lastEdit = (el, oldValue, oldRange, inserted)
        }
        if let before = oldRange, AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, padded as CFString) == .success {
            if confirmed, let expected {
                if confirm(expected, in: el, while: still, attempts: 2) {
                    recordEdit(padded); remember(padded); return true
                }
                // An accepted edit can arrive late. Only fall back when neither text nor cursor changed.
                guard value(el) == oldValue, selectedRange(el) == oldRange else {
                    unconfirmed = true; Log.note("insert: draft AX edit not confirmed, kept for Paste last"); return false
                }
            }
            // Moved by the length of the text: it landed. Otherwise the app said yes and did nothing.
            if !confirmed, let after = selectedRange(el), after.location == before.location + (padded as NSString).length || after.location > before.location {
                recordEdit(padded); remember(padded); return true
            }
            Log.note("insert: accessibility accepted but cursor did not move, typing")
        }
        // Focus can move between the check and here: never type into a page or a video.
        guard Self.canTypeAtFocus else { Log.note("insert: focus left the text box, not typed"); return false }
        let before = joining == nil ? value(el) : nil
        let ok = type(padded, while: still)
        if confirmed, let expected {
            let landed = ok && confirm(expected, in: el, while: still)
            if landed { recordEdit(padded); remember(padded) }
            else { unconfirmed = true; Log.note("insert: draft typing not confirmed, kept for Paste last") }
            return landed
        }
        if ok { recordEdit(padded); remember(padded) }
        else if typedSome { recordEdit(String(decoding: padded.utf16.prefix(typedCount), as: UTF16.self)) }
        // A whole dictation in a box that says what it holds, and the box hasn't changed a second later: it may not
        // have landed. Never pasted automatically (a busy app can still take the typing late, and then it would be
        // there twice): the caller says so and Control-Option-V pastes it (D-825).
        if ok, let before, !landed(in: el, before: before) {
            unconfirmed = true
            Log.note("insert: typing not seen in the box after a second")
        }
        return ok
    }

    /// Read the complete expected value in the original focused box. Whitespace normalization is harmless;
    /// a changed word, cursor movement alone, or merely posting events cannot confirm a draft.
    private static func confirm(_ expected: String, in element: AXUIElement, while still: () -> Bool,
                                attempts: Int = 20) -> Bool {
        for _ in 0..<attempts {
            guard still(), let (now, _) = focusedElement(), CFEqual(now, element) else { return false }
            if let value = value(element), BoxText.same(expected, value) { return true }
            usleep(50_000)
        }
        return false
    }

    /// Replace only the known suffix, using the editor's actual length and checking what landed afterward.
    static func replaceDraft(_ draft: String, with replacement: String, expectedBox: String,
                             in element: AXUIElement, while still: @escaping () -> Bool) -> Bool {
        lastEdit = nil
        guard still(), let (now, _) = focusedElement(), CFEqual(now, element),
              let value = value(element), let cursor = selectedRange(element),
              let edit = DraftReplacement(expectedBox: expectedBox, actual: value, cursor: cursor,
                                          draft: draft, replacement: replacement) else { return false }
        if edit.landed(value) { return true }
        let count = ((value as NSString).substring(with: edit.range)).count
        let safe: () -> Bool = {
            still() && focusedElement().map { CFEqual($0.0, element) } == true
        }
        guard backspace(count, while: safe) == count,
              replacement.isEmpty || type(replacement, while: safe),
              confirm(edit.expected, in: element, while: safe) else {
            forgetLast()
            Log.note("draft: replacement not confirmed; checked words kept for Paste last")
            return false
        }
        lastEdit = (element, edit.before, edit.range, replacement)
        forgetLast()
        return true
    }

    /// True after the last insert when typing was sent but not seen in the box.
    private(set) static var unconfirmed = false
    /// The exact edit just sent by Voice, for the starting box's expected text. Not arbitrary text read afterward.
    private(set) static var lastEdit: (element: AXUIElement, before: String, range: NSRange, replacement: String)?

    /// The box's text changed within a second of typing.
    private static func landed(in el: AXUIElement, before: String) -> Bool {
        for _ in 0..<20 {
            usleep(50_000)
            if let now = value(el), now != before { return true }
        }
        return false
    }

    // MARK: The backup way in (D-825)

    struct PasteResult {
        let landed: Bool
        let copied: Bool
    }

    /// Wait for shortcut keys to come up, post an isolated Command-V, then watch the original box.
    /// Restore the clipboard only after visible AX evidence. On failure the words stay for a manual paste.
    @MainActor
    static func paste(_ text: String, triggerKey: CGKeyCode? = nil) async -> PasteResult {
        guard !text.isEmpty, !pasteBusy else { return PasteResult(landed: false, copied: false) }
        pasteInFlight = true
        defer { pasteInFlight = false; pasteQuietUntil = DispatchTime.now() + 1.5 }
        guard let clipboard = PasteClipboardLoan(text) else { return PasteResult(landed: false, copied: false) }
        func failed(_ reason: String) -> PasteResult {
            let copied = clipboard.finish(confirmed: false) == .kept
            Log.note("paste: \(reason); clipboard \(copied ? "kept for Command-V" : "changed, left alone")")
            return PasteResult(landed: false, copied: copied)
        }
        guard !ownWindowInFront, focus().kind != .notText, let (element, pid) = focusedElement() else {
            return failed("no text target")
        }
        let evidence = PasteEvidence(before: value(element), range: selectedRange(element), text: text)
        let context = pasteContext(element)
        var attempt = PasteAttempt(at: ProcessInfo.processInfo.systemUptime)
        // Read hardware only to wait. Never post modifier releases or change the user's physical key state.
        let modifierKeys = [kVK_Command, kVK_RightCommand, kVK_Control, kVK_RightControl,
                            kVK_Option, kVK_RightOption, kVK_Shift, kVK_RightShift, kVK_Function]
        while !Task.isCancelled {
            let sameElement = focusedElement().map { $0.1 == pid && CFEqual($0.0, element) } ?? false
            var sameTarget = sameElement && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && pasteContext(element) == context
            let currentValue = value(element), currentRange = selectedRange(element)
            if attempt.postedAt == nil {
                // Do not paste at a cursor or into text the user changed while releasing the shortcut.
                sameTarget = sameTarget && currentValue == evidence.before && currentRange == evidence.range
            }
            let keysDown = modifierKeys.contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
                || triggerKey.map { CGEventSource.keyState(.hidSystemState, key: $0) } == true
            let decision = attempt.next(at: ProcessInfo.processInfo.systemUptime, modifiersDown: keysDown,
                                        sameTarget: sameTarget, clipboardOwned: clipboard.ownsClipboard,
                                        landed: evidence.landed(value: currentValue, range: currentRange))
            switch decision {
            case .post:
                guard let pair = VoiceEvents.keyboardPair(key: vKey, flags: .maskCommand) else {
                    return failed("could not construct Command-V")
                }
                Log.note("paste: shortcut keys released, posting Command-V; value readable \(evidence.before != nil), cursor readable \(evidence.range != nil)")
                pair.down.post(tap: .cgSessionEventTap); pair.up.post(tap: .cgSessionEventTap)
            case .confirmed:
                if clipboard.finish(confirmed: true) == .restored { Log.note("clipboard: put back after confirmed paste") }
                else { Log.note("clipboard: something new was copied meanwhile, left as it is") }
                remember(text)
                return PasteResult(landed: true, copied: false)
            case .failed(let reason): return failed(reason)
            case .wait: break
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return failed("cancelled") }
        }
        return failed("cancelled")
    }

    /// A web app can reuse the focused element when switching conversations.
    private static func pasteContext(_ element: AXUIElement) -> [String] {
        func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &result) == .success ? result : nil
        }
        var title = ""
        if let window = attr(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            title = attr(window as! AXUIElement, kAXTitleAttribute) as? String ?? ""
        }
        var node = element
        for _ in 0..<40 {
            if let url = attr(node, kAXURLAttribute) {
                return [title, (url as? URL)?.absoluteString ?? (url as? String) ?? ""]
            }
            guard let parent = attr(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
        }
        return [title]
    }

    /// Refuse overlapping requests and allow a slow reader time before the next clipboard loan.
    static var pasteBusy: Bool { pasteInFlight || DispatchTime.now() < pasteQuietUntil }
    nonisolated(unsafe) private static var pasteInFlight = false
    nonisolated(unsafe) private static var pasteQuietUntil = DispatchTime(uptimeNanoseconds: 0)

    /// The key that gives "v" with Command held in the keyboard layout in use, so Command-V pastes on Dvorak, AZERTY
    /// and "Dvorak - QWERTY ⌘" (where Command keys follow QWERTY). Found once per layout.
    private static var vKey: CGKeyCode {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return CGKeyCode(kVK_ANSI_V) }
        let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        let id = idPtr.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        let cacheKey = "\(id)/\(LMGetKbdType())"
        if let c = vKeyCache, c.key == cacheKey { return c.code }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let code = data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return CGKeyCode(kVK_ANSI_V) }
            let command = UInt32((cmdKey >> 8) & 0xFF)
            for code in 0..<128 {
                var dead: UInt32 = 0, len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), command, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if st == noErr, len == 1, chars[0] == UniChar(("v" as UnicodeScalar).value) { return CGKeyCode(code) }
            }
            return CGKeyCode(kVK_ANSI_V)
        }
        vKeyCache = (cacheKey, code)
        return code
    }
    nonisolated(unsafe) private static var vKeyCache: (key: String, code: CGKeyCode)?

    /// What kind of place the cursor is in right now, and the focused element's role for the log.
    static func focus() -> (kind: FocusKind, role: String) {
        // Asking Accessibility about our own window from here waits on ourselves: never do it.
        if ownWindowInFront { return (.unknown, "Redpen Voice") }
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
        if ownWindowInFront { return nil }
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
              CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return (el, pid)
    }

    /// Puts text straight into a box that is not in front (you moved to another app while talking), without bringing
    /// it forward. Counts only when the box's text grew by exactly that much; Chrome and Electron boxes usually refuse
    /// when they're in the background, and then the words wait for you to go back.
    static func textInto(_ el: AXUIElement, _ text: String) -> Bool {
        guard !text.isEmpty, let before = value(el) else { return false }
        let padded = spaced(text, before: el)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, padded as CFString) == .success,
              let after = value(el), after.utf16.count == before.utf16.count + padded.utf16.count, after.contains(padded) else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        last = (padded, pid, Date()); lastDictation = nil; typedSince = false
        return true
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

    /// Deletes `count` characters before the cursor. No modifiers: with Fn held, Delete is forward delete, and with
    /// Option held it deletes whole words. `still` is asked before every character; the moment it says no (you
    /// typed or clicked), it stops. Returns how many it deleted.
    @discardableResult
    static func backspace(_ count: Int, while still: () -> Bool = { true }) -> Int {
        var done = 0
        for _ in 0..<count {
            guard still() else { break }
            guard let pair = VoiceEvents.keyboardPair(key: CGKeyCode(kVK_Delete)) else { return done }
            pair.down.post(tap: .cgSessionEventTap); pair.up.post(tap: .cgSessionEventTap)
            done += 1
            usleep(1_500)
        }
        return done
    }

    /// One of Voice's own windows is in front (Settings, first run). Accessibility questions about it would wait on
    /// ourselves, so they are never asked.
    static var ownWindowInFront: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }

    /// Forgets the last dictation's record, when the box no longer matches it (a draft was replaced), so Take back
    /// can never delete by an old length.
    static func forgetLast() { last = nil }

    /// How many characters are selected in a box, or nil when it won't say.
    static func selectionLength(_ el: AXUIElement) -> Int? { selectedRange(el)?.length }

    static func selectionRange(_ el: AXUIElement) -> NSRange? { selectedRange(el) }

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

    /// Names from the word list, spelled as they must stay when a dictation lands mid-sentence.
    nonisolated(unsafe) static var keepNames: Set<String> = []

    /// The text fitted to where it lands (D-817): lowercase start mid-sentence, no full stop right before a word.
    /// Left alone when the box won't say what is around the cursor.
    private static func fit(_ text: String, in el: AXUIElement) -> String {
        guard let r = selectedRange(el) else { return text }
        func string(_ location: Int, _ length: Int) -> String? {
            guard length > 0 else { return "" }
            var cf = CFRange(location: location, length: length)
            guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
            var v: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success else { return nil }
            return v as? String
        }
        let from = max(0, r.location - 3)
        guard let before = string(from, r.location - from) else { return text }
        let total = (value(el) as NSString?)?.length
        let afterChar: Character?
        if let total, r.location + r.length >= total { afterChar = nil }
        else { guard let a = string(r.location + r.length, 1) else { return text }; afterChar = a.first }
        let out = Fit.text(text, before: before, after: afterChar, keep: keepNames)
        if out != text { Log.note("insert: fitted to the sentence around the cursor") }
        return out
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

    private static var canTypeAtFocus: Bool {
        let current = focus()
        return FocusGate.canType(kind: current.kind, hasFocusedElement: current.role != "none" && current.role != "Redpen Voice")
    }

    /// Types the text as keyboard events, 20 characters at a time. Slower than a paste and works everywhere.
    /// Typed keys go in at the session level, not as hardware: posted as hardware they reset the Mac's "seconds since
    /// the last key press", so Voice's own typing looked like you typing and live drafts stopped after the first
    /// 20 characters (Oct 26, every draft dictation stuck at one run).
    /// Stops if you switch apps partway, so the rest never lands somewhere else, or when `still` says no.
    static func type(_ text: String, while still: () -> Bool = { true }) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var ok = false
        for chunk in Array(text.utf16).chunks(of: 20) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app { Log.note("insert: app changed while typing, stopped"); return false }
            guard still() else { Log.note("insert: you typed or clicked, stopped"); return false }
            // A tab change keeps the same app: check the place itself too, so the rest never become page shortcuts.
            guard canTypeAtFocus else { Log.note("insert: no typing target while typing, stopped"); return false }
            var units = chunk
            guard let (down, up) = VoiceEvents.keyboardPair(key: 0) else { return false }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            // No modifiers: with Fn or Option held to talk, the letters would otherwise arrive as Fn or Option
            // shortcuts (Fn-E opens emoji, Option-letters type accents).
            down.flags = []; up.flags = []
            down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
            ok = true; typedSome = true; typedCount += units.count
            usleep(4_000)
        }
        return ok
    }
}

private extension Array {
    func chunks(of n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}

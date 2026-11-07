import AppKit
import AVFoundation
import VoiceCore
import WebKit

/// After the call (D-1108, D-1126): the window that opens when a meeting's notes are ready. What has to happen first,
/// most critical first, each with Hear it; the follow-up email; then the rest, folded. The page is built from the
/// notes file by `AfterCallPage` and loads nothing; this window plays the sound, copies the email and hands it to
/// Mail as a draft. Nothing is sent from here.
@MainActor
final class AfterCall: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var file: URL?
    private var player: AVAudioPlayer?
    private var until: Double = 0, from: Double = 0
    private var tick: Timer?
    /// Name the voices, from the page's link; the window reloads once they are saved.
    var nameVoices: ((URL) -> Void)?
    /// Get better notes, from the page's link on Apple's notes (D-1272).
    var betterNotes: ((URL) -> Void)?
    var writeNotesAgain: ((URL, Bool) -> Void)?
    var onClose: (() -> Void)?
    private var retries: [URL: MeetingNotesRetry.Presentation] = [:]

    /// The page's fonts, read once from the app's Resources: Newsreader as data, so the page needs no file access.
    static let fonts: String = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return "" }
        return [("Regular", 400), ("Medium", 500), ("SemiBold", 600)].compactMap { name, weight in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("Newsreader16pt-\(name).ttf")) else { return nil }
            return "@font-face { font-family: \"Newsreader\"; src: url(data:font/ttf;base64,\(d.base64EncodedString())); font-weight: \(weight); }"
        }.joined(separator: "\n")
    }()

    /// The first word of the Mac account's full name signs the email.
    static var sender: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }

    static func audio(for file: URL) -> (me: URL, others: URL) {
        let base = file.deletingPathExtension().lastPathComponent, dir = file.deletingLastPathComponent()
        return (dir.appendingPathComponent(base + " Me.m4a"), dir.appendingPathComponent(base + " Others.m4a"))
    }

    static func page(for file: URL, retry: MeetingNotesRetry.Presentation = .init()) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let a = audio(for: file), fm = FileManager.default
        return AfterCallPage.html(AfterCallPage.read(text), sender: sender,
                                  audio: fm.fileExists(atPath: a.me.path) || fm.fileExists(atPath: a.others.path), fonts: fonts, retry: retry)
    }

    static func webView(_ handler: (WKScriptMessageHandler & WKNavigationDelegate)?, frame: NSRect) -> WKWebView {
        let c = WKWebViewConfiguration()
        // Nothing the page holds is kept anywhere: no cookies, no cache, no storage.
        c.websiteDataStore = .nonPersistent()
        if let handler { c.userContentController.add(handler, name: "redpen") }
        let w = WKWebView(frame: frame, configuration: c)
        w.navigationDelegate = handler
        w.setValue(false, forKey: "drawsBackground")
        w.underPageBackgroundColor = NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1c / 255, alpha: 1)
        return w
    }

    /// Opens (or brings back) the window for `file`. False when the file can't be read.
    @discardableResult
    func show(_ file: URL) -> Bool {
        guard let html = Self.page(for: file, retry: retries[file] ?? .init()) else { return false }
        stop()
        self.file = file
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1c / 255, alpha: 1)
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 560, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            let v = Self.webView(self, frame: w.contentLayoutRect)
            v.autoresizingMask = [.width, .height]
            w.contentView = v
            web = v
            w.center()
            window = w
        }
        window?.title = file.deletingPathExtension().lastPathComponent
        web?.loadHTMLString(html, baseURL: nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// The same notes again, after the voices were named.
    func reload() { if let f = file, window?.isVisible == true { show(f) } }

    /// Update only the page the user left open. Never reopen a dismissed window or replace another meeting's page.
    func retryStatus(_ state: MeetingNotesRetry.Presentation, for file: URL, refresh: Bool = false) {
        retries[file] = state
        guard self.file == file, window?.isVisible == true else { return }
        if refresh, let html = Self.page(for: file, retry: state) {
            stop(); web?.loadHTMLString(html, baseURL: nil)
        } else {
            let values: [String: Any] = ["message": state.message, "progress": state.progress.map { $0 as Any } ?? NSNull(), "offerClaude": state.offerClaude]
            if let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) {
                web?.evaluateJavaScript("window.notesRetry(\(json))")
            }
        }
    }

    func isShowing(_ file: URL) -> Bool { self.file == file && window?.isVisible == true }

    func windowWillClose(_ notification: Notification) { stop(); onClose?() }

    // MARK: The page's clicks

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // An unavailable model can finish before WebKit finishes loading the page. Apply the latest state then too.
        if let file, let state = retries[file] { retryStatus(state, for: file) }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let act = m["act"] as? String, let file else { return }
        switch act {
        case "hear":
            guard let track = m["track"] as? String, let from = m["from"] as? Double, let to = m["to"] as? Double else { return }
            play(track == "others" ? Self.audio(for: file).others : Self.audio(for: file).me, from: from, to: to)
        case "stop": stop()
        case "copy":
            guard let subject = m["subject"] as? String, let body = m["body"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Subject: \(subject)\n\n\(body)", forType: .string)
        case "mail":
            guard let subject = m["subject"] as? String, let body = m["body"] as? String else { return }
            // A draft in the user's mail app, addressed to no one: they choose who it goes to and press Send.
            var q = URLComponents(); q.scheme = "mailto"; q.path = ""
            q.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = q.url { NSWorkspace.shared.open(url) }
        case "names": nameVoices?(file)
        case "better": betterNotes?(file)
        case "retry": writeNotesAgain?(file, false)
        case "retry-claude": writeNotesAgain?(file, true)
        case "file": NSWorkspace.shared.open(file)
        default: break
        }
    }

    /// Only the page itself loads; a link said in a meeting never opens anything.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other && (action.request.url?.absoluteString == "about:blank" || action.request.url == nil) ? .allow : .cancel
    }

    // MARK: Sound

    private func play(_ track: URL, from: Double, to: Double) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: track) else { send(1); return }
        p.currentTime = min(from, max(0, p.duration - 0.1))
        guard p.play() else { send(1); return }
        player = p; self.from = from; until = min(to, p.duration)
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                let span = max(0.1, self.until - self.from)
                let done = min(1, max(0, (p.currentTime - self.from) / span))
                if p.currentTime >= self.until || !p.isPlaying { self.stop(); self.send(1) } else { self.send(done) }
            }
        }
    }

    private func stop() {
        tick?.invalidate(); tick = nil
        player?.stop(); player = nil
    }

    private func send(_ fraction: Double) {
        web?.evaluateJavaScript("window.heard(\(String(format: "%.3f", fraction)))")
    }

    // MARK: A picture of the page, for checking the layout

    /// `--after-call-shot notes.md out.png`: the page for a notes file drawn to a picture, with no window shown.
    static func shot(_ notes: String, to path: String) {
        let file = URL(fileURLWithPath: notes)
        guard let html = page(for: file) else { print("can't read \(notes)"); exit(1) }
        let holder = ShotLoader(path: path)
        let v = webView(holder, frame: NSRect(x: 0, y: 0, width: 780, height: 900))
        holder.web = v
        let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v
        objc_setAssociatedObject(w, "holder", holder, .OBJC_ASSOCIATION_RETAIN)
        ShotLoader.keep = w
        // Opened folds and played lines can be drawn too: `--open` shows every fold, `--quote` the first Hear it.
        holder.script = (CommandLine.arguments.contains("--open") ? "document.querySelectorAll('.deep-row').forEach(r => r.click());" : "")
            + (CommandLine.arguments.contains("--quote") ? "document.querySelector('.quote').classList.add('on'); document.querySelector('.src').classList.add('on');" : "")
        v.loadHTMLString(html, baseURL: nil)
    }
}

/// Waits for the page, makes the view as tall as the page, and saves it.
@MainActor
private final class ShotLoader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static var keep: NSWindow?
    let path: String
    weak var web: WKWebView?
    var script = ""
    init(path: String) { self.path = path }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script + "document.documentElement.scrollHeight") { h, _ in
            let height = min(CGFloat((h as? Double) ?? 900), 6000)
            webView.frame.size.height = height
            webView.window?.setContentSize(webView.frame.size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let c = WKSnapshotConfiguration(); c.rect = NSRect(x: 0, y: 0, width: webView.frame.width, height: height)
                webView.takeSnapshot(with: c) { image, _ in
                    if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: self.path))
                    }
                    exit(0)
                }
            }
        }
    }
}

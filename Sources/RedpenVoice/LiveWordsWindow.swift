import AppKit
import VoiceCore
import WebKit

/// The meeting's own window, with no other meetings, saved transcript, web requests, or persistent web storage.
@MainActor
final class LiveWordsWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var loaded = false
    private var pending: [String: Any] = [:]
    private var revision = 0
    private struct State: Equatable { var second: Int; var status: String; var paused: Bool; var onCall: Bool }
    private var sentState: State?
    private var lines: [LiveWordsLine] = []
    private var sentLines: [LiveWordsLine]?
    private var sentOnCall: Bool?
    private var awaitingApply: [(Date?) -> Void] = []
    var onClose: () -> Void = {}
    var onReady: (() -> Void)?

    func show(visible: Bool = true, width: CGFloat = 700, height: CGFloat = 720) {
        clearAndClose()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Live words"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 28 / 255, alpha: 1)
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 360, height: 280)
        w.isReleasedWhenClosed = false
        w.sharingType = .none
        w.delegate = self
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        v.navigationDelegate = self
        v.autoresizingMask = [.width, .height]
        v.setValue(false, forKey: "drawsBackground")
        v.underPageBackgroundColor = w.backgroundColor
        w.contentView = v
        window = w; web = v
        v.loadHTMLString(LiveWordsPage.html(fonts: AfterCall.fonts), baseURL: nil)
        w.center()
        if visible { w.orderFrontRegardless() }
    }

    func update(_ lines: [LiveWordsLine], elapsed: Double, status: String, paused: Bool, onCall: Bool,
                onApplied: ((Date?) -> Void)? = nil) {
        let state = State(second: Int(elapsed), status: status, paused: paused, onCall: onCall)
        // The clock only changes once a second. Dictation does not pay for four identical ticks between changes.
        if loaded, onApplied == nil, sentState == state, sentLines == lines { return }
        sentState = state
        if let onApplied { awaitingApply.append(onApplied) }
        self.lines = lines
        pending = ["elapsed": elapsed, "status": status, "paused": paused, "onCall": onCall]
        send()
    }

    /// The file harness waits for the real page to apply a line before measuring its appearance delay.
    func render(_ lines: [LiveWordsLine], elapsed: Double, onCall: Bool) async -> Bool {
        await withCheckedContinuation { turn in
            update(lines, elapsed: elapsed, status: "Listening…", paused: false, onCall: onCall,
                   onApplied: { turn.resume(returning: $0 != nil) })
        }
    }

    func prepareForTest(width: CGFloat = 700) async {
        await withCheckedContinuation { turn in
            onReady = { [weak self] in self?.onReady = nil; turn.resume() }
            show(visible: false, width: width)
        }
    }

    private func send() {
        guard loaded, !pending.isEmpty, let web else { return }
        var args = pending; pending.removeAll()
        revision += 1; args["revision"] = revision
        let onCall = args["onCall"] as? Bool
        args["lines"] = sentLines == lines && sentOnCall == onCall ? NSNull()
            : lines.map { ["id": $0.id, "track": $0.track.rawValue, "start": $0.start, "text": $0.text, "final": $0.final] as [String: Any] }
        sentLines = lines; sentOnCall = onCall
        let turns = awaitingApply; awaitingApply.removeAll()
        // A late reply must not hold up the next words. Revisions prevent an older request replacing newer state.
        // Timestamp inside WebKit, before reply delivery, so the harness measures DOM application separately.
        let script = """
        if (revision > (window.redpenRevision || 0)) {
          window.redpenRevision = revision;
          window.liveWords(lines, elapsed, status, paused, onCall);
        }
        return Date.now() / 1000;
        """
        web.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { [weak self, weak web] result in
            guard let self, let web, self.web === web else { turns.forEach { $0(nil) }; return }
            let applied: Date?
            if case .success(let value) = result, let seconds = value as? Double, seconds.isFinite {
                applied = Date(timeIntervalSince1970: seconds)
            } else { applied = nil }
            turns.forEach { $0(applied) }
        }
    }

    func clearAndClose() {
        loaded = false; pending.removeAll(); revision = 0; sentState = nil
        lines.removeAll(); sentLines = nil; sentOnCall = nil
        awaitingApply.forEach { $0(nil) }; awaitingApply.removeAll()
        web?.stopLoading()
        // Removing the view and releasing the nonpersistent store discards the DOM and its words.
        web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
        window?.contentView = nil
        window?.delegate = nil; window?.close(); window = nil
    }
    func windowWillClose(_ notification: Notification) { onClose() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard web === webView else { return }
        loaded = true; send(); onReady?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other && (action.request.url == nil || action.request.url?.absoluteString == "about:blank") ? .allow : .cancel
    }

    /// Actual WebKit behavior, not a string comparison of the page's source.
    func passiveChecks() async -> (passed: Int, failed: Int) {
        guard let web else { return (0, 1) }
        do {
            // Exercise the native bridge too, including overlapping updates and unchanged clock ticks.
            let old = LiveWordsLine(track: .me, id: 0, start: 0, end: 1, text: "old", final: false)
            var newest = old; newest.text = "newest"; newest.final = true
            update([old], elapsed: 1, status: "Listening…", paused: false, onCall: true)
            guard await render([newest], elapsed: 2, onCall: true) else { return (0, 1) }
            let nativeText = try await web.evaluateJavaScript("document.querySelector('.words').textContent") as? String
            let before = revision
            update([newest], elapsed: 2.2, status: "Listening…", paused: false, onCall: true)
            let quietTick = revision == before
            let values = try await web.evaluateJavaScript(Self.checkScript) as? [Bool] ?? []
            sentLines = nil; sentOnCall = nil
            let native = [window?.sharingType == NSWindow.SharingType.none, !web.configuration.websiteDataStore.isPersistent,
                          nativeText == "newest", quietTick]
            let all = values + native
            return (all.filter { $0 }.count, all.filter { !$0 }.count + (values.isEmpty ? 1 : 0))
        } catch { return (0, 1) }
    }

    private static let checkScript = """
    (() => {
      const checks = [], body = document.getElementById('body'), list = document.getElementById('lines');
      const rows = Array.from({length:80}, (_,i) => ({track:i%2?'me':'others',id:i,start:i*3,text:'A sample line of this meeting, with enough words to wrap across the window.',final:true}));
      liveWords(rows,241,'Listening…',false,true);
      checks.push(list.children.length === 80);
      checks.push(Math.abs(body.scrollHeight - body.clientHeight - body.scrollTop) < 2);
      checks.push([...list.querySelectorAll('.speaker')].some(e => e.textContent === 'You'));
      checks.push([...list.querySelectorAll('.speaker')].some(e => e.textContent === 'Others'));
      body.scrollTop = 0; rows.push({track:'me',id:80,start:241,text:'More words',final:false});
      liveWords(rows,242,'Listening…',false,true);
      checks.push(body.scrollTop === 0);
      checks.push(list.querySelectorAll('.draft').length === 1);
      liveWords(rows,242,'Paused',true,false);
      checks.push(document.body.classList.contains('paused') && document.getElementById('status').textContent === 'Paused');
      checks.push([...list.querySelectorAll('.speaker')].every(e => e.hidden && e.textContent === ''));
      rows[80].final = true; rows[80].text = '<img src=x onerror="window.bad=1"> & a quote';
      liveWords(rows,243,'Listening…',false,true);
      checks.push(list.querySelectorAll('.draft').length === 0);
      checks.push(!list.querySelector('img') && !window.bad && list.lastChild.querySelector('.words').textContent === rows[80].text);
      const first = list.firstChild; liveWords(null,244,'Listening…',false,true);
      checks.push(first === list.firstChild && document.getElementById('clock').textContent === '4:04');
      checks.push(document.documentElement.scrollWidth <= innerWidth);
      liveWords([],245,'Listening…',false,false);
      checks.push(list.children.length === 0);
      return checks;
    })()
    """

    /// Snapshot the actual page with made-up lines, without showing or capturing any other app.
    static func shot(to path: String, width: CGFloat = 700, paused: Bool = false, downloading: Bool = false) {
        let holder = LiveWordsWindow()
        shotHolder = holder
        holder.onReady = {
            let sample: [LiveWordsLine] = [
                .init(track: .others, id: 0, start: 893, end: 900, text: "We can take fifteen centimetres off the island. You lose one drawer stack and keep the seating.", final: true),
                .init(track: .me, id: 0, start: 901, end: 906, text: "I'd rather lose the drawers than the seating.", final: true),
                .init(track: .others, id: 1, start: 908, end: 914, text: "Okay. Fifteen off the island, and the seating stays at three.", final: true),
                .init(track: .others, id: 2, start: 915, end: 920, text: "I'll redraw it tonight and send it over before you order anything.", final: false)
            ]
            if CommandLine.arguments.contains("--verify") {
                Task { @MainActor in
                    let checks = await holder.passiveChecks()
                    print("live window checks: \(checks.passed) passed, \(checks.failed) failed")
                    if checks.failed > 0 { holder.clearAndClose(); exit(1) }
                    holder.update(downloading ? [] : sample, elapsed: 920,
                                  status: downloading ? "Downloading the fast engine (about 600 MB)…" : paused ? "Paused" : "Listening…",
                                  paused: paused, onCall: !CommandLine.arguments.contains("--room"))
                }
            }
            holder.update(downloading ? [] : sample, elapsed: 920,
                          status: downloading ? "Downloading the fast engine (about 600 MB)…" : paused ? "Paused" : "Listening…",
                          paused: paused, onCall: !CommandLine.arguments.contains("--room"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let web = holder.web else { exit(1) }
                web.takeSnapshot(with: nil) { image, error in
                    guard error == nil, let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
                    do { try data.write(to: URL(fileURLWithPath: path)); print("live words shot saved, sharing none \(holder.window?.sharingType == NSWindow.SharingType.none)") }
                    catch { print("could not save live words shot"); exit(1) }
                    holder.clearAndClose(); shotHolder = nil; exit(0)
                }
            }
        }
        holder.show(visible: false, width: width)
    }
    private static var shotHolder: LiveWordsWindow?
}

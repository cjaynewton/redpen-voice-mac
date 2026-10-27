import AppKit
import Combine
import AVFoundation
import CoreAudio
import Speech
import Carbon.HIToolbox
import SwiftUI
import VoiceCore

/// Redpen Voice: hold a key, talk, let go, and the words land where the cursor is. Apple's on-device engine, raw by
/// default, everything kept on this Mac.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem!
    private var config = Config.load()
    private let keys = HoldKey()
    private let recorder = Recorder()
    private let engine = Transcriber()
    private let hud = HUD()
    private let history = History(url: Config.historyURL)
    private var firstRun: FirstRunWindow?
    private var historyWindow: HistoryWindow?
    /// Daily counts, numbers only (D-837), in their own file: the history's keep choice never touches them.
    private let stats = StatsStore(url: Config.statsURL)
    private var statsWindow: StatsWindow?
    /// The last dictation, in memory, for Paste last when nothing is kept on disk (D-825).
    private var lastSaid: Entry?
    private var settings: SettingsWindow?
    private var session: Transcriber.Session?
    private var startedAt = Date()
    private var pausedMedia = false
    private var settleWork: DispatchWorkItem?
    private var busy = false
    private var press = 0
    private var pasteKey: Shortcut?
    private var undoKey: Shortcut?
    /// ⌃⌥S, only while "Point out words to check" is on: swaps in the other engine's hearing of the marked word.
    private var swapKey: Shortcut?
    private var riskSwap: (swapped: String, gen: Int, element: AXUIElement, typed: String)?
    private var typingWatch: Any?
    private var clickWatch: Any?
    /// The last time you typed a key or clicked, to know that the end of the box is still Voice's own typing.
    private var userActedAt = Date.distantPast
    private var names = Names(text: "")
    private let menu = MenuModel()
    private let panel = NSPopover()
    /// The app you were in when the panel opened, so Paste and Take back land there.
    private var panelOrigin: NSRunningApplication?

    func applicationDidFinishLaunching(_ n: Notification) {
        // `--hud-demo [style]` shows the talking bar for four seconds with a fake voice, then two of writing, so its
        // look can be checked on screen.
        if let i = CommandLine.arguments.firstIndex(of: "--hud-demo") {
            if i + 1 < CommandLine.arguments.count, !CommandLine.arguments[i + 1].hasPrefix("--") { hud.style = CommandLine.arguments[i + 1] }
            hud.show("", level: true)
            // `--hud-caption "text"`: words in the bar as you talk (Instant).
            if let k = CommandLine.arguments.firstIndex(of: "--hud-caption"), k + 1 < CommandLine.arguments.count {
                let text = CommandLine.arguments[k + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [hud] in hud.caption(text) }
            }
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [hud] _ in
                t += 0.05
                MainActor.assumeIsolated {
                    if t < 4 { hud.level(Float(0.45 + 0.35 * sin(t * 9) * sin(t * 2.3))) } else if t < 4.06 { hud.writing() }
                    // `--hud-snapshot dir` also saves the talking and writing bars as PNGs.
                    if let k = CommandLine.arguments.firstIndex(of: "--hud-snapshot"), k + 1 < CommandLine.arguments.count,
                       abs(t - 2) < 0.026 || abs(t - 5) < 0.026 {
                        hud.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[k + 1]).appendingPathComponent("\(hud.style)-\(t < 4 ? "talking" : "writing").png"))
                    }
                }
                if t > 6 { exit(0) }
            }
            return
        }
        // `--hud-message "text" [ok]` shows a message in the talking bar for three seconds, so its look can be checked.
        if let i = CommandLine.arguments.firstIndex(of: "--hud-message"), i + 1 < CommandLine.arguments.count {
            hud.flash(CommandLine.arguments[i + 1], ok: CommandLine.arguments.contains("ok"), for: 3)
            if let k = CommandLine.arguments.firstIndex(of: "--hud-snapshot"), k + 1 < CommandLine.arguments.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [hud] in
                    hud.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[k + 1]).appendingPathComponent("message.png"))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { exit(0) }
            return
        }
        // `--stats-shot out.png [dark]` draws the Stats window with made-up sample numbers, never the ones on this Mac.
        if let i = CommandLine.arguments.firstIndex(of: "--stats-shot"), i + 1 < CommandLine.arguments.count {
            Ink.registerFonts()
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("dark") ? .darkAqua : .aqua)
            let now = Date()
            let sample = StatsModel.sample(now: now)
            let model = StatsModel(typing: 40) { sample }; model.now = { now }
            let v = NSHostingView(rootView: StatsView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            v.frame = NSRect(x: 0, y: 0, width: StatsView.width, height: 728)
            Self.shoot(v, to: CommandLine.arguments[i + 1])
            return
        }
        Config.ensureNamesFile()
        // Once, before the history is trimmed: the counts from before stats.json existed carry over.
        if stats.backfillIfNeeded(history.all()) { Log.note("stats: counted \(stats.days.reduce(0) { $0 + $1.dictations }) dictations from the history") }
        history.trim()
        history.apply(keep: config.historyKeep ?? "all")
        names = Names(text: Config.loadNames()); Insert.keepNames = Set(names.spellings)
        engine.onState = { [weak self] s in
            self?.refreshMenu()
            self?.firstRun?.refresh()
            self?.settings?.model.engineState = s
            if s == .ready {
                self?.warmMic()
                if self?.restarted == true { self?.restarted = false; self?.hud.flash("Restarted, ready", ok: true, for: 2.5) }
            }
        }
        // `--draft-replace-test out.txt` checks draft replacement in the app in front: with "Mine stays. " already in the
        // box and the cursor after it, types two drafts, replaces the first with Whisper's version (and retypes the
        // second), then reads the box back. Writes pass or fail to out.txt.
        if let i = CommandLine.arguments.firstIndex(of: "--draft-replace-test"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let want = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : "TextEdit"
            let ids = ["TextEdit": "com.apple.TextEdit", "Google Chrome": "com.google.Chrome"]
            if let id = ids[want], let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var lines: [String] = ["app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")", "trusted: \(AXIsProcessTrusted())"]
                // Never type or delete anywhere but the test document: the app in front must be the expected one and
                // the focus a text box.
                guard NSWorkspace.shared.frontmostApplication?.localizedName == want, Insert.focus().kind == .text else {
                    lines.append("SKIPPED: \(want) with a text box was not in front")
                    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                    exit(2)
                }
                let el = Insert.focusedElement()?.0
                func box() -> String { el.flatMap { Insert.value($0) } ?? "(can't read)" }
                // Cursor to the end of the box (Command-Down).
                if let src = CGEventSource(stateID: .combinedSessionState) {
                    for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 125, keyDown: down); e?.flags = .maskCommand; e?.post(tap: .cghidEventTap) }
                }
                usleep(300_000)
                lines.append("before: \(box().debugDescription)")
                // Drafts over 20 characters (more than one typed chunk each), with the same guard live drafts use.
                let start = Date()
                let quiet = { AppDelegate.userQuietSince(start) }
                let d1 = "one two three four five six", d2 = "seven eight nine ten eleven"
                let ok1 = Insert.text(d1, while: quiet)
                let a = String(repeating: " ", count: Insert.typedPadding) + d1
                usleep(300_000)
                let ok2 = Insert.text(d2, while: quiet)
                let b = String(repeating: " ", count: Insert.typedPadding) + d2
                lines.append("draft 1 typed \(ok1), draft 2 typed \(ok2), still quiet \(quiet())")
                usleep(300_000)
                lines.append("drafts: \(box().debugDescription)")
                let fixed = (a.first == " " ? " " : "") + "One, two, three, four, five, six."
                let n = Insert.backspace((a + b).count, while: quiet)
                let ok = Insert.type(fixed + b, while: quiet)
                usleep(400_000)
                let final = box()
                lines.append("deleted \(n) of \((a + b).count), retyped \(ok)")
                lines.append("after: \(final.debugDescription)")
                let want = "Mine stays. One, two, three, four, five, six. seven eight nine ten eleven"
                lines.append(final.hasSuffix(want) || final == want ? "PASS" : "FAIL (wanted \(want.debugDescription))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // `--back-test out.txt AppName` checks typing into a box that is no longer in front: notes the focused box in the
        // named app, brings Finder forward, types into the noted box without bringing it back, and reads it.
        if let i = CommandLine.arguments.firstIndex(of: "--back-test"), i + 2 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1], want = CommandLine.arguments[i + 2]
            let ids = ["TextEdit": "com.apple.TextEdit", "Google Chrome": "com.google.Chrome"]
            if let id = ids[want], let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var lines = ["app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"]
                guard NSWorkspace.shared.frontmostApplication?.localizedName == want, Insert.focus().kind == .text, let (el, _) = Insert.focusedElement() else {
                    lines.append("SKIPPED"); try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8); exit(2)
                }
                let before = Insert.value(el) ?? "?"
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
                usleep(600_000)
                lines.append("front now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                let ok = Insert.textInto(el, "back where I started")
                lines.append("typed into the box in the background: \(ok)")
                lines.append("before: \(before.debugDescription)")
                lines.append("after: \((Insert.value(el) ?? "?").debugDescription)")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // `--session-test clips.txt [pauseSeconds]` feeds each clip through a live dictation at talking speed and times
        // the wait after letting go.
        if let i = CommandLine.arguments.firstIndex(of: "--session-test"), i + 1 < CommandLine.arguments.count {
            let list = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            let pause = i + 2 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 2]) ?? 0.4 : 0.4
            var config = config
            // `--engine live` runs the Instant engine instead of Whisper.
            config.engine = CommandLine.arguments.firstIndex(of: "--engine").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "whisper"
            Task { [config, engine] in
                await engine.prepare(config)
                for path in list where !path.isEmpty {
                    do { let r = try await engine.sessionTest(URL(fileURLWithPath: path), pause: pause, engine: config.engine); print("\((path as NSString).lastPathComponent): \(r.ms) ms after release: \(r.text)") }
                    catch { print("failed: \(error)") }
                    fflush(stdout)
                }
                exit(0)
            }
            return
        }
        // `--speed-test clip.wav [idleSeconds]` times Whisper on one clip, warm and after sitting idle.
        if let i = CommandLine.arguments.firstIndex(of: "--speed-test"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let idle = i + 2 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 2]) ?? 60 : 60
            var config = config
            config.engine = "whisper"
            Task { [config, engine] in
                await engine.prepare(config)
                do { try await engine.speedTest(URL(fileURLWithPath: path), idle: idle) } catch { print("failed: \(error)") }
                fflush(stdout); exit(0)
            }
            return
        }
        // `--stream-test files.txt out.jsonl [pauseSeconds]` writes each file whole and streamed (cut at pauses as a
        // live dictation would be), one JSON line each, with the wait after release. Whisper only.
        if let i = CommandLine.arguments.firstIndex(of: "--stream-test"), i + 2 < CommandLine.arguments.count {
            let list = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            let outPath = CommandLine.arguments[i + 2]
            let pause = i + 3 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 3]) ?? 0.5 : 0.5
            var config = config
            config.engine = "whisper"
            if ProcessInfo.processInfo.environment["VOICE_DRAFT"] == "1" { config.draftMode = true }
            FileManager.default.createFile(atPath: outPath, contents: nil)
            Task { [config, engine] in
                await engine.prepare(config)
                guard let h = FileHandle(forWritingAtPath: outPath) else { print("cannot write \(outPath)"); exit(1) }
                for path in list where !path.isEmpty {
                    do {
                        let env = ProcessInfo.processInfo.environment
                        if env["VOICE_DRAFT"] == "1" {
                            let row = try await engine.draftTest(URL(fileURLWithPath: path))
                            if let d = try? JSONSerialization.data(withJSONObject: row) { h.write(d); h.write(Data("\n".utf8)) }
                            print("\((path as NSString).lastPathComponent) done"); fflush(stdout)
                            continue
                        }
                        let row = try await engine.streamTest(URL(fileURLWithPath: path), chunker: Chunker(pauseSeconds: pause),
                                                              hints: env["VOICE_HINTS"] ?? "", carry: env["VOICE_CARRY"] == "1")
                        if let d = try? JSONSerialization.data(withJSONObject: row) { h.write(d); h.write(Data("\n".utf8)) }
                        print("\((path as NSString).lastPathComponent) done"); fflush(stdout)
                    } catch { print("\(path): \(error)") }
                }
                try? h.close()
                exit(0)
            }
            return
        }
        // `--transcribe file.wav` runs the engine over a file and prints the text: the engine checked without a mic.
        // `--transcribe-list files.txt out.jsonl` runs the engine over many files, one JSON line each, and skips
        // files already in the output so a stopped run picks up where it left off. Used for the accuracy benchmark.
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe-list"), i + 2 < CommandLine.arguments.count {
            let list = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            let outPath = CommandLine.arguments[i + 2]
            var config = config
            if let e = CommandLine.arguments.firstIndex(of: "--engine"), e + 1 < CommandLine.arguments.count { config.engine = CommandLine.arguments[e + 1] }
            let done = Set(((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> String? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) .flatMap { ($0 as? [String: Any])?["file"] as? String }
            })
            if !FileManager.default.fileExists(atPath: outPath) { FileManager.default.createFile(atPath: outPath, contents: nil) }
            Task { [config, engine] in
                await engine.prepare(config)
                guard let h = FileHandle(forWritingAtPath: outPath) else { print("cannot write \(outPath)"); exit(1) }
                h.seekToEndOfFile()
                var n = done.count
                for path in list where !path.isEmpty && !done.contains((path as NSString).lastPathComponent) {
                    let start = Date()
                    var row: [String: Any] = ["file": (path as NSString).lastPathComponent]
                    do { row["hyp"] = try await engine.transcribeFile(URL(fileURLWithPath: path), config: config) }
                    catch { row["error"] = "\(error)" }
                    row["secs"] = Date().timeIntervalSince(start)
                    if let d = try? JSONSerialization.data(withJSONObject: row) { h.write(d); h.write(Data("\n".utf8)) }
                    n += 1
                    if n % 25 == 0 { print("\(n) of \(list.count)"); fflush(stdout) }
                }
                try? h.close()
                print("done \(n) of \(list.count)")
                exit(0)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            var config = config
            if let e = CommandLine.arguments.firstIndex(of: "--engine"), e + 1 < CommandLine.arguments.count { config.engine = CommandLine.arguments[e + 1] }
            Task { [config, engine] in
                await engine.prepare(config)
                do { print(try await engine.transcribeFile(url, config: config)) } catch { print("error: \(error)") }
                exit(0)
            }
            return
        }
        // `--media-check` logs which apps hold the speakers and how loud the Mac is playing right now.
        // `--tap-test pid seconds out.wav` records what one app plays through the same tap a dictation uses and writes
        // the 16 kHz copy the engines hear, for checking that the video's words can be written down (D-817).
        if let i = CommandLine.arguments.firstIndex(of: "--tap-test"), i + 3 < CommandLine.arguments.count,
           var pid = pid_t(CommandLine.arguments[i + 1]), let secs = Double(CommandLine.arguments[i + 2]) {
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 3])
            var obj = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
            let rec = SoundTap.Recording()
            SoundTap.loudness(of: [obj], for: secs, record: rec) { peak in
                let a = rec.mono16k()
                let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                if let f = try? AVAudioFile(forWriting: out, settings: fmt.settings), let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, a.count))) {
                    b.frameLength = AVAudioFrameCount(a.count)
                    a.withUnsafeBufferPointer { if let base = $0.baseAddress { b.floatChannelData![0].update(from: base, count: a.count) } }
                    try? f.write(from: b)
                }
                print("tap-test: process \(obj), peak \(peak.map { String(format: "%.3f", $0) } ?? "none"), \(String(format: "%.2f", Double(a.count) / 16000)) s kept")
                exit(0)
            }
            return
        }
        // `--box-test pid` checks the start-box fingerprint on a real app (D-817): the focused box read again must
        // match, every other text box in its window must not, and the same box emptied (a sent message) must not.
        if let i = CommandLine.arguments.firstIndex(of: "--box-test"), i + 1 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            usleep(800_000)
            func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
            var focused: CFTypeRef?
            for _ in 0..<20 where focused == nil { focused = attr(app, kAXFocusedUIElementAttribute); if focused == nil { usleep(250_000) } }
            guard let f = focused else { print("box-test: no focused box"); exit(1) }
            let el = f as! AXUIElement
            let start = Self.boxPrint(el, withText: true)
            print("box-test: start \(start.role ?? "?"), id \(start.identifier ?? "none"), frame \(start.frame.map { "\($0)" } ?? "none"), text \(start.prefix.map { "\($0.count) chars" } ?? "unreadable")")
            print("box-test: same box again -> \(BoxMatch.same(start: start, now: Self.boxPrint(el, withText: false), nowText: Insert.value(el), sameElement: true))")
            var boxes: [AXUIElement] = []
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard depth < 40 else { return }
                if (attr(e, kAXRoleAttribute) as? String) == "AXTextArea" || (attr(e, kAXRoleAttribute) as? String) == "AXTextField" { boxes.append(e) }
                for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
            }
            if let w = attr(el, kAXWindowAttribute) { walk(w as! AXUIElement, 0) }
            for o in boxes where !CFEqual(o, el) {
                print("box-test: other box in the window -> \(BoxMatch.same(start: start, now: Self.boxPrint(o, withText: false), nowText: Insert.value(o), sameElement: false))")
            }
            // Emptying is tried only on the test page, and the text is put back after.
            if (start.context ?? "").contains("rv-box-test") {
                let before = Insert.value(el) ?? ""
                AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, "" as CFString)
                usleep(300_000)
                print("box-test: same box after it was emptied -> \(BoxMatch.same(start: start, now: Self.boxPrint(el, withText: false), nowText: Insert.value(el), sameElement: true))")
                AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, before as CFString)
            } else { print("box-test: not the rv-box-test page, the box is left as it is") }
            exit(0)
        }
        // `--paste-test out.txt` checks the backup route on a real app (D-825): a new TextEdit document in front, the
        // text pasted in, read back, and the clipboard checked to be exactly what it was before.
        if let i = CommandLine.arguments.firstIndex(of: "--paste-test"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let before = NSWorkspace.shared.frontmostApplication
            let clip = ClipboardSnapshot.take()
            let doc = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rv-paste-test-\(UUID().uuidString.prefix(6)).txt")
            try? "".write(to: doc, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open([doc], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                var lines: [String] = []
                let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
                te?.activate()
                usleep(600_000)
                // Only into the test document: anything else in front and nothing is pasted.
                func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
                var ok = false
                if let pid = te?.processIdentifier, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                   let f = attr(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
                   let w = attr(f as! AXUIElement, kAXWindowAttribute), ((attr(w as! AXUIElement, kAXTitleAttribute) as? String) ?? "").contains("rv-paste-test") {
                    let el = f as! AXUIElement
                    lines.append("pasted: \(Insert.paste("Pasted by the backup route."))")
                    usleep(100_000)
                    // A second paste inside the half second: the clipboard must still come back as it was before both.
                    lines.append("pasted again: \(Insert.paste(" Twice."))")
                    usleep(400_000)
                    lines.append("box now: \((Insert.value(el) ?? "?").debugDescription)")
                    ok = true
                } else { lines.append("refused: the test document wasn't in front") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    lines.append("clipboard back exactly as before: \(clip.matches())")
                    let close = NSAppleScript(source: "tell application \"TextEdit\" to close (every document whose name starts with \"rv-paste-test\") saving no")
                    close?.executeAndReturnError(nil)
                    try? FileManager.default.removeItem(at: doc)
                    before?.activate()
                    lines.append(ok ? "done" : "not run")
                    try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--media-check") {
            let players = Media.playingApps()
            SoundTap.loudness(of: players.map(\.object), for: 0.25) { peak in
                Log.note("media-check: apps [\(players.map(\.name).joined(separator: ", "))], loudness \(peak.map { String(format: "%.4f", $0) } ?? "no tap"), playing \(MediaGate.isPlaying(peak: peak))")
                exit(0)
            }
            return
        }
        // `--settings-shot out.png [dark]` draws the settings window to a picture and quits: the layout checked without clicking.
        if let i = CommandLine.arguments.firstIndex(of: "--settings-shot"), i + 1 < CommandLine.arguments.count {
            Ink.registerFonts()
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("dark") ? .darkAqua : .aqua)
            let model = SettingsModel(config: config, engine: engine) { _ in }
            model.statsTotal = { [stats] in let s = Stats.score(stats.days); return (s.words, s.seconds) }
            // `ready`: drawn as a Mac where the chosen engine has finished loading (for the README pictures).
            if CommandLine.arguments.contains("ready") { model.engineState = .ready }
            let v = NSHostingView(rootView: SettingsView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            v.frame = NSRect(x: 0, y: 0, width: 540, height: 2000)
            let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v; v.layoutSubtreeIfNeeded(); v.display()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Twice the size, as a Retina screen shows it.
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0) {
                    rep.size = v.bounds.size
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
                exit(0)
            }
            return
        }
        // `--menu-shot out.png [dark]` draws the menu bar panel to a picture and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--menu-shot"), i + 1 < CommandLine.arguments.count {
            Ink.registerFonts()
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("dark") ? .darkAqua : .aqua)
            menu.state = menuState()
            // `ready`: drawn as a set-up Mac (engine loaded, Fn key already set), for the README pictures.
            if CommandLine.arguments.contains("ready") { menu.state.ready = true; menu.state.status = "Ready"; menu.state.warning = nil }
            let v = NSHostingView(rootView: MenuPanel(model: menu))
            v.frame = NSRect(origin: .zero, size: v.fittingSize)
            Self.shoot(v, to: CommandLine.arguments[i + 1])
            return
        }
        // `--history-shot out.png [dark]` draws the history window with the history in the folder in use (README).
        if let i = CommandLine.arguments.firstIndex(of: "--history-shot"), i + 1 < CommandLine.arguments.count {
            Ink.registerFonts()
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("dark") ? .darkAqua : .aqua)
            let model = HistoryModel(history: history, keep: config.historyKeep ?? "all"); model.reload()
            model.entries = Array(model.entries.prefix(5))
            let v = NSHostingView(rootView: HistoryView(model: model, eager: true).buttonBorderShape(.roundedRectangle(radius: 4)))
            v.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
            Self.shoot(v, to: CommandLine.arguments[i + 1])
            return
        }
        // `--firstrun-shot out.png [dark]` draws the first-run window as a new Mac sees it, nothing allowed yet.
        if let i = CommandLine.arguments.firstIndex(of: "--firstrun-shot"), i + 1 < CommandLine.arguments.count {
            Ink.registerFonts()
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("dark") ? .darkAqua : .aqua)
            // Drawn after a newcomer has set up and said the practice sentence (`fresh`: before anything is allowed).
            let host = FirstRunHost(engineState: { "ready" }, micName: { "MacBook Pro Microphone" }, watchLevel: { _ in }, stopLevel: {},
                                    setMic: { _ in }, setTalkKey: { _ in }, restartKeys: {}, relaunch: {}, openSettings: {})
            let model = FirstRunModel(config: config, host: host)
            model.fnProblem = nil; model.micName = "MacBook Pro Microphone"; model.engine = "ready"
            if CommandLine.arguments.contains("fresh") {
                model.mic = .notDetermined; model.access = false
            } else if CommandLine.arguments.contains("fn") {
                model.mic = .authorized; model.access = true; model.level = 0.4; model.fnProblem = "Fn also starts Apple's dictation"
            } else {
                model.mic = .authorized; model.access = true; model.level = 0.62; model.keySeen = true
                model.practice = "Redpen Voice is ready to go."; model.practiced = true
            }
            let v = NSHostingView(rootView: FirstRunView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            v.frame = NSRect(x: 0, y: 0, width: 540, height: 700)
            Self.shoot(v, to: CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--mics") {
            for d in Mics.all() { print("\(d.uid)\t\(d.name)") }
            print("default\t\(Mics.defaultInput()?.name ?? "?")")
            exit(0)
        }
        recorder.deviceUID = config.inputDevice
        followDefaultMic()
        // `--mic-test 3` listens for three seconds on the configured mic and prints frames, peak and the engine's text.
        if let i = CommandLine.arguments.firstIndex(of: "--mic-test"), i + 1 < CommandLine.arguments.count, let secs = Double(CommandLine.arguments[i + 1]) {
            Task { [config, engine, recorder] in
                await engine.prepare(config)
                guard let f = engine.audioFormat else { print("no format"); exit(1) }
                do { try recorder.start(format: f) } catch { print("mic start failed: \(error)"); exit(1) }
                try? await Task.sleep(for: .seconds(1))
                let (s, m) = engine.session(config)
                s.start(module: m, vocabulary: [])
                recorder.begin(onBuffer: { s.push($0) }, onLevel: { _ in })
                try? await Task.sleep(for: .seconds(secs))
                let line = "frames \(recorder.pushedFrames) (\(Double(recorder.pushedFrames) / 16000)s) peak \(recorder.peak) from \(recorder.inputName)"
                print(line); Log.note("mic-test: " + line)
                recorder.end()
                do { let t = try await s.finish(); print("text: " + t); Log.note("mic-test text: \(t.count) chars") } catch { print("finish error: \(error)") }
                exit(0)
            }
            return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Redpen Voice")
        status.button?.target = self
        status.button?.action = #selector(togglePanel)
        setUpPanel()
        Self.applyAppearance(config)
        SFSpeechRecognizer.requestAuthorization { s in Log.note("speech permission: \(s.rawValue)") }
        Task { await engine.prepare(config) }
        keys.keys = HoldKey.keys(for: config.talkKeyChoice); keys.doubleTap = config.doubleTap ?? true
        fixWatch.onLearn = { [weak self] f in self?.learn(f) }
        keys.onHandsFree = { [weak self] in self?.handsFreeOn() }
        keys.onDown = { [weak self] in self?.begin() }
        keys.onUp = { [weak self] in self?.end() }
        keys.onCancel = { [weak self] in self?.cancel() }
        keys.start()
        pasteKey = Shortcut(id: 1, keyCode: kVK_ANSI_V, name: "Control-Option-V") { [weak self] in self?.pasteLastNow() }
        undoKey = Shortcut(id: 2, keyCode: kVK_ANSI_Z, name: "Control-Option-Z") { [weak self] in self?.takeBack() }
        updateSwapKey()
        installWatches()
        if !config.firstRunDone || !AXIsProcessTrusted() {
            let w = FirstRunWindow(config: config, host: firstRunHost())
            w.onDone = { [weak self] in guard let self else { return }; self.config = Config.load(); self.syncSettings(); self.refreshMenu(); self.warmMic() }
            firstRun = w
            w.show()
        }
        // One copy at a time: a second one (opened by hand while the watchdog reopens it) goes quietly.
        // The loser leaves no quit note: the note is per copy, and the running copy's watchdog must still guard it.
        if !Watchdog.takeLock() { Log.note("another copy is running, this one quits"); exit(0) }
        // Read again now that this is the only copy: another may have counted a dictation since launch began.
        stats.reload()
        if let p = stats.problem { Log.note("stats: \(p)") }
        Watchdog.start()
        restarted = CommandLine.arguments.contains("--restarted")
        Updates.shared.start()
        updateWatch = Updates.shared.$waiting.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshMenu() } }
        Log.note("launched")
    }

    /// Watches for your own typing and clicks. Set up again when Accessibility arrives (watchers made before it can
    /// stay deaf).
    private func installWatches() {
        if let t = typingWatch { NSEvent.removeMonitor(t) }
        if let c = clickWatch { NSEvent.removeMonitor(c) }
        // Any key you type yourself after a dictation means take-back must not guess. Our own typing is skipped.
        let me = Int64(ProcessInfo.processInfo.processIdentifier)
        typingWatch = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != me {
                MainActor.assumeIsolated {
                    Insert.typedSince = true
                    if self?.keys.keys.contains(where: { $0.code == Int(e.keyCode) }) != true { self?.userActedAt = Date() }
                }
            }
        }
        // A click anywhere means you may have moved the cursor: draft fixing stops for that dictation.
        clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.userActedAt = Date() }
        }
    }

    /// What the first window needs (D-825).
    private func firstRunHost() -> FirstRunHost {
        FirstRunHost(
            engineState: { [weak self] in self?.engineWord ?? "" },
            micName: { [weak self] in self?.recorder.inputName ?? "" },
            watchLevel: { [weak self] f in
                guard let self else { return }
                if self.recorder.inputName.isEmpty {
                    let fmt = self.engine.audioFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                    do { try self.recorder.start(format: fmt) } catch { Log.note("first run: mic failed \(error.localizedDescription)") }
                }
                self.recorder.watchLevel(f)
            },
            stopLevel: { [weak self] in self?.recorder.watchLevel(nil) },
            setMic: { [weak self] uid in
                guard let self else { return }
                self.config.inputDevice = uid; self.recorder.deviceUID = uid; self.syncSettings()
                let fmt = self.engine.audioFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                do { try self.recorder.start(format: fmt) } catch { Log.note("first run: mic failed \(error.localizedDescription)") }
            },
            setTalkKey: { [weak self] choice in
                guard let self else { return }
                self.config.talkKey = choice; self.keys.keys = HoldKey.keys(for: choice); self.syncSettings(); self.refreshMenu()
            },
            restartKeys: { [weak self] in
                guard let self else { return }
                self.keys.restart(); self.installWatches()
                Log.note("first run: Accessibility arrived, key watchers set up again")
            },
            relaunch: { [weak self] in self?.relaunch() },
            openSettings: { [weak self] in self?.openSettings() },
            changed: { [weak self] in guard let self else { return }; self.config = Config.load(); self.syncSettings(); self.refreshMenu() }
        )
    }

    /// Opens a fresh copy and quits this one: a clean quit (the watchdog stays quiet), the new copy starts after.
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The app's path goes in as an argument, never inside the command text.
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        Log.note("first run: restarting")
        NSApp.terminate(nil)
    }

    /// Quit asked while you are talking: finish the dictation and write the words first, then go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session != nil else {
            // Words still being written are dropped on quit; the video they paused is put back.
            if pausedMedia, config.resumeMedia ?? true { pausedMedia = false; Media.pressPlayPause(); Log.note("media: resumed on quit") }
            return .terminateNow
        }
        Log.note("quit asked mid-dictation, finishing first")
        quitting = true
        end()
        return .terminateLater
    }
    private var quitting = false
    private var updateWatch: AnyCancellable?
    /// Set while Voice decides whether something was playing, so the new session holds its drafts until then.
    private var holdForMedia = false
    /// The dictation a video decision belongs to, kept even after you let go, and how much of it came from before the
    /// key went down. A new one for every press.
    final class PendingMedia { weak var session: Transcriber.Session?; var preRoll = 0 }
    private var pendingMedia = PendingMedia()

    /// Calls back once the apps' sound has gone quiet (checked every tenth of a second), or after `tries` checks.
    /// Draws a view to a PNG at twice its size, as a Retina screen shows it, then quits. For the README pictures.
    static func shoot(_ v: NSView, to path: String) {
        let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v; v.layoutSubtreeIfNeeded(); v.display()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = v.bounds.size
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    nonisolated static func waitForQuiet(_ apps: [AudioObjectID], tries: Int, record: SoundTap.Recording? = nil, done: @escaping @Sendable (Date) -> Void) {
        SoundTap.loudness(of: apps, for: 0.1, record: record) { peak in
            if !MediaGate.isPlaying(peak: peak) || tries <= 0 { done(Date()) } else { waitForQuiet(apps, tries: tries - 1, record: record, done: done) }
        }
    }
    /// Reopened by the watchdog after a crash: the bar says so once the engine is ready.
    private var restarted = false

    func applicationWillTerminate(_ n: Notification) { Watchdog.markCleanQuit() }
    /// Dictations whose words are still being written. The pause is held until the last one is done.
    private var writing = 0
    /// The press whose recording the mic is feeding. Only that press may stop it.
    private var micOwner = 0
    /// Goes up with every press. A dictation finishing after a newer press began never waits or touches the bar.
    private var delivery = 0

    private var engineWord: String {
        switch engine.state {
        case .ready: return "ready"
        case .checking: return "checking"
        case .unsupported: return "unsupported"
        case .downloading(let p): return "downloading\(p)"
        case .failed(let s): return "failed: " + s
        }
    }

    // MARK: Dictation

    /// Keeps the mic open with a short memory, so the first syllable is never lost. Needs the mic allowed first.
    /// When the Mac's input changes (lid closed, interface plugged in), move the warm mic with it,
    /// unless a specific mic was picked in Settings.
    private func followDefaultMic() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.remicIfDefaultMoved(reason: "Mac input changed") }
        }
    }

    /// Restarts the warm mic on the Mac's current input if it has moved. Waits if a dictation is running.
    private func remicIfDefaultMoved(reason: String) {
        guard config.inputDevice.isEmpty, session == nil, testFile == nil,
              let now = Mics.defaultInput()?.uid, now != recorder.currentUID else { return }
        Log.note("mic: \(reason), moving to \(Mics.defaultInput()?.name ?? now)")
        recorder.stopEngine()
        warmMic()
    }

    private func warmMic() {
        guard let format = engine.audioFormat, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do { try recorder.start(format: format) } catch { Log.note("mic warm failed: \(error.localizedDescription)") }
    }

    private func begin() {
        guard !busy, session == nil, testFile == nil else { return }
        if firstRun?.isOpen == true { firstRun?.keySeen() }
        guard engine.state == .ready, let format = engine.audioFormat else { hud.flash(engineWord == "ready" ? "Not ready" : "Engine " + engineWord); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { hud.flash("Allow the microphone"); return }
        remicIfDefaultMoved(reason: "input moved before this press")
        if waitingText != nil { stopWaiting(); hud.hide(); Log.note("insert: new press, the waiting words stay for paste") }
        // Where this dictation's words go back to, if you move away while they are written.
        if Insert.focus().kind == .text, let (el, pid) = Insert.focusedElement() {
            startBox = StartBox(pid: pid, element: el, app: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "that app",
                                window: Self.windowTitle(pid), print: Self.boxPrint(el, withText: true))
        } else { startBox = nil }
        fixWatch.finish()
        delivery += 1
        busy = true
        // The bar waits a quarter second, so an Fn shortcut never flickers it.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil else { return }
            if self.config.showLevel {
                self.hud.style = self.config.levelLook; self.hud.micName = self.recorder.inputName
                self.hud.show("", level: true)
            }
        }
        // The pause listens to the speakers for that same quarter second and presses pause only on real sound.
        // An app holding the speakers open in silence (Chrome, Boom 3D) no longer starts a paused video.
        press += 1
        let thisPress = press
        // A press that starts while the last one's pause is still held (its words still being written) takes the
        // pause over, so the video comes back once, after this press, and is never paused or started twice.
        // The video is left alone until this is a real press: a quick tap (the first of a double tap, or a stray
        // tap) is over before 0.3 s and never presses anything, so taps can't flip a video on and off.
        pendingMedia = PendingMedia()
        if resumeWork != nil { resumeWork?.cancel(); resumeWork = nil }  // pressed again before the video came back
        if pausedMedia {
            Log.note("media: still paused from the last press")
        } else if config.pauseMedia {
            let players = Media.playingApps()
            if players.isEmpty { Log.note("media: no app playing") }
            else {
                holdForMedia = true
                // Listen from the moment the key goes down; press pause no sooner than 0.3 s in, so a tap never does.
                let pressedAt = Date()
                let mine = pendingMedia
                // What the app plays from here until it goes quiet is kept, so its words can come off the start.
                let played = SoundTap.Recording()
                SoundTap.loudness(of: players.map(\.object), for: 0.25, record: played) { peak in
                    DispatchQueue.main.async { [weak self] in
                        let wait = max(0, 0.3 - Date().timeIntervalSince(pressedAt))
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                            guard let self, let s = mine.session else { return }
                            // Let go (or pressed again) before Voice could decide: this dictation still gets a decision,
                            // so the video's words can't slip through. A press that short was all video if anything played.
                            guard self.press == thisPress, self.session === s, !self.pausedMedia else {
                                // Never erased: the words are kept for Paste last and nothing is typed.
                                if MediaGate.isPlaying(peak: peak) { s.mediaUnchecked() }
                                s.mediaSettled(); return
                            }
                            let playing = MediaGate.isPlaying(peak: peak)
                            Log.note("media: apps [\(players.map(\.name).joined(separator: ", "))], loudness \(peak.map { String(format: "%.4f", $0) } ?? "no tap"), paused \(playing)")
                            guard playing else { s.mediaSettled(); return }  // nothing playing: every word kept
                            self.pausedMedia = true; Media.pressPlayPause()
                            let pausedAt = Date()
                            // The video's own sound reached the mic until the pause took hold: listen for that app going
                            // quiet, then leave out everything before it, plus 0.15 s for the speakers and the room.
                            Self.waitForQuiet(players.map(\.object), tries: 8, record: played) { quietAt in
                                DispatchQueue.main.async {
                                    // Every word you said is kept and the video's words come off the start (D-817),
                                    // when Voice heard the video and the engine can write it down. Otherwise the
                                    // start is left out as before: the Mac's own engine, drafts typed as you talk,
                                    // nothing heard, or Instant, which drops the rest of a dictation when two voices
                                    // overlap (6 of 211 WildSpeech clips with other people talking, Oct 26 2026).
                                    let audio = played.mono16k()
                                    let canTakeOff = ["whisper", "parakeet"].contains(self.config.engine) && s.drafter == nil
                                    if canTakeOff, played.peak > 0, audio.count > 1600 {
                                        // The second before the key went down came from the mic alone; the app's sound
                                        // wasn't heard then, so that part is left out, all but its last 0.15 s.
                                        if mine.preRoll > 2400 { s.silence(upTo: mine.preRoll - 2400) }
                                        s.mediaEcho(audio)
                                        s.mediaSettled()
                                        Log.note("media: kept every word; the video's \(String(format: "%.1f", Double(audio.count) / 16000)) s will come off the start, quiet \(Log.ms(quietAt.timeIntervalSince(pausedAt)))ms after the pause")
                                        return
                                    }
                                    let cut = s.sampleAt(quietAt.addingTimeInterval(0.15))
                                    s.silence(upTo: cut)
                                    s.mediaSettled()
                                    Log.note("media: left out the first \(String(format: "%.1f", Double(cut) / 16000)) s (the video's sound), quiet \(Log.ms(quietAt.timeIntervalSince(pausedAt)))ms after the pause")
                                }
                            }
                        }
                    }
                }
            }
        }
        settleWork?.cancel(); settleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: settle)
        let (s, module) = engine.session(config)
        session = s
        pendingMedia.session = s
        if holdForMedia { s.holdForMedia(); holdForMedia = false }
        startedAt = Date()
        names = Names(text: Config.loadNames()); Insert.keepNames = Set(names.spellings)
        if config.sounds { NSSound(named: "Pop")?.play() }
        if recorder.inputName.isEmpty {
            do { try recorder.start(format: format) } catch {
                Log.note("mic failed: \(error.localizedDescription)"); hud.flash("No microphone"); session = nil; busy = false; return
            }
        }
        // The engine is listening before the pre-roll arrives, so nothing waits in a queue.
        s.start(module: module, vocabulary: names.vocabulary)
        // Whisper writes each stretch at a pause while you talk, so only the last few seconds are left at the end.
        livePieces = 0; liveTyped = 0; liveShown = ""; liveStopped = false; liveLeftover = ""
        // A dictation still finishing keeps its drafts as typed: the new one's words come after them.
        finishingDrafting?.checksStopped = true; finishingDrafting?.draftsStopped = true
        drafting = nil
        if config.engine == "whisper", s.drafter != nil, config.mode != "rewrite" {
            drafting = Drafting(owner: s)
            s.onDraft = { [weak self, weak s] i, t in DispatchQueue.main.async { if let s { self?.draft(i, t, from: s) } } }
            s.onCheck = { [weak self, weak s] r, t in DispatchQueue.main.async { if let s { self?.check(r, t, from: s) } } }
            s.streamDrafts()
            s.stream(Chunker(pauseSeconds: talk.pauseSeconds))
        } else if config.engine == "whisper" {
            // Off unless switched on: Whisper reads a hint word by word before it starts, and his 355-character names
            // list added about 3 s to every dictation (2.0 s to 5.2 s on the same clip, Oct 25). The names list still
            // fixes the words after Whisper writes them.
            s.hints = (config.screenHints ?? false) ? Hints.line(names: names.spellings, screen: screenWords()) : ""
            s.onPiece = { [weak self, weak s] piece in DispatchQueue.main.async { if let s { self?.piece(piece, from: s) } } }
            s.stream(Chunker(pauseSeconds: talk.pauseSeconds))
        } else if config.engine == "live" {
            // Instant (D-816): its words show in the bar as you talk; the box gets the text once, at the end.
            s.onPartial = { [weak self, weak s] text in
                DispatchQueue.main.async {
                    guard let self, let s, self.session === s, self.config.liveWords ?? true, !text.isEmpty else { return }
                    self.hud.caption(self.names.apply(text))
                }
            }
        }
        recorder.begin(onBuffer: { buf in s.push(buf) },
                       onLevel: { [weak self] v in DispatchQueue.main.async { self?.hud.level(v) } })
        pendingMedia.preRoll = Int(recorder.pushedFrames)
        micOwner = thisPress
        Log.note("recording from \(recorder.inputName)")
        busy = false
    }

    /// Fn was a shortcut, not talking: drop the audio, put the music back, no words written.
    private func cancel() {
        guard let s = session else { return }
        // Drafts already typed: finish and keep this dictation (no more edits to the box) rather than drop it with
        // words already on screen and nothing in history.
        if let d = drafting, d.owner === s, d.typedAny { d.checksStopped = true; d.draftsStopped = true; end(); return }
        wasHandsFree = false
        session = nil
        settleWork?.cancel()
        recorder.end()
        s.cancel()
        hud.hide()
        resumeMedia()
        Log.note("cancelled: another key while holding")
    }

    /// Pieces of the current dictation written so far, how many of them are already typed into the box, and the text
    /// shown in the bar.
    /// How you talk, learned from your dictations: numbers only, in talk.json beside your settings.
    private static let talkURL = Config.dir.appendingPathComponent("talk.json")
    private var talk = TalkProfile.load(AppDelegate.talkURL)
    private var livePieces = 0
    /// Learns names you fix by hand after a dictation.
    private let fixWatch = FixWatch()
    private var liveTyped = 0
    private var liveShown = ""
    private var liveStopped = false
    private var liveLeftover = ""

    /// A stretch Whisper finished while you are still talking. Hands-free, it is typed into the box now (in order,
    /// only into a text box, never in rewrite mode, which needs the whole dictation). Holding the key, Fn or Option
    /// is down and would turn typed letters into shortcuts, so it is shown in the bar and goes in when you let go.
    private func piece(_ text: String, from s: Transcriber.Session) {
        guard session === s else { return }
        livePieces += 1
        liveShown += (liveShown.isEmpty ? "" : " ") + text
        guard config.liveWords ?? true else { return }
        // Typed as you talk, holding the key or hands-free, but only into a text box (D-763). Holding the key needs a
        // box Accessibility names as text; hands-free also takes a box it can't name (Electron apps), as at release.
        let focus = config.mode == "rewrite" ? (kind: FocusKind.notText, role: "") : Insert.focus()
        // Moved away from the box you started in: live typing stops; the rest follows that box at the end.
        if let b = startBox, !liveStopped, !isAt(b) { liveStopped = true; Log.note("live: you moved away from the box, live typing stopped") }
        let canType = keys.handsFree ? focus.kind != .notText : focus.kind == .text
        if canType, !liveStopped, liveTyped == livePieces - 1, waitingText == nil {
            let out = config.mode == "noUms" ? Fillers.strip(names.apply(text)) : names.apply(text)
            // Only "um"s: nothing to type, the piece is done.
            if out.trimmingCharacters(in: .whitespaces).isEmpty { liveTyped += 1; return }
            if Insert.text(out, joining: delivery) { liveTyped += 1; Log.note("live: piece \(livePieces) typed, \(keys.handsFree ? "hands-free" : "holding the key")") }
            else if Insert.typedSome {
                // Part of it went in before the box changed: keep exactly what didn't, for the end, never retype the rest.
                let typed = Insert.typedCount - (Insert.typedPadding)
                let ns = out as NSString
                liveLeftover = typed < ns.length ? ns.substring(from: max(0, typed)) : ""
                liveTyped += 1; liveStopped = true; Log.note("live: piece \(livePieces) typed in part, live typing stopped")
            } else { liveStopped = true; Log.note("live: piece \(livePieces) not typed, the rest goes in at the end") }
        } else {
            hud.caption(liveShown)
        }
    }

    /// Name-like words near the cursor: the box you're in and the window's title. Read once, kept nowhere.
    private func screenWords() -> [String] {
        guard let (el, pid) = Insert.focusedElement() else { return [] }
        var text = Insert.value(el) ?? ""
        var w: CFTypeRef?, t: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &w) == .success, let w,
           AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success, let title = t as? String {
            text = title + "\n" + text
        }
        return Hints.fromScreen(text)
    }

    /// A name fixed the same way twice: it goes into the word list, where you can read it and delete the line.
    private func learn(_ f: Corrections.Fix) {
        var list = Config.loadNames()
        if !list.isEmpty, !list.hasSuffix("\n") { list += "\n" }
        list += "\(f.heard) = \(f.fixed)\n"
        try? list.write(to: Config.namesURL, atomically: true, encoding: .utf8)
        if session == nil { hud.flash("Learned: \(f.fixed)", ok: true, for: 2.5) }
        Log.note("learned a word from your fixes")
    }

    /// The second tap: the bar shows straight away and says hands-free, so you can see it's still listening with no
    /// key held. It stays until you tap again.
    private func handsFreeOn() {
        guard session != nil else { return }
        settleWork?.cancel()
        hud.style = config.levelLook == "off" ? "pen" : config.levelLook; hud.micName = recorder.inputName
        hud.show("", level: true)
        hud.caption("Hands-free · tap \(keys.ownerName ?? keys.keys.first?.name ?? "the key") to stop")
        wasHandsFree = true
    }
    private var wasHandsFree = false

    // MARK: Fast draft, Whisper checks (D-764)

    /// One dictation's drafts: what they typed, in order, so a check replaces exactly that and nothing else. Kept per
    /// dictation, so a dictation still finishing never touches the drafts of a newer one.
    final class Drafting {
        struct Run { var drafts: Range<Int>; var text: String; var checked: Bool }
        let owner: Transcriber.Session
        let startedAt = Date()
        var runs: [Run] = []
        var nextDraft = 0
        var box: (pid: pid_t, element: AXUIElement)?
        var draftsStopped = false, checksStopped = false
        var firstLag: Double?
        var checks = 0, changed = 0, words = 0
        init(owner: Transcriber.Session) { self.owner = owner }
        /// Anything actually typed (empty drafts leave nothing in the box).
        var typedAny: Bool { runs.contains { !$0.text.isEmpty } }
    }
    private var drafting: Drafting?
    /// True when every talk key is a modifier (Fn, Option, Command, Control): its presses never show up as key
    /// presses, so any hardware key press is you typing.
    private var talkKeyIsModifier: Bool { keys.keys.allSatisfy { HoldKey.modifiers[$0.code] != nil } }

    private func clean(_ t: String) -> String {
        let n = names.apply(t)
        return config.mode == "noUms" ? Fillers.strip(n) : n
    }

    /// Still Voice's own typing at the end of the same box: no key or click from you since this dictation began
    /// (read from the keyboard and mouse hardware, so it holds even while Voice is busy typing), same app, same box.
    private func draftSafe(_ d: Drafting) -> Bool {
        guard Self.userQuietSince(d.startedAt, keys: talkKeyIsModifier), userActedAt < d.startedAt, let b = d.box,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == b.pid,
              let (now, _) = Insert.focusedElement(), CFEqual(now, b.element) else { return false }
        return true
    }

    /// No key or click from the hardware since `t` (Voice's own typing is posted, not hardware, so it doesn't count).
    /// `keys`: count hardware key presses too. Off when the talk key is an ordinary key (its own repeats would count).
    nonisolated static func userQuietSince(_ t: Date, keys: Bool = true) -> Bool {
        let since = Date().timeIntervalSince(t)
        let kinds: [CGEventType] = keys ? [.keyDown, .leftMouseDown, .rightMouseDown] : [.leftMouseDown, .rightMouseDown]
        for e in kinds where CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: e) < since {
            return false
        }
        return true
    }

    /// A draft from the fast engine: typed at once if the cursor is in a text box (D-763), in order, never after a
    /// draft that couldn't go in, never over a selection.
    private func draft(_ i: Int, _ text: String, from s: Transcriber.Session) {
        // The current dictation's drafts, or the last ones of the dictation you just let go of (so its record has no gap).
        guard let d = (drafting?.owner === s && session === s ? drafting : finishingDrafting?.owner === s ? finishingDrafting : nil),
              i == d.nextDraft else { return }
        d.nextDraft = i + 1
        let out = clean(text)
        if d.draftsStopped { liveShown += (liveShown.isEmpty ? "" : " ") + out; hud.caption(liveShown); return }
        if out.trimmingCharacters(in: .whitespaces).isEmpty { d.runs.append(.init(drafts: i..<i + 1, text: "", checked: false)); return }
        if d.box == nil {
            // The first words fix where this dictation goes: a text box with a plain cursor (no selected words, which
            // typing would replace), or nowhere until you let go.
            guard Insert.focus().kind == .text, let (el, pid) = Insert.focusedElement(), Insert.selectionLength(el) == 0 else {
                d.draftsStopped = true; liveShown = out; hud.caption(liveShown); return
            }
            d.box = (pid, el)
        }
        guard draftSafe(d) else { d.draftsStopped = true; liveShown = out; hud.caption(liveShown); Log.note("draft: you moved or typed, drafts stopped"); return }
        let started = d.startedAt, keysCount = talkKeyIsModifier
        if Insert.text(out, joining: delivery, while: { AppDelegate.userQuietSince(started, keys: keysCount) }) {
            d.runs.append(.init(drafts: i..<i + 1, text: String(repeating: " ", count: Insert.typedPadding) + out, checked: false))
            if d.firstLag == nil { d.firstLag = Date().timeIntervalSince(s.timeOf(s.speechOnset)) }
        } else {
            d.draftsStopped = true
            if Insert.typedSome { d.checksStopped = true }  // the box no longer matches the record
            Log.note("draft: could not type, drafts stopped")
        }
    }

    /// Whisper's text for drafts `range`. If it isn't exactly what the drafts typed (words, capitals or punctuation),
    /// and the end of the box is still Voice's own typing, the drafts from there on are deleted and typed again with
    /// Whisper's text. Taking effect also after you let go, for the dictation still finishing.
    private func check(_ range: Range<Int>, _ whisper: String, from s: Transcriber.Session) {
        guard let d = (drafting?.owner === s ? drafting : finishingDrafting?.owner === s ? finishingDrafting : nil), !d.checksStopped else { return }
        guard let first = d.runs.firstIndex(where: { $0.drafts.lowerBound == range.lowerBound }),
              let last = d.runs.lastIndex(where: { $0.drafts.upperBound == range.upperBound }), last >= first else {
            if d.typedAny { d.checksStopped = true }
            return
        }
        replace(d, runs: first...last, drafts: range, with: clean(whisper))
    }

    /// Replaces runs `idx` (and retypes any later runs) with Whisper's text, guarded at every step.
    private func replace(_ d: Drafting, runs idx: ClosedRange<Int>, drafts range: Range<Int>, with whisper: String) {
        let covered = d.runs[idx]
        let typed = covered.map(\.text).joined()
        let lead = typed.first == " " ? " " : ""
        let fixed = whisper.trimmingCharacters(in: .whitespaces).isEmpty ? "" : lead + whisper.trimmingCharacters(in: .whitespaces)
        d.checks += 1
        if fixed == typed { d.runs.replaceSubrange(idx, with: [.init(drafts: range, text: typed, checked: true)]); return }
        let n = Corrections.wordsChanged(typed, fixed)
        d.changed += 1; d.words += n
        guard draftSafe(d) else { d.checksStopped = true; Log.note("draft: you moved or typed, the draft stays"); return }
        let later = d.runs[(idx.upperBound + 1)...].map(\.text).joined()
        let started = d.startedAt, keysCount = talkKeyIsModifier
        let quiet: () -> Bool = { AppDelegate.userQuietSince(started, keys: keysCount) }
        let deleted = Insert.backspace((typed + later).count, while: quiet)
        guard deleted == (typed + later).count, (fixed + later).isEmpty || Insert.type(fixed + later, while: quiet) else {
            d.checksStopped = true; Insert.forgetLast()
            Log.note("draft: stopped partway (you typed or clicked); history has the checked text")
            return
        }
        d.runs.replaceSubrange(idx, with: [.init(drafts: range, text: fixed, checked: true)])
        Insert.forgetLast()  // Take back's record no longer matches the box
    }
    /// The dictation whose ending is being written, so its last checks still land after you let go.
    private var finishingDrafting: Drafting?

    /// The ending in draft mode: Whisper's last words replace the drafts not yet checked (if the end of the box is
    /// still Voice's own typing), then one log line with the numbers that say whether this works.
    private func finishDrafts(_ d: Drafting, _ s: Transcriber.Session, released: Date) {
        let tail = clean(s.lastTail)
        if !d.checksStopped, let first = d.runs.firstIndex(where: { !$0.checked }) {
            let lower = d.runs[first].drafts.lowerBound
            replace(d, runs: first...(d.runs.count - 1), drafts: lower..<max(lower + 1, s.draftCount), with: tail)
        } else if !d.checksStopped, !tail.isEmpty, draftSafe(d) {
            _ = Insert.text(tail, joining: delivery)  // words after the last draft
        }
        // A name split across two checks ("claw" | "code") is only fixed in the whole text: if the box still differs
        // from the whole cleaned text, one last replacement makes it exactly that.
        if !d.checksStopped, !d.runs.isEmpty {
            let typed = d.runs.map(\.text).joined()
            let lead = typed.first == " " ? " " : ""
            let whole = lead + clean(s.written.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            if typed != whole, !whole.trimmingCharacters(in: .whitespaces).isEmpty {
                replace(d, runs: 0...(d.runs.count - 1), drafts: d.runs[0].drafts.lowerBound..<max(d.runs[0].drafts.lowerBound + 1, s.draftCount), with: whole)
            }
        }
        let kept = d.checksStopped || d.draftsStopped
        if kept { hud.flash("Part went in as a quick draft. ⌃⌥V pastes the checked version.", for: 3) } else { hud.hide() }
        let lag = d.firstLag.map { "\(Log.ms($0))ms" } ?? "none"
        Log.note("draft: first words \(lag) after you started talking, \(d.runs.count) runs, checks \(d.checks), changed \(d.changed) (\(d.words) words), \(kept ? "draft kept" : "final is Whisper's"), ending typed \(Log.ms(Date().timeIntervalSince(released)))ms after release")
    }

    /// The text box you were in when you started talking. The words go back there, even if you moved to another app
    /// while they were being written ("like Monologue"): straight in if that app allows it, or the moment you are
    /// back in that box. Never into some other box.
    struct StartBox { let pid: pid_t; let element: AXUIElement; let app: String; let window: String?; let print: BoxPrint }
    private var startBox: StartBox?

    private static func windowTitle(_ pid: pid_t) -> String? {
        var w: CFTypeRef?, t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &w) == .success, let w,
              AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return nil }
        return t as? String
    }

    /// A box's fingerprint: role, Accessibility id, place on screen, and (at key-down) the start of its text.
    private static func boxPrint(_ el: AXUIElement, withText: Bool) -> BoxPrint {
        func attr(_ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success ? v : nil }
        var p = CGPoint.zero, sz = CGSize.zero
        var frame: CGRect?
        if let pv = attr(kAXPositionAttribute), let sv = attr(kAXSizeAttribute), CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID(),
           AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &sz) { frame = CGRect(origin: p, size: sz) }
        let prefix = withText ? Insert.value(el).map { String($0.prefix(BoxMatch.prefixLength)) } : nil
        // Where the box is: its window's title and the web page's address when there is one, so a chat app's one
        // reused box in another conversation isn't taken for the same box.
        var title = ""
        if let w = attr(kAXWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success { title = t as? String ?? "" }
        }
        var url = ""
        var node: AXUIElement? = el
        for _ in 0..<40 {
            guard let n = node else { break }
            var r: CFTypeRef?, u: CFTypeRef?, p: CFTypeRef?
            if AXUIElementCopyAttributeValue(n, kAXRoleAttribute as CFString, &r) == .success, (r as? String) == "AXWebArea",
               AXUIElementCopyAttributeValue(n, kAXURLAttribute as CFString, &u) == .success {
                url = (u as? URL)?.absoluteString ?? (u as? String) ?? ""; break
            }
            guard AXUIElementCopyAttributeValue(n, kAXParentAttribute as CFString, &p) == .success, let p, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            node = (p as! AXUIElement)
        }
        let context = title.isEmpty && url.isEmpty ? nil : title + "|" + url
        return BoxPrint(role: attr(kAXRoleAttribute) as? String, identifier: attr(kAXIdentifierAttribute) as? String, frame: frame, prefix: prefix, context: context)
    }

    /// True when the cursor is back in that very box (D-817): the same element, or one that is clearly the same box
    /// (same role and place, or same id), and its text still starts as it did at key-down. Another box in the same
    /// window never counts; a sent and cleared box never counts.
    private func isAt(_ b: StartBox) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == b.pid, let (now, _) = Insert.focusedElement() else { return false }
        return BoxMatch.same(start: b.print, now: Self.boxPrint(now, withText: false), nowText: Insert.value(now), sameElement: CFEqual(now, b.element))
    }

    /// The box you started in still holds what it held at key-down, so writing into it in the background is safe.
    private func unchanged(_ b: StartBox) -> Bool {
        BoxMatch.same(start: b.print, now: Self.boxPrint(b.element, withText: false), nowText: Insert.value(b.element), sameElement: true)
    }

    /// Words waiting for the box you started in.
    private var waitingBox: StartBox?

    private func holdForBox(_ b: StartBox, _ text: String) {
        stopWaiting()
        waitingText = text; waitingBox = b
        hud.flash("Saved for \(b.app). It goes in when you're back in that box, or press ⌃⌥V.", for: 3)
        let until = Date().addingTimeInterval(600)
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWaiting(until: until) }
        }
    }

    /// Words that finished while your cursor wasn't in a text box. They go in when you click into one.
    private var waitingText: String?
    private var waitTimer: Timer?
    private var waitSeen = 0
    private var waitPid: pid_t = 0

    private func holdForClick(_ text: String) {
        stopWaiting()
        waitingText = text
        let until = Date().addingTimeInterval(60)
        hud.show("Click where the words go", level: false)
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWaiting(until: until) }
        }
    }

    private func checkWaiting(until: Date) {
        guard let text = waitingText, session == nil else { return }
        // Voice's own windows (Settings, History) are never where waiting words go.
        if Insert.ownWindowInFront { waitSeen = 0; return }
        if let b = waitingBox {
            if Date() > until { stopWaiting(); Log.note("insert: you didn't go back to the box in 10 minutes, kept for paste"); return }
            guard isAt(b) else {
                // Back in that box, but it was sent or changed: never type into it. Paste last has the words.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == b.pid, let (now, _) = Insert.focusedElement(), CFEqual(now, b.element) {
                    stopWaiting()
                    hud.flash("That box changed since you started. Press ⌃⌥V to paste", for: 3)
                    Log.note("insert: the box you started in changed, kept for paste")
                }
                return
            }
            stopWaiting()
            let ok = Insert.text(text)
            if ok, Insert.unconfirmed { hud.flash("Didn't see it land. Press ⌃⌥V to paste it", for: 3) }
            else { hud.flash(ok ? "Typed where you started" : "Couldn't type it here. Press ⌃⌥V to paste", ok: ok, for: ok ? 1.2 : 2.5) }
            Log.note("insert: back in the box you started in, typed \(ok)")
            return
        }
        if Date() > until {
            stopWaiting()
            hud.flash("Kept it. Press ⌃⌥V to paste", for: 3)
            Log.note("insert: nobody clicked a text box in a minute, kept for paste")
            return
        }
        // Same rule as straight after talking: anything but a page or a control takes the words. A box Accessibility
        // can't name (Electron apps) must look the same twice, so the moment between two apps doesn't count.
        // In a browser only a real text box counts: a failed read on a page must never release the words.
        let focus = Insert.focus()
        let front = NSWorkspace.shared.frontmostApplication
        let browser = FocusGate.browsers.contains(front?.bundleIdentifier ?? "")
        if focus.kind == .notText || (focus.kind == .unknown && browser) { waitSeen = 0; return }
        let pid = front?.processIdentifier ?? 0
        waitSeen = pid == waitPid ? waitSeen + 1 : 1
        waitPid = pid
        guard focus.kind == .text || waitSeen >= 2 else { return }
        stopWaiting()
        let ok = Insert.text(text)
        if ok, Insert.unconfirmed { hud.flash("Didn't see it land. Press ⌃⌥V to paste it", for: 3) }
        else { hud.flash(ok ? "Pasted" : "Couldn't type it here. Press ⌃⌥V to paste", ok: ok, for: ok ? 1.0 : 2.5) }
        Log.note("insert: pasted after a click into \(focus.role), \(ok)")
    }

    private func stopWaiting() {
        waitTimer?.invalidate(); waitTimer = nil
        waitingText = nil; waitSeen = 0; waitingBox = nil
    }

    /// Puts back what this app paused, once. Not while a recording, or another dictation's writing, still holds the
    /// pause; the last one to finish puts it back. It listens first, and if a video or song is already playing (you
    /// pressed play yourself, or the Mac picked another tab), it presses nothing: the play/pause key is a switch, so
    /// a press then would pause that one or start a second video beside it. If it can't listen, it presses nothing
    /// either: a video left paused is better than a surprise.
    /// Puts the video back a second after you finish, not at once: press again within that second and it simply stays
    /// paused. Play at once then pause two seconds later didn't stick on Oct 25 (the video was still starting up).
    private func resumeMedia() {
        guard MediaGate.shouldResume(paused: pausedMedia, recordingAgain: session != nil || writing > 0) else { return }
        if quitting { resumeNow(); return }
        resumeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.resumeNow() }
        resumeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
    private var resumeWork: DispatchWorkItem?

    private func resumeNow() {
        resumeWork = nil
        guard MediaGate.shouldResume(paused: pausedMedia, recordingAgain: session != nil || writing > 0) else { return }
        pausedMedia = false
        // "Play again when I stop talking" off: pause only, so nothing ever starts by itself.
        guard config.resumeMedia ?? true else { Log.note("media: left paused, play again is off"); return }
        // Quitting: no time to listen, the app is about to go.
        if quitting { Media.pressPlayPause(); Log.note("media: resumed on quit"); return }
        let players = Media.playingApps()
        guard !players.isEmpty else { Media.pressPlayPause(); Log.note("media: resumed"); return }
        SoundTap.loudness(of: players.map(\.object), for: 0.2) { peak in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let playing = MediaGate.isPlaying(peak: peak)
                if self.session != nil || self.writing > 0 {
                    // A new press started while this listened: it takes the pause over and puts it back later.
                    if !playing { self.pausedMedia = true }
                    Log.note("media: new press while resuming, \(playing ? "already playing" : "still paused")")
                } else if peak == nil {
                    Log.note("media: not resumed, couldn't listen to [\(players.map(\.name).joined(separator: ", "))]")
                } else if MediaGate.shouldResume(paused: true, playingNow: playing) {
                    Media.pressPlayPause()
                    Log.note("media: resumed")
                } else {
                    Log.note("media: not resumed, already playing in [\(players.map(\.name).joined(separator: ", "))]")
                }
            }
        }
    }

    private func end() {
        guard let s = session else { return }
        session = nil
        let seconds = Date().timeIntervalSince(startedAt)
        settleWork?.cancel()
        hud.writing()
        if config.sounds { NSSound(named: "Tink")?.play() }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let owner = press
        let gen = delivery
        let typedLive = liveTyped  // pieces already typed while you talked; only the rest goes in now
        let myDrafting = drafting
        finishingDrafting = myDrafting
        let box = startBox
        let leftover = liveLeftover
        writing += 1
        let releasedAt = Date()
        let handsFree = wasHandsFree
        wasHandsFree = false
        Task { [weak self] in
            guard let self else { return }
            // More audio after the key comes up, for a last syllable still in the air: half a second, or a tenth
            // when you had already gone quiet (Whisper), which saves most of that wait on every dictation.
            try? await Task.sleep(for: .milliseconds(s.endedQuiet ? 100 : 500))
            // A new press that started in that half second owns the mic now. Stopping it here cut its recording off.
            if self.micOwner == owner {
                Log.note("audio: \(self.recorder.pushedFrames) frames (\(String(format: "%.1f", Double(self.recorder.pushedFrames) / 16000))s), peak \(String(format: "%.3f", self.recorder.peak))")
                self.recorder.end()
            } else {
                Log.note("audio: a new press started, its recording kept going")
            }
            var raw = ""
            let f0 = Date()
            do { raw = try await s.finish() } catch { Log.note("finish failed: \(error.localizedDescription)") }
            let engineMs = Log.ms(Date().timeIntervalSince(f0))
            let t0 = Date()
            raw = self.names.apply(raw)
            var cleaned: String? = nil
            if self.config.mode == "rewrite", !raw.isEmpty { cleaned = await Cleanup.run(raw) }
            if self.config.mode == "noUms", !raw.isEmpty { let s = Fillers.strip(raw); if s != raw { cleaned = s } }
            let text = cleaned ?? raw
            // What still has to go in: everything, or only the pieces not already typed while you talked.
            var rest = text
            if typedLive > 0 {
                let r = self.names.apply(s.written.dropFirst(typedLive).joined(separator: " "))
                let more = self.config.mode == "noUms" ? Fillers.strip(r) : r
                rest = [leftover, more].filter { !$0.isEmpty }.joined(separator: leftover.hasSuffix(" ") ? "" : " ")
            }
            var inserted = false
            // Fast draft, Whisper checks: the drafts are already in the box; Whisper's ending replaces the last ones.
            let draftHandled = myDrafting?.typedAny == true
            if let d = myDrafting, draftHandled { self.finishDrafts(d, s, released: releasedAt); inserted = true }
            if self.finishingDrafting === myDrafting { self.finishingDrafting = nil }
            if draftHandled {}
            else if text.isEmpty, self.delivery != gen { Log.note("no words, a new press began") }
            else if text.isEmpty { self.hud.flash(self.recorder.peak < 0.005 ? "No sound from \(self.recorder.inputName)" : "Didn't catch that", for: 2.5) }
            else if self.firstRun?.isOpen == true, Insert.ownWindowInFront {
                // Said into the first window: the practice sentence goes straight into it.
                self.firstRun?.practiced(text); inserted = true; self.hud.hide()
                Log.note("first run: practice sentence, \(text.split(separator: " ").count) words")
            }
            else if s.echoFailed {
                // A video was playing and its words couldn't be written down to take them off: nothing is typed.
                self.hud.flash("A video was playing and its words couldn't be checked. Press ⌃⌥V to paste", for: 3.5)
                Log.note("media: the video's words couldn't be written down, kept for paste")
            }
            else {
                // The words go where your cursor is now, whichever app that is. If it isn't in a text box (a web page,
                // a video, a list), nothing is typed there: the words wait for you to click into one.
                let focus = Insert.focus()
                let newer = self.delivery != gen  // you pressed again while these words were being written
                if let b = box, !rest.isEmpty, !self.isAt(b) {
                    // You moved away while the words were written: they go back to the box you started in. When a
                    // newer dictation has started they never go anywhere else: Paste last has them.
                    if newer { Log.note("insert: away from the box you started in and a new press began, kept for paste") }
                    else if self.unchanged(b), Insert.textInto(b.element, rest) {
                        inserted = true
                        self.hud.flash("Typed into \(b.app), where you started", ok: true, for: 1.5)
                        Log.note("insert: typed into the box you started in, without bringing it forward")
                    } else {
                        Log.note("insert: you moved away; words wait for the box you started in")
                        self.holdForBox(b, rest)
                    }
                } else if focus.kind == .notText {
                    if newer { Log.note("insert: cursor not in a text box (\(focus.role)) and a new press began, kept for paste") }
                    else if !rest.isEmpty { Log.note("insert: cursor not in a text box (\(focus.role)), waiting for a click"); self.holdForClick(rest) }
                } else {
                    inserted = rest.isEmpty ? true : Insert.text(rest, joining: typedLive > 0 ? gen : nil)
                    if inserted, !newer { self.fixWatch.watch(text) }
                    if inserted, !newer, draftHandled == false, !s.hadMedia { self.pointOutWords(text, audio: s.recorded, gen: gen) }
                    if !newer {
                        if inserted, Insert.unconfirmed { self.hud.flash("Didn't see it land. Press ⌃⌥V to paste it", for: 3) }
                        else if inserted { if handsFree { self.hud.flash("Hands-free done", ok: true) } else { self.hud.hide() } }
                        else { self.hud.flash("Couldn't type it here. Press ⌃⌥V to paste", for: 2.5) }
                    }
                    Log.note("insert: focus \(focus.role), \(focus.kind.rawValue)")
                }
            }
            if typedLive > 0 { Log.note("live: \(typedLive) of \(s.written.count) pieces typed while talking") }
            if s.endingLost { self.hud.flash("The last few words didn't come through. Say them again.", for: 3.5) }
            if !raw.isEmpty, ["whisper", "parakeet", "live"].contains(self.config.engine) {
                self.talk.add(s.recorded, words: raw.split(separator: " ").count)
                self.talk.save(AppDelegate.talkURL)
            }
            // A press that caught no words (a stray tap, a shortcut) leaves no history entry: 163 of 553 were empty.
            if !text.isEmpty {
                let entry = Entry(raw: raw, cleaned: cleaned, seconds: seconds, app: app, inserted: inserted)
                self.lastSaid = entry
                // How long it's kept is your choice (D-825): nothing at all, the last week, or the newest 2,000.
                // The day's numbers are counted whatever is kept (D-837).
                Dictations.record(entry, keep: self.config.historyKeep ?? "all", history: self.history, stats: self.stats, engine: self.config.engine)
            }
            self.writing -= 1
            self.resumeMedia()
            Log.note("dictation \(Log.int(seconds))s, \(raw.split(separator: " ").count) words, write \(Log.ms(Date().timeIntervalSince(t0)))ms, engine \(engineMs)ms, key up to done \(Log.ms(Date().timeIntervalSince(releasedAt)))ms, into \(app), inserted \(inserted)")
            self.refreshMenu()
            if self.quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    // MARK: Menu

    /// Light, dark, or the Mac's own setting, for every window and the menu bar panel. The talking bar stays dark.
    static func applyAppearance(_ c: Config) {
        NSApp.appearance = c.appearance.map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) } ?? nil
    }

    private func setUpPanel() {
        Ink.registerFonts()
        panel.behavior = .transient
        panel.animates = false
        let host = NSHostingController(rootView: MenuPanel(model: menu))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        menu.setMode = { [weak self] m in self?.setMode(m) }
        menu.paste = { [weak self] in self?.fromPanel { $0.pasteLastNow() } }
        menu.history = { [weak self] in self?.panel.close(); self?.openHistory() }
        menu.stats = { [weak self] in self?.panel.close(); self?.openStats() }
        menu.takeBack = { [weak self] in self?.fromPanel { $0.takeBack() } }
        menu.show = { [weak self] in self?.panel.close(); self?.showLast() }
        menu.file = { [weak self] in self?.panel.close(); self?.transcribeAFile() }
        menu.test = { [weak self] in self?.panel.close(); self?.toggleTestRecording() }
        menu.words = { [weak self] in self?.panel.close(); self?.editNames() }
        menu.settings = { [weak self] in self?.panel.close(); self?.openSettings() }
        menu.updates = { [weak self] in self?.panel.close(); Updates.shared.checkNow() }
        refreshMenu()
    }

    @objc private func togglePanel() {
        if panel.isShown { panel.close(); return }
        guard let button = status.button else { return }
        let front = NSWorkspace.shared.frontmostApplication
        panelOrigin = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? panelOrigin : front
        refreshMenu()
        // Sized to its content before it opens, so the top is never cut off.
        if let v = panel.contentViewController?.view { v.layoutSubtreeIfNeeded(); panel.contentSize = v.fittingSize }
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.contentViewController?.view.window?.makeKey()
    }

    /// Closes the panel, hands focus back to the app you were in, then acts there.
    private func fromPanel(_ act: @escaping (AppDelegate) -> Void) {
        panel.close()
        panelOrigin?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if let self { act(self) } }
    }

    private func refreshMenu() {
        menu.state = menuState()
        if let m = statsWindow?.model { m.typing = config.typingSpeed; m.reload() }
    }

    private func menuState() -> MenuState {
        var m = MenuState()
        switch engine.state {
        case .ready: m.ready = true; m.status = "Ready"
        case .checking: m.status = "Getting ready"
        case .downloading(let p): m.status = "Downloading \(p)%"
        case .unsupported: m.status = "Not available"
        case .failed: m.status = "Engine failed"
        }
        m.engine = ["whisper": "Most accurate (Whisper)", "parakeet": "Fast", "live": "Instant"][config.engine] ?? "Mac built-in"
        m.mic = recorder.inputName
        m.update = Updates.shared.waiting
        let fnTalks = config.talkKeyChoice == "fn" || config.talkKeyChoice == "fnOrOption"
        m.warning = fnTalks ? FnKey.problem.map { "\($0). Set “Press 🌐 key to” to Do Nothing in Keyboard settings." } : nil
        m.talk = talk.summary ?? (talk.dictations > 0 ? "Learning how you talk: \(min(talk.dictations, TalkProfile.learnAfter)) of \(TalkProfile.learnAfter) dictations" : "")
        m.keyLine = "Hold \(keyNames) to talk." + ((config.doubleTap ?? true) ? " Tap twice to keep talking." : "")
        let all = history.all()
        let today = Stats.today(stats.days, typing: config.typingSpeed), total = Stats.score(stats.days, typing: config.typingSpeed)
        m.todayWords = today.words; m.todayWPM = today.wordsPerMinute; m.todaySaved = today.minutesSaved
        m.totalWords = total.words; m.totalSaved = total.minutesSaved
        m.mode = config.mode
        m.last = (all.last ?? lastSaid).map(\.text)
        m.canTakeBack = Insert.last != nil
        m.testing = testFile != nil
        return m
    }

    private var keyNames: String {
        HoldKey.keys(for: config.talkKeyChoice).map(\.name).joined(separator: " or ")
    }

    private func setMode(_ mode: String) {
        config.mode = mode
        config.save(); settings?.model.config = config; refreshMenu()
    }

    /// Control-Option-V: the last dictation again, at the cursor.
    private func pasteLastNow() {
        guard session == nil, let e = history.lastSpoken() ?? lastSaid else { hud.flash("Nothing to paste yet"); return }
        stopWaiting()
        delivery += 1  // a dictation still being written won't start its own wait after this
        // Never type into a page or a video: there, letters are shortcuts.
        let focus = Insert.focus()
        guard focus.kind != .notText else {
            hud.flash("Click into a text box, then press ⌃⌥V", for: 2.5)
            Log.note("paste last: cursor not in a text box (\(focus.role))")
            return
        }
        // The backup route: a paste that puts your clipboard back, so it works where typing just failed (D-825).
        if Insert.pasteBusy { hud.flash("Still pasting. Press ⌃⌥V again in a second", for: 2); return }
        let ok = Insert.paste(e.text)
        hud.flash(ok ? "Pasted" : "Could not paste", ok: ok)
        Log.note("paste last: \(ok)")
    }

    /// Point out words to check (D-817 test): a second engine hears the same audio after the words went in, so nothing
    /// waits. Only a "not", a number, a name or the first or last three words, heard differently, is shown.
    private func pointOutWords(_ text: String, audio: [Float], gen: Int) {
        riskSwap = nil
        guard config.engine == "whisper", config.riskMarks == true, let (element, _) = Insert.focusedElement(), let typed = Insert.last?.text else { return }
        Task { [weak self] in
            guard let self, let other = await self.engine.otherHearing(audio) else { return }
            // A newer dictation since: this one's check is dropped, so it can't mark or count the new one.
            guard self.delivery == gen, self.session == nil else { return }
            let marks = RiskyWords.find(final: text, other: self.names.apply(other), names: Set(self.names.spellings))
            self.fixWatch.marked = Set(marks.flatMap { $0.heard.lowercased().split(separator: " ").map(String.init) })
            guard let m = marks.first else { Log.note("risk: nothing to check"); return }
            self.riskSwap = (m.swapped, gen, element, typed)
            self.hud.flash("Check “\(m.heard)”, also heard “\(m.other)”. ⌃⌥S swaps", for: 4)
            Log.note("risk: \(marks.count) to check (\(marks.map(\.kind).joined(separator: ", ")))")
        }
    }

    /// ⌃⌥S: the last dictation out, the other hearing in, only while it is still the last thing typed.
    private func swapRisky() {
        guard session == nil, let r = riskSwap, r.gen == delivery else { hud.flash("Nothing to swap"); return }
        // Only in the very box, and only when it can be read and still ends with what went in: never a blind delete.
        let typed = r.typed.trimmingCharacters(in: .whitespaces)
        guard let (now, _) = Insert.focusedElement(), CFEqual(now, r.element), let v = Insert.value(now),
              v.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(typed) else {
            hud.flash("Can't swap here. Press ⌃⌥Z, then ⌃⌥V", for: 2.5); Log.note("risk swap: box changed, not swapped"); return
        }
        riskSwap = nil
        if let why = Insert.undoLast() { hud.flash(why, for: 2.5); Log.note("risk swap: \(why)"); return }
        let ok = Insert.text(r.swapped)
        hud.flash(ok ? "Swapped" : "Couldn't type it. Press ⌃⌥V to paste", ok: ok, for: ok ? 1.0 : 2.5)
        Log.note("risk swap: \(ok)")
    }

    private func updateSwapKey() {
        if config.riskMarks == true, config.engine == "whisper" {
            if swapKey == nil { swapKey = Shortcut(id: 3, keyCode: kVK_ANSI_S, name: "Control-Option-S") { [weak self] in self?.swapRisky() } }
        } else { swapKey = nil }
    }

    /// Control-Option-Z: takes the last dictation back out, only when it is provably still the last thing typed.
    @objc private func takeBack() {
        guard session == nil else { return }
        let why = Insert.undoLast()
        hud.flash(why ?? "Taken back", ok: why == nil, for: why == nil ? 1.0 : 2.5)
        Log.note("take back: \(why ?? "done")")
    }

    /// Any audio or video file to text, saved beside the file and opened. Same engine, same raw words.
    @objc private func transcribeAFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = "Pick a recording to turn into text"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        hud.show("Transcribing…", level: false)
        Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await FileAudio.readable(url)
                let text = self.names.apply(try await self.engine.transcribeFile(audio, config: self.config))
                let name = url.deletingPathExtension().lastPathComponent + " transcript.txt"
                var out = url.deletingLastPathComponent().appendingPathComponent(name)
                if !FileManager.default.isWritableFile(atPath: out.deletingLastPathComponent().path) {
                    out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(name)
                }
                try text.write(to: out, atomically: true, encoding: .utf8)
                if audio != url { try? FileManager.default.removeItem(at: audio) }
                self.hud.flash("Saved \(text.split(separator: " ").count) words", ok: true, for: 2)
                NSWorkspace.shared.open(out)
                Log.note("file transcribed: \(text.split(separator: " ").count) words")
            } catch {
                self.hud.flash("Could not read that file", for: 2.5)
                Log.note("file transcribe failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func showLast() {
        guard let e = history.lastSpoken() ?? lastSaid else { return }
        let a = NSAlert()
        a.messageText = "Last dictation"
        a.informativeText = (e.cleaned.map { "Rewrite:\n\($0)\n\nRaw:\n" } ?? "") + e.raw
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: Test recording

    private var testFile: AVAudioFile?
    private var testFrames: AVAudioFrameCount = 0
    private var testStop: DispatchWorkItem?

    /// Records up to ten minutes from the same mic, same channel choice, to a file on the Desktop, for scoring the
    /// engines against each other on real talking. Stops itself at ten minutes or from the menu.
    @objc private func toggleTestRecording() {
        if testFile != nil { endTestRecording(); return }
        guard let format = engine.audioFormat, !recorder.inputName.isEmpty else { hud.flash("Mic not ready"); return }
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f.string(from: Date()) }()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/redpen-voice-test-\(stamp).wav")
        do { testFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved) }
        catch { Log.note("test: cannot create file \(error.localizedDescription)"); hud.flash("Could not create the file"); return }
        testFrames = 0
        recorder.begin(onBuffer: { [weak self] buf in
            guard let self, let f = self.testFile else { return }
            try? f.write(from: buf)
            self.testFrames += buf.frameLength
            let secs = Int(Double(self.testFrames) / format.sampleRate)
            if secs % 5 == 0 { DispatchQueue.main.async { self.hud.show("Test \(secs / 60):\(String(format: "%02d", secs % 60))", level: true) } }
        }, onLevel: { [weak self] v in DispatchQueue.main.async { self?.hud.level(v) } })
        hud.show("Test 0:00", level: true)
        let w = DispatchWorkItem { [weak self] in self?.endTestRecording() }
        testStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: w)
        Log.note("test: recording to \(url.lastPathComponent) from \(recorder.inputName)")
        refreshMenu()
    }

    private func endTestRecording() {
        testStop?.cancel()
        recorder.end()
        let secs = Int(Double(testFrames) / (engine.audioFormat?.sampleRate ?? 16000))
        let name = testFile?.url.lastPathComponent ?? ""
        testFile = nil
        hud.flash("Saved \(secs / 60):\(String(format: "%02d", secs % 60)) to the Desktop", ok: true, for: 3)
        Log.note("test: saved \(name), \(secs)s")
        refreshMenu()
    }

    @objc private func editNames() { Config.ensureNamesFile(); NSWorkspace.shared.open(Config.namesURL) }

    /// The history window (D-825), made once and kept.
    private func openHistory() {
        if historyWindow == nil {
            let m = HistoryModel(history: history, keep: config.historyKeep ?? "all")
            m.onKeep = { [weak self] k in
                guard let self else { return }
                var c = Config.load(); c.historyKeep = k; c.save(); self.config.historyKeep = k; self.syncSettings()
                self.history.apply(keep: k)
                Log.note("history: keep \(k)")
                self.refreshMenu()
            }
            historyWindow = HistoryWindow(model: m)
        }
        historyWindow?.show()
    }

    /// The Stats window (D-837), made once and kept.
    private func openStats() {
        if statsWindow == nil {
            let m = StatsModel(typing: config.typingSpeed) { [weak self] in self?.stats.days ?? [] }
            m.onReset = { [weak self] in
                let ok = self?.stats.reset() ?? false
                Log.note(ok ? "stats: reset" : "stats: reset failed, stats.json couldn't be written")
                self?.refreshMenu()
            }
            m.openSettings = { [weak self] in self?.openSettings() }
            statsWindow = StatsWindow(model: m)
        }
        statsWindow?.model.typing = config.typingSpeed
        statsWindow?.show()
    }

    /// Settings keeps its own copy and saves all of it on any change: give it the saved file as it is now, so a change
    /// made in the first window or the history window is never written back over.
    private func syncSettings() { settings?.model.config = Config.load() }

    @objc private func openSettings() {
        syncSettings()
        if settings == nil {
            config = Config.load()  // the saved file as it is now, with any change made in the first window
            let model = SettingsModel(config: config, engine: engine) { [weak self] c in
                guard let self else { return }
                let engineChanged = c.engine != self.config.engine || c.locale != self.config.locale || c.draftMode != self.config.draftMode || c.riskMarks != self.config.riskMarks
                let micChanged = c.inputDevice != self.config.inputDevice
                self.config = c
                Self.applyAppearance(c)
                if micChanged { self.recorder.deviceUID = c.inputDevice; self.warmMic() }
                self.keys.keys = HoldKey.keys(for: c.talkKeyChoice); self.keys.doubleTap = c.doubleTap ?? true
                if engineChanged { Task { await self.engine.prepare(c) } }
                self.updateSwapKey()
                self.refreshMenu()
            }
            model.recordTest = { [weak self] in self?.toggleTestRecording() }
            model.back = { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.togglePanel() } }
            model.showHistory = { [weak self] in self?.openHistory() }
            model.statsTotal = { [weak self] in let s = Stats.score(self?.stats.days ?? []); return (s.words, s.seconds) }
            settings = SettingsWindow(model: model)
        }
        settings?.show()
    }
}

// Watchdog mode: a small copy that reopens the app if it crashes. Runs before any window or menu exists.
if let i = CommandLine.arguments.firstIndex(of: "--watchdog"), i + 1 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) {
    Watchdog.run(parent: pid)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

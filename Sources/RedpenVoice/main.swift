import AppKit
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
    private var settings: SettingsWindow?
    private var session: Transcriber.Session?
    private var startedAt = Date()
    private var pausedMedia = false
    private var settleWork: DispatchWorkItem?
    private var busy = false
    private var press = 0
    private var pasteKey: Shortcut?
    private var undoKey: Shortcut?
    private var typingWatch: Any?
    private var names = Names(text: "")
    private let menu = MenuModel()
    private let panel = NSPopover()
    /// The app you were in when the panel opened, so Paste and Take back land there.
    private var panelOrigin: NSRunningApplication?

    func applicationDidFinishLaunching(_ n: Notification) {
        // `--hud-demo [style]` shows the talking bar for four seconds with a fake voice, then two of writing, so its
        // look can be checked on screen.
        if let i = CommandLine.arguments.firstIndex(of: "--hud-demo") {
            if i + 1 < CommandLine.arguments.count { hud.style = CommandLine.arguments[i + 1] }
            hud.show("", level: true)
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [hud] _ in
                t += 0.05
                MainActor.assumeIsolated {
                    if t < 4 { hud.level(Float(0.45 + 0.35 * sin(t * 9) * sin(t * 2.3))) } else if t < 4.06 { hud.writing() }
                }
                if t > 6 { exit(0) }
            }
            return
        }
        // `--hud-message "text" [ok]` shows a message in the talking bar for three seconds, so its look can be checked.
        if let i = CommandLine.arguments.firstIndex(of: "--hud-message"), i + 1 < CommandLine.arguments.count {
            hud.flash(CommandLine.arguments[i + 1], ok: CommandLine.arguments.contains("ok"), for: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { exit(0) }
            return
        }
        Config.ensureNamesFile()
        history.trim()
        names = Names(text: Config.loadNames())
        engine.onState = { [weak self] s in
            self?.refreshMenu()
            self?.firstRun?.refresh()
            self?.settings?.model.engineState = s
            if s == .ready { self?.warmMic() }
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
            let v = NSHostingView(rootView: SettingsView(model: SettingsModel(config: config, engine: engine) { _ in }))
            v.frame = NSRect(x: 0, y: 0, width: 540, height: 2000)
            let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v; v.layoutSubtreeIfNeeded(); v.display()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
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
            let v = NSHostingView(rootView: MenuPanel(model: menu))
            v.frame = NSRect(origin: .zero, size: v.fittingSize)
            let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v; v.layoutSubtreeIfNeeded(); v.display()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
                exit(0)
            }
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
        keys.onDown = { [weak self] in self?.begin() }
        keys.onUp = { [weak self] in self?.end() }
        keys.onCancel = { [weak self] in self?.cancel() }
        keys.start()
        pasteKey = Shortcut(id: 1, keyCode: kVK_ANSI_V, name: "Control-Option-V") { [weak self] in self?.pasteLastNow() }
        undoKey = Shortcut(id: 2, keyCode: kVK_ANSI_Z, name: "Control-Option-Z") { [weak self] in self?.takeBack() }
        // Any key you type yourself after a dictation means take-back must not guess. Our own typing is skipped.
        let me = Int64(ProcessInfo.processInfo.processIdentifier)
        typingWatch = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            if e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != me { MainActor.assumeIsolated { Insert.typedSince = true } }
        }
        if !config.firstRunDone || !AXIsProcessTrusted() {
            let w = FirstRunWindow(config: config, engineState: { [weak self] in self?.engineWord ?? "" })
            w.onDone = { [weak self] in guard let self else { return }; self.config = Config.load(); self.refreshMenu(); self.warmMic() }
            firstRun = w
            w.show()
        }
        Log.note("launched")
    }

    /// Quit asked while you are talking: finish the dictation and write the words first, then go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session != nil else {
            // Words still being written are dropped on quit; the video they paused is put back.
            if pausedMedia { pausedMedia = false; Media.pressPlayPause(); Log.note("media: resumed on quit") }
            return .terminateNow
        }
        Log.note("quit asked mid-dictation, finishing first")
        quitting = true
        end()
        return .terminateLater
    }
    private var quitting = false
    /// Dictations whose words are still being written. The pause is held until the last one is done.
    private var writing = 0

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
        guard engine.state == .ready, let format = engine.audioFormat else { hud.flash(engineWord == "ready" ? "Not ready" : "Engine " + engineWord); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { hud.flash("Allow the microphone"); return }
        remicIfDefaultMoved(reason: "input moved before this press")
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
        let players = config.pauseMedia && !pausedMedia ? Media.playingApps() : []
        if pausedMedia {
            Log.note("media: still paused from the last press")
        } else if !players.isEmpty {
            SoundTap.loudness(of: players.map(\.object), for: 0.25) { peak in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.press == thisPress, self.session != nil, !self.pausedMedia else { return }
                    let playing = MediaGate.isPlaying(peak: peak)
                    if playing { self.pausedMedia = true; Media.pressPlayPause() }
                    Log.note("media: apps [\(players.map(\.name).joined(separator: ", "))], loudness \(peak.map { String(format: "%.4f", $0) } ?? "no tap"), paused \(playing)")
                }
            }
        } else {
            Log.note("media: no app playing")
        }
        settleWork?.cancel(); settleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: settle)
        let (s, module) = engine.session(config)
        session = s
        startedAt = Date()
        startedIn = NSWorkspace.shared.frontmostApplication
        names = Names(text: Config.loadNames())
        if config.sounds { NSSound(named: "Pop")?.play() }
        if recorder.inputName.isEmpty {
            do { try recorder.start(format: format) } catch {
                Log.note("mic failed: \(error.localizedDescription)"); hud.flash("No microphone"); session = nil; busy = false; return
            }
        }
        // The engine is listening before the pre-roll arrives, so nothing waits in a queue.
        s.start(module: module, vocabulary: names.vocabulary)
        recorder.begin(onBuffer: { buf in s.push(buf) },
                       onLevel: { [weak self] v in DispatchQueue.main.async { self?.hud.level(v) } })
        Log.note("recording from \(recorder.inputName)")
        busy = false
    }

    /// Fn was a shortcut, not talking: drop the audio, put the music back, no words written.
    private func cancel() {
        guard let s = session else { return }
        session = nil
        settleWork?.cancel()
        recorder.end()
        s.cancel()
        hud.hide()
        resumeMedia()
        Log.note("cancelled: another key while holding")
    }

    private var startedIn: NSRunningApplication?

    /// Puts back what this app paused, once. Not while a recording, or another dictation's writing, still holds the
    /// pause; the last one to finish puts it back. It listens first, and if a video or song is already playing (you
    /// pressed play yourself, or the Mac picked another tab), it presses nothing: the play/pause key is a switch, so
    /// a press then would pause that one or start a second video beside it. If it can't listen, it presses nothing
    /// either: a video left paused is better than a surprise.
    private func resumeMedia() {
        guard MediaGate.shouldResume(paused: pausedMedia, recordingAgain: session != nil || writing > 0) else { return }
        pausedMedia = false
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
        writing += 1
        Task { [weak self] in
            guard let self else { return }
            // Half a second more after the key comes up: the last syllable is usually still in the air.
            try? await Task.sleep(for: .milliseconds(500))
            Log.note("audio: \(self.recorder.pushedFrames) frames (\(String(format: "%.1f", Double(self.recorder.pushedFrames) / 16000))s), peak \(String(format: "%.3f", self.recorder.peak))")
            self.recorder.end()
            var raw = ""
            do { raw = try await s.finish() } catch { Log.note("finish failed: \(error.localizedDescription)") }
            let t0 = Date()
            raw = self.names.apply(raw)
            var cleaned: String? = nil
            if self.config.mode == "rewrite", !raw.isEmpty { cleaned = await Cleanup.run(raw) }
            if self.config.mode == "noUms", !raw.isEmpty { let s = Fillers.strip(raw); if s != raw { cleaned = s } }
            let text = cleaned ?? raw
            var inserted = false
            if text.isEmpty { self.hud.flash(self.recorder.peak < 0.005 ? "No sound from \(self.recorder.inputName)" : "Didn't catch that", for: 2.5) }
            else {
                // The words go to the app you started in. If you switched, it is brought back first.
                if let origin = self.startedIn, NSWorkspace.shared.frontmostApplication?.processIdentifier != origin.processIdentifier {
                    origin.activate()
                    try? await Task.sleep(for: .milliseconds(350))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != origin.processIdentifier {
                        Log.note("insert: could not return to \(origin.localizedName ?? "?"), kept in history")
                        self.hud.flash("You switched apps. Press ⌃⌥V to paste", for: 2.5)
                        self.history.append(Entry(raw: raw, cleaned: cleaned, seconds: seconds, app: app, inserted: false))
                        self.writing -= 1
                        self.resumeMedia()
                        return
                    }
                }
                inserted = Insert.text(text)
                if inserted { self.hud.hide() }
                if !inserted { self.hud.flash("Couldn't type it here. Press ⌃⌥V to paste", for: 2.5) }
            }
            self.history.append(Entry(raw: raw, cleaned: cleaned, seconds: seconds, app: app, inserted: inserted))
            self.writing -= 1
            self.resumeMedia()
            Log.note("dictation \(Int(seconds))s, \(raw.split(separator: " ").count) words, write \(Int(Date().timeIntervalSince(t0) * 1000))ms, into \(app), inserted \(inserted)")
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
        menu.takeBack = { [weak self] in self?.fromPanel { $0.takeBack() } }
        menu.show = { [weak self] in self?.panel.close(); self?.showLast() }
        menu.file = { [weak self] in self?.panel.close(); self?.transcribeAFile() }
        menu.test = { [weak self] in self?.panel.close(); self?.toggleTestRecording() }
        menu.words = { [weak self] in self?.panel.close(); self?.editNames() }
        menu.settings = { [weak self] in self?.panel.close(); self?.openSettings() }
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

    private func refreshMenu() { menu.state = menuState() }

    private func menuState() -> MenuState {
        var m = MenuState()
        switch engine.state {
        case .ready: m.ready = true; m.status = "Ready"
        case .checking: m.status = "Getting ready"
        case .downloading(let p): m.status = "Downloading \(p)%"
        case .unsupported: m.status = "Not available"
        case .failed: m.status = "Engine failed"
        }
        m.engine = config.engine == "whisper" ? "Whisper" : "Mac built-in"
        m.mic = recorder.inputName
        m.keyLine = "Hold \(keyNames) to talk." + ((config.doubleTap ?? true) ? " Tap twice to keep talking." : "")
        let all = history.all()
        let today = Score.today(all), total = Score(all)
        m.todayWords = today.words; m.todayWPM = today.wordsPerMinute; m.todaySaved = today.minutesSaved
        m.totalWords = total.words; m.totalSaved = total.minutesSaved
        m.mode = config.mode
        m.last = all.last.map(\.text)
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
        guard session == nil, let e = history.last() else { hud.flash("Nothing to paste yet"); return }
        let ok = Insert.text(e.text)
        hud.flash(ok ? "Pasted" : "Could not paste", ok: ok)
        Log.note("paste last: \(ok)")
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
        guard let e = history.last() else { return }
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

    @objc private func openSettings() {
        if settings == nil {
            let model = SettingsModel(config: config, engine: engine) { [weak self] c in
                guard let self else { return }
                let engineChanged = c.engine != self.config.engine || c.locale != self.config.locale
                let micChanged = c.inputDevice != self.config.inputDevice
                self.config = c
                Self.applyAppearance(c)
                if micChanged { self.recorder.deviceUID = c.inputDevice; self.warmMic() }
                self.keys.keys = HoldKey.keys(for: c.talkKeyChoice); self.keys.doubleTap = c.doubleTap ?? true
                if engineChanged { Task { await self.engine.prepare(c) } }
                self.refreshMenu()
            }
            model.recordTest = { [weak self] in self?.toggleTestRecording() }
            model.back = { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.togglePanel() } }
            settings = SettingsWindow(model: model)
        }
        settings?.show()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

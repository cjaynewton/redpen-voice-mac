import AppKit
import SwiftUI
import AVFoundation

/// What the first window needs from the app: the engine's state, the microphone, the talk key, and a way back in when
/// something is stuck.
@MainActor
struct FirstRunHost {
    var engineState: () -> String
    var micName: () -> String
    /// Starts reading the microphone's level for the window (the app warms the mic if it isn't on yet).
    var watchLevel: (@escaping (Float) -> Void) -> Void
    var stopLevel: () -> Void
    var setMic: (String) -> Void
    var setTalkKey: (String) -> Void
    /// Accessibility just arrived: the key watchers are set up again so the talk key works without a restart.
    var restartKeys: () -> Void
    var relaunch: () -> Void
    var openSettings: () -> Void
}

/// The first window (D-825): one screen that proves it works before you leave it. It asks how your words should come
/// out, sets up the microphone (with its level, so a silent or wrong mic shows now), Accessibility, the Fn key and the
/// engine, then has you say one sentence and shows it. Done waits until all of that is true.
@MainActor
final class FirstRunWindow {
    private var window: NSWindow?
    private let model: FirstRunModel
    var onDone: () -> Void = {}

    init(config: Config, host: FirstRunHost) {
        model = FirstRunModel(config: config, host: host)
    }

    /// True while the window is open: a dictation said into it is the practice sentence.
    var isOpen: Bool { window?.isVisible == true }

    func show() {
        Ink.registerFonts()
        model.onDone = { [weak self] in self?.close(); self?.onDone() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Redpen Voice"
        w.contentView = NSHostingView(rootView: FirstRunView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { model.stop(); window?.close() }
    func refresh() { model.tick() }
    /// The talk key went down while the window was open: the key works.
    func keySeen() { model.keySeen = true }
    /// Words said while the window was in front: the practice sentence.
    func practiced(_ text: String) { model.practice = text; model.practiced = !text.isEmpty }
}

@MainActor
final class FirstRunModel: ObservableObject {
    @Published var config: Config
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var access = AXIsProcessTrusted()
    @Published var fnProblem = FnKey.problem
    @Published var engine = ""
    @Published var level: Float = 0
    @Published var micName = ""
    /// Seconds the microphone has been on without hearing anything louder than a quiet room.
    @Published var silentFor = 0.0
    @Published var keySeen = false
    @Published var practice = ""
    @Published var practiced = false
    @Published var skipped = false
    let host: FirstRunHost
    var onDone: () -> Void = {}
    private var listening = false
    private var lastLoud = Date()
    private var listeningSince = Date()

    init(config: Config, host: FirstRunHost) {
        self.config = config; self.host = host; engine = host.engineState()
    }

    /// The talk key includes Fn, so a Fn setting other than Do Nothing fires along with Voice.
    var fnInUse: Bool { HoldKey.keys(for: config.talkKeyChoice).contains { $0.code == HoldKey.fn.code } }
    var fnBlocking: Bool { fnInUse && fnProblem != nil }
    var micOK: Bool { mic == .authorized }
    var engineReady: Bool { engine == "ready" }
    var keyNames: String { HoldKey.keys(for: config.talkKeyChoice).map(\.name).joined(separator: " or ") }
    var canFinish: Bool { micOK && access && engineReady && !fnBlocking && (practiced || skipped) }

    func start() { tick() }

    func stop() {
        if listening { host.stopLevel(); listening = false }
    }

    func tick() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        config = Config.load()  // Settings may have changed the engine or the key
        let trusted = AXIsProcessTrusted()
        // Accessibility just turned on: watchers set up while it was off may never hear the key, so set them up again.
        if trusted, !access { host.restartKeys() }
        access = trusted
        engine = host.engineState()
        fnProblem = FnKey.problem
        micName = host.micName()
        if micOK, !listening {
            listening = true; listeningSince = Date(); lastLoud = Date()
            host.watchLevel { [weak self] v in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.level = v
                    if v > 0.25 { self.lastLoud = Date() }
                    self.silentFor = Date().timeIntervalSince(self.lastLoud)
                }
            }
        }
    }

    func askMic() {
        if mic == .denied || mic == .restricted { openPrivacy("Privacy_Microphone"); return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.tick() } }
    }

    func askAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        openPrivacy("Privacy_Accessibility")
    }

    func openPrivacy(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }

    func openKeyboardSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    /// Changes one setting on the saved file as it is now, so a change made in Settings meanwhile is never undone.
    private func update(_ change: (inout Config) -> Void) {
        var c = Config.load(); change(&c); c.save(); config = c
    }

    func useRightOption() {
        update { $0.talkKey = "rightOption" }
        host.setTalkKey("rightOption")
    }

    func chooseMic(_ uid: String) {
        update { $0.inputDevice = uid }
        host.setMic(uid)
        lastLoud = Date(); silentFor = 0
    }

    func choose(_ mode: String) { update { $0.mode = mode } }

    func done() { stop(); update { $0.firstRunDone = true }; onDone() }
}

struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content.padding(28) }
            Divider().overlay(Ink.line)
            footer.padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 540, height: 700)
        .background(Ink.paper)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.tick() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Redpen Voice").font(Ink.serif(28)).foregroundStyle(Ink.text)
            Text("Hold a key, talk, let go. Your words go where you were typing.")
                .font(.system(size: 14)).foregroundStyle(Ink.mid).padding(.top, 2)

            heading("1", "How your words come out")
            HStack(spacing: 10) {
                choice("Raw words", "What you said, as you said it.", "raw")
                choice("Ums taken out", "Only sounds like “um” and “uh” go.", "noUms")
                choice("Tidy it up", "Repeats out, punctuation in. Can change a word.", "rewrite")
            }
            .fixedSize(horizontal: false, vertical: true)

            heading("2", "Set up")
            if model.fnBlocking { fnWarning.padding(.bottom, 8) }
            micStep
            Divider().overlay(Ink.line)
            step(done: model.access, title: "Accessibility",
                 detail: model.access ? "On. Voice can see your talk key and type into other apps."
                                      : "So Voice can see your talk key and type into other apps. Turn on Redpen Voice in the list, then come back.") {
                if !model.access { Button("Open settings", action: model.askAccess).controlSize(.small) }
            }
            Divider().overlay(Ink.line)
            step(done: model.engineReady, title: "Speech engine", detail: engineLine) {
                Button("Choose in Settings", action: model.host.openSettings).controlSize(.small)
            }

            heading("3", "Try it")
            practice
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if !model.practiced, !model.skipped {
                Button("Skip the practice") { model.skipped = true }.buttonStyle(.plain).foregroundStyle(Ink.dim).font(.system(size: 12.5))
            }
            Spacer()
            if !model.canFinish { Text(waitingFor).font(.system(size: 12.5)).foregroundStyle(Ink.dim) }
            Button("Done") { model.done() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Ink.red).disabled(!model.canFinish)
        }
    }

    /// What Done is still waiting for, in a few words.
    private var waitingFor: String {
        if !model.micOK { return "Waiting for the microphone" }
        if !model.access { return "Waiting for Accessibility" }
        if model.fnBlocking { return "Waiting for the Fn key" }
        if !model.engineReady { return "Waiting for the engine" }
        return "Say the practice sentence first"
    }

    private func heading(_ n: String, _ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n).font(Ink.serif(18)).foregroundStyle(Ink.red)
            Text(s).font(Ink.serif(18)).foregroundStyle(Ink.text)
        }
        .padding(.top, 22).padding(.bottom, 10)
    }

    // MARK: Microphone

    private var micStep: some View {
        step(done: model.micOK && model.silentFor < 6, title: "Microphone", detail: micLine) {
            if model.mic == .notDetermined { Button("Allow", action: model.askMic).controlSize(.small) }
            else if model.mic == .denied || model.mic == .restricted { Button("Open Microphone settings", action: model.askMic).controlSize(.small) }
            else {
                Picker("", selection: Binding(get: { model.config.inputDevice }, set: { model.chooseMic($0) })) {
                    Text("Same as the Mac").tag("")
                    ForEach(Mics.all(), id: \.uid) { Text($0.name).tag($0.uid) }
                }.labelsHidden().frame(width: 190)
            }
        } extra: {
            if model.micOK { levelBar.padding(.top, 6) }
        }
    }

    private var micLine: String {
        switch model.mic {
        case .notDetermined: return "So Voice can hear you."
        case .denied, .restricted: return "The microphone is off for Redpen Voice. Turn it on in Privacy & Security, then come back."
        default:
            let name = model.micName.isEmpty ? "the microphone" : model.micName
            if model.silentFor >= 6 { return "Nothing heard from \(name). If that isn't the mic you talk into, pick another." }
            return "Listening on \(name). Say something: the bar should move."
        }
    }

    private var levelBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Ink.line)
                RoundedRectangle(cornerRadius: 2).fill(model.level > 0.25 ? Ink.ok : Ink.dim)
                    .frame(width: max(2, g.size.width * CGFloat(model.level)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: model.level)
    }

    // MARK: Fn

    private var fnWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.fnProblem ?? "Fn does something else too"). Holding Fn would do that and Voice at the same time.")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.red).fixedSize(horizontal: false, vertical: true)
            Text("In Keyboard settings, set “Press 🌐 key to” to Do Nothing. Or talk with right Option instead.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Keyboard settings", action: model.openKeyboardSettings).controlSize(.small)
                Button("Use right Option instead", action: model.useRightOption).controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Ink.red, lineWidth: 1.5))
    }

    // MARK: Engine

    var engineLine: String {
        let name = ["whisper": "Most accurate (Whisper)", "live": "Instant", "parakeet": "Instant"][model.config.engine] ?? "Mac built-in"
        switch model.engine {
        case "ready":
            return name == "Mac built-in"
                ? "Mac built-in is ready. For fewer mistakes, Most accurate or Instant can download later in Settings."
                : "\(name) is ready. Runs on this Mac only."
        case "unsupported": return "This Mac or language is not supported."
        case let s where s.hasPrefix("downloading"):
            let dl = ["whisper": "Whisper", "live": "Instant", "parakeet": "Instant"][model.config.engine] ?? "Apple's speech model"
            return "Downloading \(dl) " + s.dropFirst(11) + "%…"
        case let s where s.hasPrefix("failed"): return s
        default: return "Getting \(name) ready…"
        }
    }

    // MARK: Practice

    private var practice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.practiced ? "That's your voice. Now try it in any app: click where you'd type, hold \(model.keyNames) and talk."
                                 : "Click here, then hold \(model.keyNames) and say: “Redpen Voice is ready to go.”")
                .font(.system(size: 13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            Text(model.practice.isEmpty ? (model.keySeen ? "Listening…" : " ") : model.practice)
                .font(Ink.body(17)).foregroundStyle(model.practice.isEmpty ? Ink.dim : Ink.text)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                .padding(10)
                .overlay(Rectangle().stroke(model.practiced ? Ink.ok : Ink.line, lineWidth: model.practiced ? 1.5 : 1))
                .contentShape(Rectangle())
                .onTapGesture { NSApp.activate(ignoringOtherApps: true) }
            if model.access, model.micOK, model.engineReady, !model.practiced, !model.keySeen {
                HStack(spacing: 6) {
                    Text("Holding the key does nothing?").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                    Button("Restart Redpen Voice", action: model.host.relaunch).buttonStyle(.plain).foregroundStyle(Ink.red).font(.system(size: 12.5))
                }
            }
        }
    }

    // MARK: Pieces

    func choice(_ title: String, _ detail: String, _ mode: String) -> some View {
        let on = model.config.mode == mode
        return Button { model.choose(mode) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? Ink.red : Ink.line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func step<C: View>(done: Bool, title: String, detail: String, @ViewBuilder control: () -> C) -> some View {
        step(done: done, title: title, detail: detail, control: control) { EmptyView() }
    }

    func step<C: View, E: View>(done: Bool, title: String, detail: String, @ViewBuilder control: () -> C, @ViewBuilder extra: () -> E) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Ink.ok : Ink.dim).font(.system(size: 16)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Ink.text)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 10)
    }
}

import AppKit
import Carbon.HIToolbox
import CoreText
import SwiftUI
import ServiceManagement
import VoiceCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: Config { didSet { config.save(); onChange(config) } }
    @Published var openAtLogin: Bool {
        didSet { if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }
    }
    @Published var engineState: Transcriber.State
    /// Whisper's background download: nil when idle, 0 to 1 while downloading, 1 while it loads.
    @Published var fetch: Double?
    @Published var fetchError: String?
    let onChange: (Config) -> Void
    /// Starts or stops a test recording to the Desktop, for comparing engines on real talking.
    var recordTest: () -> Void = {}
    var close: () -> Void = {}
    /// Back to the menu bar panel.
    var back: () -> Void = {}
    /// Opens the history window (D-825).
    var showHistory: () -> Void = { NSWorkspace.shared.activateFileViewerSelecting([Config.historyURL]) }
    /// All-time words and talking seconds from the stats, for the time-saved line (D-837).
    var statsTotal: () -> (words: Int, seconds: Double) = { (0, 0) }
    private let engine: Transcriber
    private var fetchTask: Task<Void, Never>?

    init(config: Config, engine: Transcriber, onChange: @escaping (Config) -> Void) {
        self.config = config; self.engine = engine; self.onChange = onChange
        engineState = engine.state
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Other key

    @Published var listeningForKey = false
    @Published var keyMessage: String?
    private var keyMonitor: Any?

    static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Waits for the next key pressed in this window. Keys that type or move the cursor are turned down, since
    /// holding one would type into the page as well. Escape gives up.
    func listenForKey() {
        stopListening()
        listeningForKey = true; keyMessage = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            let code = Int(e.keyCode)
            if e.type == .flagsChanged {
                guard let flag = HoldKey.modifiers[code], e.modifierFlags.contains(flag), let name = HoldKey.modifierNames[code] else { return e }
                self.pick(code, name); return nil
            }
            if code == kVK_Escape { self.stopListening(); return nil }
            if let name = Self.fKeys[code] { self.pick(code, name); return nil }
            self.keyMessage = "That key types or moves the cursor. Pick an F-key, or a key like right Command."
            return nil
        }
    }

    private func pick(_ code: Int, _ name: String) {
        stopListening()
        config.talkKey = "key:\(code):\(name)"
    }

    func stopListening() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil; listeningForKey = false
    }

    var usesWhisper: Bool { config.engine == "whisper" }
    var usesInstant: Bool { config.engine == "live" || config.engine == "parakeet" }
    var whisperOnDisk: Bool { Transcriber.whisperOnDisk }

    /// Downloads and loads Whisper while the built-in engine keeps working, then switches to it.
    func getWhisper() {
        guard fetchTask == nil else { return }
        fetch = 0; fetchError = nil
        fetchTask = Task { [weak self, engine] in
            do {
                try await engine.fetchWhisper { p in Task { @MainActor in self?.fetch = p } }
                guard let self, !Task.isCancelled else { return }
                self.fetch = nil; self.fetchTask = nil
                self.config.engine = "whisper"
            } catch {
                guard let self else { return }
                if !Task.isCancelled { self.fetchError = error.localizedDescription; Log.note("settings: whisper download failed \(error.localizedDescription)") }
                self.fetch = nil; self.fetchTask = nil
            }
        }
    }

    func cancelWhisper() { fetchTask?.cancel(); fetchTask = nil; fetch = nil }

    func chooseWhisper() { if whisperOnDisk { config.engine = "whisper" } else { getWhisper() } }

    /// "heard = meant" lines from names.txt, comments and blank lines skipped.
    var names: [String] {
        Config.loadNames().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    var dictationCount: Int {
        ((try? String(contentsOf: Config.historyURL, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    let model: SettingsModel
    init(model: SettingsModel) { self.model = model }

    func show() {
        if window == nil {
            Ink.registerFonts()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen Voice"
            w.contentView = NSHostingView(rootView: SettingsView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            w.contentMinSize = NSSize(width: 540, height: 420)
            w.center(); w.isReleasedWhenClosed = false
            window = w
            model.close = { [weak w] in w?.close() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The settings page's paper, ink and red pen, matched to Redpen's fix card. Each colour has a dark twin.
enum Ink {
    static let paper = pair(light: 0xFBFAF7, dark: 0x1D1C1A)
    static let text = pair(light: 0x1C1B19, dark: 0xF3F1EC)
    static let mid = pair(light: 0x5F5C56, dark: 0xB5B1A9)
    static let dim = pair(light: 0x8D8A83, dark: 0x86827A)
    static let red = pair(light: 0xC8281E, dark: 0xFF5A4A)
    static let line = Color.primary.opacity(0.12)
    static let ok = pair(light: 0x2E9D4F, dark: 0x4CC46D)

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "Newsreader16pt-Italic" : "Newsreader16pt-SemiBold", size: size)
    }
    static func body(_ size: CGFloat) -> Font { .custom("Newsreader16pt-Regular", size: size) }

    private static func pair(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    private static var registered = false
    /// Newsreader ships in the app's Resources/Fonts and is registered for this process only.
    static func registerFonts() {
        guard !registered, let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        registered = true
        for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var showTest = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { model.close(); model.back() } label: {
                    Text("‹ Back").font(.system(size: 13))
                }.buttonStyle(.plain).foregroundStyle(Ink.red).keyboardShortcut(.cancelAction).padding(.bottom, 6)
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings").font(Ink.serif(28)).foregroundStyle(Ink.text)
                    Spacer()
                    status
                }
                heading("Engine")
                engineSection
                heading("What you get")
                outputChoice
                heading("Talking")
                talking
                heading("Words it gets wrong")
                wordsRow
                row("Suggest words to add", "A recurring name, at most once a day after you finish talking.") {
                    Toggle("", isOn: Binding(get: { model.config.suggestWords ?? true }, set: { model.config.suggestWords = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(Ink.red)
                }.padding(.top, 12)
                heading("Time saved")
                typingRow
                footer
            }
            .padding(.horizontal, 36).padding(.top, 14).padding(.bottom, 26)
        }
        .background(Ink.paper)
        .frame(minWidth: 540, minHeight: 420)
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(Ink.serif(18)).foregroundStyle(Ink.text)
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.red).frame(height: 2) }
            .padding(.top, 28).padding(.bottom, 6)
    }

    private var status: some View {
        let (word, live): (String, Bool) = {
            switch model.engineState {
            case .ready: return ("Ready on " + (model.usesWhisper ? "Most accurate" : model.usesInstant ? "Instant" : "Mac built-in"), true)
            case .checking: return ("Getting ready", false)
            case .downloading(let p): return ("Downloading \(p)%", false)
            case .unsupported: return ("Language not supported", false)
            case .failed: return ("Engine failed", false)
            }
        }()
        return HStack(spacing: 7) {
            Circle().fill(live ? Ink.ok : Ink.dim).frame(width: 8, height: 8)
            Text(word).font(.system(size: 13)).foregroundStyle(Ink.mid)
        }
    }

    // MARK: Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            engineRow(on: model.usesWhisper, dashed: !model.whisperOnDisk, action: model.chooseWhisper) {
                title("Most accurate", "Whisper")
                if let p = model.fetch {
                    note(p < 1 ? "Downloading. Keep talking, the built-in engine handles your words until Whisper is ready."
                               : "Getting Whisper ready. This takes a minute or two, once.")
                    ProgressView(value: p < 1 ? p : nil).tint(Ink.red).padding(.top, 8)
                    HStack {
                        Text(p < 1 ? "\(Int(p * 626)) of 626 MB" : "Loading").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
                        Spacer()
                        Button("Cancel") { model.cancelWhisper() }.buttonStyle(.plain).foregroundStyle(Ink.red)
                    }.padding(.top, 4)
                } else if model.whisperOnDisk {
                    note("Fewest mistakes, best with noise and other voices. Your words go in about 2 seconds after you stop.")
                } else {
                    note("Fewest mistakes, best with noise and other voices. Your words go in about 2 seconds after you stop. A one-time 626 MB download.")
                    heard("Whisper heard", whisperLine)
                    if let e = model.fetchError { Text("Download stopped: \(e)").font(.system(size: 12.5)).foregroundStyle(Ink.red).padding(.top, 6) }
                    Button("Download Whisper") { model.getWhisper() }.controlSize(.large).padding(.top, 10)
                }
            }
            if model.usesWhisper {
                row("Point out words to check (test)", "When a second engine hears a “not”, a number, a name or your first or last words differently, the bar shows that word for a few seconds and ⌃⌥S swaps in the other version. Off while we test whether it helps.") {
                    Toggle("", isOn: Binding(get: { model.config.riskMarks ?? false }, set: { model.config.riskMarks = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(Ink.red)
                }
                row("Quick draft while Whisper works", "A rough draft types into the box as you talk; a moment later Whisper fixes any words it heard differently. It stops fixing the moment you click or type.") {
                    Toggle("", isOn: Binding(get: { model.config.draftMode ?? false }, set: { model.config.draftMode = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(Ink.red)
                }.padding(.bottom, 10)
            }
            Divider().overlay(Ink.line)
            engineRow(on: model.usesInstant, dashed: !Transcriber.liveOnDisk, action: { model.config.engine = "live" }) {
                title("Instant", "Parakeet")
                note(Transcriber.liveOnDisk
                     ? "Your words show in the bar as you talk and go in right after you let go, with no wait for writing. About 1 more word in 100 wrong than Whisper, and weaker when other people talk over you. English only."
                     : "Your words show in the bar as you talk and go in right after you let go, with no wait for writing. About 1 more word in 100 wrong than Whisper, and weaker when other people talk over you. English only. A one-time 600 MB download the first time you pick it.")
            }
            Divider().overlay(Ink.line)
            engineRow(on: !model.usesWhisper && !model.usesInstant, dashed: false, action: { model.config.engine = "dictation" }) {
                title("Mac built-in", "Apple")
                note("Built into macOS. If the Mac's speech files for your language aren't there yet, they download from Apple once. Gets the most words wrong of the three.")
                if !model.whisperOnDisk && model.fetch == nil { heard("Mac built-in heard", builtInLine) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.whisperOnDisk || model.fetch != nil
                     ? "Words wrong in 1,100 test recordings: Most accurate 7.8%, Instant 9.2%, Mac built-in 12.0%."
                     : "That sentence was recorded with people talking nearby. Words wrong in 1,100 test recordings: Most accurate 7.8%, Instant 9.2%, Mac built-in 12.0%.")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 12)
            Button("How we tested") { showTest.toggle() }.buttonStyle(.plain).foregroundStyle(Ink.red).font(.system(size: 12.5))
                .popover(isPresented: $showTest, arrowEdge: .bottom) {
                    Text("All three ran on WildSpeech-Bench, 1,100 public recordings of people asking questions: some in quiet rooms, some on the street, some with others talking. Whisper got 7.8% of words wrong, Instant 9.2%, the Mac's built-in engine 12.0%. On 44 clips of one person's own talking, Whisper got 13.8% wrong and Instant 14.8%. Instant's text was ready about 0.03 s after the audio ended; Whisper's last piece took about 1.2 s.")
                        .font(.system(size: 13)).frame(width: 300).fixedSize(horizontal: false, vertical: true).padding(14)
                }
        }
    }

    private func engineRow<C: View>(on: Bool, dashed: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().strokeBorder(on ? Ink.red : Ink.dim, style: StrokeStyle(lineWidth: 1.5, dash: dashed && !on ? [2.5, 2.5] : []))
                if on { Circle().fill(Ink.red).padding(4) }
            }.frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) { content() }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    /// An engine's plain name, and the model behind it in grey.
    private func title(_ name: String, _ model: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.system(size: 15, weight: .semibold))
            Text(model).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(Ink.mid).padding(.top, 3).fixedSize(horizontal: false, vertical: true)
    }

    private func heard(_ who: String, _ line: Text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(who.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Ink.dim)
            line.font(Ink.body(16.5)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 10)
    }

    /// A real WildSpeech-Bench clip (0443), recorded with people talking nearby. Whisper got every word.
    private var whisperLine: Text {
        Text("Based on the sentiment around gold, how should I trade gold futures in the session tomorrow?").foregroundStyle(Ink.text)
            + Text("  ✓ no mistakes").font(.system(size: 13)).foregroundStyle(Ink.ok)
    }

    /// The same clip from the built-in engine: it dropped "gold" and wrote "features". Marked the way Redpen marks text.
    private var builtInLine: Text {
        let fix = { (s: String) in Text(s).font(Ink.serif(15, italic: true)).foregroundStyle(Ink.red) }
        return Text("Based on the sentiment around").foregroundStyle(Ink.text)
            + fix(" ‸gold") + Text(", how should I trade gold ").foregroundStyle(Ink.text)
            + Text("features").strikethrough(color: Ink.red).foregroundStyle(Ink.text)
            + fix(" futures") + Text(" in the session tomorrow?").foregroundStyle(Ink.text)
    }

    // MARK: Output, talking, words

    /// Two switches over the three modes: neither is your words as said, the first takes out only sounds,
    /// the second is the on-device rewrite (which takes the sounds out too, so the first shows on with it).
    private var outputChoice: some View {
        let ums = Binding(get: { model.config.mode != "raw" },
                          set: { model.config.mode = $0 ? "noUms" : "raw" })
        let tidy = Binding(get: { model.config.mode == "rewrite" },
                           set: { model.config.mode = $0 ? "rewrite" : "noUms" })
        return VStack(spacing: 0) {
            row("Take out ums and uhs", "“So, um, I think we, we should…” becomes “So, I think we, we should…”. Every word stays.") {
                Toggle("", isOn: ums).labelsHidden().toggleStyle(.switch).tint(Ink.red).disabled(model.config.mode == "rewrite")
            }
            Divider().overlay(Ink.line)
            row("Tidy it up", "Also takes out repeats and false starts and fixes punctuation, using the Mac's on-device AI. It can change a word now and then.") {
                Toggle("", isOn: tidy).labelsHidden().toggleStyle(.switch).tint(Ink.red)
            }
        }
    }

    private var talking: some View {
        VStack(spacing: 0) {
            row("Hold to talk", model.listeningForKey ? (model.keyMessage ?? "Press the key you want to hold. Escape to stop.") : nil) {
                if model.listeningForKey {
                    Button("Cancel") { model.stopListening() }
                } else {
                    Picker("", selection: Binding(get: { model.config.talkKeyChoice },
                                                  set: { v in if v == "other" { model.listenForKey() } else { model.config.talkKey = v } })) {
                        Text("Fn or right Option").tag("fnOrOption")
                        Text("Fn (globe)").tag("fn")
                        Text("Right Option").tag("rightOption")
                        Text("Right Command").tag("rightCommand")
                        Text("Right Control").tag("rightControl")
                        if model.config.talkKeyChoice.hasPrefix("key:") {
                            Text(HoldKey.keys(for: model.config.talkKeyChoice).first.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() } ?? "")
                                .tag(model.config.talkKeyChoice)
                        }
                        Divider()
                        Text("Other key…").tag("other")
                    }.labelsHidden().frame(width: 220, alignment: .trailing)
                }
            }
            Divider().overlay(Ink.line)
            row("Double-tap to keep talking", "Tap twice and talk with your hands free. Tap once more to finish.") {
                Toggle("", isOn: Binding(get: { model.config.doubleTap ?? true }, set: { model.config.doubleTap = $0 }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.red)
            }
            Divider().overlay(Ink.line)
            row("Microphone", "Pick the one you talk into. An interface with nothing plugged in records silence.") {
                Picker("", selection: $model.config.inputDevice) {
                    Text("Same as the Mac" + (Mics.defaultInput().map { " (\($0.name))" } ?? "")).tag("")
                    ForEach(Mics.all(), id: \.uid) { d in Text(d.name).tag(d.uid) }
                }.labelsHidden().frame(width: 220, alignment: .trailing)
            }
            Divider().overlay(Ink.line)
            row("Record a test", "Up to ten minutes from this mic, saved to the Desktop. Click again to stop.") {
                Button("Record") { model.recordTest() }
            }
            Divider().overlay(Ink.line)
            row("Language") {
                Picker("", selection: $model.config.locale) {
                    Text("English (Canada)").tag("en-CA"); Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB")
                }.labelsHidden().frame(width: 220, alignment: .trailing)
            }
            Divider().overlay(Ink.line)
            row("Pause music and video while I talk") { Toggle("", isOn: $model.config.pauseMedia).labelsHidden().toggleStyle(.switch).tint(Ink.red) }
            Divider().overlay(Ink.line)
            row("Words appear as I talk", "Instant: shown in the bar. Most accurate: typed into the box as you go when you're in one, otherwise shown in the bar.") {
                Toggle("", isOn: Binding(get: { model.config.liveWords ?? true }, set: { model.config.liveWords = $0 }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.red)
            }
            Divider().overlay(Ink.line)
            row("Play again when I stop talking", "Off: your video stays paused until you press play, so nothing starts by itself.") {
                Toggle("", isOn: Binding(get: { model.config.resumeMedia ?? true }, set: { model.config.resumeMedia = $0 }))
                    .labelsHidden().toggleStyle(.switch).tint(Ink.red).disabled(!model.config.pauseMedia)
            }
            Divider().overlay(Ink.line)
            row("Level bar", "The bar near the bottom of the screen while you talk.") {
                Picker("", selection: Binding(get: { model.config.levelLook },
                                              set: { v in model.config.showLevel = v != "off"; if v != "off" { model.config.levelStyle = v } })) {
                    Text("Red pen line").tag("pen"); Text("Bars from the middle").tag("bars"); Text("Rolling tape").tag("tape")
                    Text("Breathing dot").tag("dot"); Text("Classic bars").tag("classic"); Divider(); Text("Off").tag("off")
                }.labelsHidden().frame(width: 220, alignment: .trailing)
            }
            Divider().overlay(Ink.line)
            row("Light or dark") {
                Picker("", selection: Binding(get: { model.config.appearance ?? "auto" },
                                              set: { model.config.appearance = $0 == "auto" ? nil : $0 })) {
                    Text("Match the Mac").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }.labelsHidden().frame(width: 220, alignment: .trailing)
            }
            Divider().overlay(Ink.line)
            row("Click at start and stop") { Toggle("", isOn: $model.config.sounds).labelsHidden().toggleStyle(.switch).tint(Ink.red) }
        }
    }

    /// Your typing speed, next to the line it changes (D-837).
    private var typingRow: some View {
        let t = model.statsTotal()
        let speed = Int(model.config.typingSpeed)
        let saved = Score(words: t.words, seconds: t.seconds, typing: model.config.typingSpeed).minutesSaved
        let steps = Array(stride(from: 20, through: 120, by: 10))
        let choices = steps + (steps.contains(speed) ? [] : [speed])
        return row("Your typing speed", "\(Score.savedText(saved)) saved so far, compared with typing at \(speed) words a minute.") {
            Picker("", selection: Binding(get: { speed }, set: { model.config.typingWPM = $0 })) {
                ForEach(choices.sorted(), id: \.self) { Text("\($0) words a minute").tag($0) }
            }.labelsHidden().frame(width: 220, alignment: .trailing)
        }
    }

    private var wordsRow: some View {
        let names = model.names
        let sample = names.prefix(3).map { $0.replacingOccurrences(of: " = ", with: " → ") }.joined(separator: " · ")
        return row("\(names.count) \(names.count == 1 ? "fix" : "fixes"), applied after every dictation", sample.isEmpty ? "Add a name, or “heard = meant”, one per line." : sample) {
            Button("Edit list") { Config.ensureNamesFile(); NSWorkspace.shared.open(Config.namesURL) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.dictationCount) dictations: their text is kept on this Mac (the last 2,000), never the sound.").foregroundStyle(Ink.dim)
                Button("Show") { model.showHistory() }.buttonStyle(.plain).foregroundStyle(Ink.red)
                Spacer()
                Text("Open at login").foregroundStyle(Ink.dim)
                Toggle("", isOn: $model.openAtLogin).labelsHidden().toggleStyle(.switch).tint(Ink.red)
            }
            Text("The microphone stays on while Voice is open (the orange dot) so your first word isn't cut. It holds only the last 0.6 s in memory, and keeps nothing until you press the key.")
                .foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(.top, 14)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
        .padding(.top, 24)
    }

    private func row<C: View>(_ label: String, _ sub: String? = nil, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 14)).foregroundStyle(Ink.text)
                if let sub { Text(sub).font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }.padding(.vertical, 11)
    }
}

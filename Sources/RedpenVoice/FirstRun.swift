import AppKit
import SwiftUI
import AVFoundation

/// The first window: one question, then the three things the Mac needs to allow.
@MainActor
final class FirstRunWindow {
    private var window: NSWindow?
    private let model: FirstRunModel
    var onDone: () -> Void = {}

    init(config: Config, engineState: @escaping () -> String) {
        model = FirstRunModel(config: config, engineState: engineState)
    }

    func show() {
        model.onDone = { [weak self] in self?.window?.close(); self?.onDone() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Redpen Voice"
        w.contentView = NSHostingView(rootView: FirstRunView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func refresh() { model.tick() }
}

@MainActor
final class FirstRunModel: ObservableObject {
    @Published var config: Config
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var access = AXIsProcessTrusted()
    @Published var fnOK = FnKey.problem == nil
    @Published var engine = ""
    let engineState: () -> String
    var onDone: () -> Void = {}

    init(config: Config, engineState: @escaping () -> String) { self.config = config; self.engineState = engineState; engine = engineState() }

    func tick() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized; access = AXIsProcessTrusted(); engine = engineState()
        fnOK = FnKey.problem == nil
    }

    func askMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { self.mic = ok } }
    }

    func askAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    func openKeyboardSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    func choose(_ mode: String) { config.mode = mode; config.save() }

    func done() { config.firstRunDone = true; config.save(); onDone() }
}

struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hold a key, talk, let go. The words land where your cursor is.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Text("How should your words come out?")
                .font(.system(size: 17, weight: .semibold))
            HStack(spacing: 12) {
                choice("Raw words", "What you said, as you said it.", "raw")
                choice("Ums taken out", "Only sounds like “um” and “uh” go. Every word stays.", "noUms")
                choice("Rewrite it", "Ums and false starts out, punctuation in. Your words stay.", "rewrite")
            }
            Text("You can flip this any time from the menu bar.").font(.system(size: 12)).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            step(done: model.mic, title: "Microphone", detail: "So it can hear you.", button: "Allow", action: model.askMic)
            step(done: model.access, title: "Accessibility", detail: "So it can type into other apps and see the Fn key.", button: "Open settings", action: model.askAccess)
            step(done: model.engine == "ready", title: "Speech engine", detail: engineLine, button: nil, action: {})
            step(done: model.fnOK, title: "The Fn key",
                 detail: model.fnOK ? "Set to Do Nothing, so only Redpen Voice answers it."
                     : "\(FnKey.problem ?? "Fn does something else too"). In Keyboard settings, set “Press 🌐 key to” to Do Nothing.",
                 button: "Open Keyboard settings", action: model.openKeyboardSettings)

            Spacer()
            HStack {
                Spacer()
                Button("Done") { model.done() }.keyboardShortcut(.defaultAction).disabled(!(model.mic && model.access))
            }
        }
        .padding(28)
        .frame(width: 480, height: 560)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in model.tick() }
    }

    var engineLine: String {
        switch model.engine {
        case "ready": return "Downloaded and ready. Runs on this Mac only."
        case "unsupported": return "This Mac or language is not supported."
        case let s where s.hasPrefix("downloading"): return "Downloading Apple's speech model " + s.dropFirst(11) + "%…"
        case let s where s.hasPrefix("failed"): return s
        default: return "Checking…"
        }
    }

    func choice(_ title: String, _ detail: String, _ mode: String) -> some View {
        Button { model.choose(mode) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(title).font(.system(size: 14, weight: .semibold)); Spacer(); if model.config.mode == mode { Image(systemName: "checkmark.circle.fill") } }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).stroke(model.config.mode == mode ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: model.config.mode == mode ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    func step(done: Bool, title: String, detail: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.green : Color.secondary).font(.system(size: 16)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let button, !done { Button(button, action: action).controlSize(.small) }
        }
    }
}

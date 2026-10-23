import AppKit
import SwiftUI

/// What the menu bar panel shows. Rebuilt by the app whenever something changes; the panel just draws it.
struct MenuState {
    var ready = false
    var status = "Getting ready"
    var engine = "Mac built-in"
    var mic = ""
    var keyLine = ""
    var todayWords = 0, todayWPM = 0, todaySaved = 0
    var totalWords = 0, totalSaved = 0
    var mode = "raw"
    var last: String?
    var canTakeBack = false
    var testing = false
}

@MainActor
final class MenuModel: ObservableObject {
    @Published var state = MenuState()
    var setMode: (String) -> Void = { _ in }
    var paste: () -> Void = {}
    var show: () -> Void = {}
    var takeBack: () -> Void = {}
    var file: () -> Void = {}
    var test: () -> Void = {}
    var words: () -> Void = {}
    var settings: () -> Void = {}
}

/// The panel under the menu bar icon, in the settings page's paper, ink and red pen. Only what you reach for
/// from the menu bar; everything else lives in Settings.
struct MenuPanel: View {
    @ObservedObject var model: MenuModel
    private var s: MenuState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if s.testing { action("Stop the test recording", red: true, model.test).padding(.top, 10) }
            switches.padding(.top, 16)
            rule
            action("Paste last dictation", keys: "⌃⌥V", model.paste).disabled(s.last == nil)
            action("Transcribe a file…", model.file)
            action("Settings…", keys: "⌘,", model.settings).keyboardShortcut(",", modifiers: .command)
            rule
            action("Quit Redpen Voice", keys: "⌘Q") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
        .frame(width: 300)
        .background(Ink.paper)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Redpen Voice").font(Ink.serif(19)).foregroundStyle(Ink.text)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(s.ready ? Ink.ok : Ink.dim).frame(width: 7, height: 7)
                    Text(s.ready ? "Ready on \(s.engine)" : s.status).font(.system(size: 12)).foregroundStyle(Ink.mid)
                }
            }
            Text("\(s.todayWords.formatted()) words today, \(s.todaySaved) min saved")
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim)
        }
    }

    private var switches: some View {
        let ums = Binding(get: { s.mode != "raw" }, set: { model.setMode($0 ? "noUms" : "raw") })
        let tidy = Binding(get: { s.mode == "rewrite" }, set: { model.setMode($0 ? "rewrite" : "noUms") })
        return VStack(spacing: 10) {
            toggleRow("Take out ums and uhs", ums).disabled(s.mode == "rewrite")
            toggleRow("Tidy it up", tidy)
        }
    }

    private var rule: some View { Rectangle().fill(Ink.line).frame(height: 1).padding(.vertical, 8) }

    private func toggleRow(_ label: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(Ink.text)
            Spacer()
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Ink.red)
        }
    }

    private func action(_ label: String, keys: String? = nil, red: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Text(label).font(.system(size: 13.5)).foregroundStyle(red ? Ink.red : Ink.text)
                Spacer()
                if let keys { Text(keys).font(.system(size: 12)).foregroundStyle(Ink.dim) }
            }
            .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(HoverRow()).padding(.horizontal, -8)
    }
}

/// A faint wash under the pointer, so a row reads as clickable without boxes.
private struct HoverRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Hovered(label: configuration.label, pressed: configuration.isPressed) }
    private struct Hovered<L: View>: View {
        let label: L; let pressed: Bool
        @State private var over = false
        var body: some View {
            label.background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(pressed ? 0.1 : over ? 0.06 : 0)))
                .onHover { over = $0 }
        }
    }
}

import AppKit
import SwiftUI
import VoiceCore

/// What the menu bar panel shows. Rebuilt by the app whenever something changes; the panel just draws it.
struct MenuState {
    var ready = false
    var status = "Getting ready"
    var engine = "Mac built-in"
    var mic = ""
    var keyLine = ""
    /// How you talk, once learned, or how far along the learning is.
    var talk = ""
    var todayWords = 0, todayWPM = 0, todaySaved = 0
    var totalWords = 0, totalSaved = 0
    var mode = "raw"
    var last: String?
    var canTakeBack = false
    var testing = false
    /// When the meeting being recorded started (D-951), how far its notes have got, and meetings never written up.
    var meetingStarted: Date?
    var meetingPaused = false
    var notesStatus: String?
    var needsNotes = false
    var unfinished = 0
    /// Tell people apart in person is on (D-1034), so the menu offers to name them.
    var nameVoices = false
    /// A newer version found by the daily check, shown instead of a window over your work.
    var update: String?
    /// Something on this Mac that gets in the way, said plainly (the Fn key set to start Apple's dictation).
    var warning: String?
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
    var history: () -> Void = {}
    var stats: () -> Void = {}
    var updates: () -> Void = {}
    var meeting: () -> Void = {}
    var pauseMeeting: () -> Void = {}
    var copyNotice: () -> Void = {}
    var unfinished: () -> Void = {}
    var nameVoices: () -> Void = {}
    /// After the call (D-1126): a meeting's notes, actions first.
    var openNotes: () -> Void = {}
    var writeNotesAgain: () -> Void = {}
    /// Send a report (D-1034).
    var report: () -> Void = {}
}

/// The concise native panel keeps Dictation and Meetings apart. Every existing app callback stays reachable.
struct MenuPanel: View {
    @ObservedObject var model: MenuModel
    @State private var tab = "dictation"
    @State private var appearanceRevision = 0
    private var s: MenuState { model.state }

    init(model: MenuModel, initialTab: String = "dictation") {
        self.model = model
        _tab = State(initialValue: initialTab == "meetings" ? "meetings" : "dictation")
    }

    var body: some View {
        let _ = appearanceRevision
        VStack(alignment: .leading, spacing: 0) {
            header
            if s.testing { action("Stop the test recording", red: true, model.test).padding(.top, 10) }
            Picker("Voice mode", selection: $tab) {
                Text("Dictation").tag("dictation")
                Text(s.meetingStarted != nil ? (s.meetingPaused ? "Meetings · paused" : "Meetings · recording") : "Meetings").tag("meetings")
            }.pickerStyle(.segmented).labelsHidden().padding(.vertical, 15)
            if tab == "dictation" { dictationRows } else { meetingRows }
            footer.padding(.top, 14)
        }
        .padding(17)
        .frame(width: 326)
        .background(Ink.paper)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceAppearanceChanged"))) { _ in appearanceRevision += 1 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                VoiceMark().frame(width: 22, height: 22).foregroundStyle(Ink.red)
                Text("Redpen Voice").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 5)
                HStack(spacing: 5) {
                    Circle().fill(s.ready ? Ink.ok : Ink.dim).frame(width: 5, height: 5)
                    Text(s.ready ? "Ready" : s.status).font(.system(size: 11)).foregroundStyle(Ink.mid)
                }.help(s.ready ? "Ready on " + s.engine : s.status)
            }.foregroundStyle(Ink.text)
            if let warning = s.warning {
                Text(warning).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !s.talk.isEmpty {
                Text(s.talk).font(.system(size: 12)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dictationRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Last dictation").font(.system(size: 11)).foregroundStyle(Ink.mid).padding(.bottom, 7)
            VStack(alignment: .leading, spacing: 12) {
                Text(s.last ?? "Your next dictation will appear here.")
                    .font(.system(size: 13)).foregroundStyle(s.last == nil ? Ink.mid : Ink.text)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: model.paste) {
                    HStack { Spacer(); Text("Paste last"); Spacer(); Text("⌃⌥V").foregroundStyle(Ink.mid) }
                        .font(.system(size: 12, weight: .medium)).padding(.vertical, 7).padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).background(Ink.subtle, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.border.opacity(0.6)))
                    .disabled(s.last == nil)
            }.padding(12).background(Ink.raised, in: RoundedRectangle(cornerRadius: 3))
            switches.padding(.top, 17).padding(.bottom, 12)
            action("History", navigates: true, model.history)
            action("Names & words", navigates: true, model.words)
            action("Transcribe a file", navigates: true, model.file)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(action: model.stats) {
                Text("Stats").font(.system(size: 13)).foregroundStyle(Ink.text)
                    .padding(.vertical, 6).contentShape(Rectangle())
            }
            Spacer()
            Button(action: model.settings) {
                Text("Settings").font(.system(size: 13)).foregroundStyle(Ink.text)
                    .padding(.vertical, 6).contentShape(Rectangle())
            }.keyboardShortcut(",", modifiers: .command)
            Menu {
                if s.last != nil { Button("Show last dictation…", action: model.show) }
                if s.canTakeBack { Button("Take back last dictation", action: model.takeBack) }
                if s.last != nil || s.canTakeBack { Divider() }
                Button(s.update.map { "Install version \($0)…" } ?? "Check for updates…", action: model.updates)
                Button("Send a report…", action: model.report)
                Divider()
                Text(todayLine)
                Text("All time: \(s.totalWords.formatted()) words, \(Score.savedText(s.totalSaved)) saved")
                if !s.keyLine.isEmpty { Text(s.keyLine) }
                if !s.mic.isEmpty { Text(s.mic) }
                Divider()
                Button("Quit Redpen Voice") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            } label: {
                HStack(spacing: 4) {
                    Text("More").font(.system(size: 13)).foregroundStyle(Ink.text)
                    if s.update != nil { Circle().fill(Ink.red).frame(width: 5, height: 5) }
                }.padding(.vertical, 6).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).fixedSize()
        }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Ink.text)
    }

    /// Actual counts from MenuState. The speed is left out until there is one.
    private var todayLine: String {
        let words = "\(s.todayWords.formatted()) \(s.todayWords == 1 ? "word" : "words") today"
        return ([words] + (s.todayWPM > 0 ? ["\(s.todayWPM) wpm"] : []) + ["\(Score.savedText(s.todaySaved)) saved"]).joined(separator: " · ")
    }

    private var switches: some View {
        let ums = Binding(get: { s.mode != "raw" }, set: { model.setMode($0 ? "noUms" : "raw") })
        let tidy = Binding(get: { s.mode == "rewrite" }, set: { model.setMode($0 ? "rewrite" : "noUms") })
        return VStack(spacing: 10) {
            toggleRow("Take out ums and uhs", ums).disabled(s.mode == "rewrite")
            toggleRow("Tidy it up", tidy)
        }
    }

    /// Start and stop, the time while it records, the notice for the chat, and how far the notes have got.
    private var meetingRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let started = s.meetingStarted {
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    action("Stop meeting notes (\(Meeting.clock(ctx.date.timeIntervalSince(started))))", keys: "⌃⌥M", red: true, model.meeting)
                }
                action(s.meetingPaused ? "Resume meeting notes" : "Pause meeting notes", keys: "⌃⌥P", model.pauseMeeting)
            } else {
                action("Start meeting notes", model.meeting)
            }
            action("Copy notice for the meeting chat", model.copyNotice)
            if s.meetingStarted == nil { action("Open meeting notes…", model.openNotes) }
            if s.needsNotes, s.meetingStarted == nil { action("Write notes again", model.writeNotesAgain).disabled(s.notesStatus != nil) }
            if s.nameVoices, s.meetingStarted == nil { action("Name the voices…", model.nameVoices) }
            if s.unfinished > 0, s.notesStatus == nil {
                action("Write notes for \(s.unfinished == 1 ? "an unfinished meeting" : "\(s.unfinished) unfinished meetings")…", model.unfinished)
            }
            if let n = s.notesStatus {
                Text(n).font(.system(size: 12.5)).foregroundStyle(Ink.dim).monospacedDigit().padding(.vertical, 4)
            }
        }
    }

    private func toggleRow(_ label: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Ink.text)
            Spacer()
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Ink.red)
        }
    }

    private func action(_ label: String, keys: String? = nil, red: Bool = false, navigates: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(red ? Ink.red : Ink.text)
                Spacer()
                if let keys { Text(keys).font(.system(size: 12)).foregroundStyle(Ink.dim) }
                if navigates {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.mid).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 8).contentShape(Rectangle())
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
            label.background(RoundedRectangle(cornerRadius: 4).fill(Ink.raised.opacity(pressed ? 1 : over ? 0.7 : 0)))
                .onHover { over = $0 }
        }
    }
}

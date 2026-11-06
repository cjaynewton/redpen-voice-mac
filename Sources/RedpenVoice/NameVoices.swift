import AppKit
import SwiftUI
import VoiceCore

/// Name the voices (D-1034): the voices told apart in one meeting's notes, each with the first thing it said, and a
/// box for its name. Saving changes the name on every line and in the summary's owners, in the file itself.
@MainActor
final class NameVoices {
    private var window: NSWindow?
    /// Told when names are saved, so a window showing these notes can show the new names (D-1126).
    var saved: ((URL) -> Void)?

    /// Opens for `file`; false when its transcript has no voices to name (only Me and Others).
    @discardableResult
    func show(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let voices = Meeting.voices(inFile: text)
        guard voices.contains(where: { $0 != .me }) else { return false }
        let said = Meeting.said(Meeting.transcript(inFile: text))
        let rows = voices.map { v in
            NameVoicesView.Row(voice: v, name: v.rawValue,
                               sample: said.first { $0.speaker == v.rawValue && $0.text.split(separator: " ").count >= 4 }
                                   ?? said.first { $0.speaker == v.rawValue })
        }
        window?.close()
        let view = NameVoicesView(rows: rows, title: file.deletingPathExtension().lastPathComponent) { [weak self] changes in
            guard let changes else { self?.window?.close(); return nil }
            guard let now = try? String(contentsOf: file, encoding: .utf8),
                  let out = Meeting.renaming(changes.map { (Speaker(rawValue: $0.voice.rawValue), $0.name) }, in: now)
            else { return "A name can't be empty, Others or Paused, or hold : [ ] # or *." }
            do { try MeetingNotes.savePrivately(out, to: file) } catch { return "The notes file can't be saved." }
            Log.note("meeting: named \(changes.filter { $0.voice.rawValue != $0.name }.count) voices")
            self?.window?.close()
            self?.saved?(file)
            return nil
        }
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Name the voices"
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return true
    }
}

struct NameVoicesView: View {
    struct Row: Identifiable { var voice: Speaker; var name: String; var sample: Meeting.Said?; var id: String { voice.rawValue } }
    @State var rows: [Row]
    let title: String
    /// Saves the names (nil to cancel); returns why it couldn't, or nil when done.
    let done: ([(voice: Speaker, name: String)]?) -> String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            Text("Type a name for each voice. Every line and to-do in these notes changes with it.")
                .font(.system(size: 13)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            ForEach($rows) { $r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.voice.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text).frame(width: 90, alignment: .leading)
                        TextField("", text: $r.name).textFieldStyle(.roundedBorder)
                    }
                    if let s = r.sample {
                        Text("[\(Meeting.clock(s.at))] " + (s.text.count > 110 ? String(s.text.prefix(110)) + "…" : s.text))
                            .font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(2).padding(.leading, 98)
                    }
                }.padding(.top, 12)
            }
            if let problem { Text(problem).font(.system(size: 12.5)).foregroundStyle(Ink.red).padding(.top, 10) }
            HStack {
                Spacer()
                Button("Cancel") { _ = done(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { problem = done(rows.map { ($0.voice, $0.name) }) }.keyboardShortcut(.defaultAction)
            }.padding(.top, 16)
        }
        .padding(20).frame(width: 520).background(Ink.paper)
    }
}

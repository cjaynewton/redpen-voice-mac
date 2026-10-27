import AppKit
import SwiftUI
import VoiceCore

/// Your dictations (D-825): search them, copy one, delete one, and choose how long they're kept. Opened from the menu.
/// Everything stays in history.jsonl on this Mac.
@MainActor
final class HistoryWindow {
    private var window: NSWindow?
    let model: HistoryModel
    init(model: HistoryModel) { self.model = model }

    func show() {
        model.reload()
        if window == nil {
            Ink.registerFonts()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen Voice History"
            w.contentView = NSHostingView(rootView: HistoryView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            w.contentMinSize = NSSize(width: 460, height: 360)
            w.center(); w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var query = ""
    @Published var keep: String
    @Published var copied: Date?
    let history: History
    /// The choice changed: the app saves it and applies it to the file.
    var onKeep: (String) -> Void = { _ in }

    init(history: History, keep: String) { self.history = history; self.keep = keep }

    func reload() { entries = history.all().filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.reversed() }

    /// Newest first, matching every word typed in the search, in any order, ignoring case.
    var shown: [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in let t = (e.text + " " + e.app).lowercased(); return words.allSatisfy { t.contains($0) } }
    }

    func copy(_ e: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(e.text, forType: .string)
        copied = e.date
    }

    func delete(_ e: Entry) { history.remove(e); reload() }

    func setKeep(_ k: String) { keep = k; onKeep(k); reload() }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    /// Draw every row now (for a picture of the window); the window itself draws rows as they scroll into view.
    var eager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(Ink.serif(26)).foregroundStyle(Ink.text)
                Spacer()
                Text("Keep").font(.system(size: 13)).foregroundStyle(Ink.mid)
                Picker("", selection: Binding(get: { model.keep }, set: { model.setKeep($0) })) {
                    Text("The last 2,000").tag("all")
                    Text("The last week").tag("week")
                    Text("Nothing (clears the list)").tag("none")
                }.labelsHidden().frame(width: 200)
            }
            Text(model.keep == "none"
                 ? "Nothing is kept. Paste last still has your last dictation until Voice quits."
                 : "\(model.entries.count) \(model.entries.count == 1 ? "dictation" : "dictations"), kept only on this Mac, never the sound.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim).padding(.top, 2)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                TextField("Search", text: $model.query).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.line))
            .padding(.top, 16).padding(.bottom, 6)

            ScrollView {
                if eager { VStack(alignment: .leading, spacing: 0) { rows } } else { LazyVStack(alignment: .leading, spacing: 0) { rows } }
            }
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 360)
        .background(Ink.paper)
    }

    @ViewBuilder private var rows: some View {
        ForEach(Array(model.shown.enumerated()), id: \.offset) { _, e in
            row(e)
            Divider().overlay(Ink.line)
        }
        if model.shown.isEmpty {
            Text(model.query.isEmpty ? "Nothing here yet. Your dictations will show up here." : "No dictation has those words.")
                .font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 24)
        }
    }

    private func row(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.when(e.date)).foregroundStyle(Ink.dim)
                Text("·").foregroundStyle(Ink.dim)
                Text(e.app).foregroundStyle(Ink.dim)
                Spacer()
                Button(model.copied == e.date ? "Copied" : "Copy") { model.copy(e) }.buttonStyle(.plain).foregroundStyle(Ink.red)
                Button("Delete") { model.delete(e) }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            }
            .font(.system(size: 12.5))
            Text(e.text).font(Ink.body(16)).foregroundStyle(Ink.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    /// "Today 3:41 pm", "Yesterday 9:02 am", or the date for anything older.
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

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
    @State private var confirmClear = false
    @State private var appearanceRevision = 0

    init(model: HistoryModel, eager: Bool = false) {
        self.model = model
        self.eager = eager
    }

    var body: some View {
        let _ = appearanceRevision
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your words").font(.system(size: 25, weight: .semibold)).foregroundStyle(Ink.text)
                Spacer()
                Text("Keep").font(.system(size: 13)).foregroundStyle(Ink.mid)
                Picker("Keep dictations", selection: Binding(get: { model.keep }, set: { chooseRetention($0) })) {
                    Text("The last 2,000").tag("all")
                    Text("The last week").tag("week")
                    Text("Nothing").tag("none")
                }.labelsHidden().frame(width: 180).help("How long to keep dictations")
            }
            Text(model.keep == "none"
                 ? "Nothing is kept. Paste last still has your last dictation until Voice quits."
                 : "\(model.entries.count) \(model.entries.count == 1 ? "dictation" : "dictations"), kept only on this Mac, never the sound.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim).padding(.top, 2)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.dim)
                TextField("Search your dictations", text: $model.query).textFieldStyle(.plain).font(.system(size: 14))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Ink.subtle, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.border.opacity(0.6)))
            .padding(.top, 20).padding(.bottom, 8)

            ScrollView {
                if eager { VStack(alignment: .leading, spacing: 0) { rows } } else { LazyVStack(alignment: .leading, spacing: 0) { rows } }
            }
        }
        .padding(28)
        .frame(minWidth: 460, minHeight: 360)
        .background(Ink.paper)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceAppearanceChanged"))) { _ in appearanceRevision += 1 }
        .alert("Clear dictation history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear history", role: .destructive) { model.setKeep("none") }
        } message: {
            Text("Choosing Nothing clears the saved list and stops keeping future dictations. This cannot be undone. Your stats stay.")
        }
    }

    private func chooseRetention(_ keep: String) {
        guard keep != model.keep else { return }
        if keep == "none" { confirmClear = true }
        else { model.setKeep(keep) }
    }

    @ViewBuilder private var rows: some View {
        ForEach(Array(model.shown.enumerated()), id: \.offset) { _, e in
            row(e)
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
                Button("Delete") { model.delete(e) }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            }
            .font(.system(size: 12.5))
            Text(e.text).font(.system(size: 14)).foregroundStyle(Ink.text).textSelection(.enabled)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5).padding(.bottom, 8)
            Button { model.copy(e) } label: {
                Label(model.copied == e.date ? "Copied" : "Copy", systemImage: model.copied == e.date ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.text)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Ink.raised, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.border.opacity(0.6)))
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
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

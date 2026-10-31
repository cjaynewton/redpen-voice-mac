import AppKit
import SwiftUI
import VoiceCore

/// This copy of Redpen Voice and this Mac, in shapes that hold no names (D-1034).
enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown" }
    /// When this copy was built: its executable's date, new with every build even when the version number isn't.
    static var builtAt: String {
        guard let exe = Bundle.main.executableURL,
              let d = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date else { return "unknown" }
        return ISO8601DateFormatter().string(from: d)
    }
    /// After "launched" in the log, so the words-landed count knows when this build first started.
    static var buildLine: String { "\(version) (\(build)), built \(builtAt)" }
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    /// The model id, "MacBookPro18,2": the kind of Mac, never its name.
    static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// The main settings by name, as VoiceReport lists them. Never the microphone's name, a folder or a command.
    static func settings(_ c: Config) -> [(String, String)] {
        func on(_ b: Bool) -> String { b ? "on" : "off" }
        let key = c.talkKeyChoice.hasPrefix("key:") ? "other key" : c.talkKeyChoice
        return [
            ("engine", c.engine), ("language", c.locale), ("words", c.mode), ("talk key", key),
            ("double tap for hands-free", on(c.doubleTap ?? true)), ("Enter stops and sends", on(c.enterSends ?? true)),
            ("while I talk", c.whileTalking.rawValue), ("quick drafts", on(c.draftMode ?? false)),
            ("pause videos", on(c.pauseMedia)), ("play again after", on(c.resumeMedia ?? true)),
            ("point out words to check", on(c.riskMarks ?? false)), ("history kept", c.historyKeep ?? "all"),
            ("suggest words", on(c.suggestWords ?? true)), ("screen hints", on(c.screenHints ?? false)),
            ("sounds", on(c.sounds)), ("level bar", c.levelLook), ("appearance", c.appearance ?? "Mac"),
            ("microphone", c.inputDevice.isEmpty ? "Mac default" : "chosen"),
            ("better summary", c.betterSummaryWith ?? "off"), ("keep meeting audio", on(c.keepMeetingAudio ?? true)),
            ("meetings folder", c.meetingsFolder == nil ? "default" : "chosen"), ("typing speed", String(Int(c.typingSpeed))),
        ]
    }
}

/// Send a report (D-1034): shows exactly what the report holds before anything leaves the Mac, then Copy or Save to
/// Desktop. No network and no address: the tester sends it however they like.
@MainActor
final class SendReportWindow {
    private var window: NSWindow?
    let model: SendReportModel
    init(model: SendReportModel) { self.model = model }

    func show() {
        model.reload()
        if window == nil {
            Ink.registerFonts()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Send a Report"
            w.contentView = NSHostingView(rootView: SendReportView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            w.contentMinSize = NSSize(width: 480, height: 420)
            w.center(); w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SendReportModel: ObservableObject {
    /// Everything but the typed note, built when the window opens.
    @Published var base = ""
    @Published var note = ""
    @Published var done: String?
    /// Builds the report's counts and settings, from the log and config on this Mac.
    var build: () -> String

    init(build: @escaping () -> String) { self.build = build }

    func reload() { base = build(); done = nil }

    var report: String { base + VoiceReport.noteSection(note) }

    func copy() {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(report, forType: .string)
        done = "Copied. Paste it into an email or a message."
        Log.note("report: copied")
    }

    func saveToDesktop() {
        let desk = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmm"
        let stem = "Redpen Voice report \(f.string(from: Date()))"
        var url = desk.appendingPathComponent(stem + ".txt"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = desk.appendingPathComponent("\(stem) \(n).txt"); n += 1 }
        do {
            try Data(report.utf8).write(to: url, options: .withoutOverwriting)
            done = "Saved to the Desktop as \(url.lastPathComponent)."
            Log.note("report: saved to the Desktop")
        } catch {
            done = "Couldn't save to the Desktop. Copy it instead."
            Log.note("report: not saved, \(MeetingNotes.code(error))")
        }
    }
}

struct SendReportView: View {
    @ObservedObject var model: SendReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send a report").font(Ink.serif(26)).foregroundStyle(Ink.text)
            Text("This is everything in it. Counts and settings only, never your words, app names or file names. Nothing leaves this Mac until you send it yourself.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 2)

            TextField("What happened? (optional)", text: $model.note).textFieldStyle(.plain).font(.system(size: 14))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.line))
                .padding(.top, 16)
            Text("Only what you type here goes in as words.").font(.system(size: 12)).foregroundStyle(Ink.dim).padding(.top, 4)

            ScrollView {
                Text(model.report).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.line))
            .padding(.top, 14)

            HStack(alignment: .firstTextBaseline) {
                Text(model.done ?? "").font(.system(size: 12.5)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Copy") { model.copy() }
                Button("Save to Desktop") { model.saveToDesktop() }
            }
            .padding(.top, 14)
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 420)
        .background(Ink.paper)
    }
}

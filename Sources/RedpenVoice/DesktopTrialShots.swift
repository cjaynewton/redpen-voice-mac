import AppKit
import SwiftUI
import VoiceCore

/// Offscreen fixture rendering. Entered before AppDelegate exists, so normal recording, input taps,
/// updates, recovery and the watchdog never start. Nothing is loaded from the user's Voice folder.
@MainActor
enum DesktopTrialShots {
    static func run(to directory: URL) -> Int32 {
        let fixture = directory.appendingPathComponent("fixture", isDirectory: true)
        guard Config.dir.standardizedFileURL == fixture.standardizedFileURL,
              Log.url.standardizedFileURL == fixture.appendingPathComponent("render.log").standardizedFileURL else {
            print("Set REDPEN_VOICE_DIR to the output directory's fixture subfolder and REDPEN_VOICE_TEST_LOG to its render.log.")
            return 1
        }
        do { try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true) }
        catch { print("Cannot create fixture directory."); return 1 }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 21))!
        let sample = StatsModel.sample(now: now)
        let stats = StatsModel(typing: 40) { sample }
        stats.now = { now }; stats.landed = StatsModel.sampleLanded(now: now)
        var config = Config(); config.engine = "whisper"; config.firstRunDone = true
        let history = HistoryModel(history: History(url: fixture.appendingPathComponent("unused-history.jsonl")), keep: "all")
        history.entries = [
            Entry(date: now, raw: "I want the next version to feel lighter. Keep the things I use close by, and let everything else get out of the way.", seconds: 12, app: "Sample draft", inserted: true),
            Entry(date: now.addingTimeInterval(-1800), raw: "Let's keep the Friday meeting short and leave room for questions.", seconds: 6, app: "Sample message", inserted: true),
            Entry(date: now.addingTimeInterval(-7200), raw: "A small mark in the middle, then I can move it wherever I need it.", seconds: 8, app: "Sample note", inserted: false)
        ]
        let menu = MenuModel()
        menu.state.ready = true; menu.state.status = "Ready"; menu.state.engine = "Most accurate"
        menu.state.last = history.entries.first?.text
        let today = Stats.today(sample, now: now), total = Stats.score(sample)
        menu.state.todayWords = today.words; menu.state.todayWPM = today.wordsPerMinute; menu.state.todaySaved = today.minutesSaved
        menu.state.totalWords = total.words; menu.state.totalSaved = total.minutesSaved
        var files: [String] = []
        do {
            for palette in ["dark", "light", "colour"] {
                VoiceAppearance.apply(palette)
                var shown = config; shown.appearance = palette
                let settings = SettingsModel(config: shown, engine: Transcriber()) { _ in }
                settings.engineState = .ready; settings.summaryInstalled = []
                settings.statsTotal = { let score = Stats.score(sample); return (score.words, score.seconds) }
                guard HUD.captureStates(to: directory.appendingPathComponent(palette + "-bar", isDirectory: true)) == 0 else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                func shot<V: View>(_ name: String, _ view: V, size: NSSize? = nil) throws {
                    let v = NSHostingView(rootView: view.buttonBorderShape(.roundedRectangle(radius: 3)))
                    v.frame = NSRect(origin: .zero, size: size ?? v.fittingSize)
                    let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    w.appearance = NSApp.appearance; w.contentView = v
                    v.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                    v.layoutSubtreeIfNeeded(); v.display()
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
                    rep.size = v.bounds.size; v.cacheDisplay(in: v.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    let filename = "\(palette)-\(name).png"
                    try png.write(to: directory.appendingPathComponent(filename))
                    files.append(filename)
                    // Never ordered on screen, never key, never an input target.
                    guard !w.isVisible && !w.isKeyWindow else { throw CocoaError(.validationMissingMandatoryProperty) }
                }
                try shot("menu", MenuPanel(model: menu))
                try shot("meetings", MenuPanel(model: menu, initialTab: "meetings"))
                try shot("stats", StatsView(model: stats), size: NSSize(width: 640, height: 650))
                try shot("fun", StatsView(model: stats, initialSection: "fun"), size: NSSize(width: 640, height: 650))
                try shot("delivery", StatsView(model: stats, initialSection: "delivery"), size: NSSize(width: 640, height: 650))
                try shot("history", HistoryView(model: history, eager: true), size: NSSize(width: 640, height: 650))
                for section in ["General", "Talking", "Floating bar", "Names & words", "Meetings", "Advanced"] {
                    try shot("settings-" + section.lowercased().replacingOccurrences(of: " ", with: "-"), SettingsView(model: settings, initialSection: section), size: NSSize(width: 880, height: 720))
                }
            }
            let record: [String: Any] = ["files": files, "count": files.count, "syntheticData": true, "offscreen": true, "normalAppDelegateCreated": false]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("native-shots.json"))
        } catch { print("Native screenshot verification failed: \(error)"); return 1 }
        print("Rendered \(files.count) offscreen native fixtures. No normal Voice services started.")
        return 0
    }
}

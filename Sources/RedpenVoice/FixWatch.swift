import AppKit
import VoiceCore

/// After a dictation goes in, watches that text box for up to two minutes. When you fix a name Voice got wrong by
/// hand ("so well" to "Sowell"), it notices; the second time the same fix happens, the name goes into your word list
/// for good. It only reads the box it typed into, keeps nothing but the fix pairs (learned.json), and never logs words.
@MainActor
final class FixWatch {
    static let url = Config.dir.appendingPathComponent("learned.json")
    var onLearn: (Corrections.Fix) -> Void = { _ in }
    private var learned = Learned.load(FixWatch.url)
    private var typed = ""
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var box: String?
    private var until = Date()
    private var timer: Timer?
    /// Words pointed out to check in this dictation (D-817 test), lowercased. Counted against the words fixed by hand,
    /// numbers only (risk.json), to see whether pointed-out words get fixed far more often than the rest.
    var marked: Set<String>?
    static let tallyURL = Config.dir.appendingPathComponent("risk.json")

    /// Starts watching the focused box, which has just received `text`.
    func watch(_ text: String) {
        finish()
        guard text.split(separator: " ").count >= 2, let (el, pid) = Insert.focusedElement() else { return }
        typed = text; element = el; self.pid = pid; box = nil; until = Date().addingTimeInterval(120); marked = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func tick() {
        guard let el = element else { finish(); return }
        if Date() > until || NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { finish(); return }
        // Another box in the same app: judge the one Voice typed into, as it was last seen.
        if let (now, _) = Insert.focusedElement(), !CFEqual(now, el) { finish(); return }
        guard let v = Insert.value(el) else { finish(); return }
        // Emptied: sent or cleared. Judge the last full box.
        if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finish(); return }
        box = v
    }

    /// Stops watching and learns from the last look at the box.
    func finish() {
        timer?.invalidate(); timer = nil
        defer { element = nil; box = nil; typed = "" }
        guard let box, !typed.isEmpty else { return }
        let typed = self.typed, marked = self.marked
        // Matching runs off the main thread, so a long box never stalls typing or the talk key.
        Task.detached(priority: .utility) {
            let fixes = Corrections.find(typed: typed, now: box)
            if let marked { Self.tally(typed: typed, marked: marked, fixes: fixes) }
            guard !fixes.isEmpty else { return }
            await MainActor.run { self.learn(fixes) }
        }
    }

    /// Counts only: words pointed out and how many of them you fixed, the other words and how many of those.
    nonisolated static func tally(typed: String, marked: Set<String>, fixes: [Corrections.Fix]) {
        var t = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: tallyURL))) ?? [:]
        let words = typed.lowercased().split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let fixed = fixes.flatMap { $0.heard.lowercased().split(separator: " ").map(String.init) }
        let m = words.filter { marked.contains($0) }.count
        let mf = fixed.filter { marked.contains($0) }.count
        t["dictations", default: 0] += 1
        t["markedWords", default: 0] += m; t["markedFixed", default: 0] += mf
        t["otherWords", default: 0] += words.count - m; t["otherFixed", default: 0] += fixed.count - mf
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: tallyURL, options: .atomic) }
    }

    private func learn(_ fixes: [Corrections.Fix]) {
        var changed = false
        for f in fixes where Self.looksLikeAName(f.fixed) {
            changed = true
            if learned.see(f) { onLearn(f) }
        }
        if changed { learned.save(Self.url) }
    }

    /// Only names and terms are learned: a fix to an everyday word ("their" to "there") depends on the sentence and
    /// would be wrong elsewhere. A name has an unusual capital (iPhone, GitHub), two capitalised words (Claude Code),
    /// a digit, or a word the Mac's dictionary doesn't know (Sowell).
    static func looksLikeAName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        if s.contains(where: \.isNumber) { return true }
        if words.contains(where: { $0.dropFirst().contains(where: \.isUppercase) }) { return true }
        if words.count >= 2, words.filter({ $0.first?.isUppercase == true }).count >= 2 { return true }
        let lower = s.lowercased()
        return NSSpellChecker.shared.checkSpelling(of: lower, startingAt: 0).location != NSNotFound
    }
}

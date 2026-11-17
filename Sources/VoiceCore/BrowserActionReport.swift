import Foundation

/// Classifies a browser reply without exposing its error text, URLs, titles or page content.
/// Discovery also recovers confirmed pauses from the journal if the runner stopped before returning.
public struct BrowserActionReport {
    public let reply: BrowserPauseOperation.Reply
    public let fields: String

    public init(action: BrowserPauseOperation.Action, status: Int32, output: String, error: String,
                timedOut: Bool, journal: [String] = []) {
        let tokens = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
        var codes = journal.filter { $0.hasPrefix("?") }.compactMap { Int($0.split(separator: ":").last ?? "") }
        // osascript puts the AppleEvent error code at the end, in parentheses. Never retain the message.
        if let range = error.range(of: #"\(-?[0-9]+\)\s*$"#, options: .regularExpression),
           let code = Int(error[range].trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()) {
            codes.append(code)
        }
        codes = Array(Set(codes)).sorted()
        let denied = codes.contains(-1743) || error.lowercased().contains("not authorized")
        let refused = tokens.contains("refused") || error.contains("Apple Events") || error.contains("turned off")
        let timeout = timedOut || codes.contains(-1712) || tokens.contains("slow")
        let failed = status != 0 && !timeout && !denied && !refused
            || codes.contains { $0 != -1712 && $0 != -1743 } && !refused
        var confirmed = 0, attempted = 0, unansweredCount = 0
        let phase: String
        switch action {
        case .discover:
            phase = "discovery"
            var counts: [Int: Int] = [:]
            for line in journal.filter({ $0.hasPrefix("=") }).map({ String($0.dropFirst()) }) + tokens {
                let pair = line.split(separator: ":")
                if pair.count == 2, let tab = Int(pair[0]), let count = Int(pair[1]), count > 0 {
                    counts[tab] = count
                }
            }
            let parsed = BrowserMedia.discoveryJournal(journal, runnerStopped: timedOut || status != 0)
            let unanswered = parsed.unanswered.filter { counts[$0] == nil }
            let touched = Set(parsed.touched).union(counts.keys).sorted()
            confirmed = counts.count; attempted = touched.count; unansweredCount = unanswered.count
            reply = .discovered(counts: counts, touched: touched, slow: timeout, refused: refused,
                                unanswered: unanswered, failed: failed, notAllowed: denied)
        case .pause(_, _, let retry):
            phase = retry ? "retry" : "known"
            attempted = 1
            if timeout { reply = .timeout; unansweredCount = 1 }
            else if denied { reply = .notAllowed }
            else if status != 0 { reply = refused ? .refused : .failed }
            else if let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                reply = count < 0 ? .navigated : .paused(count); confirmed = count > 0 ? 1 : 0
            } else { reply = .empty }
        }
        let reason: String
        if denied { reason = "not_allowed" }
        else if timeout { reason = "timeout" }
        else if refused { reason = "scripts_off" }
        else if failed { reason = "runner_error" }
        else if confirmed > 0 { reason = "paused" }
        else if reply == .navigated { reason = "stale_page" }
        else { reason = "nothing_confirmed" }
        let codeList = codes.isEmpty ? "none" : codes.map(String.init).joined(separator: ",")
        fields = "phase=\(phase) reason=\(reason) exit=\(status) apple_errors=\(codeList) timed_out=\(timedOut ? 1 : 0) attempted=\(attempted) confirmed=\(confirmed) unanswered=\(unansweredCount)"
    }
}

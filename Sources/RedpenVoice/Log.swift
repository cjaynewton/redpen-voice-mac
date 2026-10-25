import Foundation

/// State changes in ~/Library/Logs/RedpenVoice.log: timings, app names, counts and errors. Never the words you said.
enum Log {
    /// A whole number for a log line that can never crash: infinite or NaN (a timing that never started) gives -1.
    /// A log line once crashed dictation this way (Oct 25 01:09, Whisper's first-word time).
    static func int(_ x: Double) -> Int { x.isFinite ? Int(max(-1e12, min(1e12, x))) : -1 }
    static func ms(_ seconds: Double) -> Int { int(seconds * 1000) }

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RedpenVoice.log")
    static let cap = 1_000_000
    nonisolated(unsafe) static var written = 0

    static func note(_ s: String) {
        if written % 500 == 0, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > cap {
            try? FileManager.default.removeItem(at: url)
        }
        written += 1
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600]) }
    }
}

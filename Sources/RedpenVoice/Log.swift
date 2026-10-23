import Foundation

/// State changes in ~/Library/Logs/RedpenVoice.log: timings, app names, counts and errors. Never the words you said.
enum Log {
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

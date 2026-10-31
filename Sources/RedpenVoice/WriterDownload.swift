import Foundation
import VoiceCore

/// Fetches a writer's files from Hugging Face over HTTPS at its pinned revision into a folder, one file at a time,
/// and checks each against its listed hash before keeping it. A file already there and matching is kept, so a
/// download stopped by a quit goes on where it was. Nothing is marked usable until every file has passed (D-1010).
final class WriterFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noSpace(need: Int64, free: Int64)
        case server(Int)
        case mismatch
        case network
        case cancelled
    }

    let writer: LocalWriter
    let files: [LocalWriter.File]
    let folder: URL
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var waiting: CheckedContinuation<Void, Error>?
    private var current: LocalWriter.File?
    private var base: Int64 = 0
    private var stopped = false
    private var lastReport = Date.distantPast
    private var progress: @Sendable (Int64) -> Void = { _ in }

    /// `files` is all of the writer's unless a test asks for fewer.
    init(writer: LocalWriter, files: [LocalWriter.File]? = nil, folder: URL) {
        self.writer = writer; self.files = files ?? writer.files; self.folder = folder
    }

    var total: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Downloads what is missing, reporting bytes done a few times a second. Throws a Failure.
    func run(progress: @escaping @Sendable (Int64) -> Void) async throws {
        self.progress = progress
        let fm = FileManager.default
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { throw Failure.noSpace(need: total, free: 0) }
        // Room for what is left, and 1 GB more for the Mac.
        let have = files.reduce(Int64(0)) { sum, f in
            let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(f.name).path)[.size] as? NSNumber)?.int64Value
            return sum + (size == f.size ? f.size : 0)
        }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if total - have + 1_000_000_000 > free { throw Failure.noSpace(need: total - have, free: free) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        base = 0
        for f in files {
            let dest = folder.appendingPathComponent(f.name)
            if LocalWriter.matches(f, at: dest, cancelled: { [weak self] in self?.isStopped ?? true }) {
                base += f.size; progress(base); continue
            }
            if isStopped { throw Failure.cancelled }
            try? fm.removeItem(at: dest)
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if stopped { c.resume(throwing: Failure.cancelled); return }
                    current = f; waiting = c
                    let t = session.downloadTask(with: URLRequest(url: writer.url(f)))
                    task = t
                    t.resume()
                }
            }
            guard LocalWriter.matches(f, at: dest, cancelled: { [weak self] in self?.isStopped ?? true }) else {
                try? fm.removeItem(at: dest)
                throw isStopped ? Failure.cancelled : Failure.mismatch
            }
            base += f.size
            progress(base)
        }
    }

    /// Stops the file in flight; `run` then throws `.cancelled`.
    func cancel() {
        lock.withLock { stopped = true; task?.cancel() }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func finish(_ error: Error?) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock { let c = waiting; waiting = nil; task = nil; return c }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.2, let f = lock.withLock({ current }) else { return }
        lastReport = now
        progress(base + min(totalBytesWritten, f.size))
    }

    /// The finished file goes into place here: URLSession deletes it when this returns.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let f = lock.withLock({ current }) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { finish(Failure.server(code)); return }
        let dest = folder.appendingPathComponent(f.name)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(nil)
        } catch {
            finish(Failure.network)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(isStopped || (error as NSError).code == NSURLErrorCancelled ? Failure.cancelled : Failure.network)
    }

    /// Hugging Face sends the big files from its storage servers: followed only over HTTPS.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    /// A plain line for Settings.
    static func message(_ e: Error) -> String {
        switch e as? Failure {
        case .noSpace(let need, let free)?:
            "Needs \(LocalWriter.gb(need + 1_000_000_000)) free on this Mac. It has \(LocalWriter.gb(free)) free now."
        case .server(let code)?: "Hugging Face didn't send the file (error \(code)). Try again later."
        case .mismatch?: "A downloaded file didn't match the one listed, so it was deleted. Try again."
        case .cancelled?: "Download cancelled."
        default: "The download stopped. Check the internet connection and try again."
        }
    }

    /// A short code for the log, never a file or folder name.
    static func code(_ e: Error) -> String {
        switch e as? Failure {
        case .noSpace?: "no space"
        case .server(let c)?: "server \(c)"
        case .mismatch?: "hash mismatch"
        case .cancelled?: "cancelled"
        default: "network"
        }
    }
}

/// The one writer download, for Settings: started, followed and cancelled there, and kept going when the window
/// closes (D-1010).
@MainActor
final class WriterDownloads: ObservableObject {
    static let shared = WriterDownloads()

    /// Bytes downloaded while a download runs; nil otherwise.
    @Published private(set) var done: Int64?
    @Published private(set) var error: String?
    /// Bumped when a copy appears or goes, so Settings looks at the disk again.
    @Published private(set) var changed = 0
    private var fetch: WriterFetch?

    var running: Bool { fetch != nil }

    func start(_ w: LocalWriter) {
        guard fetch == nil, LocalNotes.folder(w) == nil else { return }
        let f = WriterFetch(writer: w, folder: LocalNotes.own(w))
        fetch = f; done = 0; error = nil
        let t0 = Date()
        Log.note("notes writer: download started (\(w.id), \(w.sizeText))")
        Task.detached { [weak self] in
            do {
                try await f.run { n in Task { @MainActor in if self?.fetch === f { self?.done = n } } }
                try Data().write(to: f.folder.appendingPathComponent(LocalNotes.checkedMark))
                Log.note("notes writer: downloaded and checked (\(w.id)) in \(Log.int(Date().timeIntervalSince(t0)))s")
                await self?.ended(f, error: nil)
            } catch {
                Log.note("notes writer: download stopped (\(w.id)), \(WriterFetch.code(error))")
                // Cancelled means the user doesn't want it: what came down goes too.
                if (error as? WriterFetch.Failure) == .cancelled { LocalNotes.removeOwn(w) }
                await self?.ended(f, error: error)
            }
        }
    }

    private func ended(_ f: WriterFetch, error e: Error?) {
        guard fetch === f else { return }
        fetch = nil; done = nil
        if let e, (e as? WriterFetch.Failure) != .cancelled { error = WriterFetch.message(e) }
        changed += 1
    }

    func cancel() { fetch?.cancel() }

    /// Deletes Redpen's own copy only. A copy in Hugging Face's folder belongs to the tools that put it there.
    func remove(_ w: LocalWriter) {
        guard fetch == nil else { return }
        LocalNotes.removeOwn(w)
        Log.note("notes writer: removed (\(w.id))")
        error = nil; changed += 1
    }
}

extension LocalNotes {
    /// Deletes Redpen's copy of `w` and the folders it leaves empty, never anything outside Redpen's models folder.
    static func removeOwn(_ w: LocalWriter) { removeOwn(at: own(w)) }

    static func removeOwn(at folder: URL) {
        let fm = FileManager.default
        let root = Transcriber.modelsDir.appendingPathComponent("notes-writers", isDirectory: true).standardizedFileURL
        var dir = folder.standardizedFileURL
        guard dir.path.hasPrefix(root.path + "/") else { return }
        try? fm.removeItem(at: dir)
        dir = dir.deletingLastPathComponent()
        while dir.path == root.path || dir.path.hasPrefix(root.path + "/"), (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }
}

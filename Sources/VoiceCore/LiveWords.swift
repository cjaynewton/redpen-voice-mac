import Foundation

public enum LiveWordsTrack: String, Sendable, CaseIterable { case me, others }

/// One bounded hearing, with a stable identity while the unfinished line changes. Times are on the track's clock.
public struct LiveWordsPiece: Sendable {
    public var id: Int
    public var start: Double
    public var speechEnd: Double
    public var final: Bool
    public var audio: [Float]
}

/// 16 kHz audio, inspected in 30 ms frames. Keep a little lead-in, finish at 0.6 s of quiet or 15 s, and offer a
/// fresh hearing every 1.5 s while someone keeps talking. Silence alone never creates a line. No file access.
public struct LiveWordsSegmenter: Sendable {
    public static let rate = 16_000
    public static let frame = 480
    public static let maximum = 15 * rate
    private var pending: [Float] = []
    private var lead: [Float] = []
    private var line: [Float] = []
    private var cursor: Int
    private var from = 0, lastSpeech = 0, voiced = 0, lastPreview = 0, identity = 0
    private let threshold: Float

    public init(startSample: Int = 0, threshold: Float = 0.006) {
        cursor = startSample; self.threshold = threshold
    }

    public var bufferedSamples: Int { pending.count + lead.count + line.count }

    public mutating func push(_ audio: [Float]) -> [LiveWordsPiece] {
        pending.append(contentsOf: audio)
        var out: [LiveWordsPiece] = [], i = 0
        while i + Self.frame <= pending.count {
            if let done = consume(Array(pending[i..<(i + Self.frame)])) { out.append(done) }
            i += Self.frame
        }
        if i > 0 { pending.removeFirst(i) }
        return out
    }

    private mutating func consume(_ frame: [Float]) -> LiveWordsPiece? {
        let energy = frame.reduce(Float(0)) { $0 + ($1.isFinite ? $1 * $1 : 0) }
        let speech = (energy / Float(frame.count)).squareRoot() >= threshold
        defer { cursor += frame.count }
        if line.isEmpty {
            guard speech else {
                lead.append(contentsOf: frame)
                if lead.count > 3 * Self.frame { lead.removeFirst(lead.count - 3 * Self.frame) }
                return nil
            }
            from = cursor - lead.count
            line = lead; lead.removeAll(keepingCapacity: true)
        }
        line.append(contentsOf: frame)
        if speech { lastSpeech = line.count; voiced += frame.count }
        if line.count - lastSpeech >= 9_600 || line.count >= Self.maximum { return finishLine() }
        return nil
    }

    public mutating func preview() -> LiveWordsPiece? {
        guard voiced >= 1_920, lastSpeech - lastPreview >= 24_000 else { return nil }
        lastPreview = lastSpeech
        return piece(final: false)
    }

    /// Used at EOF by the file test. A real meeting discards unfinished words at Stop instead.
    public mutating func finish() -> LiveWordsPiece? {
        if !pending.isEmpty {
            let tail = pending; pending.removeAll()
            if let done = consume(tail) { return done }
        }
        return line.isEmpty ? nil : finishLine()
    }

    private func piece(final: Bool) -> LiveWordsPiece {
        LiveWordsPiece(id: identity, start: Double(from) / Double(Self.rate),
                       speechEnd: Double(from + lastSpeech) / Double(Self.rate), final: final,
                       audio: Array(line.prefix(min(line.count, lastSpeech + 2_400))))
    }

    private mutating func finishLine() -> LiveWordsPiece? {
        let done = voiced >= 1_920 ? piece(final: true) : nil
        line.removeAll(keepingCapacity: true)
        voiced = 0; lastSpeech = 0; lastPreview = 0; identity += 1
        return done
    }
}

public struct LiveWordsLine: Sendable, Equatable {
    public var track: LiveWordsTrack
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var final: Bool
    public init(track: LiveWordsTrack, id: Int, start: Double, end: Double, text: String, final: Bool) {
        self.track = track; self.id = id; self.start = start; self.end = end; self.text = text; self.final = final
    }
}

/// In-memory words only. Replacing a preview never duplicates its eventual finished line. Both tracks share time.
public struct LiveWordsLines: Sendable {
    public private(set) var lines: [LiveWordsLine] = []
    public init() {}
    public mutating func put(_ line: LiveWordsLine) {
        if let i = lines.firstIndex(where: { $0.track == line.track && $0.id == line.id }) {
            guard !lines[i].final else { return }
            if line.text.isEmpty { lines.remove(at: i) } else { lines[i] = line }
        } else if !line.text.isEmpty { lines.append(line) }
        lines.sort { $0.start == $1.start ? $0.track.rawValue < $1.track.rawValue : $0.start < $1.start }
    }
    public mutating func clear() { lines.removeAll() }
    public static func speaker(_ track: LiveWordsTrack, onCall: Bool) -> String {
        onCall ? (track == .me ? "You" : "Others") : ""
    }
}

/// Dictation never waits for this lock or for a live job to finish. A lease covers recording through the engine's
/// ending. An already submitted Core ML prediction cannot be preempted; its result waits and is reheard afterward.
public final class LiveWordsPriority: @unchecked Sendable {
    public static let shared = LiveWordsPriority()
    private let lock = NSLock()
    private var active: Set<UUID> = []
    private var epoch = 0
    public init() {}
    public var idleEpoch: Int? { lock.withLock { active.isEmpty ? epoch : nil } }
    public func isCurrent(_ value: Int) -> Bool { idleEpoch == value }
    public func begin() -> Lease {
        let id = UUID()
        lock.withLock { active.insert(id); epoch += 1 }
        return Lease(owner: self, id: id)
    }
    private func end(_ id: UUID) { lock.withLock { _ = active.remove(id) } }
    public final class Lease: @unchecked Sendable {
        private let owner: LiveWordsPriority
        private let id: UUID
        fileprivate init(owner: LiveWordsPriority, id: UUID) { self.owner = owner; self.id = id }
        public func end() { owner.end(id) }
        deinit { end() }
    }
}

import Foundation

/// The click to recover a saved meeting (D-1334). No providers or settings here; the app supplies those boundaries.
public enum MeetingNotesRetry {
    public enum Writer: String { case apple, claude }
    public typealias SummaryResult = (note: String, claudeFailed: String?, wrote: Bool, saveFailed: Bool)

    public enum Outcome: Equatable {
        case written, alreadyWritten, cancelled, fileUnavailable, saveFailed, appleUnavailable, empty

        public var message: String {
            switch self {
            case .written: "Notes written."
            case .alreadyWritten: "This meeting already has notes."
            case .cancelled: "Nothing was sent. You can try again when you're ready."
            case .fileUnavailable: "The notes file was moved, deleted or can't be read. Open it from its new location."
            case .saveFailed: "The notes couldn't be saved. Your transcript is kept."
            case .appleUnavailable: "Apple's model isn't available on this Mac right now. Your transcript is saved."
            case .empty: "Nothing was heard to summarise. Your transcript is kept."
            }
        }
    }

    /// Recheck after the question: a file may have moved while the user was deciding. Only an explicit yes can
    /// reach the Claude callback. An unanswered or dismissed question sends nothing, and has no timeout here.
    @MainActor
    public static func run(_ file: URL, claudeNotes: Bool?, ask: () async -> Bool?,
                           summarize: (URL, Writer) async -> SummaryResult) async -> Outcome {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .fileUnavailable }
        guard Meeting.needsNotes(inFile: text) else { return .alreadyWritten }
        let yes: Bool
        if let claudeNotes { yes = claudeNotes }
        else {
            guard let answer = await ask() else { return .cancelled }
            yes = answer
        }
        guard let now = try? String(contentsOf: file, encoding: .utf8) else { return .fileUnavailable }
        guard Meeting.needsNotes(inFile: now) else { return .alreadyWritten }
        let result = await summarize(file, yes ? .claude : .apple)
        guard (try? String(contentsOf: file, encoding: .utf8)) != nil else { return .fileUnavailable }
        if result.saveFailed { return .saveFailed }
        if result.wrote { return .written }
        if result.note == "cancelled" { return .cancelled }
        return result.note == "empty" ? .empty : .appleUnavailable
    }

    /// Transient page state only. Closing the window never schedules a new attempt or brings it back.
    public struct Presentation {
        public var message: String
        public var progress: Int?
        public var offerClaude: Bool
        public init(message: String = "", progress: Int? = nil, offerClaude: Bool = false) {
            self.message = message; self.progress = progress; self.offerClaude = offerClaude
        }
    }
}

import Foundation
import VoiceCore

/// Better summary (D-956): off unless chosen in Settings, and nothing is sent until the bar's button is clicked. It
/// goes through the user's own Claude, ChatGPT or Gemini plan, by each company's command-line tool (Claude Code,
/// Codex, Antigravity CLI), never an API key: the same programs, flags, time limits and messages as Redpen Grammar's
/// Deep check. Arguments go straight to the program, never through a shell, and the transcript goes in on stdin.
/// The answer gets the same check as Apple's summary before it goes into the notes.
enum BetterSummary {
    static let helpers = ["claude", "chatgpt", "gemini"]
    /// The fourth helper (D-1010): a writer downloaded to this Mac and run inside the app. Nothing leaves the Mac.
    static let onMac = "mac"

    static func name(_ h: String) -> String {
        h == onMac ? LocalNotes.writer?.name ?? "this Mac" : h == "chatgpt" ? "ChatGPT" : h == "gemini" ? "Gemini" : "Claude"
    }

    /// The bar offers a summary only from a helper that can write one: on this Mac, once the writer is downloaded.
    static func canOffer(_ h: String) -> Bool { h != onMac || LocalNotes.ready }

    /// The bar's button and its tip.
    static func button(_ h: String) -> String { h == onMac ? "Better summary on this Mac" : "Better summary with \(name(h))" }
    static func tip(_ h: String) -> String {
        h == onMac ? "Writes a second summary with \(name(h)) on this Mac and puts it on top of the notes. Nothing leaves the Mac."
                   : "Sends this meeting's transcript to \(name(h)) through your own plan, then puts its summary on top of the notes"
    }
    static func company(_ h: String) -> String { h == "chatgpt" ? "OpenAI" : h == "gemini" ? "Google" : "Anthropic" }
    static func tool(_ h: String) -> String { h == "chatgpt" ? "Codex" : h == "gemini" ? "the Antigravity CLI" : "Claude Code" }

    /// Where each tool's official installer, Homebrew or npm put it.
    static func path(_ h: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = h == "chatgpt" ? "codex" : h == "gemini" ? "agy" : "claude"
        var places = ["/opt/homebrew/bin/", "/usr/local/bin/", home + "/.local/bin/", home + "/.antigravity/bin/"].map { $0 + name }
        if h == "claude" { places.append(home + "/.claude/local/claude") }
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Installed and signed in. Starts the tool, which may ask its company's servers (Google's always does), so only
    /// once the user has chosen that helper, and never on the main thread.
    static func ready(_ h: String) -> Bool {
        guard let p = path(h) else { return false }
        switch h {
        case "chatgpt": return run(p, ["login", "status"]).localizedCaseInsensitiveContains("logged in using chatgpt")
        // Google's tool has no sign-in status command, but listing its models asks you to sign in first.
        case "gemini": let out = run(p, ["models"]); return !out.isEmpty && !out.localizedCaseInsensitiveContains("sign in")
        default: let out = run(p, ["auth", "status", "--json"]); return out.contains("\"loggedIn\": true") || out.contains("\"loggedIn\":true")
        }
    }

    /// The helpers installed on this Mac, in Settings order. Only looks for the files: starts nothing, sends nothing.
    static func installed() -> [String] { helpers.filter { path($0) != nil } }

    static let prompt = """
    Write meeting notes from the transcript on stdin. Each line starts with its time in brackets and a speaker. "Me" \
    is the person taking the notes. "Others" is everyone else on the call.

    Rules:
    - Use only what was said. Infer nothing. If you are not sure, leave it out.
    - Keep numbers, dates, amounts and goals exactly as they were said.
    - End every key point, decision and to-do with the time of the transcript line that says it, in square brackets, \
    exactly as written there, like [12:34].
    - A decision is something the people on the call agreed on.
    - A to-do is only a commitment or an ask: someone says they will do something ("I'll", "we'll", "I'm going to") \
    or asks someone to ("can you", "could you", "let's have Sam do"). Greetings, thanks and goodbyes are never to-dos.
    - Owners are Me, Others, or a name said in the transcript. Never invent a name. A to-do belongs to Me only when a \
    line marked Me says they will do it.
    - Leave out small talk: greetings, health, weather, thanks and goodbyes.
    - At most 10 key points, 6 decisions and 10 to-dos. Under a heading with nothing in it, write "None heard."
    - Plain words. No preamble, no closing remarks, no other headings.

    Answer in exactly this form:

    ### Overview
    Two or three sentences on what the meeting was about and where it ended up.

    ### Key points
    - One point. [mm:ss]

    ### Decisions
    - One decision. [mm:ss]

    ### To-dos
    - Owner: what they will do. [mm:ss]
    """

    // MARK: Running a tool

    struct Job: Sendable {
        let helper: String
        let path: String?
        let args: [String]
        let input: String?
        let answerFile: URL?
        /// An empty folder made for this run alone, deleted afterwards, so a tool that reads "the workspace" finds nothing.
        let folder: URL
    }

    /// Codex features that let the model act rather than answer.
    static let codexOff = ["shell_tool", "unified_exec", "shell_snapshot", "apps", "browser_use", "browser_use_external",
                           "in_app_browser", "computer_use", "image_generation", "view_image", "plugins",
                           "skill_search", "tool_suggest", "sleep_tool"]

    /// Claude Code with its tools, MCP servers, slash commands, hooks and the user's own settings and CLAUDE.md
    /// instructions off, so it can only read and answer, in the form asked. Codex
    /// read-only, without the user's config, rules, project instructions or web search, with its acting tools off,
    /// saving nothing. The Antigravity CLI in its sandbox with slash commands off; it reads the prompt from the
    /// command line, so the transcript goes there.
    static func job(_ h: String, prompt: String, input: String) -> Job {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-summary-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        switch h {
        case "chatgpt":
            let answer = folder.appendingPathComponent("answer.txt")
            return Job(helper: h, path: path(h),
                       args: ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                              "-s", "read-only", "-C", folder.path, "--color", "never",
                              "-c", "model_reasoning_effort=\"medium\"", "-c", "project_doc_max_bytes=0", "-c", #"web_search="disabled""#]
                           + codexOff.flatMap { ["--disable", $0] } + ["-o", answer.path, prompt],
                       input: input, answerFile: answer, folder: folder)
        case "gemini":
            return Job(helper: h, path: path(h),
                       args: ["-p", prompt + "\n\n<stdin>\n" + input + "\n</stdin>", "--output-format", "text",
                              "--sandbox", "--disable-slash-commands", "--effort", "high"],
                       input: nil, answerFile: nil, folder: folder)
        default:
            return Job(helper: h, path: path(h),
                       args: ["-p", prompt, "--model", "sonnet", "--output-format", "text",
                              "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                              "--setting-sources=", "--settings", #"{"disableAllHooks":true}"#],
                       input: input, answerFile: nil, folder: folder)
        }
    }

    /// Runs a job: the answer, or a plain reason it failed. Gives up after `limit` seconds, whatever stalls.
    static func call(_ job: Job, limit: TimeInterval = 300) -> (ok: Bool, text: String) {
        defer { try? FileManager.default.removeItem(at: job.folder) }
        guard let path = job.path else { return (false, missing(job.helper)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = job.args
        p.currentDirectoryURL = job.folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = job.input == nil ? FileHandle.nullDevice : inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        let out = Collected(), err = Collected()
        out.watch(outPipe.fileHandleForReading)
        err.watch(errPipe.fileHandleForReading)
        do { try p.run() } catch { return (false, "Couldn't start \(tool(job.helper)).") }
        if let input = job.input {
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async { try? writer.write(contentsOf: Data(input.utf8)); try? writer.close() }
        }
        if done.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            return (false, "\(name(job.helper)) didn't answer within \(Int(limit / 60)) minutes. Try again later.")
        }
        out.waitForEnd(seconds: 5)
        err.waitForEnd(seconds: 1)
        let raw = job.answerFile.flatMap { try? Data(contentsOf: $0) } ?? out.data
        let o = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 || o.isEmpty {
            let e = String(decoding: err.data, as: UTF8.self) + "\n" + o
            return (false, limitMessage(e, who: name(job.helper)) ?? "\(tool(job.helper)) returned an error (exit \(p.terminationStatus)).")
        }
        return (true, o)
    }

    /// A plain line when the plan has hit its usage limit, with the reset time if given.
    static func limitMessage(_ reply: String, who: String) -> String? {
        let l = reply.lowercased()
        guard ["quota", "rate limit", "usage limit", "resource_exhausted", "limit reached", "(code 429)"].contains(where: l.contains) else { return nil }
        var s = "Your \(who) plan has reached its limit for now."
        if let r = reply.range(of: #"[Rr]esets in [0-9hms ]+"#, options: .regularExpression) {
            s += " It " + reply[r].trimmingCharacters(in: .whitespaces).lowercased() + "."
        }
        return s
    }

    /// The sign-in step for each tool, in the words its own screen uses.
    static func signIn(_ h: String) -> String {
        switch h {
        case "chatgpt": "Open Terminal, type codex and press Return, then choose Sign in with ChatGPT."
        case "gemini": "Open Terminal, type agy and press Return, then sign in with your Google account."
        default: "Open Terminal, type claude and press Return, then sign in with your Claude account."
        }
    }

    static func missing(_ h: String) -> String {
        "Better summary with \(name(h)) needs \(tool(h)), signed in with your \(name(h)) plan."
    }

    /// Runs a tool with fixed arguments and returns what it printed; nothing after `limit` seconds.
    static func run(_ path: String, _ args: [String], limit: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        let c = Collected()
        c.watch(out.fileHandleForReading)
        do { try p.run() } catch { return "" }
        if done.wait(timeout: .now() + limit) == .timedOut { p.terminate(); return "" }
        c.waitForEnd(seconds: 2)
        return String(decoding: c.data, as: UTF8.self)
    }

    // MARK: Into the notes

    struct Outcome { let ok: Bool; let message: String; var checked: Meeting.Checked? = nil; var raw: Meeting.Summary? = nil }

    /// Asks the helper for a summary of the notes file's transcript, checks it, and puts it on top of the notes with
    /// Apple's kept below. The file is left as it was on any failure. Runs a tool for minutes: never on the main thread.
    static func write(file: URL, helper: String) -> Outcome {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return Outcome(ok: false, message: "The notes file can't be read.") }
        let transcript = Meeting.transcript(inFile: text).components(separatedBy: "\n").filter { $0.hasPrefix("[") }.joined(separator: "\n")
        guard !Meeting.said(transcript).isEmpty else { return Outcome(ok: false, message: "Nothing was heard to summarise.") }
        let t0 = Date()
        let answer = helper == onMac ? LocalNotes.answer(transcript) : call(job(helper, prompt: prompt, input: transcript))
        guard answer.ok else {
            Log.note("meeting: better summary failed (\(helper)) after \(Log.int(Date().timeIntervalSince(t0)))s")
            return Outcome(ok: false, message: answer.text)
        }
        guard let raw = Meeting.parse(written: answer.text) else {
            Log.note("meeting: better summary from \(helper) not in the expected form")
            return Outcome(ok: false, message: "\(name(helper))'s answer wasn't in the expected form. Your notes are unchanged.")
        }
        let checked = Meeting.check(raw, transcript: transcript)
        let label = helper == onMac ? Meeting.localLabel(name(helper)) : Meeting.betterLabel(name(helper))
        let section = Meeting.summaryMarkdown(checked, transcript: transcript, label: label)
        // Read again: the file may have been edited while the helper worked.
        guard let now = try? String(contentsOf: file, encoding: .utf8) else { return Outcome(ok: false, message: "The notes file can't be read.") }
        do {
            try MeetingNotes.savePrivately(Meeting.placingBetter(section, in: now), to: file)
        } catch {
            return Outcome(ok: false, message: "The notes file can't be saved.")
        }
        let s = checked.summary
        Log.note("meeting: better summary from \(helper) in \(Log.int(Date().timeIntervalSince(t0)))s, \(s.points.count) points, \(s.decisions.count) decisions, \(s.todos.count) to-dos; check moved \(checked.moved), left out \(checked.dropped), not tasks \(checked.notTasks), uncited \(checked.uncited)")
        return Outcome(ok: true, message: "\(name(helper))'s summary is in the notes", checked: checked, raw: raw)
    }
}

/// Bytes read from a pipe as they arrive, safe to read from any thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let ended = DispatchSemaphore(value: 0)

    var data: Data { lock.withLock { buffer } }

    func watch(_ h: FileHandle) {
        h.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { h.readabilityHandler = nil; return }
            if chunk.isEmpty { h.readabilityHandler = nil; self.ended.signal() } else { self.lock.withLock { self.buffer.append(chunk) } }
        }
    }

    func waitForEnd(seconds: Double) { _ = ended.wait(timeout: .now() + seconds) }
}

import Foundation

/// Pausing a video in Chrome by asking its tab, not by pressing the play/pause key. The key goes to whichever tab macOS
/// calls "Now Playing", and with several video tabs open that can be a paused one, so the key started a second video
/// instead of pausing the one you heard (Nov 1 2026, two Chrome windows, Prime Video beside YouTube). The tab is asked
/// to pause only what is playing out loud, marks what it paused, and later plays only those back.
public enum BrowserMedia {
    public static let chromeBundleID = "com.google.Chrome"
    static let mark = "data-redpen-paused"

    /// Letters and digits only, so the token can sit inside the page script as plain text.
    public static func token() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    static func clean(_ token: String) -> String { token.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    /// Pauses every video and song on the page that is playing out loud (muted previews are left alone), marks each
    /// with the token, and returns how many. Marks left from an earlier pause are cleared first.
    public static func pauseScript(token: String) -> String {
        let t = clean(token)
        return "(function(){var n=0;document.querySelectorAll('[\(mark)]').forEach(function(m){m.removeAttribute('\(mark)')});"
            + "document.querySelectorAll('video,audio').forEach(function(m){if(!m.paused&&!m.ended&&!m.muted&&m.volume>0)"
            + "{m.pause();m.setAttribute('\(mark)','\(t)');n++}});return n})()"
    }

    /// Plays back only what the pause with this token marked, if it is still paused, and returns how many.
    public static func resumeScript(token: String) -> String {
        let t = clean(token)
        return "(function(){var n=0;document.querySelectorAll('[\(mark)=\"\(t)\"]').forEach(function(m){m.removeAttribute('\(mark)');"
            + "if(m.paused){var p=m.play();if(p&&p.catch)p.catch(function(){});n++}});return n})()"
    }

    /// Runs a page script in Chrome tabs and prints "tab id:count" for each tab where the count is above zero.
    /// Arguments: the script, then "front" (the tab showing in each window) or "all". A page that can't run scripts
    /// (a Chrome settings page) is skipped; scripts turned off or Voice not allowed stops the run with Chrome's error.
    public static let pauseRunner = """
    on run argv
    \tset js to item 1 of argv
    \tset onlyFront to (item 2 of argv is "front")
    \tset found to {}
    \ttell application id "\(chromeBundleID)"
    \t\trepeat with w in windows
    \t\t\tif onlyFront then
    \t\t\t\tset ts to {active tab of w}
    \t\t\telse
    \t\t\t\tset ts to tabs of w
    \t\t\tend if
    \t\t\trepeat with t in ts
    \t\t\t\ttry
    \t\t\t\t\tset r to execute t javascript js
    \t\t\t\t\tif r is not missing value and (r as integer) > 0 then set end of found to ((id of t) as text) & ":" & ((r as integer) as text)
    \t\t\t\ton error msg number n
    \t\t\t\t\tif n is -1743 or msg contains "Apple Events" or msg contains "turned off" then error msg number n
    \t\t\t\tend try
    \t\t\tend repeat
    \t\tend repeat
    \tend tell
    \tset AppleScript's text item delimiters to ","
    \treturn found as text
    end run
    """

    /// Runs a page script in the tabs with these ids only, wherever they are now. Same output as the pause runner.
    /// Ids are matched as text: Chrome's tab ids pass AppleScript's integer limit (536,870,911), so "as integer" turned
    /// 1388772979 into a decimal that matched no tab and nothing came back (Nov 1 2026, every resume "nothingFound").
    public static let resumeRunner = """
    on run argv
    \tset js to item 1 of argv
    \tset wanted to items 2 thru -1 of argv
    \tset found to {}
    \ttell application id "\(chromeBundleID)"
    \t\trepeat with w in windows
    \t\t\trepeat with t in tabs of w
    \t\t\t\tset tid to (id of t) as text
    \t\t\t\tif wanted contains tid then
    \t\t\t\t\ttry
    \t\t\t\t\t\tset r to execute t javascript js
    \t\t\t\t\t\tif r is not missing value then set end of found to tid & ":" & ((r as integer) as text)
    \t\t\t\t\ton error msg number n
    \t\t\t\t\t\tif n is -1743 or msg contains "Apple Events" or msg contains "turned off" then error msg number n
    \t\t\t\t\tend try
    \t\t\t\tend if
    \t\t\tend repeat
    \t\tend repeat
    \tend tell
    \tset AppleScript's text item delimiters to ","
    \treturn found as text
    end run
    """

    public enum Outcome: Equatable {
        /// Paused or played in these tabs (ids), with how many videos or songs in all.
        case handled(tabs: [Int], count: Int)
        /// Chrome answered, but no tab had anything playing out loud that a page script can reach (a video inside
        /// another site's frame, say). The key is the fallback.
        case nothingFound
        /// Chrome's "Allow JavaScript from Apple Events" is off.
        case scriptsOff
        /// The Mac said no to Voice controlling Chrome (Privacy & Security, Automation).
        case notAllowed
        case failed(String)
    }

    /// Reads what osascript printed. Chrome's error for scripts turned off says "Allow JavaScript from Apple Events";
    /// -1743 is the Mac refusing Automation.
    public static func outcome(status: Int32, output: String, error: String) -> Outcome {
        guard status == 0 else {
            if error.contains("-1743") || error.lowercased().contains("not authorized") { return .notAllowed }
            if error.contains("Apple Events") || error.contains("turned off") { return .scriptsOff }
            return .failed(String(error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))
        }
        var tabs: [Int] = [], count = 0
        for part in output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
            let bits = part.split(separator: ":")
            guard bits.count == 2, let tab = Int(bits[0].trimmingCharacters(in: .whitespaces)),
                  let n = Int(bits[1].trimmingCharacters(in: .whitespaces)) else { continue }
            if n > 0 { tabs.append(tab); count += n }
        }
        return tabs.isEmpty ? .nothingFound : .handled(tabs: tabs, count: count)
    }

    /// True when the sound comes from Chrome: its helper processes live inside Google Chrome.app.
    public static func isChrome(path: String) -> Bool { path.contains("/Google Chrome.app/") }
}

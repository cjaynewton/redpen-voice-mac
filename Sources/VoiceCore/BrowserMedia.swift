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
    public static func cleanIdentity(_ value: String) -> String { clean(value) }
    static func clean(_ token: String) -> String { token.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    /// Probe and pause are separate bounded actions. Document identity and element references never leave the page.
    /// Navigation loses this registry, so a retry cannot act on a replacement document in the same tab.
    public static func probeScript(token: String, document: String, expires: Double, inheriting: [String] = []) -> String {
        let t = clean(token), d = clean(document)
        let inherited = inheriting.map { "'\(clean($0))'" }.joined(separator: ",")
        return "(function(){if(Date.now()>\(expires)){return ''}var r=window.__redpenMedia||(window.__redpenMedia=Object.create(null));"
            + "if(r['\(t)']&&r['\(t)'].cancelled)return '';var old=[\(inherited)];"
            + "var items=Array.from(document.querySelectorAll('video,audio')).filter(function(m){var owners=(m.getAttribute('\(mark)')||'').split(' ');return (!m.paused&&!m.ended&&!m.muted&&m.volume>0)||(m.paused&&owners.some(function(v){return v&&(old.indexOf(v)>=0||(m.__redpenOwners&&m.__redpenOwners[v]=='live'))}))});"
            + "if(!items.length)return '';r['\(t)']={doc:'\(d)',items:items,cancelled:false};return '\(d)'})()"
    }

    /// First pause creates its document fence and acts in the same page call. The timestamp rejects an older
    /// recording even if its AppleEvent arrives after a newer recording has already visited this page.
    public static func directPauseScript(token: String, document: String, expires: Double,
                                         started: Double, inheriting: [String] = []) -> String {
        let t = clean(token), d = clean(document)
        return "(function(){if(Date.now()>\(expires)||((window.__redpenLatest||0)>\(started)))return -1;"
            + "window.__redpenLatest=\(started);var all=window.__redpenMedia||(window.__redpenMedia=Object.create(null));"
            + "if(all['\(t)']&&all['\(t)'].cancelled)return -1;"
            + "if(!all['\(t)'])all['\(t)']={doc:'\(d)',started:\(started),items:Array.from(document.querySelectorAll('video,audio')),cancelled:false};"
            + "return " + pauseScript(token: token, document: document, expires: expires, inheriting: inheriting) + "})()"
    }

    /// Each element has explicit live/sealed owner status. Playback ends the old hold, even if its native resume
    /// failed. An audible element also proves that all its previous holds ended, including marks from older builds.
    /// An inherited paused element gets the new owner's mark before the old owner is sealed.
    public static func pauseScript(token: String, document: String? = nil, expires: Double = 9e15,
                                   inheriting: [String] = []) -> String {
        let t = clean(token)
        let inherited = inheriting.map { "'\(clean($0))'" }.joined(separator: ",")
        let selection: String
        if let document {
            selection = "var r=window.__redpenMedia&&window.__redpenMedia['\(t)'];if(!r||r.cancelled||(r.started&&(window.__redpenLatest||0)>r.started)||r.doc!='\(clean(document))')return -1;var items=r.items;"
        } else { selection = "var items=Array.from(document.querySelectorAll('video,audio'));" }
        return "(function(){if(Date.now()>\(expires))return -1;var n=0;var old=[\(inherited)];" + selection
            + "items.forEach(function(m){if(!m.isConnected)return;var owners=(m.getAttribute('\(mark)')||'').split(' ').filter(Boolean);var status=m.__redpenOwners||(m.__redpenOwners=Object.create(null));"
            + "var audible=!m.paused&&!m.ended&&!m.muted&&m.volume>0;var adopt=m.paused&&owners.some(function(v){return old.indexOf(v)>=0||status[v]=='live'});"
            + "if(audible){owners.forEach(function(v){status[v]='sealed'});try{m.pause()}catch(e){}}"
            + "if(m.paused&&(audible||adopt)){status['\(t)']='live';if(owners.indexOf('\(t)')<0)owners.push('\(t)');"
            + "old.forEach(function(v){status[v]='sealed';var registry=window.__redpenMedia;if(registry&&registry[v])registry[v]={cancelled:true}});"
            + "if(!m.__redpenPlaybackWatch&&m.addEventListener){m.__redpenPlaybackWatch=true;m.addEventListener('play',function(){if(m.paused)return;Object.keys(m.__redpenOwners).forEach(function(v){m.__redpenOwners[v]='sealed'})})}}"
            + "owners=owners.filter(function(v){return status[v]!='sealed'});if(owners.length)m.setAttribute('\(mark)',owners.join(' '));else m.removeAttribute('\(mark)');"
            + "Object.keys(status).forEach(function(v){if(owners.indexOf(v)<0)delete status[v]});"
            + "if(m.paused&&owners.indexOf('\(t)')>=0)n++});return n})()"
    }

    /// Seal held tokens. Exact dispatched tabs may also seal an unseen token before a late direct pause arrives.
    /// Drop sealed foreign marks, but never play while a remaining live owner holds this element.
    public static func resumeScript(token: String, play: Bool = true, inheriting: [String] = [], sealUnseen: Bool = false) -> String {
        let t = clean(token)
        let tokens = (inheriting.map(clean) + [t]).map { "'\($0)'" }.joined(separator: ",")
        let seal = sealUnseen ? "r=window.__redpenMedia||(window.__redpenMedia=Object.create(null));tokens.forEach(function(v){r[v]={cancelled:true}});" : ""
        return "(function(){var n=0;var tokens=[\(tokens)];var r=window.__redpenMedia;" + seal
            + "var marked=Array.from(document.querySelectorAll('[\(mark)~=\"\(t)\"]'));"
            + "if(tokens.length>1)marked=Array.from(document.querySelectorAll('video,audio')).filter(function(m){var owners=(m.getAttribute('\(mark)')||'').split(' ');return tokens.some(function(v){return owners.indexOf(v)>=0})});"
            + "if(r)tokens.forEach(function(v){if(r[v])r[v]={cancelled:true}});"
            + "var audible=Array.from(document.querySelectorAll('video,audio')).some(function(m){return !m.paused&&!m.ended&&!m.muted&&m.volume>0});"
            + "marked.forEach(function(m){var status=m.__redpenOwners||(m.__redpenOwners=Object.create(null));var held=(m.getAttribute('\(mark)')||'').split(' ').some(function(v){return tokens.indexOf(v)>=0&&status[v]!='sealed'});tokens.forEach(function(v){status[v]='sealed'});"
            + "var rest=(m.getAttribute('\(mark)')||'').split(' ').filter(function(v){return v&&status[v]!='sealed'});if(rest.length)m.setAttribute('\(mark)',rest.join(' '));else m.removeAttribute('\(mark)');"
            + "Object.keys(status).forEach(function(v){if(rest.indexOf(v)<0)delete status[v]});"
            + "if(\(play ? "true" : "false")&&held&&!rest.length&&!audible&&m.paused){var p=m.play();if(p&&p.catch)p.catch(function(){});n++}});return n})()"
    }

    /// One discovery process, stopping at the first successful tab. IDs are journalled BEFORE execute so a
    /// timeout still supplies exact reconciliation targets. A tab that times out is journalled again with "!"
    /// in front. The journal contains only numeric IDs and that mark, never URLs.
    public static let discoveryRunner = """
    on run argv
        set js to item 1 of argv
        set journalPath to item 2 of argv
        set permitPath to item 3 of argv
        set excluded to items 4 thru -1 of argv
        set slow to false
        set refused to false
        set ordered to my orderedTabs()
        repeat with t in ordered
            set tid to ""
            try
                try
                    if (read POSIX file permitPath) is not "1" then return ""
                on error
                    return ""
                end try
                set tid to my tabID(contents of t)
                if excluded does not contain tid then
                    -- Closing the file before execute makes even a killed process's target recoverable.
                    set journal to open for access POSIX file journalPath with write permission
                    try
                        write (tid & linefeed) to journal starting at eof
                        close access journal
                    on error msg number n
                        close access journal
                        error msg number n
                    end try
                    set result to my pauseTab(contents of t, js)
                    if result is not missing value and (result as integer) > 0 then return tid & ":" & (result as text)
                end if
            on error msg number n
                if n is -1743 then error msg number n
                if n is -1712 then
                    set slow to true
                    -- Name the tab that never answered, so only it gets a second look when the talking ends.
                    if tid is not "" then
                        try
                            set journal to open for access POSIX file journalPath with write permission
                            write ("!" & tid & linefeed) to journal starting at eof
                            close access journal
                        on error
                            try
                                close access POSIX file journalPath
                            end try
                        end try
                    end if
                end if
                if msg contains "Apple Events" or msg contains "turned off" then set refused to true
            end try
        end repeat
        if slow then return "slow"
        if refused then return "refused"
        return ""
    end run

    on orderedTabs()
        set fronts to {}
        set likely to {}
        set others to {}
        set sites to {\(mediaSites.map { "\"\($0)\"" }.joined(separator: ", "))}
        tell application id "\(chromeBundleID)"
            with timeout of 1 second
                repeat with w in windows
                    try
                    set ts to tabs of w
                    set us to URL of tabs of w
                    set activeIndex to 0
                    try
                        set activeIndex to active tab index of w
                    end try
                    repeat with i from 1 to count of ts
                        if i is activeIndex then
                            set end of fronts to item i of ts
                        else
                            set onSite to false
                            repeat with site in sites
                                if (item i of us) contains (contents of site) then set onSite to true
                            end repeat
                            if onSite then
                                set end of likely to item i of ts
                            else
                                set end of others to item i of ts
                            end if
                        end if
                    end repeat
                    on error msg number n
                        if n is -1743 then error msg number n
                        -- One unreadable window cannot prevent checking the others.
                    end try
                end repeat
            end timeout
        end tell
        return fronts & likely & others
    end orderedTabs

    on tabID(t)
        tell application id "\(chromeBundleID)"
            with timeout of 1 second
                return (id of t) as text
            end timeout
        end tell
    end tabID

    on pauseTab(t, js)
        tell application id "\(chromeBundleID)"
            with timeout of 1 second
                return execute t javascript js
            end timeout
        end tell
    end pauseTab
    """

    /// One bounded phase per process. Site URLs order background candidates inside AppleScript only.
    /// Only opaque IDs, a generated document identity or a count leave the runner. No page text or titles.
    public static let actionRunner = """
    on run argv
        set phase to item 1 of argv
        tell application id "\(chromeBundleID)"
            with timeout of 1 second
                if phase is "windows" then
                    return (id of windows) as list
                else if phase is "tabs" or phase is "front" then
                    set wid to item 2 of argv
                    set sites to {\(mediaSites.map { "\"\($0)\"" }.joined(separator: ", "))}
                    repeat with w in windows
                        if ((id of w) as text) is wid then
                            set frontID to (id of active tab of w) as text
                            if phase is "front" then return frontID
                            set found to {frontID}
                            set others to {}
                            set tids to id of tabs of w
                            set urls to URL of tabs of w
                            repeat with i from 1 to count of tids
                                set tid to (item i of tids) as text
                                if tid is not frontID then
                                    set likely to false
                                    repeat with site in sites
                                        if (item i of urls) contains (contents of site) then set likely to true
                                    end repeat
                                    if likely then
                                        set end of found to tid
                                    else
                                        set end of others to tid
                                    end if
                                end if
                            end repeat
                            set found to found & others
                            set AppleScript's text item delimiters to ","
                            return found as text
                        end if
                    end repeat
                    return ""
                else
                    set tid to item 2 of argv
                    set js to item 3 of argv
                    repeat with w in windows
                        repeat with t in tabs of w
                            if ((id of t) as text) is tid then return execute t javascript js
                        end repeat
                    end repeat
                    return ""
                end if
            end timeout
        end tell
    end run
    """

    /// Runs a page script in Chrome tabs and prints "tab id:count" for each tab where the count is above zero.
    /// Arguments: the script, then "first" or "every". The tabs go in three rounds: the tab showing in each window,
    /// then tabs on video and music sites, then the rest. "first" stops after the first round that finds something
    /// (a pause); "every" runs all three (a resume whose tabs were never learned). Each tab gets one second: a page that
    /// is busy or asleep is skipped instead of holding up the pause (Nov 2 2026, a pause that took over 2.5 s). A page
    /// that can't run scripts (a Chrome settings page) is skipped too, and so is a tab in a Chrome profile with scripts
    /// turned off: the switch is per profile, and one refusing window used to stop the whole run (Nov 2 2026, 08:49).
    /// "refused" is printed only when nothing was found and some tab refused. Voice not allowed stops the run.
    public static let pauseRunner = """
    property slow : false
    property refused : false

    on run argv
    \tset js to item 1 of argv
    \tset untilFound to (item 2 of argv is "first")
    \tset sites to {\(mediaSites.map { "\"\($0)\"" }.joined(separator: ", "))}
    \tset fronts to {}
    \tset likely to {}
    \tset others to {}
    \ttell application id "\(chromeBundleID)"
    \t\trepeat with w in windows
    \t\t\tset a to active tab index of w
    \t\t\tset ts to tabs of w
    \t\t\tset us to URL of tabs of w
    \t\t\trepeat with i from 1 to count of ts
    \t\t\t\tif i is a then
    \t\t\t\t\tset end of fronts to item i of ts
    \t\t\t\telse
    \t\t\t\t\tset onSite to false
    \t\t\t\t\trepeat with h in sites
    \t\t\t\t\t\tif (item i of us) contains (contents of h) then set onSite to true
    \t\t\t\t\tend repeat
    \t\t\t\t\tif onSite then
    \t\t\t\t\t\tset end of likely to item i of ts
    \t\t\t\t\telse
    \t\t\t\t\t\tset end of others to item i of ts
    \t\t\t\t\tend if
    \t\t\t\tend if
    \t\t\tend repeat
    \t\tend repeat
    \tend tell
    \tset found to my runIn(js, fronts)
    \tif not (untilFound and found is not {}) then set found to found & my runIn(js, likely)
    \tif not (untilFound and found is not {}) then set found to found & my runIn(js, others)
    \tif slow then set end of found to "slow"
    \tif refused and found is {} then set end of found to "refused"
    \tset AppleScript's text item delimiters to ","
    \treturn found as text
    end run

    on runIn(js, ts)
    \tset found to {}
    \ttell application id "\(chromeBundleID)"
    \t\trepeat with t in ts
    \t\t\ttry
    \t\t\t\twith timeout of 1 second
    \t\t\t\t\tset r to execute (contents of t) javascript js
    \t\t\t\tend timeout
    \t\t\t\tif r is not missing value and (r as integer) > 0 then set end of found to ((id of (contents of t)) as text) & ":" & ((r as integer) as text)
    \t\t\ton error msg number n
    \t\t\t\tif n is -1743 then error msg number n
    \t\t\t\tif n is -1712 then set slow to true
    \t\t\t\tif msg contains "Apple Events" or msg contains "turned off" then set refused to true
    \t\t\tend try
    \t\tend repeat
    \tend tell
    \treturn found
    end runIn
    """

    /// Video and music sites, checked right after the tabs on show.
    static let mediaSites = ["youtube.", "netflix.", "primevideo.", "amazon.", "disneyplus.", "crave.ca", "max.com",
                             "hulu.", "paramountplus.", "tv.apple.", "music.apple.", "spotify.", "twitch.", "vimeo.",
                             "soundcloud.", "dazn.", "tsn.", "sportsnet.", "zwift.", "peacocktv."]

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
    \t\t\t\t\t\twith timeout of 1 second
    \t\t\t\t\t\t\tset r to execute t javascript js
    \t\t\t\t\t\tend timeout
    \t\t\t\t\t\tif r is not missing value then set end of found to tid & ":" & ((r as integer) as text)
    \t\t\t\t\ton error msg number n
    \t\t\t\t\t\tif n is -1743 then error msg number n
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

    /// Whether a Chrome answer that paused nothing falls back to the play/pause key. Only when Voice heard sound: after
    /// a quiet listen the key would land on a quiet Mac and start music or a paused video (Nov 9 2026, three misses
    /// in a quiet moment of a video, loudness 0.0000 to 0.0012).
    public static func keyAfterQuietCheck(_ outcome: Outcome, chromeOnly: Bool) -> Bool {
        if chromeOnly { return false }
        if case .handled = outcome { return false }
        return true
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
        // A tab too slow to answer may still pause later, so pressing the key then could start a second video.
        if tabs.isEmpty, output.contains("slow") { return .failed("slow") }
        if tabs.isEmpty, output.contains("refused") { return .scriptsOff }
        return tabs.isEmpty ? .nothingFound : .handled(tabs: tabs, count: count)
    }

    /// How many videos one tab played again on release. A clean answer with no number means the tab is closed
    /// or its page was replaced: nothing of ours is left there, so it counts as cleared (0). nil only when
    /// Chrome did not answer.
    public static func resumeCount(status: Int32, output: String, timedOut: Bool) -> Int? {
        guard status == 0, !timedOut else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Reads the discovery journal: one line per tab asked, written before the ask, and "!" plus the tab for
    /// each one that timed out. A runner stopped mid-ask leaves its last tab with no answer either.
    public static func discoveryJournal(_ lines: [String], runnerStopped: Bool) -> (touched: [Int], unanswered: [Int]) {
        let touched = lines.compactMap { Int($0) }
        var unanswered = lines.compactMap { $0.hasPrefix("!") ? Int($0.dropFirst()) : nil }
        if runnerStopped, let last = lines.last.flatMap({ Int($0) }), !unanswered.contains(last) { unanswered.append(last) }
        return (touched, unanswered)
    }

    /// True when the sound comes from Chrome: its helper processes live inside Google Chrome.app.
    public static func isChrome(path: String) -> Bool { path.contains("/Google Chrome.app/") }
}

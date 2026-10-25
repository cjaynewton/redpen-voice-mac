import Foundation

/// Whether the cursor is in a place that takes typed words, from what Accessibility says about the focused element.
/// Typing into anything else is worse than useless: on a web page, letters are shortcuts (on YouTube "k" plays,
/// "f" goes full screen, numbers jump in the video).
public enum FocusKind: String, Sendable { case text, notText, unknown }

public enum FocusGate {
    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Never take typed words, in any app.
    public static let controls: Set<String> = [
        "AXButton", "AXLink", "AXStaticText", "AXImage", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell",
        "AXMenuItem", "AXMenuBar", "AXCheckBox", "AXRadioButton", "AXSlider", "AXTabGroup", "AXToolbar",
        "AXPopUpButton", "AXBrowser", "AXColumn", "AXDisclosureTriangle", "AXIncrementor",
    ]
    /// Boxes around other things. In a browser they are the page (a video player, a feed). Elsewhere they can be
    /// an editor's own frame: Word sometimes names its page area as focused while you type in it.
    public static let containers: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXWindow", "AXApplication"]

    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// `role` nil means Accessibility named no focused element (Electron apps often don't): unknown, so the words
    /// are typed as before. Only editable evidence makes a place text: a selected range alone is not, since a web
    /// page reports one for any selected words.
    public static func kind(role: String?, editableAncestor: Bool, valueSettable: Bool, inBrowser: Bool) -> FocusKind {
        guard let role, !role.isEmpty else { return .unknown }
        if textRoles.contains(role) || editableAncestor { return .text }
        if valueSettable, !controls.contains(role) { return .text }
        if role == "AXWebArea" || controls.contains(role) { return .notText }
        if containers.contains(role) { return inBrowser ? .notText : .unknown }
        return .unknown
    }
}

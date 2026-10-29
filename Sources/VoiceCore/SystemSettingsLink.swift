import Foundation

/// Current Settings extension IDs, with the legacy pane tried only if opening the current URL fails.
/// IDs and anchors checked in Apple's installed ExtensionKit bundles, 2026-10-29.
public enum SystemSettingsLink: CaseIterable {
    case accessibility, microphone, systemAudio, keyboard

    private var anchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .microphone: return "Privacy_Microphone"
        case .systemAudio: return "Privacy_AudioCapture"
        case .keyboard: return ""
        }
    }

    public var url: URL {
        let pane = self == .keyboard ? "com.apple.Keyboard-Settings.extension" : "com.apple.settings.PrivacySecurity.extension?\(anchor)"
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    public var fallbackURL: URL {
        let pane = self == .keyboard ? "com.apple.preference.keyboard" : "com.apple.preference.security?\(anchor)"
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    @discardableResult
    public func open(using openURL: (URL) -> Bool) -> Bool {
        openURL(url) || openURL(fallbackURL)
    }
}

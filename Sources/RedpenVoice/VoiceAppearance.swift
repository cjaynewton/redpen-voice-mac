import AppKit
import SwiftUI

/// Config.appearance is the persisted source. This is only the current process's resolved choice.
/// Palette access stays nonisolated for the existing Ink call sites. Changes happen on the main actor.
enum VoiceAppearance {
    private(set) static var selection = "system"
    private static var initialized = false

    @MainActor static func apply(_ saved: String?) {
        let next = ["dark", "light", "colour"].contains(saved ?? "") ? saved! : "system"
        guard !initialized || next != selection else { return }
        initialized = true
        selection = next
        switch next {
        case "dark", "colour": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
        NotificationCenter.default.post(name: Notification.Name("VoiceAppearanceChanged"), object: nil)
    }
}

/// Shared native palette. Computed colours resolve again after VoiceAppearanceChanged; dynamic NSColors also
/// follow macOS appearance changes while Match the Mac is selected. Legacy font helpers keep their API.
enum Ink {
    enum Role { case paper, raised, subtle, text, mid, dim, red, border, ok }
    static var paper: Color { Color(nsColor: color(.paper)) }
    static var raised: Color { Color(nsColor: color(.raised)) }
    static var subtle: Color { Color(nsColor: color(.subtle)) }
    static var text: Color { Color(nsColor: color(.text)) }
    static var mid: Color { Color(nsColor: color(.mid)) }
    static var dim: Color { Color(nsColor: color(.dim)) }
    static var red: Color { Color(nsColor: color(.red)) }
    static var border: Color { Color(nsColor: color(.border)) }
    static var line: Color { border.opacity(0.4) }
    static var ok: Color { Color(nsColor: color(.ok)) }

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let font = Font.system(size: size, weight: .semibold)
        return italic ? font.italic() : font
    }
    static func body(_ size: CGFloat) -> Font { .system(size: size) }
    /// Retained because several native windows call this before creating their views.
    static func registerFonts() {}

    /// Use this bridge for AppKit views, including the talking bar. Resolve CGColors inside the view's draw/update.
    static func color(_ role: Role) -> NSColor {
        NSColor(name: nil) { appearance in
            let colour = VoiceAppearance.selection == "colour"
            let light = VoiceAppearance.selection == "light" || (VoiceAppearance.selection == "system" && appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua)
            let value: UInt32
            switch role {
            case .paper: value = colour ? 0x2049C6 : light ? 0xFBFCFE : 0x27292D
            case .raised: value = colour ? 0x14369B : light ? 0xE8EDF3 : 0x34383E
            case .subtle: value = colour ? 0x0D2468 : light ? 0xE9EDF2 : 0x1D1F23
            case .text: value = colour ? 0xFFFFFF : light ? 0x1B2028 : 0xF5F5F6
            case .mid: value = colour ? 0xE1EAFF : light ? 0x505D6D : 0xBDC4CE
            case .dim: value = colour ? 0xD0DEFF : light ? 0x596677 : 0xA6AFBB
            case .red: value = colour ? 0xFFC0B5 : light ? 0xBD2E29 : 0xFF756B
            case .border: value = colour ? 0x92B0FF : light ? 0x8C99AA : 0x747C88
            case .ok: value = colour ? 0xC4F2D4 : light ? 0x26794A : 0x79B998
            }
            return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
                           green: CGFloat(value >> 8 & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}

/// The existing three-stroke Voice mark, reused inside native windows. The menu bar image is unchanged.
struct VoiceMark: View {
    var body: some View {
        HStack(spacing: 3) {
            Rectangle().frame(width: 3, height: 8)
            Rectangle().frame(width: 3, height: 20)
            Rectangle().frame(width: 3, height: 8)
        }.accessibilityHidden(true)
    }
}

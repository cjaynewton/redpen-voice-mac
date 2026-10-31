import AppKit

/// The approved three square-ended bars, on the same 32-point grid as the drawing. While meeting notes record
/// (D-951) the bars are the red pen's red, so it is plain from across the room that Voice is recording.
enum VoiceMenuBarIcon {
    static func image(recording: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let scale = bounds.width / 32
            (recording ? NSColor(srgbRed: 0xE0 / 255, green: 0x3A / 255, blue: 0x2E / 255, alpha: 1) : NSColor.black).setFill()
            for bar in [NSRect(x: 7, y: 12, width: 4, height: 8),
                        NSRect(x: 14, y: 6, width: 4, height: 20),
                        NSRect(x: 21, y: 12, width: 4, height: 8)] {
                NSRect(x: bounds.minX + bar.minX * scale, y: bounds.minY + bar.minY * scale,
                       width: bar.width * scale, height: bar.height * scale).fill()
            }
            return true
        }
        image.isTemplate = !recording
        image.accessibilityDescription = recording ? "Redpen Voice, meeting notes recording" : "Redpen Voice"
        return image
    }
}

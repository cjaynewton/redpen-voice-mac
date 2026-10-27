import AppKit

/// The approved three square-ended bars, on the same 32-point grid as the drawing.
enum VoiceMenuBarIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let scale = bounds.width / 32
            NSColor.black.setFill()
            for bar in [NSRect(x: 7, y: 12, width: 4, height: 8),
                        NSRect(x: 14, y: 6, width: 4, height: 20),
                        NSRect(x: 21, y: 12, width: 4, height: 8)] {
                NSRect(x: bounds.minX + bar.minX * scale, y: bounds.minY + bar.minY * scale,
                       width: bar.width * scale, height: bar.height * scale).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Redpen Voice"
        return image
    }
}

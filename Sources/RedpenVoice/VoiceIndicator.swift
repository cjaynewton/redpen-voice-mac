import AppKit

/// Appearance-only preferences. These never migrate or rewrite the dictation configuration.
enum VoiceIndicator {
    static let shapeKey = "VoiceIndicator.shape"
    static let colourKey = "VoiceIndicator.colour"
    static let defaultColour = "FF574B"
    enum Shape: String, CaseIterable { case ribbon, strokes, thread
        var title: String { rawValue.capitalized }
    }
    static func shape(_ defaults: UserDefaults) -> Shape {
        Shape(rawValue: defaults.string(forKey: shapeKey) ?? "") ?? .ribbon
    }
    static func colour(_ value: String) -> NSColor {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = hex.count == 6 ? UInt32(hex, radix: 16) : nil
        let rgb = number ?? 0xFF574B
        return NSColor(srgbRed: CGFloat(rgb >> 16 & 255) / 255,
                       green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func hex(_ colour: NSColor) -> String {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return defaultColour }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    /// Matches the accepted preview at 116 x 40 points. Amplitude is microphone-driven;
    /// phase only gives that amplitude a smooth flow. Quiet input holds a still, fine mark.
    static func points(shape: Shape, stroke: Int, level: CGFloat, phase: Double,
                       writing: Bool, reducedMotion: Bool, done: Bool = false) -> [CGPoint] {
        let strength = sqrt(min(1, max(0, level.isFinite ? level : 0)))
        let amplitude: CGFloat = reducedMotion ? 6 : 1 + strength * 10
        let motion = reducedMotion || (!writing && strength < 0.035) ? 0 : phase
        return (0...48).map { i in
            let u = CGFloat(i) / 48
            if done {
                let t = u * 2
                return t <= 1 ? CGPoint(x: 49 + 7*t, y: 20 + 6*t) : CGPoint(x: 56 + 14*(t-1), y: 26 - 14*(t-1))
            }
            let width: CGFloat = writing ? 46 : 76
            let x = (116 - width)/2 + u*width
            let envelope = pow(sin(u * .pi), 1.2)
            let y: CGFloat
            switch shape {
            case .ribbon:
                y = 20 + (writing ? 1.4 : amplitude) * envelope *
                    (0.76*sin(u*16-motion*4) + 0.24*sin(u*27-motion*3))
            case .strokes:
                let sx: CGFloat = (writing ? 43 : 35) + CGFloat(stroke)*(writing ? 10 : 17) + u*(writing ? 9 : 14)
                let h: CGFloat = writing ? 4 : 3 + amplitude*(stroke == 1 ? 1.1 : 0.75)
                return CGPoint(x: sx + 1.1*sin(u * .pi), y: 20 + (0.5-u)*h*2 + 0.7*sin(u * .pi))
            case .thread:
                y = 20 + (stroke == 0 ? 1 : -1) * (writing ? 3 : 1+amplitude*0.72) * envelope *
                    sin(u*16-motion*3.7+CGFloat(stroke)*0.55)
            }
            return CGPoint(x: x, y: y)
        }
    }
}

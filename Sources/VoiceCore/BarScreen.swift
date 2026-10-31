import Foundation

/// All frames use AppKit's bottom-left desktop coordinates. The largest overlap wins for a spanning box.
public enum BarScreen {
    public struct Choice: Equatable {
        public let index: Int
        public let reason: String
    }

    public static func fromAccessibility(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    public static func choose(screens: [CGRect], textBox: CGRect?, window: CGRect?, pointer: CGPoint) -> Choice? {
        func overlap(_ frame: CGRect?) -> Int? {
            guard let frame, !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return nil }
            var best: Int?, area: CGFloat = 0
            for (i, screen) in screens.enumerated() {
                let intersection = frame.intersection(screen)
                let a = intersection.isNull ? 0 : intersection.width * intersection.height
                if a > area { best = i; area = a }
            }
            return best
        }
        if let i = overlap(textBox) { return Choice(index: i, reason: "text box") }
        if let i = overlap(window) { return Choice(index: i, reason: "focused window") }
        guard !screens.isEmpty else { return nil }
        return Choice(index: screens.firstIndex { $0.contains(pointer) } ?? 0, reason: "pointer")
    }

    /// Where the bar sits on `visible` (the screen's visible frame): centred, 120 points up from the bottom, above
    /// where chat apps put their typing box. When the box you started in is there anyway (D-972, Oct 31 2026: the bar
    /// can now show your words the whole time you talk), it moves just above the box, or just below when above won't
    /// fit, so it never covers your text. A box too tall for either keeps the usual place.
    public static func origin(visible: CGRect, size: CGSize, avoiding box: CGRect?) -> CGPoint {
        let x = visible.midX - size.width / 2
        let usual = CGPoint(x: x, y: visible.minY + 120)
        guard let box, !box.isNull, !box.isEmpty, !box.isInfinite,
              CGRect(origin: usual, size: size).intersects(box.insetBy(dx: -8, dy: -8)) else { return usual }
        let above = box.maxY + 12
        if above + size.height <= visible.maxY - 8 { return CGPoint(x: x, y: above) }
        let below = box.minY - 12 - size.height
        if below >= visible.minY + 8 { return CGPoint(x: x, y: below) }
        return usual
    }
}

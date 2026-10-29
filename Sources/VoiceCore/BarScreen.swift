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
}

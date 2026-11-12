import Foundation

/// Geometry shared by the native bar and its display-removal checks. Desktop coordinates are bottom-left.
public enum TalkingBar {
    public enum State: String, CaseIterable { case resting, listening, writing, needs, done, message }

    public static func size(_ state: State, style: String, menu: Bool = false, small: Bool = false) -> CGSize {
        if small && !menu && state != .message { return CGSize(width: 157, height: 26) }
        let dot = style == "dot"
        let width: CGFloat
        switch state {
        case .resting: width = dot ? 142 : 182
        case .listening: width = dot ? 174 : 314
        case .writing: width = 282
        case .needs: width = dot ? 306 : 328
        case .done: width = 78
        case .message: width = 314
        }
        let rail: CGFloat = state == .resting || state == .done ? 40 : 52
        return CGSize(width: menu ? max(width, state == .resting ? 236 : 314) : width,
                      height: rail + (menu ? (state == .resting ? 137 : 165) : 0))
    }

    /// Keep the entire piece on one display, including after a display disappears. Never clamp to the union
    /// of displays: the union can contain a large hole. The closest surviving display wins when none overlaps.
    public static func fitted(origin: CGPoint, size: CGSize, screens: [CGRect]) -> CGRect {
        let screens = screens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard let first = screens.first else { return CGRect(origin: origin, size: size) }
        let point = origin.x.isFinite && origin.y.isFinite ? origin : first.origin
        let proposed = CGRect(origin: point, size: size)
        func overlap(_ s: CGRect) -> CGFloat {
            let r = s.intersection(proposed)
            return r.isNull ? 0 : r.width * r.height
        }
        func distance(_ s: CGRect) -> CGFloat {
            let dx = max(s.minX - point.x, 0, point.x - s.maxX)
            let dy = max(s.minY - point.y, 0, point.y - s.maxY)
            return dx * dx + dy * dy
        }
        let screen = screens.dropFirst().reduce(first) { best, candidate in
            let a = overlap(best), b = overlap(candidate)
            return b > a || (a == b && distance(candidate) < distance(best)) ? candidate : best
        }
        let safe = screen.insetBy(dx: min(8, screen.width / 4), dy: min(8, screen.height / 4))
        let width = min(size.width, safe.width), height = min(size.height, safe.height)
        return CGRect(x: min(max(point.x, safe.minX), safe.maxX - width),
                      y: min(max(point.y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

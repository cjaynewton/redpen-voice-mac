import Foundation
import CoreGraphics

/// Session-only placement. Display identities come from NSScreenNumber, never array order.
public struct TrialBarPlacement {
    public enum Edge: String { case left, right }
    public struct Position: Equatable {
        public var center: CGPoint
        public var edge: Edge?
        public init(center: CGPoint, edge: Edge? = nil) { self.center = center; self.edge = edge }
    }
    private var positions: [UInt32: Position] = [:]
    public init() {}
    public func position(on display: UInt32) -> Position? { positions[display] }
    public mutating func reset(_ display: UInt32) { positions.removeValue(forKey: display) }
    public mutating func retain(displays: Set<UInt32>) { positions = positions.filter { displays.contains($0.key) } }

    public mutating func save(center: CGPoint, on display: UInt32, visible: CGRect, dock: Bool) {
        guard visible.width > 0, visible.height > 0, center.x.isFinite, center.y.isFinite else { return }
        let edge: Edge? = dock && center.x <= visible.minX + 48 ? .left
            : dock && center.x >= visible.maxX - 48 ? .right : nil
        positions[display] = Position(center: CGPoint(x: min(1, max(0, (center.x - visible.minX) / visible.width)),
                                                     y: min(1, max(0, (center.y - visible.minY) / visible.height))), edge: edge)
    }

    /// Keep the default bar above the Dock, growing upwards when controls or recovery text appear.
    /// Saved centres still survive resolution changes and content expansion.
    public static let bottomInset: CGFloat = 16
    public func frame(on display: UInt32, visible: CGRect, size: CGSize) -> CGRect {
        let saved = positions[display]
        let width = min(max(0, size.width), visible.width), height = min(max(0, size.height), visible.height)
        let center = saved?.center ?? CGPoint(x: 0.5, y: 0)
        var x = visible.minX + center.x * visible.width - width / 2
        let y = saved == nil ? visible.minY + Self.bottomInset
            : visible.minY + center.y * visible.height - height / 2
        if saved?.edge == .left { x = visible.minX }
        if saved?.edge == .right { x = visible.maxX - width }
        return CGRect(x: min(max(visible.minX, x), visible.maxX - width),
                      y: min(max(visible.minY, y), visible.maxY - height),
                      width: width, height: height)
    }

    public static func size(timer: Bool, dragged: Bool, expanded: Bool, tucked: Bool) -> CGSize {
        if tucked { return CGSize(width: 12, height: 44) }
        if expanded { return CGSize(width: 272, height: 40) }
        if timer { return CGSize(width: 164, height: 40) }
        return CGSize(width: 116, height: 40)
    }
}

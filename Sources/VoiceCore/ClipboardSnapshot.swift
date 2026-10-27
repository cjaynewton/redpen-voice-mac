import AppKit

/// Everything on a pasteboard, every item in every format, kept exactly so it can be put back after Voice borrows
/// the clipboard for a paste (D-825). Typing stays the default; the clipboard is only borrowed when typing didn't land,
/// and for Paste last.
public struct ClipboardSnapshot: Sendable {
    let items: [[String: Data]]

    public static func take(_ pb: NSPasteboard = .general) -> ClipboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        return ClipboardSnapshot(items: items)
    }

    /// True when the pasteboard holds the same items, in the same formats, with the same bytes.
    public func matches(_ pb: NSPasteboard = .general) -> Bool { ClipboardSnapshot.take(pb).items == items }

    public func restore(to pb: NSPasteboard = .general) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { kinds in
            let item = NSPasteboardItem()
            for (t, d) in kinds { item.setData(d, forType: NSPasteboard.PasteboardType(t)) }
            return item
        }
        pb.writeObjects(restored)
    }
}

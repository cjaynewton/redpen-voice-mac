import Foundation

/// A snapshot of comparisons already made during paste delivery. No text, URL, title or identifier is stored.
/// It explains a refusal without weakening the existing target or duplicate-delivery safeguards.
public struct PasteTargetCheck {
    public let sameElement: Bool
    public let sameApp: Bool
    public let sameTitle: Bool?
    public let sameAddress: Bool?
    public let sameValue: Bool
    public let sameSelection: Bool
    public let posted: Bool
    public let landed: Bool

    public init(sameElement: Bool, sameApp: Bool, sameTitle: Bool?, sameAddress: Bool?,
                sameValue: Bool, sameSelection: Bool, posted: Bool, landed: Bool) {
        self.sameElement = sameElement; self.sameApp = sameApp; self.sameTitle = sameTitle
        self.sameAddress = sameAddress; self.sameValue = sameValue; self.sameSelection = sameSelection
        self.posted = posted; self.landed = landed
    }
    public var sameTarget: Bool {
        sameElement && sameApp && sameTitle == true && sameAddress == true
            && (posted || (sameValue && sameSelection))
    }
    public var fields: String {
        func flag(_ value: Bool?) -> Int { value.map { $0 ? 1 : 0 } ?? -1 }
        return "posted=\(flag(posted)) element_same=\(flag(sameElement)) app_same=\(flag(sameApp)) title_same=\(flag(sameTitle)) address_same=\(flag(sameAddress)) value_same=\(flag(sameValue)) selection_same=\(flag(sameSelection)) landed_evidence=\(flag(landed))"
    }
}

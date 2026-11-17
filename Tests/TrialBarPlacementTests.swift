import XCTest
import CoreGraphics
import VoiceCore

final class TrialBarPlacementTests: XCTestCase {
    func testThreePhysicalDisplaysStartAtTheirOwnExactCentre() {
        let layout = TrialBarPlacement()
        let frames = [CGRect(x: -1920, y: 80, width: 1920, height: 1080),
                      CGRect(x: 0, y: 0, width: 1728, height: 1080),
                      CGRect(x: 1728, y: -600, width: 2560, height: 1440)]
        for (index, visible) in frames.enumerated() {
            let frame = layout.frame(on: UInt32(index + 1), visible: visible, size: CGSize(width: 48, height: 48))
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.midY, visible.midY)
        }
    }

    func testDisplayPositionsAreIndependentAndCentreOnlyResetsOne() {
        var layout = TrialBarPlacement()
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 0, y: 0, width: 1400, height: 900)
        layout.save(center: CGPoint(x: -980, y: 200), on: 41, visible: left, dock: true)
        layout.save(center: CGPoint(x: 700, y: 650), on: 72, visible: right, dock: true)
        let second = layout.position(on: 72)
        XCTAssertEqual(layout.position(on: 41)?.edge, .left)
        XCTAssertNil(layout.position(on: 72)?.edge)
        layout.reset(41)
        XCTAssertNil(layout.position(on: 41))
        XCTAssertEqual(layout.position(on: 72), second)
        XCTAssertNil(TrialBarPlacement().position(on: 72), "A new process session has no previous placement")
    }

    func testDockingBothSidesFitsExpandedRecoveryAndTuckedTab() {
        var layout = TrialBarPlacement()
        let screen = CGRect(x: -1600, y: -250, width: 1600, height: 1000)
        for edge in [TrialBarPlacement.Edge.left, .right] {
            let center = CGPoint(x: edge == .left ? screen.minX + 20 : screen.maxX - 20, y: screen.midY)
            layout.save(center: center, on: 5, visible: screen, dock: true)
            XCTAssertEqual(layout.position(on: 5)?.edge, edge)
            for size in [CGSize(width: 12, height: 44), CGSize(width: 64, height: 48), CGSize(width: 480, height: 200)] {
                let frame = layout.frame(on: 5, visible: screen, size: size)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(edge == .left ? frame.minX : frame.maxX, edge == .left ? screen.minX : screen.maxX)
            }
        }
    }

    func testResolutionChangeAndRemovalNeverStrandPosition() {
        var layout = TrialBarPlacement()
        let old = CGRect(x: 4000, y: 500, width: 2560, height: 1440)
        layout.save(center: CGPoint(x: 6500, y: 1900), on: 11, visible: old, dock: false)
        let smaller = CGRect(x: -1200, y: -800, width: 1200, height: 800)
        XCTAssertTrue(smaller.contains(layout.frame(on: 11, visible: smaller, size: CGSize(width: 480, height: 240))))
        layout.retain(displays: [22])
        XCTAssertNil(layout.position(on: 11))
        let fallback = layout.frame(on: 22, visible: smaller, size: CGSize(width: 48, height: 48))
        XCTAssertEqual(fallback.midX, smaller.midX)
        XCTAssertEqual(fallback.midY, smaller.midY)
    }

    func testDraggingDoesNotDockUntilReleaseAndInvalidInputDoesNotPoisonPlacement() {
        var layout = TrialBarPlacement()
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        layout.save(center: CGPoint(x: 20, y: 450), on: 1, visible: screen, dock: false)
        XCTAssertNil(layout.position(on: 1)?.edge)
        let previous = layout.position(on: 1)
        layout.save(center: CGPoint(x: CGFloat.nan, y: 20), on: 1, visible: screen, dock: true)
        XCTAssertEqual(layout.position(on: 1), previous)
        layout.save(center: CGPoint(x: 20, y: 450), on: 1, visible: screen, dock: true)
        XCTAssertEqual(layout.position(on: 1)?.edge, .left)
    }

    func testTrialSizesAndExpansionKeepsTheSavedCentre() {
        XCTAssertEqual(TrialBarPlacement.size(timer: false, dragged: false, expanded: false, tucked: false), CGSize(width: 48, height: 48))
        XCTAssertEqual(TrialBarPlacement.size(timer: false, dragged: true, expanded: false, tucked: false), CGSize(width: 64, height: 48))
        XCTAssertEqual(TrialBarPlacement.size(timer: true, dragged: true, expanded: false, tucked: false), CGSize(width: 96, height: 38))
        XCTAssertEqual(TrialBarPlacement.size(timer: true, dragged: false, expanded: true, tucked: false), CGSize(width: 264, height: 48))
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        var layout = TrialBarPlacement()
        layout.save(center: CGPoint(x: 650, y: 500), on: 10, visible: screen, dock: false)
        let small = layout.frame(on: 10, visible: screen, size: CGSize(width: 48, height: 48))
        let expanded = layout.frame(on: 10, visible: screen, size: CGSize(width: 264, height: 48))
        XCTAssertEqual(small.midX, expanded.midX)
        XCTAssertEqual(small.midY, expanded.midY)
    }
}

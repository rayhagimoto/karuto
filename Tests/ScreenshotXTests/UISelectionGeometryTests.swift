import Testing
import CoreGraphics
@testable import ScreenshotX

struct UISelectionGeometryTests {
    @Test func testReverseDragClipsToSecondaryDisplay() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let rect = SelectionGeometry.rectangle(from: CGPoint(x: -100, y: 1100), to: CGPoint(x: -2000, y: 100), within: screen)
        #expect(rect == CGRect(x: -1920, y: 200, width: 1820, height: 900))
    }

    @Test func testMovePreservesSizeAtDisplayEdge() {
        let screen = CGRect(x: 0, y: -900, width: 1440, height: 900)
        let rect = SelectionGeometry.moved(CGRect(x: 100, y: -400, width: 600, height: 300), delta: CGSize(width: 1600, height: 500), within: screen)
        #expect(rect == CGRect(x: 840, y: -300, width: 600, height: 300))
    }

    @Test func testOversizeDimensionEntryFitsDisplay() {
        let screen = CGRect(x: -1280, y: 0, width: 1280, height: 720)
        let rect = SelectionGeometry.resized(CGRect(x: -1000, y: 100, width: 50, height: 50), size: CGSize(width: 3000, height: 1000), within: screen)
        #expect(rect == screen)
    }
}

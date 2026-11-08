import AppKit
import Testing
@testable import Karuto

@MainActor
struct ToolbarGeometryTests {
    @Test func bottomMenuOpensUpWithoutClippingAnyRows() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 900, y: 60, width: 26, height: 26)
        let size = CGSize(width: 320, height: 180)
        let placement = ToolbarGeometry.menuPlacement(anchor: anchor, menuSize: size, visibleFrame: screen)
        #expect(placement.opensUpward)
        #expect(placement.topLeft == CGPoint(x: 606, y: 274))
        let menu = CGRect(x: placement.topLeft.x, y: placement.topLeft.y - size.height, width: size.width, height: size.height)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(menu))
        #expect(menu.minY == anchor.maxY + 8)
    }

    @Test func topMenuOpensDownAndClampsHorizontalEdges() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let placement = ToolbarGeometry.menuPlacement(anchor: CGRect(x: -1900, y: 1200, width: 26, height: 26),
                                                       menuSize: CGSize(width: 320, height: 180), visibleFrame: screen)
        #expect(!placement.opensUpward)
        #expect(placement.topLeft == CGPoint(x: -1912, y: 1192))
    }

    @Test func crampedMenuUsesLargerSideAndStaysInsideDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 400)
        let placement = ToolbarGeometry.menuPlacement(anchor: CGRect(x: 790, y: 150, width: 26, height: 26),
                                                       menuSize: CGSize(width: 320, height: 280), visibleFrame: screen)
        #expect(placement.opensUpward)
        #expect(placement.topLeft == CGPoint(x: 472, y: 392))
    }

    @Test func toolbarMovementClampsAtEdgesAndCanCrossDisplays() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let initial = CGRect(x: 400, y: 55, width: 672, height: 112)
        let start = CGPoint(x: 500, y: 100)
        let moved = ToolbarGeometry.moved(initial, from: start, to: CGPoint(x: -500, y: 500), visibleFrames: [left, right])
        #expect(moved == CGRect(x: -680, y: 455, width: 672, height: 112))
        let corner = ToolbarGeometry.moved(initial, from: start, to: CGPoint(x: 1910, y: 1070), visibleFrames: [left, right])
        #expect(corner == CGRect(x: 1240, y: 960, width: 672, height: 112))
        #expect(moved.size == initial.size)
    }

    @Test func toolbarPanDefersClicksAndHasPriorityOverControlGestures() throws {
        _ = NSApplication.shared
        let root = CaptureToolbarView(frame: CGRect(x: 0, y: 0, width: 672, height: 112))
        let button = NSButton(title: "Area", target: nil, action: nil)
        root.addSubview(button)
        let pan = try #require(root.gestureRecognizers.first as? NSPanGestureRecognizer)
        #expect(pan.delaysPrimaryMouseButtonEvents)
        #expect(pan.buttonMask == 1)
        let click = NSClickGestureRecognizer(target: nil, action: nil)
        button.addGestureRecognizer(click)
        #expect(root.gestureRecognizer(pan, shouldBeRequiredToFailBy: click))
        let unrelated = NSClickGestureRecognizer(target: nil, action: nil)
        #expect(!root.gestureRecognizer(pan, shouldBeRequiredToFailBy: unrelated))
        // No dedicated drag control is added to the toolbar.
        #expect(root.subviews == [button])
    }
}

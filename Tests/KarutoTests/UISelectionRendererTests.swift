import AppKit
import QuartzCore
import Testing
@testable import Karuto

@MainActor
struct UISelectionRendererTests {
    @Test func unaffectedDisplayDoesNotRewriteLayers() throws {
        let renderer = SelectionOverlayRenderer(size: CGSize(width: 1440, height: 900), scale: 2)
        let shade = try #require(renderer.rootLayer.sublayers?.first as? CAShapeLayer)
        let initialPath = try #require(shade.path)
        for x in stride(from: -2000, through: -1600, by: 10) {
            #expect(!renderer.update(rect: CGRect(x: x, y: 100, width: 300, height: 200), text: "Changing text", resizable: true))
        }
        #expect(shade.path === initialPath)
    }

    @Test func movingSelectionReusesArtworkAndText() throws {
        let renderer = SelectionOverlayRenderer(size: CGSize(width: 1440, height: 900), scale: 2)
        let first = CGRect(x: 80, y: 100, width: 600, height: 300)
        #expect(renderer.update(rect: first, text: "600 × 300 pt", resizable: true))
        let layers = try #require(renderer.rootLayer.sublayers)
        let selection = layers[1]
        let border = try #require(selection.sublayers?.first as? CAShapeLayer)
        let oldBorder = try #require(border.path)
        let label = try #require(layers[2].sublayers?.first as? CATextLayer)
        let oldText = try #require(label.string as? NSAttributedString)
        let moved = first.offsetBy(dx: 75, dy: 50)
        #expect(renderer.update(rect: moved, text: "600 × 300 pt", resizable: true))
        #expect(selection.frame == moved)
        #expect(border.path === oldBorder)
        #expect((label.string as? NSAttributedString) === oldText)
        #expect(!renderer.update(rect: moved, text: "600 × 300 pt", resizable: true))
        #expect(label.contentsScale == 2)
        let coverage = try #require(renderer.rootLayer.backgroundColor).alpha
        #expect(coverage > 1.0 / 255.0 && coverage <= 0.01)
        #expect(allLayers(renderer.rootLayer).allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    @Test func switchingDisplaysClearsPreviousCutout() throws {
        let left = SelectionOverlayRenderer(size: CGSize(width: 1920, height: 1080), scale: 1)
        let right = SelectionOverlayRenderer(size: CGSize(width: 1440, height: 900), scale: 2)
        let selectedOnLeft = CGRect(x: 1500, y: 200, width: 300, height: 200)
        left.update(rect: selectedOnLeft, text: "300 × 200 pt", resizable: true)
        // The left display's global origin is -1920; the same global rectangle
        // is wholly left of the right display's local origin.
        right.update(rect: selectedOnLeft.offsetBy(dx: -1920, dy: 0), text: "300 × 200 pt", resizable: true)
        let leftShade = try #require(left.rootLayer.sublayers?.first as? CAShapeLayer)
        #expect(leftShade.path?.contains(CGPoint(x: 1600, y: 250), using: .evenOdd) == false)
        let selectedOnRight = CGRect(x: 200, y: 300, width: 400, height: 200)
        right.update(rect: selectedOnRight, text: "400 × 200 pt", resizable: true)
        left.update(rect: selectedOnRight.offsetBy(dx: 1920, dy: 0), text: "400 × 200 pt", resizable: true)
        #expect(leftShade.path?.contains(CGPoint(x: 1600, y: 250), using: .evenOdd) == true)
        #expect(left.rootLayer.sublayers?[1].isHidden == true)
        #expect(left.rootLayer.sublayers?[2].isHidden == true)
        let rightShade = try #require(right.rootLayer.sublayers?.first as? CAShapeLayer)
        #expect(rightShade.path?.contains(CGPoint(x: 300, y: 350), using: .evenOdd) == false)
    }

    @Test func clippedWindowAndBackingScaleStayConsistent() throws {
        let renderer = SelectionOverlayRenderer(size: CGSize(width: 800, height: 600), scale: 1)
        renderer.update(rect: CGRect(x: -200, y: 100, width: 500, height: 300), text: "Window", resizable: false)
        let shade = try #require(renderer.rootLayer.sublayers?.first as? CAShapeLayer)
        #expect(shade.path?.contains(CGPoint(x: 20, y: 200), using: .evenOdd) == false)
        #expect(shade.path?.contains(CGPoint(x: 500, y: 200), using: .evenOdd) == true)
        renderer.updateScale(2)
        #expect(allLayers(renderer.rootLayer).allSatisfy { $0.contentsScale == 2 })
        #expect(allLayers(renderer.rootLayer).allSatisfy { $0.animationKeys()?.isEmpty != false })
    }

    private func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { allLayers($0) }
    }
}

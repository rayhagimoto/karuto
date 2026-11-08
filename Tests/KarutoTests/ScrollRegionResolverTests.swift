import CoreGraphics
import Testing
@testable import Karuto

struct ScrollRegionResolverTests {
    @Test func candidateClipsToVisibleWindowAndDisplayAndMustContainPointer() {
        let frame = CGRect(x: -200, y: 200, width: 700, height: 500)
        let window = CGRect(x: -100, y: 100, width: 500, height: 500)
        let display = CGRect(x: 0, y: 0, width: 600, height: 500)
        #expect(ScrollRegionResolver.clippedCandidate(frame, point: CGPoint(x: 100, y: 300), window: window, display: display) == CGRect(x: 0, y: 200, width: 400, height: 300))
        #expect(ScrollRegionResolver.clippedCandidate(frame, point: CGPoint(x: -50, y: 300), window: window, display: display) == nil)
        #expect(ScrollRegionResolver.clippedCandidate(CGRect(x: 0, y: 0, width: 10, height: 10), point: .zero, window: window, display: display) == nil)
    }

    @Test func queryIdentityRejectsOldPointerAndWindowState() {
        let display = CaptureDisplay(id: 1, name: "Display", frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        let window = CaptureWindow(id: 2, title: "Pane", applicationName: "App", frame: display.frame)
        let request = ScrollRegionRequest(point: CGPoint(x: 100, y: 100), window: window, display: display, generation: 7)
        #expect(ScrollRegionResolver.isCurrent(request, generation: 7, point: request.point, windowID: 2))
        #expect(!ScrollRegionResolver.isCurrent(request, generation: 8, point: request.point, windowID: 2))
        #expect(!ScrollRegionResolver.isCurrent(request, generation: 7, point: CGPoint(x: 200, y: 100), windowID: 2))
        #expect(!ScrollRegionResolver.isCurrent(request, generation: 7, point: request.point, windowID: 3))
    }
}

import Testing
import CoreGraphics
@testable import Karuto

struct AutomaticScrollTests {
    @Test func calibrationIsNotGrowthAndReplayUsesMovingViewportHeight() {
        var evidence = AutomaticScrollProgress()
        evidence.observe(StitchProgress(height: 0, message: "", accepted: false, disposition: 4))
        #expect(evidence.hasFrame)
        #expect(evidence.isCalibrating)
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 844, message: "", accepted: true, disposition: 0,
                                        contentRect: CGRect(x: 100, y: 60, width: 800, height: 700),
                                        viewportHeight: 700, sourceSize: CGSize(width: 1000, height: 800)))
        #expect(!evidence.isCalibrating)
        #expect(evidence.hasExtended)
        #expect(evidence.firstHeight == 700)
        #expect(evidence.viewportFraction == 0.875)
    }

    @Test func onlyAcceptedVerticalGrowthCanComplete() {
        var evidence = AutomaticScrollProgress()
        #expect(!evidence.hasFrame)
        evidence.observe(StitchProgress(height: 600, message: "", accepted: true, disposition: 0))
        #expect(evidence.hasFrame)
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 600, message: "", accepted: false, disposition: 1))
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 900, message: "", accepted: false, disposition: 2))
        #expect(evidence.rejectedFrames == 1)
        #expect(!evidence.hasExtended)
        evidence.observe(StitchProgress(height: 800, message: "", accepted: true, disposition: 0))
        #expect(evidence.hasExtended)
        #expect(evidence.height == 800)
    }
}

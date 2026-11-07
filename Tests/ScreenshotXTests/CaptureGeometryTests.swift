import Testing
import Foundation
@testable import ScreenshotX

struct CaptureGeometryTests {
    @Test func secondaryDisplayLeftAndAbove() throws {
        let display = CGRect(x: -1920, y: 1080, width: 1920, height: 1200)
        let selection = CGRect(x: -1800, y: 1800, width: 640, height: 320)
        #expect(try CaptureGeometry.sourceRect(selection: selection, displayFrame: display) ==
                CGRect(x: 120, y: 160, width: 640, height: 320))
    }

    @Test func quartzConversionUsesPrimaryHeightRatherThanSelectedScreen() {
        #expect(CaptureGeometry.appKitRect(fromQuartz: CGRect(x: -900, y: -400, width: 800, height: 300), primaryHeight: 1080) ==
                CGRect(x: -900, y: 1180, width: 800, height: 300))
    }

    @Test func retinaPixelDimensions() throws {
        let result = try CaptureGeometry.pixelSize(points: CGSize(width: 600.5, height: 450), scale: 2)
        #expect(result.width == 1201)
        #expect(result.height == 900)
    }

    @Test func crossDisplayAndEmptySelectionsAreRejected() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(throws: CaptureError.self) { try CaptureGeometry.sourceRect(selection: CGRect(x: 1900, y: 0, width: 100, height: 100), displayFrame: display) }
        #expect(throws: CaptureError.self) { try CaptureGeometry.sourceRect(selection: .zero, displayFrame: display) }
    }

    @Test func recordingAspectRatioEvenDimensionsAndNoUpscaling() throws {
        let portrait = try CaptureGeometry.recordingSize(width: 1800, height: 2880, resolution: .hd1080)
        #expect(portrait.width == 674)
        #expect(portrait.height == 1080)
        let small = try CaptureGeometry.recordingSize(width: 601, height: 399, resolution: .hd1080)
        #expect(small.width == 600)
        #expect(small.height == 398)
        #expect(throws: CaptureError.self) { try CaptureGeometry.recordingSize(width: 6016, height: 3384, resolution: .native) }
    }
}

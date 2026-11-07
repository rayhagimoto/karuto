import CoreGraphics
import Foundation
import Testing
@testable import ScreenshotX

struct FrozenDesktopTests {
    @Test func cropUsesFrozenPixelsAndTopLeftRowsOnNegativeOriginDisplay() throws {
        let display = CaptureDisplay(id: 7, name: "Left", frame: CGRect(x: -10, y: 20, width: 4, height: 3), scale: 2)
        let original = try patternedImage(width: 8, height: 6, marker: 21)
        var suppliedFrames: [UInt32: CGImage] = [7: original]
        let frozen = FrozenDesktop(catalog: CaptureCatalog(displays: [display], windows: []), frames: suppliedFrames)
        suppliedFrames[7] = try patternedImage(width: 8, height: 6, marker: 99)
        let result = try frozen.image(for: .area(displayID: 7, rect: CGRect(x: -9, y: 21, width: 2, height: 1)))
        #expect(result.width == 4)
        #expect(result.height == 2)
        let pixels = try rgba(result)
        #expect(Array(pixels[0..<4]) == [2, 2, 21, 255])
        #expect(Array(pixels[28..<32]) == [5, 3, 21, 255])
        #expect(try frozen.image(for: .display(id: 7)) === original)
    }

    @Test func actualImageDimensionsDetermineCropScale() throws {
        // The catalog scale is deliberately different: image dimensions are the
        // authoritative mapping for the saved frame, including scaled displays.
        let display = CaptureDisplay(id: 7, name: "Scaled", frame: CGRect(x: 0, y: 0, width: 4, height: 3), scale: 1)
        let image = try patternedImage(width: 8, height: 6, marker: 4)
        let frozen = FrozenDesktop(catalog: CaptureCatalog(displays: [display], windows: []), frames: [7: image])
        let result = try frozen.image(for: .area(displayID: 7, rect: CGRect(x: 0, y: 2, width: 1, height: 1)))
        #expect(result.width == 2 && result.height == 2)
        #expect(Array(try rgba(result)[0..<4]) == [0, 0, 4, 255])
    }

    @Test func windowUsesItsFrozenVisibleRectangle() throws {
        let display = CaptureDisplay(id: 7, name: "Main", frame: CGRect(x: 0, y: 0, width: 4, height: 3), scale: 1)
        let window = CaptureWindow(id: 11, title: "Window", applicationName: "Fixture", frame: CGRect(x: -1, y: 1, width: 3, height: 2))
        let frozen = FrozenDesktop(catalog: CaptureCatalog(displays: [display], windows: [window]), frames: [7: try patternedImage(width: 4, height: 3, marker: 5)])
        let result = try frozen.image(for: .window(id: 11))
        #expect(result.width == 2 && result.height == 2)
        #expect(Array(try rgba(result)[0..<4]) == [0, 0, 5, 255])
    }

    @Test func invalidAndCrossDisplayTargetsFailInsteadOfCapturingLive() throws {
        let left = CaptureDisplay(id: 7, name: "Left", frame: CGRect(x: -4, y: 0, width: 4, height: 3), scale: 1)
        let right = CaptureDisplay(id: 8, name: "Right", frame: CGRect(x: 0, y: 0, width: 4, height: 3), scale: 1)
        let window = CaptureWindow(id: 11, title: "Spanning", applicationName: "Fixture", frame: CGRect(x: -1, y: 0, width: 2, height: 2))
        let image = try patternedImage(width: 4, height: 3, marker: 3)
        let frozen = FrozenDesktop(catalog: CaptureCatalog(displays: [left, right], windows: [window]), frames: [7: image, 8: image])
        #expect(throws: CaptureError.self) { try frozen.image(for: .display(id: 99)) }
        #expect(throws: CaptureError.self) { try frozen.image(for: .window(id: 99)) }
        #expect(throws: CaptureError.self) { try frozen.image(for: .area(displayID: 7, rect: CGRect(x: -1, y: 0, width: 2, height: 2))) }
        #expect(throws: CaptureError.self) { try frozen.image(for: .area(displayID: 7, rect: .zero)) }
        #expect(throws: FrozenDesktopError.self) { try frozen.image(for: .window(id: 11)) }
    }

    private func patternedImage(width: Int, height: Int, marker: UInt8) throws -> CGImage {
        var data = Data()
        for y in 0..<height {
            for x in 0..<width { data.append(contentsOf: [UInt8(x), UInt8(y), marker, 255]) }
        }
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}

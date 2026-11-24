import AppKit
import ImageIO
import Testing
@testable import Karuto

struct AreaAnnotationTests {
    @Test func textExportUsesBoxAlignmentWrappingAndFontStylesAtRetinaScale() throws {
        let size = CGSize(width: 280, height: 140)
        let w = Int(size.width) * 2, h = Int(size.height) * 2
        let bitmap = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let base = try #require(bitmap.makeImage())
        var mark = AreaAnnotation(tool: .text, color: .red, start: .zero, end: .zero, label: "Caption")
        mark.setTextFrame(CGRect(x: 15, y: 20, width: 220, height: 80))
        func ink() throws -> (bounds: CGRect, count: Int) {
            bitmap.clear(CGRect(x: 0, y: 0, width: w, height: h))
            let rendered = try AreaAnnotation.composite([mark], over: base, size: size)
            bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: w, height: h))
            let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
            var left = w, right = 0, bottom = h, top = 0, count = 0
            for row in 0..<h {
                for x in 0..<w where bytes[(row * w + x) * 4 + 3] > 100 {
                    let y = h - 1 - row
                    left = min(left, x); right = max(right, x)
                    bottom = min(bottom, y); top = max(top, y)
                    count += 1
                }
            }
            try #require(count > 0)
            return (CGRect(x: CGFloat(left)/2, y: CGFloat(bottom)/2, width: CGFloat(right-left+1)/2, height: CGFloat(top-bottom+1)/2), count)
        }
        mark.textStyle.bold = false
        let left = try ink()
        mark.textStyle.alignment = .center
        let center = try ink()
        mark.textStyle.alignment = .right
        let right = try ink()
        #expect(left.bounds.minX < center.bounds.minX && center.bounds.minX < right.bounds.minX)
        #expect(abs(center.bounds.midX - mark.rect.midX) < 2)
        #expect(abs(right.bounds.maxX - (mark.rect.maxX - AnnotationTextStyle.inset)) < 3)
        mark.textStyle.bold = true
        let bold = try ink()
        #expect(bold.count > right.count)
        mark.textStyle.italic = true
        let italic = try ink()
        #expect(italic.count != bold.count || italic.bounds != bold.bounds)
        mark.textStyle.underline = true
        #expect(try ink().count > italic.count)
        mark.textStyle.size = 32
        #expect(try ink().bounds.height > right.bounds.height)
        mark.label = "Several words wrap onto successive lines"
        mark.setTextFrame(CGRect(x: 28, y: 12, width: 110, height: 105))
        let wrapped = try ink()
        #expect(mark.rect.contains(wrapped.bounds))
        #expect(wrapped.bounds.height > 60)
    }

    @Test func retinaPNGHasMosaicAndCounterAtOverlayCoordinates() throws {
        let size = CGSize(width: 100, height: 80)
        let width = 200, height = 160
        let source = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            source.setFillColor(gray: x.isMultiple(of: 2) ? 0 : 1, alpha: 1)
            source.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let base = try #require(source.makeImage())
        let mosaic = AreaAnnotation(tool: .mosaic, color: .blue, start: CGPoint(x: 80, y: 75), end: CGPoint(x: 20, y: 45))
        let counter = AreaAnnotation(tool: .counter, color: .red, start: CGPoint(x: 25, y: 20), end: CGPoint(x: 55, y: 20), label: "1")
        let output = try AreaAnnotation.composite([mosaic, counter], over: base, size: size)
        #expect(try AreaAnnotation.composite([], over: base, size: size) === base)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try CaptureStore(root: folder)
        let file = try store.writePNG(output, in: store.newSession())
        let png = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(png, 0, nil))
        #expect(image.width == width && image.height == height)
        source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(source.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = ((height - 1 - y) * width + x) * 4
            return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
        }
        #expect(pixel(43, 110) == pixel(44, 110))
        #expect(pixel(17, 110) != pixel(18, 110))
        #expect(pixel(42, 40)[0] > 200 && pixel(42, 40)[1] < 80)
        #expect(pixel(93, 40)[0] > 200 && pixel(93, 40)[1] < 80)
        #expect(pixel(42, 120)[0] == pixel(42, 120)[1])
    }

    @MainActor @Test func paletteFitsSecondaryScreenAndAvoidsCaptureToolbar() {
        let screen = CGRect(x: -1000, y: 180, width: 900, height: 600)
        let toolbar = CGRect(x: -850, y: 210, width: 500, height: 160)
        for selection in [screen, CGRect(x: -980, y: 740, width: 25, height: 25), CGRect(x: -900, y: 390, width: 400, height: 240)] {
            let frame = ToolbarGeometry.paletteFrame(size: CGSize(width: 386, height: 38),
                selection: selection, screen: screen, toolbar: toolbar)
            #expect(screen.contains(frame))
            #expect(!toolbar.intersects(frame))
        }
    }

    @MainActor @Test func previewAndExportAgreeAfterMovingAndResizing() throws {
        let editor = AreaAnnotationEditor()
        let root = CALayer()
        let display = CaptureDisplay(id: 3, name: "Fixture", frame: CGRect(x: -400, y: 140, width: 400, height: 300), scale: 2)
        var rect = CGRect(x: -380, y: 160, width: 240, height: 170)
        editor.show(for: display, rect: rect, in: root, avoiding: nil)
        defer { editor.clear() }
        editor.select(.counter)
        #expect(editor.begin(at: CGPoint(x: -340, y: 200), displayID: 3))
        editor.end(at: CGPoint(x: -340, y: 200))
        rect.origin.x += 20
        editor.show(for: display, rect: rect, in: root, avoiding: nil)
        #expect(editor.marks[0].start == CGPoint(x: 40, y: 40))
        rect.origin.x += 10
        rect.size.width -= 10
        editor.show(for: display, rect: rect, in: root, avoiding: nil)
        #expect(editor.marks[0].start == CGPoint(x: 30, y: 40))
        let canvas = try #require(root.sublayers?.first)
        let markLayer = try #require(canvas.sublayers?.first)
        markLayer.displayIfNeeded()
        let bitmap = try #require(CGContext(data: nil, width: 230, height: 170, bitsPerComponent: 8,
            bytesPerRow: 920, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Render the canvas in its own local coordinates just as export does.
        canvas.render(in: bitmap)
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let offset = (129 * 230 + 21) * 4
        #expect(bytes[offset] > 200 && bytes[offset + 1] < 80 && bytes[offset + 3] == 255)
    }
}

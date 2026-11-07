import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ScreenshotX

struct StorageTests {
    private func withStore(_ body: (CaptureStore, URL) throws -> Void) throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotX-StorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = try CaptureStore(root: fixture.appendingPathComponent("captures", isDirectory: true))
        try body(store, fixture)
    }

    private func makeImage() throws -> CGImage {
        let width = 7, height = 5
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 31)
                pixels[offset + 1] = UInt8(y * 47)
                pixels[offset + 2] = UInt8((x + y) * 19)
                pixels[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func raster(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    @Test func testPNGRoundTripPreservesDimensionsAndPixels() throws {
        try withStore { store, _ in
            let directory = try store.newSession()
            let original = try makeImage()
            let result = try store.writePNG(original, in: directory)
            let source = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == 7)
            #expect(decoded.height == 5)
            let decodedPixels = try raster(decoded)
            let originalPixels = try raster(original)
            #expect(decodedPixels == originalPixels)
            #expect(result.lastPathComponent == "Screenshot.png")
            #expect(!(FileManager.default.fileExists(atPath: directory.appendingPathComponent("image.partial").path)))
        }
    }

    @Test func testSavePublishesCopyAndPreservesSessionSource() throws {
        try withStore { store, fixture in
            let session = try store.newSession()
            let source = try store.writePNG(makeImage(), in: session)
            let originalData = try Data(contentsOf: source)
            let artifact = CaptureArtifact(id: UUID(), url: source, kind: .image, width: 7, height: 5)
            let saved = try store.save(artifact, folder: fixture.appendingPathComponent("exported"))
            #expect(saved.isSaved)
            #expect(saved.id == artifact.id)
            #expect(saved.url != source)
            #expect(try Data(contentsOf: saved.url) == originalData)
            #expect(try Data(contentsOf: source) == originalData)
            #expect(!(artifact.isSaved))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: saved.url.deletingLastPathComponent().path)
            #expect(leftovers == [saved.url.lastPathComponent])
        }
    }

    @Test func testAtomicReplacementKeepsSourceAndReplacesExistingDestination() throws {
        try withStore { store, fixture in
            let source = try store.newSession().appendingPathComponent("recording.mp4")
            let destination = fixture.appendingPathComponent("saved.mp4")
            let replacement = Data("complete new recording".utf8)
            try replacement.write(to: source)
            try Data("previous recording".utf8).write(to: destination)
            try store.copyAtomically(from: source, to: destination)
            #expect(try Data(contentsOf: destination) == replacement)
            #expect(try Data(contentsOf: source) == replacement)
            #expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.hasSuffix(".partial") }))
        }
    }

    @Test func testAtomicCopyToSameSourceIsNoOp() throws {
        try withStore { store, _ in
            let session = try store.newSession()
            let source = session.appendingPathComponent("same.png")
            let bytes = Data([0, 1, 2, 3, 4])
            try bytes.write(to: source)
            let equivalent = session.appendingPathComponent(".").appendingPathComponent("same.png")
            try store.copyAtomically(from: source, to: equivalent)
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: session.path) == ["same.png"])
        }
    }

    @Test func testRemoveSessionRefusesRootSiblingAndGrandchild() throws {
        try withStore { store, fixture in
            let child = try store.newSession()
            let grandchild = child.appendingPathComponent("nested", isDirectory: true)
            let sibling = fixture.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            for protected in [store.root, sibling, grandchild] {
                store.removeSession(protected)
                #expect(FileManager.default.fileExists(atPath: protected.path))
            }
            store.removeSession(child)
            #expect(!(FileManager.default.fileExists(atPath: child.path)))
            #expect(FileManager.default.fileExists(atPath: sibling.path))
        }
    }

    @Test func testExpiredCleanupPreservesRecentAndUnownedEntries() throws {
        try withStore { store, _ in
            let expired = try store.newSession()
            let recent = try store.newSession()
            let unowned = store.root.appendingPathComponent("user-folder", isDirectory: true)
            let file = store.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
            try Data("ordinary file".utf8).write(to: file)
            let oldDate = Date().addingTimeInterval(-3 * 86_400)
            for url in [expired, unowned, file] {
                try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
            }
            store.cleanExpired()
            #expect(!(FileManager.default.fileExists(atPath: expired.path)))
            for protected in [recent, unowned, file] {
                #expect(FileManager.default.fileExists(atPath: protected.path))
            }
        }
    }
}

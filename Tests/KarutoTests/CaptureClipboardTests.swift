import AppKit
import ImageIO
import Testing
@testable import Karuto

@MainActor
struct CaptureClipboardTests {
    @Test func copiedScreenshotSupportsPNGAndTIFFReadersAfterSourceRemoval() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        let original = try Data(contentsOf: fixture.artifact.url)
        let clipboard = CaptureClipboard(pasteboard: fixture.pasteboard)
        try await clipboard.copy(fixture.artifact)
        // Promised TIFF must not depend on a file that a preview action can move.
        try FileManager.default.removeItem(at: fixture.artifact.url)
        #expect(fixture.pasteboard.data(forType: .png) == original)
        let tiff = try #require(fixture.pasteboard.data(forType: .tiff))
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 7)
        #expect(image.height == 5)
        #expect(NSImage(pasteboard: fixture.pasteboard) != nil)
    }

    @Test func explicitSnapshotDestinationsOverrideAutomaticSaveAndCopy() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        let suite = "Karuto-Snapshot-Destination-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.saveFolder = fixture.root.appendingPathComponent("Exports")
        let store = try CaptureStore(root: fixture.root.appendingPathComponent("Sessions"))
        let coordinator = CaptureCoordinator(settings: settings, store: store, clipboard: CaptureClipboard(pasteboard: fixture.pasteboard))
        let source = try #require(CGImageSourceCreateWithURL(fixture.artifact.url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        settings.autoSave = true
        settings.autoCopyScreenshots = false
        try await coordinator.finishSnapshot(image, destination: .clipboard)
        let png = try #require(fixture.pasteboard.data(forType: .png))
        let copied = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(copied, 0, nil)?.width == image.width)
        #expect(fixture.pasteboard.data(forType: .tiff) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: settings.saveFolder.path))

        settings.autoSave = false
        settings.autoCopyScreenshots = true
        let changeCount = fixture.pasteboard.changeCount
        try await coordinator.finishSnapshot(image, destination: .saveFolder)
        #expect(fixture.pasteboard.changeCount == changeCount)
        let saved = try FileManager.default.contentsOfDirectory(at: settings.saveFolder, includingPropertiesForKeys: nil)
        try #require(saved.count == 1)
        #expect(saved[0].pathExtension == "png")
        let savedSource = try #require(CGImageSourceCreateWithURL(saved[0] as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(savedSource, 0, nil)?.height == image.height)
    }

    @Test func videosDoNotReplaceClipboard() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        let video = CaptureArtifact(id: UUID(), url: fixture.artifact.url, kind: .video, width: 7, height: 5)
        await #expect(throws: CaptureClipboardError.self) {
            try await CaptureClipboard(pasteboard: fixture.pasteboard).copy(video)
        }
        #expect(fixture.pasteboard.string(forType: .string) == "Keep this clipboard")
    }

    @Test func missingAndInvalidImagesPreserveClipboard() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        try Data("Not a PNG".utf8).write(to: fixture.artifact.url)
        await #expect(throws: CaptureClipboardError.self) {
            try await CaptureClipboard(pasteboard: fixture.pasteboard).copy(fixture.artifact)
        }
        #expect(fixture.pasteboard.string(forType: .string) == "Keep this clipboard")
        try FileManager.default.removeItem(at: fixture.artifact.url)
        await #expect(throws: (any Error).self) {
            try await CaptureClipboard(pasteboard: fixture.pasteboard).copy(fixture.artifact)
        }
        #expect(fixture.pasteboard.string(forType: .string) == "Keep this clipboard")
    }

    @Test func oversizedImagesPreserveClipboard() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        let huge = CaptureArtifact(id: UUID(), url: fixture.artifact.url, kind: .image, width: 100_000, height: 100_000)
        await #expect(throws: StorageError.self) {
            try await CaptureClipboard(pasteboard: fixture.pasteboard).copy(huge)
        }
        #expect(fixture.pasteboard.string(forType: .string) == "Keep this clipboard")
    }

    @Test func cancelledCopyPreservesClipboard() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.cleanUp() }
        let clipboard = CaptureClipboard(pasteboard: fixture.pasteboard)
        let task = Task { try await clipboard.copy(fixture.artifact) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.pasteboard.string(forType: .string) == "Keep this clipboard")
    }
}

@MainActor
private struct ClipboardFixture {
    let root: URL
    let pasteboard: NSPasteboard
    let artifact: CaptureArtifact

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Karuto-ClipboardTests-\(UUID().uuidString)")
        let store = try CaptureStore(root: root)
        let context = try #require(CGContext(data: nil, width: 7, height: 5, bitsPerComponent: 8,
                                            bytesPerRow: 28, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 7, height: 5))
        let url = try store.writePNG(#require(context.makeImage()), in: root)
        artifact = CaptureArtifact(id: UUID(), url: url, kind: .image, width: 7, height: 5)
        pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        try #require(pasteboard.writeObjects(["Keep this clipboard" as NSString]))
    }

    func cleanUp() {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureClipboardError: LocalizedError {
    case notAnImage, invalidImage, unavailable

    var errorDescription: String? {
        switch self {
        case .notAnImage: "Only screenshots can be copied as images."
        case .invalidImage: "The screenshot could not be read as a PNG image."
        case .unavailable: "The clipboard could not accept the screenshot. Please try Copy again."
        }
    }
}

@MainActor
final class CaptureClipboard {
    nonisolated static let maximumPixelCount = 33_554_432
    private nonisolated static let maximumPNGBytes = 128 * 1024 * 1024
    private let pasteboard: NSPasteboard
    private var provider: ClipboardTIFFProvider?
    private var requestID: UInt64 = 0

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func copy(_ artifact: CaptureArtifact) async throws {
        try await copyPNG(width: artifact.width, height: artifact.height, kind: artifact.kind) {
            try Self.loadPNG(at: artifact.url)
        }
    }

    func copy(_ image: CGImage) async throws {
        try await copyPNG(width: image.width, height: image.height) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CaptureClipboardError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CaptureClipboardError.invalidImage }
            return data as Data
        }
    }

    private func copyPNG(width: Int, height: Int, kind: ArtifactKind = .image,
                         load: @escaping @Sendable () throws -> Data) async throws {
        requestID &+= 1
        let currentRequest = requestID
        guard kind == .image else { throw CaptureClipboardError.notAnImage }
        guard width > 0, height > 0, Double(width) * Double(height) <= Double(Self.maximumPixelCount) else {
            throw StorageError.oversizedClipboard
        }
        try Task.checkCancellation()
        let data = try await Task.detached(priority: .userInitiated, operation: load).value
        try Task.checkCancellation()
        guard currentRequest == requestID else { throw CancellationError() }
        guard data.count <= Self.maximumPNGBytes else { throw StorageError.oversizedClipboard }
        let item = NSPasteboardItem()
        let nextProvider = ClipboardTIFFProvider(png: data)
        guard item.setData(data, forType: .png),
              item.setDataProvider(nextProvider, forTypes: [.tiff]) else {
            throw CaptureClipboardError.unavailable
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CaptureClipboardError.unavailable }
        provider = nextProvider
    }

    private nonisolated static func loadPNG(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumPNGBytes else { throw StorageError.oversizedClipboard }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else {
            throw CaptureClipboardError.invalidImage
        }
        guard width.doubleValue * height.doubleValue <= Double(maximumPixelCount) else {
            throw StorageError.oversizedClipboard
        }
        return data
    }
}

/// PNG is available immediately. Decode only when a receiving app requests TIFF,
/// and release the compressed source when clipboard ownership changes.
private final class ClipboardTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var png: Data?

    init(png: Data) { self.png = png }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let data = lock.withLock({ png }) else { return }
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let tiff = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            item.setData(tiff as Data, forType: .tiff)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        lock.withLock { png = nil }
    }
}

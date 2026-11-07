import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum StorageError: LocalizedError {
    case encode, oversizedClipboard
    var errorDescription: String? {
        switch self {
        case .encode: "The image could not be saved. Check available disk space and try again."
        case .oversizedClipboard: "This image is too large for the clipboard. Save it or drag its file instead."
        }
    }
}

/// File operations have no mutable shared state; each session owns a unique directory.
final class CaptureStore: Sendable {
    let root: URL
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotX", isDirectory: true)) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func newSession() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func removeSession(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func cleanExpired() {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let date = values.contentModificationDate,
                  date < Date().addingTimeInterval(-86400) else { continue }
            try? fm.removeItem(at: directory)
        }
    }

    func writePNG(_ image: CGImage, in directory: URL) throws -> URL {
        let temporary = directory.appendingPathComponent("image.partial")
        let final = directory.appendingPathComponent("Screenshot.png")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw StorageError.encode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StorageError.encode }
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }

    func copyAtomically(from source: URL, to destination: URL) throws {
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".ScreenshotX-\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: partial) }
        try fm.copyItem(at: source, to: partial)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }
    }

    func save(_ artifact: CaptureArtifact, folder: URL) throws -> CaptureArtifact {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = artifact.kind == .video ? "mp4" : "png"
        let name = "ScreenshotX \(formatter.string(from: Date())) \(artifact.id.uuidString.prefix(6)).\(ext)"
        let destination = folder.appendingPathComponent(name)
        try copyAtomically(from: artifact.url, to: destination)
        var saved = artifact
        saved.url = destination
        saved.isSaved = true
        return saved
    }
}

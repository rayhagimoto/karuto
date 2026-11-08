import Foundation
import CoreGraphics
import CStitcher

struct StitchProgress: Sendable {
    let height: Int
    let message: String
    let accepted: Bool
    var disposition: Int = 0
    var contentRect: CGRect? = nil
    var viewportHeight: Int? = nil
    var sourceSize: CGSize = .zero
}

struct StitchOutput: Sendable {
    let width: Int
    let height: Int
}

struct StitchingError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// The lock covers append, finish and destruction. Rust never retains borrowed Swift bytes.
/// Call append on the frame callback queue and finish on a background worker, not MainActor.
final class StitchingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var firstFrameHeight: Int?
    private var capturedHeight = 0
    private let detectScrollContent: Bool
    private var calibrationRejected = false

    init(directory: URL, detectScrollContent: Bool = false) throws {
        self.detectScrollContent = detectScrollContent
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let created = directory.path.withCString { path in
            detectScrollContent ? sx_stitcher_create_calibrated(path, &message, capacity) : sx_stitcher_create(path, &message, capacity)
        }
        guard let created else { throw Self.error(message) }
        handle = created
    }

    func append(_ frame: PixelFrame) throws -> StitchProgress {
        try lock.withLock {
            guard let handle else { throw StitchingError(message: "The scrolling capture has ended.") }
            guard frame.width > 0, frame.height > 0, frame.bytesPerRow > 0,
                  frame.width <= Int(UInt32.max), frame.height <= Int(UInt32.max) else {
                throw StitchingError(message: "The capture frame has invalid dimensions.")
            }
            var progress = SXStitchProgress()
            var message = [CChar](repeating: 0, count: 512)
            let capacity = message.count
            let result = frame.data.withUnsafeBytes { raw in
                sx_stitcher_append(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count,
                                   UInt32(frame.width), UInt32(frame.height), frame.bytesPerRow,
                                   &progress, &message, capacity)
            }
            guard result == 0 else { throw Self.error(message) }
            var region = SXContentRect()
            let verified = detectScrollContent && sx_stitcher_content_rect(handle, &region) == 1
            calibrationRejected = detectScrollContent && progress.disposition == 2 && !verified
            let contentRect = verified ? CGRect(x: Int(region.x), y: Int(region.y), width: Int(region.width), height: Int(region.height)) : nil
            let height = progress.disposition == 4 ? 0 : Int(progress.height)
            let viewportHeight = verified ? Int(region.height) : frame.height
            if progress.disposition == 0, firstFrameHeight == nil { firstFrameHeight = viewportHeight }
            capturedHeight = height
            let extended = height > (firstFrameHeight ?? height)
            let movingArea = verified ? "Moving area \(Int(region.width)) × \(Int(region.height)) · " : ""
            let text: String
            switch progress.disposition {
            case 0: text = extended ? "\(movingArea)\(height) px captured." : "Ready · Scroll down inside the selected content to extend capture."
            case 1: text = extended ? "\(height) px captured · Scroll to add more." : "No scrolling captured yet · Scroll inside the selected content."
            case 2: text = "Cannot align content · Scroll back slowly, or restart with fixed headers and sidebars outside the selection."
            case 3: text = "Capture limit reached. Choose Finish to save \(height) px."
            case 4: text = "Checking moving content… Scroll gently while the area is verified."
            default: text = "Scroll down slowly, keeping previous content visible."
            }
            return StitchProgress(height: height, message: text, accepted: progress.disposition == 0, disposition: Int(progress.disposition), contentRect: contentRect, viewportHeight: viewportHeight, sourceSize: CGSize(width: frame.width, height: frame.height))
        }
    }

    var needsAreaAdjustment: Bool { lock.withLock { calibrationRejected } }

    var verifiedContentRect: CGRect? {
        lock.withLock {
            guard detectScrollContent, let handle else { return nil }
            var region = SXContentRect()
            guard sx_stitcher_content_rect(handle, &region) == 1 else { return nil }
            return CGRect(x: Int(region.x), y: Int(region.y), width: Int(region.width), height: Int(region.height))
        }
    }

    func finish(to destination: URL) throws -> StitchOutput {
        try lock.withLock {
            guard let handle else { throw StitchingError(message: "The scrolling capture has ended.") }
            if detectScrollContent, firstFrameHeight == nil {
                throw StitchingError(message: "Could not verify one scrolling content area. Adjust the selection and try again.")
            }
            guard let firstFrameHeight, capturedHeight > firstFrameHeight else {
                throw StitchingError(message: "No scrolling content was added. Try again: select only the moving content, exclude fixed headers and sidebars, and scroll down slowly before finishing.")
            }
            var progress = SXStitchProgress()
            var message = [CChar](repeating: 0, count: 512)
            let capacity = message.count
            let result = destination.path.withCString { path in
                sx_stitcher_finish(handle, path, &progress, &message, capacity)
            }
            guard result == 0 else { throw Self.error(message) }
            sx_stitcher_destroy(handle)
            self.handle = nil
            return StitchOutput(width: Int(progress.width), height: Int(progress.height))
        }
    }

    func cancel() {
        lock.withLock {
            if let handle { sx_stitcher_destroy(handle) }
            handle = nil
        }
    }

    deinit {
        if let handle { sx_stitcher_destroy(handle) }
    }

    private static func error(_ buffer: [CChar]) -> StitchingError {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let message = String(decoding: bytes, as: UTF8.self)
        return StitchingError(message: message.isEmpty ? "Scrolling capture failed." : message)
    }
}

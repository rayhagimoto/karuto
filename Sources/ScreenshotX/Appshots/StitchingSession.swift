import Foundation
import CStitcher

struct StitchProgress: Sendable {
    let height: Int
    let message: String
    let accepted: Bool
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

    init(directory: URL) throws {
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let created = directory.path.withCString { path in
            sx_stitcher_create(path, &message, capacity)
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
            let height = Int(progress.height)
            let text: String
            switch progress.disposition {
            case 0: text = "\(height) px captured · Scroll down slowly."
            case 1: text = "\(height) px captured · Scroll to add more."
            case 2: text = "Scroll back slightly to reconnect. Exclude fixed headers if needed."
            case 3: text = "Capture limit reached. Choose Finish to save \(height) px."
            default: text = "Scroll down slowly, keeping previous content visible."
            }
            return StitchProgress(height: height, message: text, accepted: progress.disposition == 0)
        }
    }

    func finish(to destination: URL) throws -> StitchOutput {
        try lock.withLock {
            guard let handle else { throw StitchingError(message: "The scrolling capture has ended.") }
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

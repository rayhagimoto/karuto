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
/// Call append on the serial stitching queue and finish on a background worker, not MainActor.
final class StitchingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var firstFrameHeight: Int?
    private var capturedHeight = 0
    private let detectScrollContent: Bool
    private var calibrationRejected = false
    private var pendingHint: CGRect?
    private var hintBottom: Int?
    private var missedOverlap = false
    private var reachedLimit = false
    private var excludedTail = false
    private var waitingForBaseline: Bool
    private var baseline: (frame: PixelFrame, changedAt: ContinuousClock.Instant)?

    init(directory: URL, detectScrollContent: Bool = false, contentHint: CGRect? = nil,
         waitForBaseline: Bool = false) throws {
        waitingForBaseline = waitForBaseline
        self.detectScrollContent = detectScrollContent
        pendingHint = contentHint.flatMap { hint in
            CGRect(x: 0, y: 0, width: 1, height: 1).contains(hint) && !hint.isEmpty ? hint : nil
        }
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let created = directory.path.withCString { path in
            detectScrollContent ? sx_stitcher_create_calibrated(path, &message, capacity) : sx_stitcher_create(path, &message, capacity)
        }
        guard let created else { throw Self.error(message) }
        handle = created
    }

    func append(_ frame: PixelFrame, at now: ContinuousClock.Instant = .now) throws -> StitchProgress {
        try lock.withLock {
            guard let handle else { throw StitchingError(message: "The scrolling capture has ended.") }
            guard frame.width > 0, frame.height > 0, frame.bytesPerRow > 0,
                  frame.width <= Int(UInt32.max), frame.height <= Int(UInt32.max) else {
                throw StitchingError(message: "The capture frame has invalid dimensions.")
            }
            guard waitingForBaseline else { return try appendLocked(frame, handle: handle) }
            if let previous = baseline, previous.frame.data == frame.data,
               previous.frame.width == frame.width, previous.frame.height == frame.height,
               previous.frame.bytesPerRow == frame.bytesPerRow {
                baseline = (frame, previous.changedAt)
            } else {
                baseline = (frame, now)
            }
            return StitchProgress(height: 0, message: "Waiting for content to settle…", accepted: false,
                                  disposition: 4, sourceSize: CGSize(width: frame.width, height: frame.height))
        }
    }

    /// Automatic input has not moved the viewport yet. Use only its most recent
    /// frame so an initial layout change cannot be mistaken for scroll motion.
    func beginMotion(force: Bool, at now: ContinuousClock.Instant = .now) throws -> Bool {
        try lock.withLock {
            guard let handle else { throw StitchingError(message: "The scrolling capture has ended.") }
            guard waitingForBaseline else { return true }
            guard let baseline else {
                if force { waitingForBaseline = false }
                return false
            }
            guard force || baseline.changedAt.duration(to: now) >= .milliseconds(450) else { return false }
            _ = try appendLocked(baseline.frame, handle: handle)
            self.baseline = nil
            waitingForBaseline = false
            return true
        }
    }

    private func appendLocked(_ frame: PixelFrame, handle: OpaquePointer) throws -> StitchProgress {
        if let hint = pendingHint {
            pendingHint = nil
            let x = max(0, Int(ceil(hint.minX * CGFloat(frame.width))))
            let y = max(0, Int(ceil(hint.minY * CGFloat(frame.height))))
            let right = min(frame.width, Int(floor(hint.maxX * CGFloat(frame.width))))
            let bottom = min(frame.height, Int(floor(hint.maxY * CGFloat(frame.height))))
            if right - x >= 16, bottom - y >= 32 {
                let rect = SXContentRect(x: UInt32(x), y: UInt32(y), width: UInt32(right - x), height: UInt32(bottom - y))
                if sx_stitcher_set_content_hint(handle, rect) == 0 { hintBottom = bottom }
            }
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
        if let contentRect {
            let bottom = hintBottom ?? frame.height
            let isFullWidth = Int(contentRect.width) >= frame.width - 4 && contentRect.minY <= 2
            // Static chrome outside a suggested pane is expected. A bottom
            // band inside the pane may cover rows the capture could not see.
            excludedTail = (hintBottom != nil || isFullWidth) &&
                bottom - Int(contentRect.maxY) > max(4, frame.height / 32)
        }
        if progress.disposition == 2 { missedOverlap = true }
        if progress.disposition == 0 || progress.disposition == 5 { missedOverlap = false }
        if progress.disposition == 3 { reachedLimit = true }
        let height = progress.disposition == 4 ? 0 : Int(progress.height)
        let viewportHeight = verified ? Int(region.height) : frame.height
        if progress.disposition == 0, firstFrameHeight == nil { firstFrameHeight = viewportHeight }
        capturedHeight = height
        let extended = height > (firstFrameHeight ?? height)
        let movingArea = verified ? "Moving area \(Int(region.width)) × \(Int(region.height)) · " : ""
        let text: String
        switch progress.disposition {
        case 0: text = extended ? "\(movingArea)\(height) px captured." : "Ready · Scroll down inside the selected content to extend capture."
        case 1 where missedOverlap, 2:
            text = "Return to the last captured area and scroll slowly, or choose Finish to review the partial capture."
        case 1: text = extended ? "\(height) px captured · Scroll to add more." : "No scrolling captured yet · Scroll inside the selected content."
        case 3: text = "Capture limit reached. Choose Finish to review \(height) px."
        case 4: text = "Checking moving content… Scroll down to verify the area."
        case 5: text = "Back at the last captured area. Scroll down slowly to continue."
        default: text = "Scroll down slowly, keeping previous content visible."
        }
        return StitchProgress(height: height, message: text, accepted: progress.disposition == 0, disposition: Int(progress.disposition), contentRect: contentRect, viewportHeight: viewportHeight, sourceSize: CGSize(width: frame.width, height: frame.height))
    }

    var needsAreaAdjustment: Bool { lock.withLock { calibrationRejected } }

    var partialReason: String? { lock.withLock { incompleteReason } }

    private var incompleteReason: String? {
        if missedOverlap { return "The overlap could not be verified. Only the verified portion can be saved." }
        if reachedLimit { return "The capture reached its limit. Only the verified portion can be saved." }
        if excludedTail { return "A fixed bottom band was excluded and may cover the end of the content." }
        return nil
    }

    var verifiedContentRect: CGRect? {
        lock.withLock {
            guard detectScrollContent, let handle else { return nil }
            var region = SXContentRect()
            guard sx_stitcher_content_rect(handle, &region) == 1 else { return nil }
            return CGRect(x: Int(region.x), y: Int(region.y), width: Int(region.width), height: Int(region.height))
        }
    }

    func finish(to destination: URL, allowPartial: Bool = false) throws -> StitchOutput {
        try lock.withLock {
            guard let handle else { throw StitchingError(message: "The scrolling capture has ended.") }
            if detectScrollContent, firstFrameHeight == nil {
                throw StitchingError(message: "Could not verify one scrolling content area. Adjust the selection and try again.")
            }
            guard let firstFrameHeight, capturedHeight > firstFrameHeight else {
                throw StitchingError(message: "No scrolling content was added. Try again: select only the moving content, exclude fixed headers and sidebars, and scroll down slowly before finishing.")
            }
            if !allowPartial, let incompleteReason {
                throw StitchingError(message: incompleteReason)
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
            baseline = nil
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

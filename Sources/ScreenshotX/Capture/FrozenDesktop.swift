import Foundation
import CoreGraphics

/// One immutable, session-owned frame per display. Cropping never consults the
/// live desktop, so the exported pixels are the same ones used by selection UI.
struct FrozenDesktop {
    let catalog: CaptureCatalog
    let frames: [UInt32: CGImage]

    /// Limits retained BGRA display frames to 256 MiB, excluding system capture
    /// buffers and any final image crop. No frames are retained between sessions.
    static let maximumPixelCount = 256 * 1024 * 1024 / 4

    func image(for target: CaptureTarget) throws -> CGImage {
        switch target {
        case .display(let id):
            guard let image = frames[id] else { throw CaptureError.targetMissing }
            return image
        case .area(let id, let rect):
            guard let display = catalog.displays.first(where: { $0.id == id }) else { throw CaptureError.targetMissing }
            return try crop(rect, on: display)
        case .window(let id):
            guard let window = catalog.windows.first(where: { $0.id == id }) else { throw CaptureError.targetMissing }
            let displays = catalog.displays.filter {
                let intersection = $0.frame.intersection(window.frame)
                return !intersection.isNull && intersection.width > 0 && intersection.height > 0
            }
            guard let display = displays.first else { throw CaptureError.targetMissing }
            guard displays.count == 1 else { throw FrozenDesktopError.windowSpansDisplays }
            // A frozen window is its visible screen rectangle, including any
            // occlusion, rather than a fresh independent-window capture.
            return try crop(window.frame.intersection(display.frame), on: display)
        }
    }

    private func crop(_ rect: CGRect, on display: CaptureDisplay) throws -> CGImage {
        guard let image = frames[display.id] else { throw CaptureError.targetMissing }
        let source = try CaptureGeometry.sourceRect(selection: rect, displayFrame: display.frame)
        let scaleX = CGFloat(image.width) / display.frame.width
        let scaleY = CGFloat(image.height) / display.frame.height
        let pixels = CGRect(x: source.minX * scaleX, y: source.minY * scaleY,
                            width: source.width * scaleX, height: source.height * scaleY).integral
        guard let result = image.cropping(to: pixels) else { throw CaptureError.invalidArea }
        return result
    }
}

enum FrozenDesktopError: LocalizedError {
    case tooLarge, windowSpansDisplays

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "These displays exceed the 256 MB frozen-frame limit. Turn off Freeze Display or reduce display resolution."
        case .windowSpansDisplays:
            "For a frozen window screenshot, choose a window on one display, use Area capture, or turn off Freeze Display."
        }
    }
}

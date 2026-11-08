import Foundation
import CoreGraphics

enum CaptureGeometry {
    /// ScreenCaptureKit/Quartz global frames have a top-left origin on the primary display.
    static func appKitRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a global AppKit selection to a display-local, top-left-origin source rectangle.
    static func sourceRect(selection: CGRect, displayFrame: CGRect) throws -> CGRect {
        guard selection.origin.x.isFinite, selection.origin.y.isFinite,
              selection.width.isFinite, selection.height.isFinite,
              selection.width >= 1, selection.height >= 1,
              displayFrame.contains(selection) else {
            throw CaptureError.invalidArea
        }
        return CGRect(x: selection.minX - displayFrame.minX,
                      y: displayFrame.maxY - selection.maxY,
                      width: selection.width, height: selection.height)
    }

    static func pixelSize(points: CGSize, scale: CGFloat) throws -> (width: Int, height: Int) {
        let width = (points.width * scale).rounded(.up)
        let height = (points.height * scale).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 32768, height <= 32768 else { throw CaptureError.invalidArea }
        return (Int(width), Int(height))
    }

    /// H.264 needs even output dimensions; fitting never enlarges source content.
    static func recordingSize(width: Int, height: Int, resolution: RecordingResolution) throws -> (width: Int, height: Int) {
        guard width >= 2, height >= 2 else { throw CaptureError.invalidArea }
        let ratio: Double = resolution == .hd1080
            ? min(1, min(1920 / Double(width), 1080 / Double(height))) : 1
        let outputWidth = max(2, Int(Double(width) * ratio) / 2 * 2)
        let outputHeight = max(2, Int(Double(height) * ratio) / 2 * 2)
        // A conservative alpha limit for the H.264 direct-to-file path.
        guard outputWidth <= 4096, outputHeight <= 4096 else { throw CaptureError.recordingTooLarge }
        return (outputWidth, outputHeight)
    }
}

enum CaptureError: LocalizedError {
    case screenPermission, microphonePermission, targetMissing, invalidArea, busy, notRecording
    case recordingTooLarge, appshotTooLarge, recordingTimedOut, stoppedUnexpectedly
    case exclusionUnavailable

    var errorDescription: String? {
        switch self {
        case .screenPermission: "Allow Karuto in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. You may need to reopen the app after granting access."
        case .microphonePermission: "Allow Karuto microphone access in System Settings → Privacy & Security → Microphone, or turn off microphone recording."
        case .targetMissing: "The selected window or display is no longer available. Please select it again."
        case .invalidArea: "Choose a nonempty area entirely within one display."
        case .busy: "A capture is already in progress. Finish it before starting another."
        case .notRecording: "There is no active recording to stop."
        case .recordingTooLarge: "This recording is too large for the alpha's H.264 output. Choose 1080p or a smaller area."
        case .appshotTooLarge: "Choose a smaller appshot region: at most 4096 pixels wide, 8192 pixels tall and 8 million pixels total."
        case .recordingTimedOut: "Recording did not start or finish in time. Please try again."
        case .stoppedUnexpectedly: "Capture stopped unexpectedly. The target may have closed or screen access may have changed."
        case .exclusionUnavailable: "Karuto could not exclude its capture controls from the recording. Please reopen capture and try again."
        }
    }
}

import AppKit
import VisionKit

enum TextCaptureError: LocalizedError {
    case unsupported, clipboard
    var errorDescription: String? {
        switch self {
        case .unsupported: "Live Text is not supported on this Mac."
        case .clipboard: "The clipboard could not accept the text. Try copying again."
        }
    }
}

/// The same analysis supplies both the copied transcript and native selection overlay.
final class TextCaptureService: Sendable {
    func recognize(_ image: CGImage) async throws -> ImageAnalysis {
        guard ImageAnalyzer.isSupported else { throw TextCaptureError.unsupported }
        try Task.checkCancellation()
        let analyzer = ImageAnalyzer()
        let analysis = try await analyzer.analyze(image, orientation: .up, configuration: .init(.text))
        try Task.checkCancellation()
        return analysis
    }

    @MainActor
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) throws -> Bool {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw TextCaptureError.clipboard }
        return true
    }
}

import AppKit
import VisionKit

/// Live Text and its source pixels share the capture canvas's point coordinates.
@MainActor
final class InlineTextPreview: NSView, NSGestureRecognizerDelegate {
    let target: CaptureTarget
    let text = ImageAnalysisOverlayView(frame: .zero)
    private let pixels = CALayer()
    private var recognition: Task<Void, Never>?
    private(set) var status = "Reading text…"
    private(set) var isReading = true
    var onChange: (() -> Void)?
    var onCopy: ((String) -> Void)?

    init(frame: CGRect, target: CaptureTarget, canvas: CALayer) {
        self.target = target
        super.init(frame: frame)
        pixels.frame = frame
        pixels.actions = ["contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        canvas.insertSublayer(pixels, at: 0)
        text.frame = bounds
        text.autoresizingMask = [.width, .height]
        text.preferredInteractionTypes = .textSelection
        text.isSupplementaryInterfaceHidden = true
        addSubview(text)
        let click = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        click.numberOfClicksRequired = 2
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = self
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func read(using sample: @escaping (CaptureTarget) async throws -> CGImage) {
        let target = target
        recognition = Task { [weak self] in
            do {
                let image = try await sample(target)
                try Task.checkCancellation()
                self?.pixels.contents = image
                let result = try await TextCaptureService().recognize(image)
                try Task.checkCancellation()
                guard let self else { return }
                text.analysis = result
                text.selectableItemsHighlighted = true
                status = result.transcript.isEmpty ? "No text found" : "Double-click a word to copy"
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = error.localizedDescription
            }
            self?.isReading = false
            self?.onChange?()
        }
    }

    func close() {
        recognition?.cancel()
        onChange = nil
        onCopy = nil
        text.analysis = nil
        pixels.removeFromSuperlayer()
        removeFromSuperview()
    }

    /// Leave blank space and crop handles available to the selection canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard hasText(at: local) else { return nil }
        return super.hitTest(point)
    }

    func hasText(at point: CGPoint) -> Bool {
        // VisionKit queries the image from its top left. The capture canvas uses AppKit points.
        bounds.contains(point) && text.hasText(at: CGPoint(x: point.x, y: bounds.height - point.y))
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }

    @objc private func doubleClicked() {
        // Let Live Text finish the same mouse event before reading its word selection.
        Task { @MainActor [weak self] in
            guard let self, !text.selectedText.isEmpty else { return }
            onCopy?(text.selectedText)
        }
    }
}

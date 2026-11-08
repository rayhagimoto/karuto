import AppKit
import QuartzCore

/// Retained selection artwork in local AppKit points. The view hosts this tree
/// directly, so dragging never repaints a display-sized AppKit backing store.
@MainActor
final class SelectionOverlayRenderer {
    let rootLayer = CALayer()
    private let shade = CAShapeLayer()
    private let selection = CALayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let badge = CALayer()
    private let label = CATextLayer()
    private let bounds: CGRect
    private var state: State?
    private var badgeSize = CGSize.zero
    private let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    private struct State: Equatable {
        var rect: CGRect?
        var text: String
        var resizable: Bool
        var preview: Bool
    }

    init(size: CGSize, scale: CGFloat) {
        bounds = CGRect(origin: .zero, size: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        rootLayer.masksToBounds = true
        // WindowServer skips fully transparent pixels during mouse hit-testing.
        // Retain negligible coverage so the clear selection interior can be moved.
        // https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:)
        rootLayer.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        shade.fillColor = NSColor.black.withAlphaComponent(0.34).cgColor
        shade.fillRule = .evenOdd
        shade.frame = bounds
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1
        handles.fillColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        badge.cornerRadius = 6
        label.truncationMode = .end
        rootLayer.addSublayer(shade)
        rootLayer.addSublayer(selection)
        selection.addSublayer(border)
        selection.addSublayer(handles)
        rootLayer.addSublayer(badge)
        badge.addSublayer(label)
        CATransaction.commit()
        updateScale(scale)
        update(rect: nil, text: "", resizable: false)
    }

    func updateScale(_ scale: CGFloat) {
        guard rootLayer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [rootLayer, shade, selection, border, handles, badge, label] {
            layer.contentsScale = scale
        }
        CATransaction.commit()
    }

    /// Returns false without mutating layers for repeated or off-display state.
    /// Transactions commit with the current AppKit event; no fixed-rate timer or
    /// interpolation can leave the visible selection behind the pointer model.
    @discardableResult
    func update(rect: CGRect?, text: String, resizable: Bool, preview: Bool = false) -> Bool {
        let visibleRect = rect.flatMap { $0.intersects(bounds) && !$0.isEmpty ? $0 : nil }
        let next = State(rect: visibleRect, text: visibleRect == nil ? "" : text, resizable: visibleRect != nil && resizable, preview: preview)
        guard state != next else { return false }
        let previous = state
        state = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if previous?.rect != next.rect || previous == nil {
            let path = CGMutablePath()
            path.addRect(bounds)
            if let rect = next.rect { path.addRect(rect.intersection(bounds)) }
            shade.path = path
        }
        border.lineDashPattern = next.preview ? [6, 4] : nil
        selection.isHidden = next.rect == nil
        badge.isHidden = next.rect == nil || next.text.isEmpty
        guard let rect = next.rect else { return true }

        selection.frame = rect
        if previous?.rect?.size != rect.size {
            border.frame = CGRect(origin: .zero, size: rect.size)
            handles.frame = border.frame
            border.path = CGPath(rect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 0.5, dy: 0.5), transform: nil)
        }
        handles.isHidden = !next.resizable
        if next.resizable && (previous?.rect?.size != rect.size || previous?.resizable != true) {
            let path = CGMutablePath()
            for point in Self.handlePoints(in: CGRect(origin: .zero, size: rect.size)) {
                path.addRoundedRect(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), cornerWidth: 2, cornerHeight: 2)
            }
            handles.path = path
        }
        if previous?.text != next.text {
            let text = NSAttributedString(string: next.text, attributes: textAttributes)
            badgeSize = CGSize(width: min(ceil(text.size().width) + 16, max(16, bounds.width - 16)), height: 24)
            label.string = text
            label.frame = CGRect(x: 8, y: 4, width: badgeSize.width - 16, height: 16)
        }
        badge.frame = CGRect(
            x: min(max(rect.midX - badgeSize.width / 2, 8), bounds.maxX - badgeSize.width - 8),
            y: max(8, min(rect.minY - 30, bounds.maxY - 28)),
            width: badgeSize.width, height: badgeSize.height)
        return true
    }

    static func handlePoints(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
}

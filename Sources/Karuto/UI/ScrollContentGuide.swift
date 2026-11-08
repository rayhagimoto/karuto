import AppKit
import QuartzCore

/// Shows the verified moving crop without taking focus or intercepting scrolling.
@MainActor
final class ScrollContentGuide {
    private var panel: CapturePanel?
    private var lastRect: CGRect?

    func show(region: CGRect, sourceSize: CGSize, target: CaptureTarget, catalog: CaptureCatalog?) {
        guard let catalog, sourceSize.width > 0, sourceSize.height > 0 else { return }
        let source: CGRect?
        switch target {
        case .area(_, let rect): source = rect
        case .display(let id): source = catalog.displays.first { $0.id == id }?.frame
        case .window(let id): source = catalog.windows.first { $0.id == id }?.frame
        }
        guard let source else { return }
        let xScale = source.width / sourceSize.width
        let yScale = source.height / sourceSize.height
        let rect = CGRect(x: source.minX + region.minX * xScale,
                          y: source.maxY - region.maxY * yScale,
                          width: region.width * xScale, height: region.height * yScale)
        guard rect != lastRect else { return }
        dismiss()
        lastRect = rect
        let panel = CapturePanel(contentRect: rect.insetBy(dx: -2, dy: -2), level: .statusBar)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemTeal.cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [5, 4]
        view.layer = border
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        panel.contentView = view
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        lastRect = nil
    }
}

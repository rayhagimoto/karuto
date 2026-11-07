import AppKit

@MainActor
final class SessionControlsController {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private var panel: CapturePanel?
    private var messageLabel: NSTextField?

    func show(title: String, message: String, stopTitle: String, allowsCancel: Bool = true) {
        dismiss()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
        let panel = CapturePanel(contentRect: CGRect(x: bounds.midX - 210, y: bounds.maxY - 100, width: 420, height: 82), level: .statusBar)
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        let surface = CaptureSurface(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        let row = NSStackView()
        row.spacing = 12
        pinSubview(row, to: surface.contentView, inset: 12)
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        let titleLabel = captureLabel(title, size: 13, color: .labelColor)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        column.addArrangedSubview(titleLabel)
        let label = captureLabel(message, size: 11)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        column.addArrangedSubview(label)
        messageLabel = label
        row.addArrangedSubview(column)
        if !stopTitle.isEmpty {
            let stop = CaptureActionButton(title: stopTitle, symbol: "stop.fill") { [weak self] in self?.onStop?() }
            stop.emphasized = true
            stop.contentTintColor = .systemRed
            stop.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(stop)
        }
        if allowsCancel {
            let cancel = CaptureActionButton(title: "Cancel") { [weak self] in self?.onCancel?() }
            row.addArrangedSubview(cancel)
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func update(message: String) { messageLabel?.stringValue = message }
    func dismiss() { panel?.orderOut(nil); panel = nil; messageLabel = nil }
}

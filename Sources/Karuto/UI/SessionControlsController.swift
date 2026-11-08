import AppKit

@MainActor
final class SessionControlsController {
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onManual: (() -> Void)?
    var onReselect: (() -> Void)?
    private var panel: CapturePanel?
    private var messageLabel: NSTextField?

    func show(title: String, message: String, stopTitle: String, allowsCancel: Bool = true, allowsManual: Bool = false, allowsReselect: Bool = false) {
        let expanded = allowsManual || allowsReselect
        dismiss()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
        let width: CGFloat = expanded ? 560 : 420
        let height: CGFloat = expanded ? 118 : 82
        let panel = CapturePanel(contentRect: CGRect(x: bounds.midX - width / 2, y: bounds.maxY - height - 18, width: width, height: height), level: .statusBar)
        panel.isMovableByWindowBackground = true
        let surface = CaptureSurface(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        let row = NSStackView()
        row.spacing = 12
        row.orientation = expanded ? .vertical : .horizontal
        row.alignment = expanded ? .leading : .centerY
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
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        row.addArrangedSubview(actions)
        if expanded {
            column.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            label.lineBreakMode = .byWordWrapping
            label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            let spacer = NSView()
            actions.addArrangedSubview(spacer)
            actions.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        if allowsReselect {
            let adjust = CaptureActionButton(title: "Adjust Area") { [weak self] in self?.onReselect?() }
            actions.addArrangedSubview(adjust)
        }
        if allowsManual {
            let manual = CaptureActionButton(title: "Scroll Manually") { [weak self] in self?.onManual?() }
            manual.setAccessibilityLabel("Switch to manual scrolling")
            actions.addArrangedSubview(manual)
        }
        if !stopTitle.isEmpty {
            let stop = CaptureActionButton(title: stopTitle, symbol: "stop.fill") { [weak self] in self?.onStop?() }
            stop.emphasized = true
            stop.contentTintColor = .systemRed
            stop.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.addArrangedSubview(stop)
        }
        if allowsCancel {
            let cancel = CaptureActionButton(title: "Cancel") { [weak self] in self?.onCancel?() }
            actions.addArrangedSubview(cancel)
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func update(message: String) { messageLabel?.stringValue = message }
    func dismiss() { panel?.orderOut(nil); panel = nil; messageLabel = nil }
}

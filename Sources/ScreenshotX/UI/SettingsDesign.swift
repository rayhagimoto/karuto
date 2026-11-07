import AppKit

/// Native material with a single content boundary. Controls live inside the
/// glass content view, so AppKit owns their compositing and vibrancy.
@MainActor
final class SettingsGlassSurface: NSView {
    let content = SettingsContentView()

    init(cornerRadius: CGFloat = 20, interactive: Bool = false) {
        super.init(frame: .zero)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
            glass.contentView = content
            pinSubview(glass, to: self)
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
            ])
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = cornerRadius
            material.layer?.masksToBounds = true
            pinSubview(material, to: self)
            pinSubview(content, to: material)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class SettingsContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Explicit icon and text alignment avoids NSButtonCell's bezel/alignment insets.
@MainActor
final class SettingsNavigationButton: NSButton {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var handler: (() -> Void)?

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(invoke)
        setButtonType(.toggle)
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        setAccessibilityLabel(title + " settings")
        setAccessibilityRole(.radioButton)
        wantsLayer = true
        layer?.cornerRadius = 12
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.isSelectable = false
        label.setAccessibilityElement(false)
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    func select(_ selected: Bool) {
        state = selected ? .on : .off
        layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.075).cgColor : NSColor.clear.cgColor
        icon.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        setAccessibilityValue(selected ? 1 : 0)
    }
    @objc private func invoke() { handler?() }
}

@MainActor
func styleSettingsButton(_ button: NSButton) {
    button.font = .systemFont(ofSize: 13, weight: .medium)
    button.controlSize = .large
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
}

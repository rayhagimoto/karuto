import AppKit

@MainActor
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, level: NSWindow.Level = .floating) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentMinSize = contentRect.size
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        self.level = level
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // CaptureEngine excludes transient Karuto controls while allowing
        // Preferences. Keep native windows shareable for accessibility tooling.
        animationBehavior = .none
    }
}

@MainActor
class ClosureButton: NSButton {
    var handler: (() -> Void)?
    init(title: String, symbol: String? = nil, handler: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        self.handler = handler
        target = self
        action = #selector(invoke)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: .medium)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func invoke() { handler?() }
}


@MainActor
final class CaptureModeButton: ClosureButton {
    private let iconView = NSImageView()
    private let labelView = NSTextField(labelWithString: "")

    override var title: String {
        didSet { labelView.stringValue = title }
    }
    override var image: NSImage? {
        didSet { updateAppearance() }
    }
    override var state: NSControl.StateValue {
        didSet { updateAppearance() }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 54) }
    // This button draws explicit rows, not the native bezel. Native image-based
    // alignment insets otherwise extend its layer above the stack's 5pt padding.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override init(title: String, symbol: String? = nil, handler: (() -> Void)? = nil) {
        super.init(title: title, symbol: symbol, handler: handler)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 11
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        setAccessibilityRole(.radioButton)

        // The icon occupies its own fixed row. Its original aspect ratio is
        // preserved, so narrow arrows and wide display symbols are not stretched.
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.setAccessibilityElement(false)
        addSubview(iconView)

        // Every mode shares the same label row and baseline, independent of its
        // icon's dimensions. Labels never receive text selection or cell tinting.
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.stringValue = title
        labelView.font = .systemFont(ofSize: 13, weight: .regular)
        labelView.alignment = .center
        labelView.isSelectable = false
        labelView.isEditable = false
        labelView.setAccessibilityElement(false)
        addSubview(labelView)
        updateAppearance()
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            labelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            labelView.topAnchor.constraint(equalTo: topAnchor, constant: 33),
            labelView.heightAnchor.constraint(equalToConstant: 17)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setButtonType(_ type: NSButton.ButtonType) {
        super.setButtonType(type)
        // Setting the type resets the cell masks; keep toggle tracking tint-only.
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        setAccessibilityValue(state == .on ? 1 : 0)
        // Event handlers and appearance-change callbacks need not run inside
        // this view's drawing appearance. Palette images and CGColors resolve
        // immediately, so use the view's override rather than the system theme.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let tint = NSColor.labelColor.withAlphaComponent(state == .on ? 1 : 0.72)
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            iconView.image = image?.withSymbolConfiguration(configuration)
            labelView.textColor = tint
            layer?.backgroundColor = state == .on ? NSColor.labelColor.withAlphaComponent(0.055).cgColor : NSColor.clear.cgColor
        }
    }

    // Keep the whole tile as one native button, including clicks on its subviews.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) { /* The two explicit rows draw the contents. */ }
}

@MainActor
final class CaptureActionButton: ClosureButton {
    var emphasized = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: ceil(textWidth) + 24 + (image == nil ? 0 : 20), height: 26)
    }

    override init(title: String, symbol: String? = nil, handler: (() -> Void)? = nil) {
        super.init(title: title, symbol: symbol, handler: handler)
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let fill: CGFloat = isHighlighted ? 0.22 : emphasized ? 0.13 : 0.06
        NSColor.labelColor.withAlphaComponent(isEnabled ? fill : 0.03).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let tint = (contentTintColor ?? .labelColor).withAlphaComponent(isEnabled ? 0.9 : 0.3)
        var textX: CGFloat = 12
        if let image {
            image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))?.draw(
                in: NSRect(x: 12, y: bounds.midY - 6, width: 12, height: 12), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += 20
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: tint]
        let textSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: textX, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        }
    }
}

@MainActor
final class CaptureSurface: NSView {
    /// All controls belong inside the system glass content view, never beside it.
    let contentView = NSView()
    var cornerRadius: CGFloat = 16 { didSet { updateCornerRadius() } }
    private var effectView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = contentView
            // The native effect supplies refraction, blur, and its own edge
            // treatment. No painted tint or extra border sits over the glass.
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            effectView = glass
            pinSubview(glass, to: self)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: glass.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
            ])
        } else {
            // Older supported macOS versions retain the native blurred material.
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.isEmphasized = false
            material.wantsLayer = true
            effectView = material
            pinSubview(material, to: self)
            pinSubview(contentView, to: material)
        }
        updateCornerRadius()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateCornerRadius() {
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            effectView?.layer?.cornerRadius = cornerRadius
            effectView?.layer?.masksToBounds = true
        }
    }
}

@MainActor
func captureLabel(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = color
    return label
}

@MainActor
func pinSubview(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

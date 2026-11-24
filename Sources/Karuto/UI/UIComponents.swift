import AppKit
import SwiftUI

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


/// AppKit owns panel focus, menu anchoring and dragging. SwiftUI draws the system symbols.
@MainActor
final class CaptureToolbarButton: ClosureButton {
    private let glyph: NSHostingView<ToolbarGlyph>
    let showsCheckmark: Bool
    var focusHint: String
    var focusChanged: (() -> Void)?
    var symbolName: String { didSet { if oldValue != symbolName { updateGlyph() } } }
    var drawsSelection = true
    private var keyboardFocused = false
    override var state: NSControl.StateValue { didSet { if oldValue != state { updateGlyph() } } }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { updateGlyph() } } }
    override var isHighlighted: Bool { didSet { if oldValue != isHighlighted { updateGlyph() } } }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 32) }

    init(_ label: String, symbol: String, checked: Bool = false, handler: (() -> Void)? = nil) {
        focusHint = label
        showsCheckmark = checked
        symbolName = symbol
        glyph = NSHostingView(rootView: ToolbarGlyph(symbol: symbol))
        super.init(title: "", handler: handler)
        isBordered = false
        focusRingType = .none
        if checked {
            setButtonType(.toggle)
            setAccessibilityRole(.checkBox)
        }
        setAccessibilityLabel(label)
        toolTip = label
        glyph.sizingOptions = []
        glyph.setAccessibilityElement(false)
        pinSubview(glyph, to: self)
        updateGlyph()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateGlyph() {
        glyph.rootView = ToolbarGlyph(symbol: symbolName,
                                      selected: state == .on, drawsSelection: drawsSelection, checked: showsCheckmark && state == .on,
                                      enabled: isEnabled, highlighted: isHighlighted, focused: keyboardFocused,
                                      dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if showsCheckmark { setAccessibilityValue(state == .on ? 1 : 0) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlyph()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            keyboardFocused = true
            updateGlyph()
            focusChanged?()
        }
        return accepted
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {}
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            keyboardFocused = false
            updateGlyph()
        }
        return resigned
    }
}

private struct ToolbarGlyph: View {
    var symbol: String
    var selected = false
    var drawsSelection = true
    var checked = false
    var enabled = true
    var highlighted = false
    var focused = false
    var dark = false

    // Layer-backed symbols inside native glass need a foreground resolved
    // against the host appearance, including when SwiftUI redraws a toggle.
    private var ink: Color { dark ? .white : .black }
    private var tileOpacity: Double {
        if highlighted { return 0.18 }
        if checked { return 0.13 }
        return selected && drawsSelection ? 0.075 : 0
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .regular))
            .overlay(alignment: .bottomTrailing) {
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(dark ? Color.black : Color.white, ink)
                        .font(.system(size: 10, weight: .bold))
                        .offset(x: 5, y: 4)
                }
            }
            .overlay(alignment: .trailing) {
                if symbol == "computermouse" {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 10, weight: .medium))
                        .offset(x: 9)
                }
            }
        .foregroundStyle(ink.opacity(selected || focused ? 1 : 0.78))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(ink.opacity(tileOpacity))
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(ink.opacity(0.72), lineWidth: 2)
            }
        }
        .opacity(enabled ? 1 : 0.35)
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityHidden(true)
    }
}

@MainActor
final class CaptureModeSelector: NSStackView {
    private let selection = CALayer()
    private weak var selectedButton: CaptureToolbarButton?

    init(buttons: [CaptureToolbarButton]) {
        super.init(frame: .zero)
        spacing = 2
        distribution = .fillEqually
        wantsLayer = true
        selection.cornerRadius = 7
        layer?.insertSublayer(selection, at: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Capture mode")
        for button in buttons {
            button.drawsSelection = false
            button.setAccessibilityRole(.radioButton)
            addArrangedSubview(button)
        }
        updateSelectionColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ index: Int) {
        guard let button = arrangedSubviews[index] as? CaptureToolbarButton, button !== selectedButton else { return }
        let shouldAnimate = selectedButton != nil && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        selectedButton?.state = .off
        selectedButton?.setAccessibilityValue(0)
        button.state = .on
        button.setAccessibilityValue(1)
        selectedButton = button
        positionSelection(animated: shouldAnimate)
    }

    override func layout() {
        super.layout()
        positionSelection(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionColor()
    }

    private func updateSelectionColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selection.backgroundColor = NSColor.labelColor.withAlphaComponent(0.075).cgColor
        }
    }

    private func positionSelection(animated: Bool) {
        guard let button = selectedButton, selection.frame != button.frame else { return }
        let previous = selection.animation(forKey: "position") == nil
            ? selection.position : selection.presentation()?.position ?? selection.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.frame = button.frame
        CATransaction.commit()
        if animated {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = previous
            slide.toValue = selection.position
            slide.duration = 0.22
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            selection.add(slide, forKey: "position")
        } else {
            selection.removeAnimation(forKey: "position")
        }
    }
}

@MainActor
final class CaptureActionButton: ClosureButton {
    var emphasized = false
    var showsBackground = true
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        if title.isEmpty { return NSSize(width: 26, height: 26) }
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
        if showsBackground || isHighlighted {
            let fill: CGFloat = isHighlighted ? 0.22 : emphasized || state == .on ? 0.13 : 0.06
            NSColor.labelColor.withAlphaComponent(isEnabled ? fill : 0.03).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let tint = (contentTintColor ?? .labelColor).withAlphaComponent(isEnabled ? 0.9 : 0.3)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: tint]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconWidth: CGFloat = image == nil ? 0 : 20
        let contentX = (bounds.width - textSize.width - iconWidth) / 2
        if let image {
            let size: CGFloat = 14
            let iconX = title.isEmpty ? bounds.midX - size / 2 : contentX
            let configuration = NSImage.SymbolConfiguration(paletteColors: [tint])
            if let symbol = image.withSymbolConfiguration(configuration) {
                let scale = size / max(symbol.size.width, symbol.size.height)
                let width = symbol.size.width * scale
                let height = symbol.size.height * scale
                symbol.draw(in: NSRect(x: iconX + (size - width) / 2, y: bounds.midY - height / 2,
                                       width: width, height: height), from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        (title as NSString).draw(at: NSPoint(x: contentX + iconWidth, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
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

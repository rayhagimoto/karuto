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
    fileprivate var showSelectionFocus: ((Bool) -> Void)?
    var symbolName: String { didSet { if oldValue != symbolName { updateGlyph() } } }
    var shortcut: String? { didSet { if oldValue != shortcut { updateGlyph() } } }
    var isRegionTile = false {
        didSet {
            if oldValue != isRegionTile {
                invalidateIntrinsicContentSize()
                updateGlyph()
            }
        }
    }
    var symbolScale: CGFloat = 1 {
        didSet {
            if oldValue != symbolScale {
                invalidateIntrinsicContentSize()
                updateGlyph()
            }
        }
    }
    var showsPressEffect = true { didSet { if oldValue != showsPressEffect { updateGlyph() } } }
    fileprivate var isSelectionOption = false
    private var keyboardFocused = false
    override var state: NSControl.StateValue { didSet { if oldValue != state { updateGlyph() } } }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { updateGlyph() } } }
    override var isHighlighted: Bool { didSet { if oldValue != isHighlighted { updateGlyph() } } }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        NSSize(width: (isRegionTile ? 52 : 34) * symbolScale, height: (isRegionTile ? 44 : 32) * symbolScale)
    }

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
        let selected = (isSelectionOption || showsCheckmark) && state == .on
        glyph.rootView = ToolbarGlyph(symbol: symbolName, shortcut: shortcut, isRegionTile: isRegionTile,
                                      selected: selected, checked: showsCheckmark && selected,
                                      enabled: isEnabled, highlighted: isHighlighted && showsPressEffect, focused: keyboardFocused,
                                      dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                                      symbolScale: symbolScale)
        if showsCheckmark { setAccessibilityValue(state == .on ? 1 : 0) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlyph()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            let eventType = NSApp.currentEvent?.type
            showKeyboardFocus(showsPressEffect || (eventType != .leftMouseDown && eventType != .leftMouseUp))
            focusChanged?()
        }
        return accepted
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {}
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { showKeyboardFocus(false) }
        return resigned
    }

    private func showKeyboardFocus(_ focused: Bool) {
        if let showSelectionFocus {
            showSelectionFocus(focused)
        } else {
            keyboardFocused = focused
            updateGlyph()
        }
    }
}

private struct ToolbarGlyph: View {
    var symbol: String
    var shortcut: String? = nil
    var isRegionTile = false
    var selected = false
    var checked = false
    var enabled = true
    var highlighted = false
    var focused = false
    var dark = false
    var symbolScale: CGFloat = 1

    // Layer-backed symbols inside native glass need a foreground resolved
    // against the host appearance, including when SwiftUI redraws a toggle.
    private var ink: Color { dark ? .white : .black }
    private var tileOpacity: Double {
        if highlighted { return 0.18 }
        return checked ? 0.13 : 0
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (isRegionTile ? 20 : 17) * symbolScale, weight: .regular))
            .overlay(alignment: .bottomTrailing) {
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(dark ? Color.black : Color.white, ink)
                        .font(.system(size: 10 * symbolScale, weight: .bold))
                        .offset(x: 5 * symbolScale, y: 4 * symbolScale)
                }
            }
            .overlay(alignment: .trailing) {
                if symbol == "computermouse" {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 10 * symbolScale, weight: .medium))
                        .offset(x: 9 * symbolScale)
                }
            }
            .overlay(alignment: .bottom) {
                if isRegionTile && symbol == "doc.text" {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10 * symbolScale, weight: .semibold))
                        .offset(y: 5 * symbolScale)
                }
            }
        .foregroundStyle(ink.opacity(selected || focused ? 1 : 0.78))
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: (isRegionTile ? 9 : 8) * symbolScale, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(ink.opacity(0.25))
                    .padding(.leading, (isRegionTile ? 7 : 2) * symbolScale)
                    .padding(.top, (isRegionTile ? 3 : 1) * symbolScale)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 7 * symbolScale)
                .fill(ink.opacity(tileOpacity))
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 7 * symbolScale)
                    .strokeBorder(ink.opacity(0.72), lineWidth: 2 * symbolScale)
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
    private let isAreaSelector: Bool
    private var selectionInset: CGFloat = 0
    private weak var selectedButton: CaptureToolbarButton?

    init(buttons: [CaptureToolbarButton], isAreaSelector: Bool = false) {
        self.isAreaSelector = isAreaSelector
        super.init(frame: .zero)
        distribution = .fillEqually
        wantsLayer = true
        applyScale(1)
        layer?.insertSublayer(selection, at: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(isAreaSelector ? "Area selection mode" : "Capture mode")
        for button in buttons {
            button.isSelectionOption = true
            if !isAreaSelector {
                button.showsPressEffect = false
                button.showSelectionFocus = { [weak selection, weak button] focused in
                    selection?.borderWidth = focused ? 2 * (button?.symbolScale ?? 1) : 0
                }
            }
            button.setAccessibilityRole(.radioButton)
            addArrangedSubview(button)
        }
        updateSelectionColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyScale(_ scale: CGFloat) {
        spacing = isAreaSelector ? 0 : 2 * scale
        selectionInset = isAreaSelector ? 0 : 3 * scale
        layer?.cornerRadius = isAreaSelector ? 0 : 22 * scale
        layer?.borderWidth = isAreaSelector ? 0 : scale
        selection.cornerRadius = (isAreaSelector ? 7 : 19) * scale
        if selection.borderWidth > 0 { selection.borderWidth = 2 * scale }
    }

    func select(_ index: Int) {
        guard let button = arrangedSubviews[index] as? CaptureToolbarButton, button !== selectedButton else { return }
        let shouldAnimate = selectedButton != nil && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        selectedButton?.state = .off
        selectedButton?.setAccessibilityValue(0)
        button.state = .on
        button.setAccessibilityValue(1)
        if let selectedButton, window?.firstResponder === selectedButton {
            window?.makeFirstResponder(button)
        }
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
            selection.borderColor = NSColor.labelColor.withAlphaComponent(0.72).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }

    private func positionSelection(animated: Bool) {
        guard let button = selectedButton else { return }
        let targetFrame = button.frame.insetBy(dx: selectionInset, dy: selectionInset)
        guard selection.frame != targetFrame else { return }
        let previous = selection.animation(forKey: "position") == nil
            ? selection.position : selection.presentation()?.position ?? selection.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.frame = targetFrame
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
    // AppKit can leave a momentary button's state on after a click.
    var isToolActive = false {
        didSet {
            state = isToolActive ? .on : .off
            setAccessibilityValue(isToolActive ? 1 : 0)
        }
    }
    var iconScale: CGFloat = 1 {
        didSet {
            guard iconScale != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        if title.isEmpty { return NSSize(width: 26 * iconScale, height: 26 * iconScale) }
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
        let radius = 7 * iconScale
        if !title.isEmpty || isToolActive || isHighlighted {
            let fill: CGFloat = isHighlighted ? 0.22 : emphasized || isToolActive ? 0.13 : 0.06
            NSColor.labelColor.withAlphaComponent(isEnabled ? fill : 0.03).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let tint = (contentTintColor ?? .labelColor).withAlphaComponent(isEnabled ? 0.9 : 0.3)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: tint]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconWidth: CGFloat = image == nil ? 0 : 20
        let contentX = (bounds.width - textSize.width - iconWidth) / 2
        if let image {
            let colors = NSImage.SymbolConfiguration(paletteColors: [tint])
            let configuration = title.isEmpty
                ? NSImage.SymbolConfiguration(pointSize: 12 * iconScale, weight: .regular).applying(colors)
                : colors
            if let symbol = image.withSymbolConfiguration(configuration) {
                // Icon-only tiles give SF Symbols their natural metrics at every toolbar size.
                let scale = title.isEmpty ? 1 : 14 / max(symbol.size.width, symbol.size.height)
                let width = symbol.size.width * scale
                let height = symbol.size.height * scale
                let x = title.isEmpty ? bounds.midX - width / 2 : contentX + (14 - width) / 2
                var rect = NSRect(x: x, y: bounds.midY - height / 2, width: width, height: height)
                rect.origin = backingAlignedRect(rect, options: .alignAllEdgesNearest).origin
                symbol.draw(in: rect, from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        (title as NSString).draw(at: NSPoint(x: contentX + iconWidth, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).stroke()
        }
    }
}

@MainActor
final class CaptureSurface: NSView {
    /// All controls belong inside the system glass content view, never beside it.
    let contentView = NSView()
    var cornerRadius: CGFloat = 16 { didSet { updateCornerRadius() } }
    private var effectView: NSView?

    init(frame: NSRect = .zero, interactive: Bool = true) {
        super.init(frame: frame)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = contentView
            // The native effect supplies refraction, blur, and its own edge
            // treatment. No painted tint or extra border sits over the glass.
            if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
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

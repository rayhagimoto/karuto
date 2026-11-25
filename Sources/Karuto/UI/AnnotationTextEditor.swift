import AppKit

/// The text view sits in the capture. A separate floating panel keeps controls
/// outside the box and lets the insertion point survive formatting changes.
@MainActor
final class AnnotationTextEditor: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    let input: CapturePanel
    let formatting: CapturePanel
    let textView = NSTextView()
    private let slider = NSSlider()
    private let sizeField = NSTextField()
    private let alignment = NSSegmentedControl()
    private var styleButtons: [CaptureActionButton] = []
    private(set) var style: AnnotationTextStyle
    private let color: AnnotationColor
    let initialBox: CGRect
    var onChange: (() -> Void)?
    var onCommit: (() -> Void)?

    init(mark: AreaAnnotation) {
        style = mark.textStyle
        color = mark.color
        initialBox = mark.rect
        let level = NSWindow.Level.statusBar.rawValue
        input = CapturePanel(contentRect: mark.rect, level: .init(rawValue: level + 5))
        formatting = CapturePanel(contentRect: CGRect(x: 0, y: 0, width: 316, height: 78), level: .init(rawValue: level + 6))
        super.init()
        formatting.becomesKeyOnlyIfNeeded = true
        input.contentMinSize = .zero
        input.hasShadow = false
        input.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        input.setAccessibilityLabel("Edit annotation text")
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: AnnotationTextStyle.inset, height: AnnotationTextStyle.inset)
        textView.setAccessibilityLabel("Annotation text")
        textView.string = mark.label
        textView.delegate = self
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = textView
        input.contentView = scroll

        let surface = CaptureSurface()
        surface.cornerRadius = 11
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        pinSubview(rows, to: surface.contentView, inset: 8)
        let sizeRow = NSStackView()
        sizeRow.spacing = 6
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Size"))
        slider.minValue = AnnotationTextStyle.sizes.lowerBound
        slider.maxValue = AnnotationTextStyle.sizes.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slideSize)
        slider.setAccessibilityLabel("Font size slider")
        sizeRow.addArrangedSubview(slider)
        sizeField.alignment = .right
        sizeField.delegate = self
        sizeField.setAccessibilityLabel("Font size in points")
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sizeRow.addArrangedSubview(sizeField)
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "pt"))
        rows.addArrangedSubview(sizeRow)
        sizeRow.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true

        let choices = NSStackView()
        choices.spacing = 4
        alignment.segmentCount = 3
        alignment.trackingMode = .selectOne
        alignment.setAccessibilityLabel("Text alignment")
        for (index, name) in ["Left", "Center", "Right"].enumerated() {
            alignment.setImage(NSImage(systemSymbolName: "text.align" + name.lowercased(), accessibilityDescription: "Align " + name.lowercased()), forSegment: index)
            alignment.setWidth(28, forSegment: index)
            alignment.setToolTip("Align " + name.lowercased(), forSegment: index)
        }
        alignment.target = self
        alignment.action = #selector(changeAlignment)
        choices.addArrangedSubview(alignment)
        for (name, property) in [("Bold", \AnnotationTextStyle.bold), ("Italic", \.italic), ("Underline", \.underline)] {
            let button = CaptureActionButton(title: "", symbol: name.lowercased()) { [weak self] in
                guard let self else { return }
                style[keyPath: property].toggle()
                updateFormat()
                focusText()
            }
            button.toolTip = name
            button.setAccessibilityLabel(name)
            choices.addArrangedSubview(button)
            styleButtons.append(button)
        }
        choices.addArrangedSubview(NSView())
        let done = CaptureActionButton(title: "Done") { [weak self] in self?.onCommit?() }
        done.emphasized = true
        choices.addArrangedSubview(done)
        rows.addArrangedSubview(choices)
        choices.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        formatting.contentView = surface
        formatting.setAccessibilityLabel("Text formatting")
        updateFormat()
    }

    func position(box: CGRect, screen: CGRect, palette: CGRect?) {
        if input.frame != box { input.setFrame(box, display: true) }
        textView.setFrameSize(CGSize(width: box.width, height: max(box.height, textView.frame.height)))
        // Keep the slider under the pointer when a larger font grows the box.
        guard !formatting.isVisible else { return }
        let frame = ToolbarGeometry.paletteFrame(size: formatting.frame.size, selection: box,
                                               screen: screen, toolbar: palette ?? .null)
        formatting.setFrameOrigin(frame.origin)
    }

    func show() {
        formatting.orderFrontRegardless()
        focusText()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func close() {
        onChange = nil
        onCommit = nil
        sizeField.delegate = nil
        textView.delegate = nil
        formatting.orderOut(nil)
        input.orderOut(nil)
    }

    @objc private func slideSize() {
        style.size = slider.doubleValue.rounded()
        updateFormat()
    }

    @objc private func changeAlignment() {
        guard let value = AnnotationTextStyle.Alignment(rawValue: alignment.selectedSegment) else { return }
        style.alignment = value
        updateFormat()
        focusText()
    }

    private func focusText() {
        input.makeKeyAndOrderFront(nil)
        input.makeFirstResponder(textView)
    }

    private var enteredSize: Double? {
        let typed = sizeField.currentEditor()?.string ?? sizeField.stringValue
        guard let size = try? Double(typed.trimmingCharacters(in: .whitespaces), format: .number, lenient: false),
              size.isFinite else { return nil }
        return size
    }

    func acceptSizeEntry() {
        if let size = enteredSize {
            style.size = min(max(size, AnnotationTextStyle.sizes.lowerBound), AnnotationTextStyle.sizes.upperBound)
        }
        updateFormat()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let size = enteredSize, AnnotationTextStyle.sizes.contains(size) else { return }
        style.size = size
        updateFormat(syncEntry: false)
    }

    func controlTextDidEndEditing(_ obj: Notification) { acceptSizeEntry() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            acceptSizeEntry()
            focusText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCommit?(); return true }
        return false
    }

    func textDidChange(_ notification: Notification) { onChange?() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCommit?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let event = NSApp.currentEvent, event.type == .keyDown,
               [36, 76].contains(event.keyCode), event.modifierFlags.contains(.shift) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else { onCommit?() }
            return true
        }
        return false
    }

    private func updateFormat(syncEntry: Bool = true) {
        let attributes = style.attributes(color: color)
        textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.typingAttributes = attributes
        // NSTextView also uses this paragraph style for empty lines.
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        slider.doubleValue = style.size
        if syncEntry { sizeField.stringValue = style.size.formatted(.number.precision(.fractionLength(0...2))) }
        alignment.selectedSegment = style.alignment.rawValue
        for (button, enabled) in zip(styleButtons, [style.bold, style.italic, style.underline]) {
            button.isToolActive = enabled
        }
        onChange?()
    }
}

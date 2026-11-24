import AppKit

/// Editable counterpart of the lightweight size label drawn during a drag.
@MainActor
final class SelectionSizeControl: NSStackView, NSTextFieldDelegate {
    static let size = CGSize(width: 144, height: 28)
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var selectionSize = CGSize.zero
    var onResize: ((CGSize) -> Void)?

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = 7
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        for (field, label) in [(widthField, "Selection width"), (heightField, "Selection height")] {
            field.setAccessibilityLabel(label)
            field.toolTip = label + " in points"
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.alignment = .center
            field.isBezeled = false
            field.backgroundColor = NSColor.white.withAlphaComponent(0.12)
            field.drawsBackground = true
            field.wantsLayer = true
            field.layer?.cornerRadius = 4
            field.layer?.masksToBounds = true
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 45).isActive = true
        }
        for item in [widthField, captureLabel("×"), heightField, captureLabel("pt")] {
            addArrangedSubview(item)
        }
        widthField.nextKeyView = heightField
        heightField.nextKeyView = widthField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isEditing: Bool { widthField.currentEditor() != nil || heightField.currentEditor() != nil }

    func focus(backwards: Bool) {
        window?.makeKey()
        (backwards ? heightField : widthField).selectText(nil)
    }

    func endEditing() {
        if isEditing { window?.makeFirstResponder(nil) }
    }

    func update(size: CGSize) {
        selectionSize = size
        for (field, value) in [(widthField, size.width), (heightField, size.height)] where field.currentEditor() == nil {
            let string = String(Int(value.rounded()))
            if field.stringValue != string { field.stringValue = string }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let isWidth = field === widthField
        var size = selectionSize
        if let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 2 {
            if isWidth { size.width = CGFloat(value) } else { size.height = CGFloat(value) }
            if size != selectionSize { onResize?(size) }
        }
        field.stringValue = String(Int((isWidth ? selectionSize.width : selectionSize.height).rounded()))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            let value = control === widthField ? selectionSize.width : selectionSize.height
            textView.string = String(Int(value.rounded()))
        case #selector(NSResponder.insertNewline(_:)): break
        default: return false
        }
        endEditing()
        return true
    }

    func contains(screenPoint: CGPoint) -> Bool {
        guard !isHidden, let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }
}

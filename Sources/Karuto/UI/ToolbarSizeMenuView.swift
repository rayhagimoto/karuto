import AppKit

@MainActor
final class ToolbarSizeMenuView: NSView {
    private let title: NSTextField
    private let value = captureLabel("", size: 12, color: .secondaryLabelColor)
    private let slider = NSSlider()
    private let labels = ["¼×", "½×", "1×", "2×", "4×"].map {
        captureLabel($0, size: 10, color: .secondaryLabelColor)
    }
    private let onChange: (Double) -> Void
    override var isFlipped: Bool { true }

    init(title: String, scale: Double, onChange: @escaping (Double) -> Void) {
        self.title = captureLabel(title, size: 13)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 73))
        autoresizingMask = .width
        slider.minValue = log2(ToolbarScale.range.lowerBound)
        slider.maxValue = log2(ToolbarScale.range.upperBound)
        slider.numberOfTickMarks = ToolbarScale.tickCount
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.doubleValue = log2(scale)
        slider.target = self
        slider.action = #selector(slide)
        slider.setAccessibilityLabel(title)
        value.alignment = .right
        for view in [self.title, value, slider] + labels { addSubview(view) }
        updateValue(scale)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let inset: CGFloat = 16
        title.frame = NSRect(x: inset, y: 4, width: bounds.width - 2 * inset - 70, height: 17)
        value.frame = NSRect(x: bounds.width - inset - 70, y: 4, width: 70, height: 17)
        slider.frame = NSRect(x: inset, y: 23, width: bounds.width - 2 * inset, height: 28)
        for (index, label) in labels.enumerated() {
            label.sizeToFit()
            label.setFrameOrigin(NSPoint(x: (tickX(index * 2) - label.frame.width / 2).rounded(), y: 54))
        }
    }

    // The thumb's center stops half a knob width inside either end of the track.
    private func tickX(_ index: Int) -> CGFloat {
        let travel = slider.frame.insetBy(dx: slider.knobThickness / 2, dy: 0)
        return travel.minX + travel.width * CGFloat(index) / CGFloat(slider.numberOfTickMarks - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in 0..<slider.numberOfTickMarks {
            let major = index.isMultiple(of: 2)
            (major ? NSColor.secondaryLabelColor : .tertiaryLabelColor).setFill()
            NSBezierPath(rect: NSRect(x: tickX(index).rounded(), y: 44, width: 1, height: major ? 6 : 3)).fill()
        }
    }

    @objc private func slide() {
        let scale = exp2(slider.doubleValue)
        updateValue(scale)
        onChange(scale)
    }

    private func updateValue(_ scale: Double) {
        value.stringValue = scale.formatted(.number.precision(.fractionLength(0...2))) + "×"
        slider.setAccessibilityValueDescription(value.stringValue)
    }
}

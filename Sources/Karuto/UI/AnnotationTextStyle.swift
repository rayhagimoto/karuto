import AppKit
import CoreText

struct AnnotationTextStyle: Equatable, Sendable {
    enum Alignment: Int, CaseIterable { case left, center, right }
    static let sizes: ClosedRange<Double> = 6...256
    static let inset: CGFloat = 4
    var size: Double = 20
    var alignment = Alignment.left
    var bold = true
    var italic = false
    var underline = false

    func attributes(color: AnnotationColor) -> [NSAttributedString.Key: Any] {
        let regular = CTFontCreateWithName("HelveticaNeue" as CFString, CGFloat(size), nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let font = CTFontCreateCopyWithSymbolicTraits(regular, 0, nil, traits, [.traitBold, .traitItalic]) ?? regular
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font as NSFont, .paragraphStyle: paragraph,
                .foregroundColor: NSColor(cgColor: color.cgColor) ?? .black,
                .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0]
    }

    private func framesetter(_ text: String, color: AnnotationColor) -> CTFramesetter {
        CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(color: color)))
    }

    private func height(using setter: CTFramesetter, width: CGFloat) -> CGFloat {
        let constraints = CGSize(width: max(1, width - 2 * Self.inset), height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, constraints, nil)
        return ceil(size.height) + 2 * Self.inset + 1
    }

    func fittedHeight(for text: String, width: CGFloat) -> CGFloat {
        // Leave a line for the insertion point after a trailing newline.
        let sample = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        return height(using: framesetter(sample, color: .black), width: width)
    }

    func draw(_ text: String, color: AnnotationColor, in box: CGRect, context: CGContext) {
        guard !text.isEmpty, !box.isEmpty else { return }
        let setter = framesetter(text, color: color)
        let height = max(box.height, height(using: setter, width: box.width))
        let layout = CGRect(x: box.minX, y: box.maxY - height, width: box.width, height: height)
            .insetBy(dx: Self.inset, dy: Self.inset)
        guard !layout.isEmpty else { return }
        context.clip(to: box)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: layout, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}

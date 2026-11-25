import AppKit

/// Session-local editor. Committed marks keep their own backing layers, so a
/// pointer update redraws only the current mark, never the desktop image.
@MainActor
final class AreaAnnotationEditor: NSObject {
    var sampleImage: ((CaptureTarget) async throws -> CGImage)?
    var onConfirm: (() -> Void)?
    var onToggleOCR: (() -> Void)?
    var ocrEnabled = false { didSet { syncButtons() } }
    var onSelectTool: ((AnnotationTool) -> Void)?
    var presentMenu: ((NSMenu, NSButton) -> Void)?
    private(set) var tool = AnnotationTool.select
    private var color = AnnotationColor.red
    private(set) var marks: [AreaAnnotation] = []
    private struct Change {
        let index: Int
        var before: AreaAnnotation?
        var after: AreaAnnotation?

        mutating func offset(by delta: CGPoint) {
            before?.offset(by: delta)
            after?.offset(by: delta)
        }
    }
    private var history: [Change] = []
    private var undone: [Change] = []
    private var draft: AreaAnnotation?
    private let canvas = CALayer()
    private var draftLayer: CALayer?
    private var strokePath: CGMutablePath?
    private var target: CaptureTarget?
    private var rect = CGRect.zero
    private var scale: CGFloat = 1
    private var grid: CGImage?
    private var sampling: Task<Void, Never>?
    private var palette: CapturePanel?
    private var movedPalette = false
    private var buttons: [AnnotationTool: CaptureActionButton] = [:]
    private var ocrButton: CaptureActionButton?
    private var undoButton: CaptureActionButton?
    private var redoButton: CaptureActionButton?
    private var colorButton: CaptureActionButton?
    private var textEditor: AnnotationTextEditor?
    private var textStyle = AnnotationTextStyle()
    private var selectedText: Int?
    private var replacing: Int?
    private struct TextDrag {
        let origin: CGPoint
        let box: CGRect
        let handle: Int?
    }
    private var textDrag: TextDrag?
    private let boxOutline = CAShapeLayer()
    private let handles = CAShapeLayer()
    var isTyping: Bool { textEditor != nil }
    var isDrawing: Bool { draft != nil }
    var canUndo: Bool { !history.isEmpty || isDrawing }
    var canRedo: Bool { !undone.isEmpty }
    func isPaletteWindow(_ window: NSWindow) -> Bool { palette === window }
    var visiblePaletteFrame: CGRect? { palette?.isVisible == true ? palette?.frame : nil }
    func containsPalette(_ point: CGPoint) -> Bool {
        guard let palette, palette.isVisible else { return false }
        return palette.frame.contains(point)
    }

    override init() {
        super.init()
        canvas.masksToBounds = true
        boxOutline.masksToBounds = true
        boxOutline.fillColor = nil
        boxOutline.strokeColor = NSColor.controlAccentColor.cgColor
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = boxOutline.strokeColor
        boxOutline.addSublayer(handles)
    }

    func show(for display: CaptureDisplay, rect: CGRect, in root: CALayer, avoiding toolbar: CGRect?) {
        let next = CaptureTarget.area(displayID: display.id, rect: rect)
        if case .area(let oldID, _) = target, oldID != display.id { clear() }
        let changed = target != next
        if target != nil, self.rect.size != rect.size, self.rect.origin != rect.origin {
            // A resize changes the crop around the marks. A move carries them with it.
            let delta = CGPoint(x: self.rect.minX - rect.minX, y: self.rect.minY - rect.minY)
            for index in marks.indices { marks[index].offset(by: delta) }
            for index in history.indices { history[index].offset(by: delta) }
            for index in undone.indices { undone[index].offset(by: delta) }
        }
        target = next
        self.rect = rect
        scale = display.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if canvas.superlayer !== root { root.addSublayer(canvas) }
        canvas.frame = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        canvas.isHidden = false
        if changed {
            sampling?.cancel()
            sampling = nil
            grid = nil
            rebuildArtwork()
        }
        updateBoxOutline()
        CATransaction.commit()
        requestGridIfNeeded()
        guard let toolbar else { return }
        let panel = palette ?? makePalette()
        let visible = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }?.visibleFrame ?? display.frame
        let frame = ToolbarGeometry.paletteFrame(size: panel.frame.size, selection: rect, screen: visible, toolbar: toolbar)
        if (changed || !movedPalette), frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
        if changed { movedPalette = false }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideDuringAdjustment() {
        palette?.orderOut(nil)
        canvas.isHidden = true
        boxOutline.isHidden = true
    }

    func clear() {
        guard target != nil else { return }
        sampling?.cancel()
        sampling = nil
        grid = nil
        textEditor?.close()
        textEditor = nil
        selectedText = nil
        replacing = nil
        textDrag = nil
        textStyle = AnnotationTextStyle()
        boxOutline.removeFromSuperlayer()
        draft = nil
        draftLayer = nil
        strokePath = nil
        marks.removeAll()
        history.removeAll()
        undone.removeAll()
        canvas.sublayers = nil
        canvas.removeFromSuperlayer()
        target = nil
        movedPalette = false
        if tool != .select { onSelectTool?(.select) }
        tool = .select
        palette?.orderOut(nil)
        syncButtons()
    }

    func select(_ newTool: AnnotationTool) {
        guard target != nil else { return }
        finishText()
        cancelDraft()
        tool = newTool
        selectedText = nil
        updateBoxOutline()
        onSelectTool?(tool)
        syncButtons()
        requestGridIfNeeded()
    }

    private func requestGridIfNeeded() {
        guard grid == nil, sampling == nil, let target, let sampleImage,
              tool == .mosaic || marks.contains(where: { $0.tool == .mosaic }) else { return }
        let size = rect.size
        sampling = Task { [weak self] in
            do {
                let image = try await sampleImage(target)
                try Task.checkCancellation()
                let grid = try await Task.detached(priority: .userInitiated) {
                    try AreaAnnotation.mosaicGrid(image, size: size)
                }.value
                try Task.checkCancellation()
                guard let self, self.target == target else { return }
                self.grid = grid
                self.rebuildArtwork()
            } catch { /* The opaque preview still identifies the mosaic area. */ }
            if !Task.isCancelled { self?.sampling = nil }
        }
    }

    func begin(at point: CGPoint, displayID: UInt32, clickCount: Int = 1) -> Bool {
        guard tool != .select, case .area(let id, _) = target else { return false }
        finishText()
        guard displayID == id, rect.contains(point) else { return true }
        let p = local(point)
        if tool == .text {
            beginText(at: p, clickCount: clickCount)
            return true
        }
        let label = tool == .counter ? String(marks.lazy.filter { $0.tool == .counter }.count + 1) : ""
        draft = AreaAnnotation(tool: tool, color: color, start: p, end: p, label: label)
        previewDraft()
        return true
    }

    func drag(to point: CGPoint) {
        guard let tool = draft?.tool, !isTyping else { return }
        let p = local(point)
        if let textDrag {
            let frame = draggedBox(textDrag, to: p)
            if let old = draft?.rect, old != frame {
                draft?.setTextFrame(frame)
                if textDrag.handle == nil, old.size == frame.size, canvas.bounds.contains(old),
                   let draftLayer {
                    // The glyphs and their layout are unchanged during a move.
                    draftLayer.frame = draftLayer.frame.offsetBy(dx: frame.minX - old.minX, dy: frame.minY - old.minY)
                } else {
                    previewDraft()
                }
                updateBoxOutline()
            }
            return
        }
        guard draft?.end != p else { return }
        if tool == .pen || tool == .highlight {
            draft?.stroke.append(p)
            strokePath?.addLine(to: p)
            (draftLayer as? CAShapeLayer)?.path = strokePath
            draft?.end = p
            return
        }
        draft?.end = p
        if let layer = draftLayer as? CAShapeLayer, let path = draft?.outline {
            layer.path = path
        } else {
            previewDraft()
        }
    }

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x - rect.minX, 0), rect.width), y: min(max(point.y - rect.minY, 0), rect.height))
    }

    func end(at point: CGPoint) {
        guard !isTyping, draft != nil else { return }
        drag(to: point)
        finishGesture()
    }

    func finishGesture() {
        if isTyping { finishText(); return }
        if let mark = draft, mark.tool == .text || mark.tool == .counter || mark.tool == .pen || mark.tool == .highlight
            || (mark.tool == .arrow ? mark.start != mark.end : !mark.rect.isEmpty) { commitDraft() }
        else { cancelDraft() }
    }

    private func commitDraft() {
        guard let draft else { return }
        let index = replacing ?? marks.count
        let before = replacing.map { marks[$0] }
        let after: AreaAnnotation? = draft.tool == .text && draft.label.isEmpty ? nil : draft
        if before != after {
            if replacing != nil { marks.remove(at: index) }
            if let after { marks.insert(after, at: index) }
            history.append(Change(index: index, before: before, after: after))
            undone.removeAll()
        }
        if after == nil { draftLayer?.removeFromSuperlayer() }
        selectedText = after?.tool == .text ? index : nil
        replacing = nil
        textDrag = nil
        self.draft = nil
        draftLayer = nil
        strokePath = nil
        updateBoxOutline()
        syncButtons()
    }

    func cancelDraft() {
        textEditor?.close()
        textEditor = nil
        textDrag = nil
        draft = nil
        strokePath = nil
        if let replacing, let draftLayer {
            canvas.replaceSublayer(draftLayer, with: makeLayer(for: marks[replacing]))
        } else {
            draftLayer?.removeFromSuperlayer()
        }
        replacing = nil
        draftLayer = nil
        updateBoxOutline()
    }

    func undo() {
        if isDrawing { cancelDraft(); return }
        guard let change = history.popLast() else { return }
        undone.append(change)
        apply(change, forward: false)
    }

    func redo() {
        guard !isDrawing, let change = undone.popLast() else { return }
        history.append(change)
        apply(change, forward: true)
    }

    private func apply(_ change: Change, forward: Bool) {
        let remove = forward ? change.before : change.after
        let insert = forward ? change.after : change.before
        if remove != nil { marks.remove(at: change.index) }
        if let insert { marks.insert(insert, at: change.index) }
        selectedText = tool == .text && insert?.tool == .text ? change.index : nil
        rebuildArtwork()
        updateBoxOutline()
        requestGridIfNeeded()
        syncButtons()
    }

    private func rebuildArtwork() {
        canvas.sublayers = nil
        for mark in marks { canvas.addSublayer(makeLayer(for: mark)) }
        draftLayer = nil
        previewDraft()
    }

    private func previewDraft() {
        guard let draft else { return }
        let layer = makeLayer(for: draft)
        layer.isHidden = isTyping
        if let original = draftLayer ?? replacing.flatMap({ canvas.sublayers?[$0] }) {
            canvas.replaceSublayer(original, with: layer)
        } else {
            canvas.addSublayer(layer)
        }
        draftLayer = layer
    }

    private func makeLayer(for mark: AreaAnnotation) -> CALayer {
        if mark.tool == .mosaic {
            let mask = CALayer()
            mask.frame = mark.rect
            mask.masksToBounds = true
            mask.backgroundColor = CGColor(gray: 0.25, alpha: 1)
            if let grid {
                let pixels = CALayer()
                pixels.frame = CGRect(x: -mark.rect.minX, y: -mark.rect.minY, width: rect.width, height: rect.height)
                pixels.contents = grid
                pixels.magnificationFilter = .nearest
                mask.addSublayer(pixels)
            }
            return mask
        }
        let path: CGPath?
        if mark.tool == .pen || mark.tool == .highlight {
            let stroke = CGMutablePath()
            stroke.move(to: mark.start)
            // A round cap on a short initial segment also shows a single click.
            stroke.addLine(to: CGPoint(x: mark.start.x + 0.01, y: mark.start.y))
            for point in mark.stroke { stroke.addLine(to: point) }
            strokePath = stroke
            path = stroke
        } else {
            path = mark.outline
        }
        if let path {
            let layer = CAShapeLayer()
            layer.frame = canvas.bounds
            layer.actions = ["path": NSNull()]
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = mark.color.cgColor
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.lineWidth = mark.tool == .highlight ? 16 : 3
            layer.opacity = mark.tool == .highlight ? 0.4 : 1
            layer.contentsScale = scale
            return layer
        }
        return AnnotationInkLayer(mark: mark, size: rect.size, scale: scale, grid: grid)
    }

    private func makePalette() -> CapturePanel {
        let surface = CaptureSurface()
        surface.cornerRadius = 11
        let stack = NSStackView()
        stack.spacing = 3
        func button(_ label: String, _ symbol: String, _ action: @escaping () -> Void) -> CaptureActionButton {
            let b = CaptureActionButton(title: "", symbol: symbol, handler: action)
            b.setAccessibilityLabel(label)
            b.toolTip = label
            stack.addArrangedSubview(b)
            return b
        }
        for tool in AnnotationTool.allCases {
            buttons[tool] = button(tool.rawValue, tool.symbol) { [weak self] in self?.select(tool) }
        }
        ocrButton = button("Recognize text", "text.viewfinder") { [weak self] in self?.onToggleOCR?() }
        colorButton = button("Ink color", "circle.fill") { [weak self] in self?.chooseColor() }
        undoButton = button("Undo annotation", "arrow.uturn.backward") { [weak self] in self?.undo() }
        redoButton = button("Redo annotation", "arrow.uturn.forward") { [weak self] in self?.redo() }
        _ = button("Capture", "checkmark") { [weak self] in self?.onConfirm?() }
        let grip = CaptureToolbarView(frame: .zero)
        grip.onMove = { [weak self] _ in self?.movedPalette = true }
        pinSubview(grip, to: surface.contentView)
        pinSubview(stack, to: grip, inset: 6)
        let width = CGFloat(stack.arrangedSubviews.count) * 29 + 9
        let panel = CapturePanel(contentRect: CGRect(x: 0, y: 0, width: width, height: 38),
                                 level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4))
        panel.contentView = surface
        panel.setAccessibilityLabel("Area annotation tools")
        palette = panel
        syncButtons()
        return panel
    }

    private func syncButtons() {
        for (key, b) in buttons {
            b.isEnabled = !ocrEnabled
            b.state = key == tool ? .on : .off
            b.setAccessibilityValue(key == tool ? 1 : 0)
        }
        ocrButton?.state = ocrEnabled ? .on : .off
        ocrButton?.setAccessibilityValue(ocrEnabled ? 1 : 0)
        undoButton?.isEnabled = !ocrEnabled && canUndo
        redoButton?.isEnabled = !ocrEnabled && !undone.isEmpty
        colorButton?.isEnabled = !ocrEnabled
        colorButton?.contentTintColor = NSColor(cgColor: color.cgColor)
        colorButton?.setAccessibilityValue(color.rawValue.capitalized)
    }

    private func chooseColor() {
        guard let colorButton else { return }
        let menu = NSMenu()
        for ink in AnnotationColor.allCases {
            let item = menu.addItem(withTitle: ink.rawValue.capitalized, action: #selector(changeColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ink.rawValue
            item.state = ink == color ? .on : .off
        }
        presentMenu?(menu, colorButton)
    }

    @objc private func changeColor(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let ink = AnnotationColor(rawValue: value) else { return }
        color = ink
        syncButtons()
    }

    private func textHit(at point: CGPoint) -> Int? {
        marks.indices.reversed().first { marks[$0].tool == .text && marks[$0].rect.contains(point) }
    }

    private func handleHit(at point: CGPoint) -> Int? {
        guard let selectedText else { return nil }
        return SelectionOverlayRenderer.handlePoints(in: marks[selectedText].rect).firstIndex {
            abs($0.x - point.x) <= 5 && abs($0.y - point.y) <= 5
        }
    }

    func cursor(at point: CGPoint) -> NSCursor? {
        guard tool == .text, rect.contains(point) else { return nil }
        let p = local(point)
        if let handle = handleHit(at: p) {
            switch handle {
            case 1, 5: return .resizeUpDown
            case 3, 7: return .resizeLeftRight
            default: return .crosshair
            }
        }
        if textDrag != nil { return .closedHand }
        return textHit(at: p) == nil ? .iBeam : .openHand
    }

    private func beginText(at point: CGPoint, clickCount: Int) {
        let handle = handleHit(at: point)
        let hit = handle != nil ? selectedText : textHit(at: point)
        selectedText = hit
        replacing = hit
        if let hit {
            draft = marks[hit]
            if clickCount >= 2 {
                openText()
            } else {
                textDrag = TextDrag(origin: point, box: marks[hit].rect, handle: handle)
                draftLayer = canvas.sublayers?[hit]
                updateBoxOutline()
            }
        } else {
            let width = min(rect.width, max(56, min(200, rect.width - point.x)))
            let height = min(rect.height, textStyle.fittedHeight(for: "", width: width))
            let box = CGRect(x: point.x, y: point.y - height, width: width, height: height)
            var mark = AreaAnnotation(tool: .text, color: color, start: point, end: point, textStyle: textStyle)
            mark.setTextFrame(SelectionGeometry.moved(box, delta: .zero, within: canvas.bounds))
            draft = mark
            openText()
        }
    }

    private func draggedBox(_ drag: TextDrag, to point: CGPoint) -> CGRect {
        let delta = CGSize(width: point.x - drag.origin.x, height: point.y - drag.origin.y)
        guard let handle = drag.handle else {
            return SelectionGeometry.moved(drag.box, delta: delta, within: canvas.bounds)
        }
        var left = drag.box.minX, right = drag.box.maxX
        var bottom = drag.box.minY, top = drag.box.maxY
        let minWidth = min(24, drag.box.width), minHeight = min(12, drag.box.height)
        if [0, 6, 7].contains(handle) { left = max(0, min(right - minWidth, left + delta.width)) }
        if [2, 3, 4].contains(handle) { right = min(rect.width, max(left + minWidth, right + delta.width)) }
        if [0, 1, 2].contains(handle) { bottom = max(0, min(top - minHeight, bottom + delta.height)) }
        if [4, 5, 6].contains(handle) { top = min(rect.height, max(bottom + minHeight, top + delta.height)) }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private func updateBoxOutline() {
        let box = draft?.tool == .text ? draft?.rect : selectedText.map { marks[$0].rect }
        guard tool == .text, let box, let root = canvas.superlayer else {
            boxOutline.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if boxOutline.superlayer !== root { root.addSublayer(boxOutline) }
        boxOutline.frame = canvas.frame
        boxOutline.isHidden = false
        boxOutline.path = CGPath(rect: box.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        let path = CGMutablePath()
        if !isTyping {
            for p in SelectionOverlayRenderer.handlePoints(in: box) {
                path.addRect(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            }
        }
        handles.path = path
        CATransaction.commit()
    }

    private func openText() {
        guard let draft else { return }
        let editor = AnnotationTextEditor(mark: draft)
        textEditor = editor
        editor.onChange = { [weak self] in self?.readText() }
        editor.onCommit = { [weak self] in self?.finishText() }
        previewDraft()
        positionTextEditor()
        updateBoxOutline()
        editor.show()
    }

    private func positionTextEditor() {
        guard let textEditor, let box = draft?.rect else { return }
        let global = box.offsetBy(dx: rect.minX, dy: rect.minY)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame ?? rect
        textEditor.position(box: global, screen: screen, palette: palette?.frame)
    }

    private func readText() {
        guard let editor = textEditor, var mark = draft else { return }
        let text = editor.textView.string
        guard mark.label != text || mark.textStyle != editor.style else { return }
        mark.label = text
        mark.textStyle = editor.style
        let base = editor.initialBox
        let height = min(rect.height, max(base.height, mark.textStyle.fittedHeight(for: text, width: base.width)))
        let box = CGRect(x: base.minX, y: base.maxY - height, width: base.width, height: height)
        mark.setTextFrame(SelectionGeometry.moved(box, delta: .zero, within: canvas.bounds))
        draft = mark
        positionTextEditor()
        updateBoxOutline()
    }

    func handleTextKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == "\u{1b}",
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        finishText()
        return true
    }

    func finishText() {
        guard let editor = textEditor else { return }
        editor.acceptSizeEntry()
        readText()
        textStyle = editor.style
        editor.close()
        textEditor = nil
        previewDraft()
        commitDraft()
    }

}

private final class AnnotationInkLayer: CALayer {
    private let mark: AreaAnnotation
    private let canvasSize: CGSize
    private let grid: CGImage?
    private let drawingOrigin: CGPoint

    init(mark: AreaAnnotation, size: CGSize, scale: CGFloat, grid: CGImage?) {
        self.mark = mark
        self.canvasSize = size
        self.grid = grid
        let dirty = mark.drawingBounds.integral.intersection(CGRect(origin: .zero, size: size))
        drawingOrigin = dirty.isNull ? .zero : dirty.origin
        super.init()
        frame = dirty.isNull ? .zero : dirty
        contentsScale = scale
        setNeedsDisplay()
    }

    override init(layer: Any) {
        let source = layer as! AnnotationInkLayer
        mark = source.mark
        canvasSize = source.canvasSize
        grid = source.grid
        drawingOrigin = source.drawingOrigin
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in ctx: CGContext) {
        ctx.translateBy(x: -drawingOrigin.x, y: -drawingOrigin.y)
        mark.draw(in: ctx, canvas: canvasSize, mosaic: grid)
    }
}

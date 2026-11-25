import AppKit
import CoreGraphics

@MainActor
final class CaptureUIController: NSObject {
    var onCapture: ((CaptureMode, CaptureRegion, CaptureTarget, [AreaAnnotation], SnapshotDestination) -> Void)?
    let editor: AreaAnnotationEditor
    var previousArea: (() -> (CaptureTarget, CGRect)?)? { didSet { updateToolbar() } }
    private var stageAreaForEditing = false
    private var captureOnRelease: Bool { instantCapture && !stageAreaForEditing && !capturesText }
    private var canChooseSnapshotDestination: Bool {
        mode == .snapshot && !instantCapture && region != .scrolling && !capturesText && target != nil
    }
    var onScrollInputPoint: ((CGPoint?) -> Void)?
    private(set) var selectedScrollPoint: CGPoint?
    // A query seam keeps stale-result behavior testable without sending AX messages.
    var scrollRegionQuery: (@Sendable (ScrollRegionRequest) async -> CGRect?)?
    private let scrollRegionResolver = ScrollRegionResolver()
    private var scrollSuggestionTask: Task<Void, Never>?
    private var pendingScrollRequest: ScrollRegionRequest?
    private var scrollSuggestionGeneration: UInt64 = 0
    private var scrollHoverPoint = CGPoint.zero
    private var scrollHoverWindowID: UInt32?
    private var hoverAreaLabel = ""
    var onCancel: (() -> Void)?
    var onSelectionSourceChange: ((CaptureMode?) -> Void)?
    var onOpenKeymap: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var keymap: KeymapController? { didSet { refreshKeymap() } }
    var instantCapture: Bool {
        get { preferences.instantCapture }
        set {
            preferences.instantCapture = newValue
            stageAreaForEditing = false
            refreshKeymap()
        }
    }
    var freezeDisplay: Bool { preferences.freezeDisplay }
    var delaySeconds: Int { preferences.delaySeconds }
    var usesFrozenSelection: Bool {
        mode == .snapshot && region != .scrolling && delaySeconds == 0 && freezeDisplay
    }
    var samplePreview: ((CaptureTarget) async throws -> CGImage)? {
        didSet { editor.sampleImage = samplePreview }
    }
    var copyRecognizedText: (String) throws -> Bool = { try TextCaptureService.copy($0) }
    private var copyStatus: String?
    var ocrEnabled = false {
        didSet {
            if ocrEnabled, region == .area { hoverArea = nil }
            if ocrEnabled, editor.tool != .select { editor.select(.select) }
            overlays.forEach { updateAccessibilityHelp(for: $0) }
            refreshSelection()
        }
    }
    var capturesText: Bool { ocrEnabled && supportsOCR }
    private var supportsOCR: Bool { mode == .snapshot && region != .scrolling }
    private var confirmTitle: String {
        if capturesText { return "Copy All Text" }
        return mode == .screenRecording || region == .scrolling ? "Continue" : "Capture"
    }
    var selectedRegion: CaptureRegion { region }
    private var menuIsTracking = false
    private var pendingSourceChange = false
    private var pendingNavigation: (() -> Void)?
    var isMenuTracking: Bool { menuIsTracking }

    private var catalog = CaptureCatalog(displays: [], windows: [])
    private let settings: AppSettings?
    private var savedPreferences: [CaptureMode: CaptureSessionPreferences] = [:]
    private(set) var mode: CaptureMode = .snapshot
    private var preferences: CaptureSessionPreferences {
        get { savedPreferences[mode] ?? CaptureSessionPreferences(instantCapture: false) }
        set {
            savedPreferences[mode] = newValue
            settings?.saveCapturePreferences(newValue, for: mode)
        }
    }
    private var region: CaptureRegion { preferences.region }
    private var target: CaptureTarget?
    private var overlayPanels: [CapturePanel] = []
    private var overlays: [SelectionOverlayView] = []
    private var toolbar: CapturePanel?
    private var toolbarScale: Double
    private var toolbarHiddenForInk = false
    private var toolbarRevealTask: Task<Void, Never>?
    private var lastToolbarFrame: CGRect?
    private var regionButtons: [CaptureRegion: CaptureToolbarButton] = [:]
    private let sizeControl = SelectionSizeControl()
    private var modeControl: CaptureModeSelector?
    private var regionControl: CaptureModeSelector?
    private var timerControl: CaptureToolbarButton?
    private var hint: NSTextField?
    private var focusGroups: [[CaptureToolbarButton]] = []
    private var shortcutButtons: [ShortcutAction: CaptureToolbarButton] = [:]
    private var eventMonitor: Any?
    private var hoverArea: CGRect?
    private var windowLocked = false
    private var hostDisplay: CaptureDisplay?
    private var priorApp: NSRunningApplication?

    init(settings: AppSettings? = nil) {
        self.settings = settings
        editor = AreaAnnotationEditor(settings: settings)
        toolbarScale = settings?.captureToolbarScale ?? 1
        super.init()
        sizeControl.onLeaveFields = { [weak self] backwards in
            guard let self else { return }
            focusGroup(backwards ? focusGroups.count - 1 : 0)
        }
        editor.onConfirm = { [weak self] in self?.confirm() }
        editor.onToggleOCR = { [weak self] in
            guard let self else { return }
            stageAreaForEditing = true
            handleShortcut(.toggleOCR)
        }
        editor.presentMenu = { [weak self] menu, button in self?.showMenu(menu, from: button) }
        editor.onPaletteResize = { [weak self] in self?.updateSizeControl() }
        editor.onSelectTool = { [weak self] tool in
            guard let self else { return }
            if tool == .select {
                if toolbarHiddenForInk { toolbar?.orderFrontRegardless() }
                toolbarHiddenForInk = false
            } else {
                toolbar?.orderOut(nil)
                toolbarHiddenForInk = true
            }
        }
        sizeControl.onResize = { [weak self] size in self?.applyDimensions(size) }
        loadPreferences()
    }

    func loadPreferences(mode initialMode: CaptureMode = .snapshot, region initialRegion: CaptureRegion? = nil) {
        mode = initialMode
        if let settings {
            for mode in CaptureMode.allCases {
                savedPreferences[mode] = settings.capturePreferences(for: mode)
            }
        }
        if let initialRegion, mode.supports(initialRegion) { preferences.region = initialRegion }
    }

    isolated deinit {
        scrollSuggestionTask?.cancel()
        toolbarRevealTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    var focusedToolbarLabel: String? {
        guard toolbar?.isKeyWindow == true else { return nil }
        return (toolbar?.firstResponder as? CaptureToolbarButton)?.accessibilityLabel()
    }

    func present(catalog: CaptureCatalog, initialRegion: CaptureRegion? = nil, frozenFrames: [UInt32: CGImage] = [:],
                 previousMode: CaptureMode? = nil, restoringFocus label: String? = nil) {
        dismiss()
        self.catalog = catalog
        if let initialRegion, mode.supports(initialRegion) { preferences.region = initialRegion }
        target = nil
        windowLocked = false
        priorApp = NSWorkspace.shared.frontmostApplication
        let point = NSEvent.mouseLocation
        hostDisplay = catalog.displays.first(where: { $0.frame.contains(point) }) ?? catalog.displays.first
        guard let hostDisplay else { return }
        for display in catalog.displays {
            let panel = CapturePanel(contentRect: display.frame, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
            panel.hasShadow = false
            let view = makeSelectionOverlay(for: display, frozenFrame: frozenFrames[display.id])
            // Keep AppKit's interactive Live Text view beside the layer-hosting canvas.
            let host = NSView(frame: view.frame)
            host.addSubview(view)
            panel.contentView = host
            panel.acceptsMouseMovedEvents = true
            panel.orderFrontRegardless()
            overlayPanels.append(panel)
        }
        makeToolbar(on: hostDisplay)
        if let previousMode, let index = CaptureMode.allCases.firstIndex(of: previousMode) {
            modeControl?.select(index)
            toolbar?.contentView?.layoutSubtreeIfNeeded()
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown { return self.handleKeyEvent(event) }
                if let window = event.window, self.sizeControl.contains(screenPoint: window.convertPoint(toScreen: event.locationInWindow)),
                   window === self.sizeControl.window {
                    self.editor.finishText()
                    window.makeKey()
                    return false
                }
                self.sizeControl.endEditing()
                // The toolbar is normally key. Let Live Text receive both clicks,
                // including the first one on another display's non-key panel.
                if self.capturesText, let window = event.window, !window.isKeyWindow,
                   let preview = self.textPreviews.first(where: { $0.window === window }),
                   preview.hasText(at: preview.convert(event.locationInWindow, from: nil)) {
                    window.makeKey()
                    window.makeFirstResponder(preview.text)
                }
                return false
            }
            return consumed ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCursorAfterActivation),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NSApp.activate(ignoringOtherApps: true)
        toolbar?.makeKeyAndOrderFront(nil)
        resetSelection()
        let restored = label.flatMap { name in
            focusGroups.joined().first { $0.isEnabled && $0.accessibilityLabel() == name }
        }
        toolbar?.makeFirstResponder(restored ?? toolbar?.contentView)
        refreshCursor(at: NSEvent.mouseLocation)
    }

    @objc private func refreshCursorAfterActivation() { refreshCursor(at: NSEvent.mouseLocation) }

    /// Apply the initial cursor without waiting for a mouse-moved event. The
    /// non-key selection windows cannot rely on AppKit cursor rectangles alone.
    func refreshCursor(at point: CGPoint) {
        if editor.containsPalette(point) {
            NSCursor.arrow.set()
        } else if let toolbar, !toolbarHiddenForInk, !toolbar.ignoresMouseEvents, toolbar.frame.contains(point), let root = toolbar.contentView {
            clearHoverArea()
            let hit = root.hitTest(toolbar.convertPoint(fromScreen: point))
            let editable = (hit as? NSTextField)?.isEditable == true || (hit as? NSTextView)?.isEditable == true
            (editable ? NSCursor.iBeam : NSCursor.arrow).set()
        } else if sizeControl.contains(screenPoint: point) {
            NSCursor.iBeam.set()
        } else if let overlay = overlays.first(where: { $0.display.frame.contains(point) }) {
            if let preview = overlay.textPreview, let window = preview.window,
               preview.hasText(at: preview.convert(window.convertPoint(fromScreen: point), from: nil)) {
                NSCursor.iBeam.set()
            } else { (editor.cursor(at: point) ?? .crosshair).set() }
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Build the same event surface independently of ordering its window front.
    func makeSelectionOverlay(for display: CaptureDisplay, frozenFrame: CGImage? = nil) -> NSView {
        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: display.frame.size), display: display, frozenFrame: frozenFrame)
        view.controller = self
        updateAccessibilityHelp(for: view)
        view.showFrozenFrame(usesFrozenSelection)
        overlays.append(view)
        return view
    }

    func dismiss() {
        target = nil
        sizeControl.removeFromSuperview()
        toolbarHiddenForInk = false
        editor.clear()
        stageAreaForEditing = false
        invalidateScrollSuggestion()
        selectedScrollPoint = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        toolbarRevealTask?.cancel()
        toolbarRevealTask = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        clearTextPreviews()
        overlayPanels.forEach { $0.orderOut(nil) }
        overlayPanels.removeAll()
        overlays.forEach { $0.cancelInteraction(); $0.releaseFrozenFrame(); $0.controller = nil }
        overlays.removeAll()
        regionButtons.removeAll()
        focusGroups.removeAll()
        shortcutButtons.removeAll()
        modeControl = nil
        regionControl = nil
        timerControl = nil
        hint = nil
        NSCursor.arrow.set()
    }

    private func cancel() {
        let app = priorApp
        dismiss()
        app?.activate(options: [])
        onCancel?()
    }

    /// Cancel the innermost selection operation before dismissing the overlay.
    /// Uses the configurable cancel action, rather than a hard-coded Escape key.
    private func cancelSelectionOrOverlay() {
        if editor.isTyping { editor.finishText(); return }
        if editor.isDrawing { editor.cancelDraft(); return }
        let dragging = overlays.contains { $0.isInteracting }
        let adjustableArea: Bool
        if case .area = target { adjustableArea = usesArea && (region != .area || !captureOnRelease) }
        else { adjustableArea = false }
        guard dragging || adjustableArea else { cancel(); return }
        overlays.forEach { $0.cancelInteraction() }
        stageAreaForEditing = false
        revealToolbarAfterDrag()
        target = nil
        hoverArea = nil
        invalidateScrollSuggestion()
        selectedScrollPoint = nil
        windowLocked = false
        refreshSelection()
    }

    private func confirm(destination: SnapshotDestination = .capturePreferences) {
        sizeControl.endEditing()
        if capturesText {
            guard canCopyAll else { return }
            copyText(textPreviews.map { $0.text.text }.filter { !$0.isEmpty }.joined(separator: "\n"))
            return
        }
        guard let target else { NSSound.beep(); return }
        editor.finishGesture()
        let marks = editor.marks
        let selectedRegion = region
        var app = priorApp
        if selectedRegion == .scrolling, case let .area(_, rect) = target {
            let point = selectedScrollPoint ?? CGPoint(x: rect.midX, y: rect.midY)
            if let pid = catalog.windows.first(where: { $0.frame.contains(point) })?.processID {
                app = NSRunningApplication(processIdentifier: pid) ?? priorApp
            }
        }
        onScrollInputPoint?(selectedRegion == .scrolling ? selectedScrollPoint : nil)
        dismiss()
        app?.activate(options: [])
        onCapture?(mode, selectedRegion, target, marks, destination)
    }

    private var selectingWindow: Bool { region == .window }
    private var selectingDisplay: Bool { region == .fullscreen }

    fileprivate func pointerMoved(_ point: CGPoint, display: CaptureDisplay) {
        if capturesText, region == .area { return }
        if (region == .area || region == .scrolling), target == nil {
            let window = catalog.windows.first { $0.frame.contains(point) }
            if region == .scrolling, let window {
                guard point != scrollHoverPoint || window.id != scrollHoverWindowID || hoverArea == nil else { return }
                scrollHoverPoint = point
                scrollHoverWindowID = window.id
                scrollSuggestionGeneration &+= 1
                hoverArea = window.frame.intersection(display.frame)
                hoverAreaLabel = "Window bounds — adjust area"
                pendingScrollRequest = ScrollRegionRequest(point: point, window: window, display: display, generation: scrollSuggestionGeneration)
                startScrollSuggestionQuery()
            } else {
                let next = window?.frame.intersection(display.frame)
                guard hoverArea != next || !hoverAreaLabel.isEmpty else { return }
                invalidateScrollSuggestion()
                hoverArea = next
                hoverAreaLabel = ""
            }
            refreshSelection()
        } else if selectingWindow && !windowLocked {
            let hit = catalog.windows.first { $0.frame.contains(point) }
            let next = hit.map { CaptureTarget.window(id: $0.id) }
            guard target != next else { return }
            target = next
            refreshSelection()
        } else if selectingDisplay {
            let next = CaptureTarget.display(id: display.id)
            guard target != next else { return }
            target = next
            refreshSelection()
        }
    }

    private func invalidateScrollSuggestion() {
        scrollSuggestionGeneration &+= 1
        scrollSuggestionTask?.cancel()
        scrollSuggestionTask = nil
        pendingScrollRequest = nil
        scrollHoverWindowID = nil
        hoverAreaLabel = ""
    }

    private func startScrollSuggestionQuery() {
        guard scrollSuggestionTask == nil else { return }
        scrollSuggestionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self, region == .scrolling, target == nil, let request = pendingScrollRequest else { break }
                pendingScrollRequest = nil
                let candidate: CGRect?
                if let query = scrollRegionQuery { candidate = await query(request) }
                else { candidate = await scrollRegionResolver.resolve(request) }
                guard !Task.isCancelled else { return }
                if region == .scrolling, target == nil,
                   ScrollRegionResolver.isCurrent(request, generation: scrollSuggestionGeneration, point: scrollHoverPoint, windowID: scrollHoverWindowID),
                   let candidate = candidate.flatMap({ ScrollRegionResolver.clippedCandidate($0, point: request.point, window: request.window.frame, display: request.display.frame) }) {
                    hoverArea = candidate
                    hoverAreaLabel = "Suggested scrolling area"
                    refreshSelection()
                }
                if pendingScrollRequest == nil { break }
            }
            self?.scrollSuggestionTask = nil
        }
    }

    fileprivate func clearHoverArea() {
        invalidateScrollSuggestion()
        guard hoverArea != nil else { return }
        hoverArea = nil
        refreshSelection()
    }

    fileprivate func proposedArea(at point: CGPoint, display: CaptureDisplay) -> CGRect? {
        guard target == nil, region == .area || region == .scrolling else { return nil }
        pointerMoved(point, display: display)
        return hoverArea
    }

    /// All area-producing gestures end here, including a click on a proposed window.
    fileprivate func commitArea(_ rect: CGRect, display: CaptureDisplay, scrollPoint: CGPoint? = nil) {
        areaChanged(rect, display: display)
        refreshSelection()
        if region == .scrolling {
            selectedScrollPoint = scrollPoint.flatMap { rect.contains($0) ? $0 : nil } ?? CGPoint(x: rect.midX, y: rect.midY)
        }
        areaReleased(rect, display: display)
    }

    fileprivate func clicked(_ point: CGPoint, display: CaptureDisplay) {
        if selectingWindow { windowLocked = false; pointerMoved(point, display: display); windowLocked = true }
        else if selectingDisplay { pointerMoved(point, display: display) }
    }

    fileprivate func areaChanged(_ rect: CGRect, display: CaptureDisplay) {
        guard !selectingWindow, !selectingDisplay else { return }
        hoverArea = nil
        if scrollHoverWindowID != nil { invalidateScrollSuggestion() }
        selectedScrollPoint = nil
        let next: CaptureTarget? = rect.width >= 2 && rect.height >= 2 ? .area(displayID: display.id, rect: rect) : nil
        guard target != next else { return }
        target = next
        drawSelection()
    }

    fileprivate func areaReleased(_ rect: CGRect, display: CaptureDisplay) {
        guard region == .area, captureOnRelease, rect.width >= 2, rect.height >= 2,
              target == .area(displayID: display.id, rect: rect) else { return }
        confirm()
    }

    fileprivate func hideToolbarForDrag() {
        if !sizeControl.isHidden { sizeControl.isHidden = true }
        guard let toolbar, !toolbar.ignoresMouseEvents || toolbarRevealTask != nil else { return }
        editor.hideDuringAdjustment()
        toolbarRevealTask?.cancel()
        toolbarRevealTask = nil
        toolbar.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            toolbar.animator().alphaValue = 0
        }
    }

    fileprivate func revealToolbarAfterDrag() {
        guard let toolbar, toolbar.ignoresMouseEvents, toolbarRevealTask == nil else { return }
        toolbarRevealTask = Task { [weak self, weak toolbar] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, let toolbar, self.toolbar === toolbar else { return }
            toolbarRevealTask = nil
            toolbar.ignoresMouseEvents = false
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                toolbar.animator().alphaValue = 1
            }
        }
    }

    fileprivate var usesArea: Bool { !selectingWindow && !selectingDisplay }

    func setRegion(_ newRegion: CaptureRegion) {
        guard mode.supports(newRegion) else { return }
        let wasFrozen = usesFrozenSelection
        if region != newRegion { preferences.region = newRegion }
        resetSelection()
        selectionSourceChanged(from: wasFrozen)
    }

    func setMode(_ newMode: CaptureMode) {
        guard mode != newMode else { return }
        let wasFrozen = usesFrozenSelection
        let previousMode = mode
        mode = newMode
        resetSelection()
        selectionSourceChanged(from: wasFrozen, previousMode: previousMode)
    }

    func setDelay(_ seconds: Int) {
        guard delaySeconds != seconds, CaptureSessionPreferences.delays.contains(seconds) else { return }
        let wasFrozen = usesFrozenSelection
        preferences.delaySeconds = seconds
        updateModeControls()
        if wasFrozen != usesFrozenSelection {
            overlays.forEach { $0.showFrozenFrame(usesFrozenSelection) }
        }
        selectionSourceChanged(from: wasFrozen)
    }

    private func selectionSourceChanged(from wasFrozen: Bool, previousMode: CaptureMode? = nil) {
        guard wasFrozen != usesFrozenSelection else { return }
        if menuIsTracking { pendingSourceChange = true }
        else { onSelectionSourceChange?(previousMode) }
    }

    private func resetSelection() {
        editor.clear()
        stageAreaForEditing = false
        invalidateScrollSuggestion()
        selectedScrollPoint = nil
        hoverArea = nil
        windowLocked = false
        target = nil
        if selectingDisplay, let hostDisplay { target = .display(id: hostDisplay.id) }
        for (buttonRegion, button) in regionButtons {
            button.isEnabled = mode.supports(buttonRegion)
            button.state = buttonRegion == region ? .on : .off
            button.setAccessibilityValue(buttonRegion == region ? 1 : 0)
            button.needsDisplay = true
        }
        if let index = CaptureRegion.allCases.firstIndex(of: region) { regionControl?.select(index) }
        updateModeControls()
        overlays.forEach {
            $0.cancelInteraction()
            updateAccessibilityHelp(for: $0)
            $0.showFrozenFrame(usesFrozenSelection)
        }
        revealToolbarAfterDrag()
        refreshSelection()
    }

    private func updateModeControls() {
        if let index = CaptureMode.allCases.firstIndex(of: mode) { modeControl?.select(index) }
        let timerStatus = delaySeconds == 0 ? "Off" : timerTitle(for: delaySeconds)
        timerControl?.symbolName = delaySeconds == 0 ? "clock" : "clock.fill"
        timerControl?.setAccessibilityValue(timerStatus)
        timerControl?.focusHint = "Capture timer: \(timerStatus)"
    }

    fileprivate func refreshSelection() {
        let rect = drawSelection()
        updateTextPreviews(rect: rect)
        editor.ocrEnabled = capturesText
        if mode == .snapshot, region == .area, !captureOnRelease,
           case .area(let id, let area) = target,
           let overlay = overlays.first(where: { $0.display.id == id }), let root = overlay.layer {
            editor.show(for: overlay.display, rect: area, in: root, avoiding: toolbar?.frame)
        } else {
            editor.clear()
        }
        updateSizeControl()
        updateToolbar()
    }

    @discardableResult
    private func drawSelection() -> CGRect? {
        var rect: CGRect?
        var text = ""
        switch target {
        case .area(_, let area):
            rect = area
            if overlays.contains(where: { $0.isInteracting }) {
                text = "\(Int(area.width.rounded())) × \(Int(area.height.rounded())) pt"
            }
        case .display(let id): rect = catalog.displays.first(where: { $0.id == id })?.frame
        case .window(let id):
            let window = catalog.windows.first(where: { $0.id == id })
            rect = window?.frame; text = window.map { $0.title.isEmpty ? $0.applicationName : $0.title } ?? ""
        case nil: rect = hoverArea; text = region == .scrolling ? hoverAreaLabel : ""
        }
        for overlay in overlays {
            let scanDisplay = capturesText && region == .area && target == nil && !overlay.isInteracting
            overlay.updateSelection(rect: scanDisplay ? overlay.display.frame : rect, text: text,
                                    resizable: usesArea && target != nil, preview: scanDisplay || (target == nil && hoverArea != nil))
        }
        return rect
    }

    private var textPreviews: [InlineTextPreview] { overlays.compactMap(\.textPreview) }

    private func textPreview(for window: NSWindow?) -> InlineTextPreview? {
        if window === toolbar {
            return textPreviews.first(where: { $0.text.hasActiveTextSelection }) ?? textPreviews.first
        }
        return textPreviews.first { $0.window === window }
    }

    private var canCopyAll: Bool {
        let previews = textPreviews
        return !previews.contains(where: \.isReading) && previews.contains { !$0.text.text.isEmpty }
    }

    private var textHint: String {
        if let copyStatus { return copyStatus }
        let previews = textPreviews
        if let ready = previews.first(where: { !$0.text.text.isEmpty }) { return ready.status }
        return previews.first(where: \.isReading)?.status ?? previews.first?.status ?? "Choose a " + region.title.lowercased()
    }

    fileprivate func clearTextPreviews() {
        copyStatus = nil
        for overlay in overlays {
            overlay.textPreview?.close()
            overlay.textPreview = nil
        }
    }

    private func updateTextPreviews(rect: CGRect?) {
        for overlay in overlays {
            let display = overlay.display
            let wholeDisplay = region == .area && target == nil
            let visible = (wholeDisplay ? display.frame : rect ?? .null).intersection(display.frame)
            let active = capturesText && !visible.isEmpty && !overlay.isInteracting
            let source: CaptureTarget = visible == display.frame ? .display(id: display.id) : .area(displayID: display.id, rect: visible)
            if active, overlay.textPreview?.target == source { continue }
            if let old = overlay.textPreview {
                old.close()
                overlay.textPreview = nil
                copyStatus = nil
            }
            guard active, let samplePreview, let host = overlay.superview, let canvas = overlay.layer else { continue }
            let frame = visible.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let preview = InlineTextPreview(frame: frame, target: source, canvas: canvas)
            preview.onCopy = { [weak self] in self?.copyText($0) }
            preview.onChange = { [weak self] in self?.refreshSelection() }
            overlay.textPreview = preview
            host.addSubview(preview, positioned: .above, relativeTo: overlay)
            preview.read(using: samplePreview)
        }
    }

    private func copyText(_ text: String) {
        do {
            guard try copyRecognizedText(text) else { return }
            copyStatus = "Copied to clipboard"
        } catch { copyStatus = error.localizedDescription }
        refreshSelection()
    }

    private var validPreviousArea: CaptureTarget? {
        guard let (previous, frame) = previousArea?(), case .area(let id, let rect) = previous,
              catalog.displays.contains(where: { $0.id == id && $0.frame == frame && frame.contains(rect) }) else { return nil }
        return previous
    }

    private func updateToolbar() {
        let confirmation = keymap?.configuration.binding(for: .confirmCapture).map { "\($0.displayString) to \(confirmTitle.lowercased())" }
            ?? "Choose \(confirmTitle) in Capture options"
        var shortcuts: [String] = []
        if canChooseSnapshotDestination, let keymap {
            for (action, label) in [(ShortcutAction.copyScreenshot, "Copy"), (.saveScreenshot, "Save")] {
                if let binding = keymap.configuration.binding(for: action) {
                    shortcuts.append("\(binding.displayString) \(label)")
                }
            }
        }
        let stagedHint = ([confirmation] + shortcuts).joined(separator: " · ")
        let message = capturesText ? textHint : region == .area && captureOnRelease ? "Drag to capture" : target != nil ? stagedHint : selectingWindow ? "Choose a window" : selectingDisplay ? "Choose a display" : "Drag to select"
        let focused = toolbar?.firstResponder as? CaptureToolbarButton
        let visibleHint = toolbar?.isKeyWindow == true ? focused?.focusHint ?? message : message
        if hint?.stringValue != visibleHint { hint?.stringValue = visibleHint }
    }

    private func updateSizeControl() {
        guard case .area(let id, let rect) = target,
              let overlay = overlays.first(where: { $0.display.id == id }), !overlay.isInteracting,
              let host = overlay.superview, host === overlay.window?.contentView else {
            sizeControl.removeFromSuperview()
            return
        }
        if sizeControl.superview !== host { host.addSubview(sizeControl) }
        let display = overlay.display
        let bounds = NSScreen.screens.first { $0.frame == display.frame }?.visibleFrame ?? display.frame
        let frame = ToolbarGeometry.selectionSizeFrame(size: SelectionSizeControl.size, selection: rect, screen: bounds,
                                                       toolbar: toolbar?.frame ?? .null, palette: editor.visiblePaletteFrame ?? .null)
        sizeControl.frame = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        sizeControl.update(size: rect.size)
        sizeControl.isHidden = false
    }

    private func applyDimensions(_ size: CGSize) {
        guard case let .area(id, existing) = target, let display = overlays.first(where: { $0.display.id == id })?.display else { return }
        let rect = SelectionGeometry.resized(existing, size: size, within: display.frame)
        target = .area(displayID: id, rect: rect)
        if let point = selectedScrollPoint, !rect.contains(point) {
            selectedScrollPoint = CGPoint(x: rect.midX, y: rect.midY)
        }
        refreshSelection()
    }

    private func makeToolbar(on display: CaptureDisplay) {
        let tileSize = NSSize(width: 52, height: 44)
        let horizontalInset: CGFloat = 10
        let surfaceHeight = tileSize.height + 12
        let root = CaptureToolbarView(frame: .zero)
        root.appearance = NSAppearance(named: .darkAqua)
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Karuto capture toolbar")
        root.setAccessibilityHelp("Tab between groups. Use arrow keys within a group and Space to activate a control. Drag the toolbar to move it.")
        root.onMove = { [weak self] frame in
            self?.lastToolbarFrame = frame
            self?.updateSizeControl()
        }
        let content = NSView()
        let surface = SettingsGlassSurface()
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(surface)
        surface.content.wantsLayer = true
        surface.content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        surface.content.layer?.cornerRadius = 20
        let row = NSStackView()
        row.spacing = 3
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.content.addSubview(row)

        func divider(leading: CGFloat, trailing: CGFloat) {
            let line = NSBox()
            line.boxType = .separator
            if let previous = row.arrangedSubviews.last {
                row.setCustomSpacing(leading, after: previous)
            }
            row.addArrangedSubview(line)
            row.setCustomSpacing(trailing, after: line)
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        let modes = CaptureMode.allCases.map { mode in
            let button = CaptureToolbarButton(mode.title, symbol: mode == .snapshot ? "camera" : "record.circle") { [weak self] in
                self?.setMode(mode)
            }
            button.isRegionTile = true
            shortcutButtons[mode == .snapshot ? .snapshotMode : .recordingMode] = button
            return button
        }
        let selector = CaptureModeSelector(buttons: modes)
        modeControl = selector
        row.addArrangedSubview(selector)
        // The capsule has a visible edge. An unselected region icon has its own side bearings.
        divider(leading: 13, trailing: 10)
        let regions: [(CaptureRegion, String, ShortcutAction)] = [
            (.area, "viewfinder", .areaMode), (.fullscreen, "display", .fullscreenMode),
            (.window, "macwindow", .windowMode), (.scrolling, "doc.text", .scrollingMode)
        ]
        var choices: [CaptureToolbarButton] = []
        for (region, symbol, action) in regions {
            let button = CaptureToolbarButton(region.title, symbol: symbol) { [weak self] in self?.setRegion(region) }
            button.isRegionTile = true
            button.setAccessibilityRole(.radioButton)
            regionButtons[region] = button
            shortcutButtons[action] = button
            choices.append(button)
        }
        let regionRow = CaptureModeSelector(buttons: choices, isAreaSelector: true)
        regionControl = regionRow
        row.addArrangedSubview(regionRow)
        // The narrow timer tile leaves less space around its icon than a region tile.
        divider(leading: 12, trailing: 13)
        let timer = CaptureToolbarButton("Capture timer", symbol: "clock")
        timer.handler = { [weak self, weak timer] in
            guard let self, let timer else { return }
            showMenu(makeTimerMenu(), from: timer)
        }
        timerControl = timer
        let options = CaptureToolbarButton("Capture options", symbol: "gearshape")
        options.handler = { [weak self, weak options] in
            guard let self, let options else { return }
            showMenu(makeOptionsMenu(), from: options)
        }
        let tools = [timer, options]
        tools.forEach { row.addArrangedSubview($0) }
        let cancel = CaptureToolbarButton("Cancel", symbol: "xmark") { [weak self] in self?.cancel() }
        row.addArrangedSubview(cancel)
        (tools + [cancel]).forEach { $0.showsPressEffect = false }
        shortcutButtons[.cancelCapture] = cancel
        focusGroups = [modes, choices, tools + [cancel]]
        let message = captureLabel("", size: 11)
        message.alignment = .center
        message.lineBreakMode = .byTruncatingTail
        message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(message)
        message.textColor = .white
        message.wantsLayer = true
        message.layer?.shadowColor = NSColor.black.cgColor
        message.layer?.shadowOpacity = 0.8
        message.layer?.shadowRadius = 3
        message.layer?.shadowOffset = .zero
        hint = message
        for button in focusGroups.joined() {
            button.symbolScale = ceil(toolbarScale)
            button.focusChanged = { [weak message, weak button] in
                if let button { button.scrollToVisible(button.bounds) }
                message?.stringValue = button?.focusHint ?? ""
            }
            let size = button.isRegionTile ? tileSize : button.intrinsicContentSize
            button.widthAnchor.constraint(equalToConstant: size.width).isActive = true
            button.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        }
        let width = row.fittingSize.width + 2 * horizontalInset
        content.frame.size = CGSize(width: width, height: surfaceHeight + 20)
        root.installContent(content)
        let previous = lastToolbarFrame.flatMap { display.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) ? $0 : nil }
        let origin = CGPoint(x: (previous?.midX ?? display.frame.midX) - width / 2, y: previous?.minY ?? display.frame.minY + 55)
        let panel = CapturePanel(contentRect: CGRect(origin: origin, size: content.frame.size), level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3))
        panel.contentMinSize = .zero
        let visibleFrame = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id })?.visibleFrame ?? display.frame
        panel.contentView = root
        panel.initialFirstResponder = root
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            surface.topAnchor.constraint(equalTo: content.topAnchor),
            surface.heightAnchor.constraint(equalToConstant: surfaceHeight),
            row.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor, constant: horizontalInset),
            row.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor, constant: -horizontalInset),
            row.centerYAnchor.constraint(equalTo: surface.content.centerYAnchor),
            message.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 4),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10)
        ])
        root.resize(to: toolbarScale, within: visibleFrame)
        updateShortcutHints()
        toolbar = panel
    }

    private func shortcutLabel(_ name: String, action: ShortcutAction) -> String {
        guard let binding = keymap?.configuration.binding(for: action) else { return name }
        return name + " · " + binding.displayString
    }

    private func updateShortcutHints() {
        for (action, button) in shortcutButtons {
            button.focusHint = shortcutLabel(button.accessibilityLabel() ?? action.title, action: action)
            button.shortcut = keymap?.configuration.binding(for: action)?.displayString
        }
    }

    func refreshKeymap() {
        updateShortcutHints()
        overlays.forEach { updateAccessibilityHelp(for: $0) }
        refreshSelection()
    }

    private var confirmInstruction: String {
        keymap?.configuration.binding(for: .confirmCapture).map { "press \($0.displayString)" } ?? "choose \(confirmTitle) in Capture options"
    }

    private var cancelInstruction: String {
        keymap?.configuration.binding(for: .cancelCapture).map { "press \($0.displayString)" } ?? "click Cancel"
    }

    private func updateAccessibilityHelp(for view: SelectionOverlayView) {
        if capturesText {
            view.setAccessibilityHelp("Double-click a word to copy it. Drag over text and press Command-C to copy a passage.")
            return
        }
        view.updateAccessibilityHelp(capturesOnRelease: region == .area && captureOnRelease,
                                     confirmation: confirmInstruction, cancellation: cancelInstruction)
    }

    /// Only overlay commands are handled here; application commands use the
    /// application's monitor and global commands use the system hotkey registry.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !menuIsTracking, NSApp.modalWindow == nil, !event.isARepeat,
              keymap?.isRecordingShortcut != true else { return false }
        if event.window === sizeControl.window, sizeControl.isEditing { return false }
        if editor.isTyping { return editor.handleTextKeyEvent(event) }
        if let field = event.window?.firstResponder as? NSTextView, field.isEditable { return false }
        let action = keymap?.action(for: event, in: .overlay)
        if action == nil, navigateToolbar(event) { return true }
        if capturesText, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let preview = textPreview(for: event.window) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                copyText(preview.text.selectedText)
                return true
            case "a":
                let string = preview.text.text
                if !string.isEmpty { preview.text.selectedRanges = [string.startIndex..<string.endIndex] }
                return true
            default: break
            }
        }
        guard let action else { return false }
        if action == .copyScreenshot || action == .saveScreenshot {
            guard let window = event.window, !(window.firstResponder is NSTextView),
                  window === toolbar || editor.isPaletteWindow(window) || overlays.contains(where: { $0.window === window }) else {
                return false
            }
        }
        return handleShortcut(action)
    }

    private func focusGroup(_ index: Int) {
        guard focusGroups.indices.contains(index) else { return }
        let group = focusGroups[index].filter { $0.isEnabled }
        let selected = group.first { $0.accessibilityRole() == .radioButton && ($0.accessibilityValue() as? Int) == 1 }
        guard let button = selected ?? group.first else { return }
        toolbar?.makeKey()
        toolbar?.makeFirstResponder(button)
    }

    private func navigateToolbar(_ event: NSEvent) -> Bool {
        guard let toolbar, let window = event.window, window === toolbar || overlayPanels.contains(where: { $0 === window }),
              !toolbarHiddenForInk, !toolbar.ignoresMouseEvents else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var focused = window.firstResponder as? CaptureToolbarButton
        if focused == nil, (window === toolbar && window.firstResponder === toolbar.contentView || overlayPanels.contains(where: { $0 === window })),
           modifiers.isEmpty, event.keyCode == 123 || event.keyCode == 124 {
            focusGroup(1)
            focused = toolbar.firstResponder as? CaptureToolbarButton
        }
        let group = focusGroups.firstIndex { buttons in buttons.contains { $0 === focused } }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == [.shift] {
            let backwards = modifiers.contains(.shift)
            let stops = focusGroups.indices.filter { focusGroups[$0].contains { $0.isEnabled } }
            guard let first = stops.first, let last = stops.last else { return false }
            let position = group.flatMap { stops.firstIndex(of: $0) }
            let next = position.map { $0 + (backwards ? -1 : 1) }
            if let next, stops.indices.contains(next) {
                focusGroup(stops[next])
            } else if sizeControl.window != nil, !sizeControl.isHidden, next != nil || !backwards {
                sizeControl.focus(backwards: backwards)
            } else {
                focusGroup(backwards ? last : first)
            }
            return true
        }
        guard modifiers.isEmpty, let focused, let group else { return false }
        if event.keyCode == 49 {
            if focused.isEnabled { focused.performClick(nil) }
            return true
        }
        guard event.keyCode == 123 || event.keyCode == 124 else { return false }
        let peers = focusGroups[group].filter { $0.isEnabled }
        guard peers.count > 1, let index = peers.firstIndex(of: focused) else { return false }
        let step = event.keyCode == 123 ? -1 : 1
        let next = peers[(index + peers.count + step) % peers.count]
        toolbar.makeFirstResponder(next)
        if next.accessibilityRole() == .radioButton { next.performClick(nil) }
        return true
    }

    /// Shared by event dispatch, menu actions, and offscreen interaction checks.
    @discardableResult
    func handleShortcut(_ action: ShortcutAction) -> Bool {
        guard !menuIsTracking else { return false }
        switch action {
        case .selectLastArea:
            guard mode == .snapshot, let previous = validPreviousArea else { return false }
            if region != .area { setRegion(.area) }
            else { resetSelection() }
            stageAreaForEditing = true
            target = previous
            overlays.forEach { updateAccessibilityHelp(for: $0) }
            refreshSelection()
        case .undoAnnotation:
            guard !capturesText, editor.canUndo else { return false }
            editor.undo()
        case .redoAnnotation:
            guard !capturesText, editor.canRedo else { return false }
            editor.redo()
        case .copyScreenshot, .saveScreenshot:
            guard canChooseSnapshotDestination, !editor.isTyping,
                  !overlays.contains(where: { $0.isInteracting }) else { return false }
            confirm(destination: action == .copyScreenshot ? .clipboard : .saveFolder)
        case .confirmCapture:
            confirm()
        case .cancelCapture: cancelSelectionOrOverlay()
        case .toggleOCR:
            guard supportsOCR else { return false }
            ocrEnabled.toggle()
        case .toggleInstantCapture: changeInstantCapture()
        case .toggleFreezeDisplay:
            guard mode == .snapshot else { return false }
            changeFreezeDisplay()
        case .areaMode: setRegion(.area)
        case .fullscreenMode: setRegion(.fullscreen)
        case .windowMode: setRegion(.window)
        case .scrollingMode:
            guard mode.supports(.scrolling) else { return false }
            setRegion(.scrolling)
        case .timerMode: setDelay(delaySeconds == 0 ? 3 : 0)
        case .snapshotMode: setMode(.snapshot)
        case .recordingMode: setMode(.screenRecording)
        default: return false
        }
        return true
    }

    private func assignShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
        guard let binding = keymap?.configuration.binding(for: action) else { return }
        item.keyEquivalent = binding.menuKeyEquivalent
        item.keyEquivalentModifierMask = binding.modifierFlags
    }

    @objc private func toggleAnnotation(_ sender: NSMenuItem) {
        stageAreaForEditing.toggle()
        refreshSelection()
    }

    func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture options")
        menu.font = .systemFont(ofSize: 14)
        menu.minimumWidth = 320
        menu.autoenablesItems = false
        let sessionHeading = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
        sessionHeading.isEnabled = false
        menu.addItem(sessionHeading)
        let instant = NSMenuItem(title: "Instant Capture", action: #selector(toggleInstantCapture(_:)), keyEquivalent: "")
        instant.target = self
        instant.state = instantCapture ? .on : .off
        instant.toolTip = "Continue on mouse release, or turn off to adjust the area and \(confirmInstruction)."
        assignShortcut(.toggleInstantCapture, to: instant)
        menu.addItem(instant)
        let annotate = NSMenuItem(title: "Annotate after selection", action: #selector(toggleAnnotation(_:)), keyEquivalent: "")
        annotate.target = self
        annotate.state = stageAreaForEditing ? .on : .off
        annotate.isEnabled = mode == .snapshot && region == .area && instantCapture && !capturesText
        menu.addItem(annotate)
        let freeze = NSMenuItem(title: "Freeze Display During Capture", action: #selector(toggleFreezeDisplay(_:)), keyEquivalent: "")
        freeze.target = self
        freeze.state = freezeDisplay ? .on : .off
        freeze.isEnabled = mode == .snapshot
        freeze.toolTip = "Freeze the display for still snapshots with the timer off. Apps and audio keep running."
        assignShortcut(.toggleFreezeDisplay, to: freeze)
        menu.addItem(freeze)
        menu.addItem(.separator())
        let size = NSMenuItem(title: "Toolbar size", action: nil, keyEquivalent: "")
        size.view = ToolbarSizeMenuView(title: size.title, scale: toolbarScale) { [weak self] scale in
            self?.changeToolbarScale(scale)
        }
        menu.addItem(size)
        menu.addItem(.separator())
        let shortcuts = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(openKeymap(_:)), keyEquivalent: "")
        shortcuts.target = self
        assignShortcut(.keymap, to: shortcuts)
        menu.addItem(shortcuts)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openPreferences(_:)), keyEquivalent: "")
        preferences.target = self
        assignShortcut(.preferences, to: preferences)
        menu.addItem(preferences)
        if mode == .snapshot, region == .area, previousArea?() != nil {
            menu.addItem(.separator())
            let recall = menu.addItem(withTitle: "Select Last Capture Region", action: #selector(recallArea), keyEquivalent: "")
            recall.target = self
            assignShortcut(.selectLastArea, to: recall)
        }
        if capturesText ? canCopyAll : target != nil {
            menu.addItem(.separator())
            let item = menu.addItem(withTitle: confirmTitle, action: #selector(confirmFromMenu), keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    private func changeToolbarScale(_ scale: Double) {
        guard toolbarScale != scale else { return }
        toolbarScale = scale
        settings?.captureToolbarScale = scale
        guard let toolbar, let root = toolbar.contentView as? CaptureToolbarView,
              let visibleFrame = toolbar.screen?.visibleFrame ?? hostDisplay?.frame else { return }
        root.resize(to: scale, within: visibleFrame)
        // Request higher-resolution symbols only when crossing a whole zoom level.
        for button in focusGroups.joined() { button.symbolScale = ceil(scale) }
        lastToolbarFrame = toolbar.frame
        updateSizeControl()
    }

    @objc private func confirmFromMenu() {
        if menuIsTracking { pendingNavigation = { [weak self] in self?.confirm() } }
        else { confirm() }
    }

    @objc private func recallArea() {
        if menuIsTracking { pendingNavigation = { [weak self] in self?.handleShortcut(.selectLastArea) } }
        else { handleShortcut(.selectLastArea) }
    }

    private func timerTitle(for delay: Int) -> String {
        switch delay {
        case 0: "Off"
        case 1: "1 second"
        default: "\(delay) seconds"
        }
    }

    func makeTimerMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture timer")
        menu.font = .systemFont(ofSize: 14)
        for delay in CaptureSessionPreferences.delays {
            let item = NSMenuItem(title: timerTitle(for: delay), action: #selector(timerChanged(_:)), keyEquivalent: "")
            item.tag = delay
            item.target = self
            item.state = delay == delaySeconds ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func showMenu(_ menu: NSMenu, from sender: NSButton) {
        let openedByMouse = NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .leftMouseUp
        menuIsTracking = true
        menu.update()
        let anchor = sender.window?.convertToScreen(sender.convert(sender.bounds, to: nil)) ?? .zero
        let anchorCenter = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) }) ?? sender.window?.screen ?? NSScreen.main
        let placement = ToolbarGeometry.menuPlacement(anchor: anchor, menuSize: menu.size,
                                                       visibleFrame: screen?.visibleFrame ?? catalog.displays.first?.frame ?? anchor)
        // A screen-space top-left anchor lets the whole menu use the available
        // display space rather than being clipped below a near-bottom button.
        menu.popUp(positioning: nil, at: placement.topLeft, in: nil)
        menuIsTracking = false
        sender.highlight(false)
        if openedByMouse, sender.window?.firstResponder === sender {
            sender.window?.makeFirstResponder(sender.window?.contentView)
        }
        // Restart selection only after the menu has finished using its window.
        if pendingSourceChange {
            pendingSourceChange = false
            onSelectionSourceChange?(nil)
        }
        let navigation = pendingNavigation
        pendingNavigation = nil
        navigation?()
    }

    @objc private func openKeymap(_ sender: NSMenuItem) {
        if menuIsTracking { pendingNavigation = onOpenKeymap }
        else { onOpenKeymap?() }
    }

    @objc private func openPreferences(_ sender: NSMenuItem) {
        if menuIsTracking { pendingNavigation = onOpenPreferences }
        else { onOpenPreferences?() }
    }

    @objc private func toggleInstantCapture(_ sender: NSMenuItem) {
        changeInstantCapture()
        sender.state = instantCapture ? .on : .off
    }

    @objc private func toggleFreezeDisplay(_ sender: NSMenuItem) {
        changeFreezeDisplay()
        sender.state = freezeDisplay ? .on : .off
    }

    private func changeInstantCapture() {
        instantCapture.toggle()
    }

    private func changeFreezeDisplay() {
        guard mode == .snapshot else { return }
        let wasFrozen = usesFrozenSelection
        preferences.freezeDisplay.toggle()
        selectionSourceChanged(from: wasFrozen)
    }

    @objc private func timerChanged(_ sender: NSMenuItem) {
        setDelay(sender.tag)
    }
}

@MainActor
final class CaptureToolbarView: NSView, NSGestureRecognizerDelegate {
    var onMove: ((CGRect) -> Void)?
    private let scrollView = NSScrollView()
    private var initialFrame: CGRect?
    private var initialPointer = CGPoint.zero
    private var pan: NSPanGestureRecognizer!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pan = NSPanGestureRecognizer(target: self, action: #selector(moveToolbar(_:)))
        pan.buttonMask = 1
        // AppKit holds clicks until the pan fails. A drag wins before controls
        // receive mouse-down; a stationary click is delivered normally.
        pan.delaysPrimaryMouseButtonEvents = true
        pan.delegate = self
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }

    func installContent(_ content: NSView) {
        setFrameSize(content.frame.size)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .legacy
        scrollView.minMagnification = ToolbarScale.range.lowerBound
        scrollView.maxMagnification = ToolbarScale.range.upperBound
        scrollView.documentView = content
        addSubview(scrollView)
    }

    func resize(to scale: CGFloat, within screen: CGRect) {
        guard let window, let content = scrollView.documentView else { return }
        let available = screen.insetBy(dx: 8, dy: 8)
        let width = ceil(content.frame.width * scale)
        let height = ceil(content.frame.height * scale)
        let bar = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let vertical = height + (width > available.width ? bar : 0) > available.height
        let horizontal = width + (vertical ? bar : 0) > available.width
        scrollView.hasHorizontalScroller = horizontal
        scrollView.hasVerticalScroller = vertical
        let size = CGSize(width: min(width + (vertical ? bar : 0), available.width),
                          height: min(height + (horizontal ? bar : 0), available.height))
        let origin = CGPoint(x: window.frame.midX - size.width / 2, y: window.frame.minY)
        let frame = ToolbarGeometry.clamped(CGRect(origin: origin, size: size), to: screen)
        window.setFrame(frame, display: false)
        scrollView.magnification = scale
        if let button = window.firstResponder as? NSButton { button.scrollToVisible(button.bounds) }
        window.displayIfNeeded()
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        for scroller in [scrollView.horizontalScroller, scrollView.verticalScroller].compactMap({ $0 }) {
            if !scroller.isHidden, scroller.bounds.contains(scroller.convert(point, from: self)) { return false }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        // Buttons, segmented controls and field editors must wait for the pan
        // decision, rather than activating or editing when a drag starts there.
        gestureRecognizer === pan && otherGestureRecognizer !== pan
            && otherGestureRecognizer.view?.isDescendant(of: self) == true
    }

    @objc private func moveToolbar(_ recognizer: NSPanGestureRecognizer) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: recognizer.location(in: nil))
        if recognizer.state == .began {
            initialFrame = window.frame
            let translation = recognizer.translation(in: nil)
            initialPointer = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
        }
        if [.began, .changed, .ended].contains(recognizer.state), let initialFrame {
            let next = ToolbarGeometry.moved(initialFrame, from: initialPointer, to: point,
                                             visibleFrames: NSScreen.screens.map(\.visibleFrame))
            window.setFrameOrigin(next.origin)
            if recognizer.state == .ended, let screen = window.screen {
                resize(to: scrollView.magnification, within: screen.visibleFrame)
            }
            onMove?(window.frame)
        }
        if [.ended, .cancelled, .failed].contains(recognizer.state) { initialFrame = nil }
    }
}

@MainActor
private final class SelectionOverlayView: NSView {
    weak var controller: CaptureUIController?
    let display: CaptureDisplay
    private(set) var selectedRect: CGRect?
    fileprivate var textPreview: InlineTextPreview?
    private let renderer: SelectionOverlayRenderer
    private var frozenFrame: CGImage?
    private var tracking: NSTrackingArea?
    private var dragStart = CGPoint.zero
    private var originalRect: CGRect?
    private var areaInteractionActive = false
    var isInteracting: Bool { areaInteractionActive }
    private var proposedRect: CGRect?
    private var interaction: Interaction = .new
    private enum Interaction { case new, move, resize(Int) }

    init(frame: CGRect, display: CaptureDisplay, frozenFrame: CGImage?) {
        self.display = display
        self.frozenFrame = frozenFrame
        renderer = SelectionOverlayRenderer(size: frame.size, scale: display.scale)
        super.init(frame: frame)
        // Assigning the layer before wantsLayer makes this a layer-hosting view.
        // AppKit owns event delivery; Core Animation owns the retained artwork.
        layer = renderer.rootLayer
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture selection on " + display.name)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    // The toolbar is key when selection starts. Accept its first mouse-down
    // instead of consuming that click only to activate the overlay window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func cancelInteraction() {
        areaInteractionActive = false
        originalRect = nil
        proposedRect = nil
    }

    func showFrozenFrame(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Layer contents sit above hit-test coverage and below selection artwork.
        renderer.rootLayer.contents = visible ? frozenFrame : nil
        renderer.rootLayer.contentsGravity = .resize
        CATransaction.commit()
    }

    func releaseFrozenFrame() {
        showFrozenFrame(false)
        frozenFrame = nil
    }

    func updateAccessibilityHelp(capturesOnRelease: Bool, confirmation: String, cancellation: String) {
        setAccessibilityHelp(capturesOnRelease
            ? "Drag to select an area and release to capture. To reset a drag, \(cancellation); with no selection, this closes capture. For an exact size, turn off Instant Capture and edit the dimensions at the selection edge."
            : "Drag to select an area. Resize by dragging its edges. Edit the width and height at the selection edge, then \(confirmation) to capture. To clear the selection, \(cancellation); repeat with no selection to close capture.")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.updateScale(window?.backingScaleFactor ?? display.scale)
    }

    func updateSelection(rect: CGRect?, text: String, resizable: Bool, preview: Bool = false) {
        selectedRect = preview ? nil : rect.flatMap { $0.intersects(display.frame) ? $0 : nil }
        let local = rect.map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
        renderer.update(rect: local, text: text, resizable: resizable, preview: preview)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }

    private func global(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    }

    // activeAlways does not deliver cursorUpdate events; explicitly refresh on
    // entry and movement even while the toolbar is the key window.
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { controller?.clearHoverArea() }
    override func mouseMoved(with event: NSEvent) {
        controller?.refreshCursor(at: global(event))
        controller?.pointerMoved(global(event), display: display)
    }
    override func mouseDown(with event: NSEvent) {
        let point = global(event)
        if controller?.editor.begin(at: point, displayID: display.id, clickCount: event.clickCount) == true { return }
        guard controller?.usesArea == true else { controller?.clicked(point, display: display); return }
        proposedRect = controller?.proposedArea(at: point, display: display)
        areaInteractionActive = true
        dragStart = point
        originalRect = selectedRect?.intersection(display.frame)
        interaction = .new
        if let rect = originalRect, !rect.isNull {
            if let index = SelectionOverlayRenderer.handlePoints(in: rect).firstIndex(where: { abs($0.x - point.x) <= 8 && abs($0.y - point.y) <= 8 }) { interaction = .resize(index) }
            else if rect.insetBy(dx: -5, dy: -5).contains(point) {
                if abs(point.x - rect.minX) <= 5 { interaction = .resize(7) }
                else if abs(point.x - rect.maxX) <= 5 { interaction = .resize(3) }
                else if abs(point.y - rect.minY) <= 5 { interaction = .resize(1) }
                else if abs(point.y - rect.maxY) <= 5 { interaction = .resize(5) }
                else { interaction = .move }
            }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if controller?.editor.isDrawing == true { controller?.editor.drag(to: global(event)); return }
        guard areaInteractionActive else { return }
        if case .new = interaction, originalRect != nil {
            controller?.editor.clear()
            originalRect = nil
        }
        if controller?.capturesText == true { controller?.clearTextPreviews() }
        controller?.hideToolbarForDrag()
        proposedRect = nil
        updateDrag(to: global(event))
    }

    override func mouseUp(with event: NSEvent) {
        if controller?.editor.isDrawing == true { controller?.editor.end(at: global(event)); return }
        guard areaInteractionActive else { return }
        defer { controller?.revealToolbarAfterDrag() }
        // The release event can contain a newer pointer location than the final
        // drag event. Commit it synchronously before Return/capture can observe it.
        let point = global(event)
        let moved = abs(point.x - dragStart.x) >= 2 || abs(point.y - dragStart.y) >= 2
        if moved, case .new = interaction, originalRect != nil { controller?.editor.clear() }
        if !moved, let proposedRect {
            areaInteractionActive = false
            self.proposedRect = nil
            controller?.commitArea(proposedRect, display: display, scrollPoint: point)
            return
        }
        if !moved, controller?.capturesText == true {
            areaInteractionActive = false
            return
        }
        let rect = updateDrag(to: point)
        areaInteractionActive = false
        proposedRect = nil
        if moved, let rect { controller?.commitArea(rect, display: display) }
        else { controller?.refreshSelection() }
    }

    @discardableResult
    private func updateDrag(to point: CGPoint) -> CGRect? {
        guard areaInteractionActive, controller?.usesArea == true else { return nil }
        var rect: CGRect
        switch interaction {
        case .new: rect = SelectionGeometry.rectangle(from: dragStart, to: point, within: display.frame)
        case .move:
            guard let originalRect else { return nil }
            rect = SelectionGeometry.moved(originalRect, delta: CGSize(width: point.x - dragStart.x, height: point.y - dragStart.y), within: display.frame)
        case .resize(let index):
            guard let originalRect else { return nil }
            var minX = originalRect.minX, maxX = originalRect.maxX, minY = originalRect.minY, maxY = originalRect.maxY
            if [0, 6, 7].contains(index) { minX = point.x }
            if [2, 3, 4].contains(index) { maxX = point.x }
            if [0, 1, 2].contains(index) { minY = point.y }
            if [4, 5, 6].contains(index) { maxY = point.y }
            rect = SelectionGeometry.rectangle(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY), within: display.frame)
        }
        rect = rect.integral.intersection(display.frame)
        controller?.areaChanged(rect, display: display)
        return rect
    }
}

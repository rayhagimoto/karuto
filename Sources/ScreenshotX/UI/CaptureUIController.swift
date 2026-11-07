import AppKit
import CoreGraphics

@MainActor
final class CaptureUIController: NSObject, NSTextFieldDelegate {
    var onCapture: ((CaptureMode, CaptureTarget) -> Void)?
    var onCancel: (() -> Void)?
    var onInstantCaptureChange: ((Bool) -> Void)?
    var onFreezeDisplayChange: ((Bool) -> Void)?
    var onOpenKeymap: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    var keymap: KeymapController? { didSet { refreshKeymap() } }
    var instantCapture = true {
        didSet {
            refreshKeymap()
        }
    }
    var freezeDisplay = false
    var selectedMode: CaptureMode { mode }
    private var optionsMenuIsTracking = false
    private var pendingFreezeChange: Bool?
    private var pendingNavigation: (() -> Void)?
    var isMenuTracking: Bool { optionsMenuIsTracking }

    private var catalog = CaptureCatalog(displays: [], windows: [])
    private var mode: CaptureMode = .area
    private var target: CaptureTarget?
    private var overlayPanels: [CapturePanel] = []
    private var overlays: [SelectionOverlayView] = []
    private var toolbar: CapturePanel?
    private var lastToolbarFrame: CGRect?
    private var modeButtons: [CaptureMode: CaptureModeButton] = [:]
    private var widthField = NSTextField(string: "")
    private var heightField = NSTextField(string: "")
    private var dimensionStack: NSStackView?
    private var dimensionSurface: NSView?
    private var windowRanks: [UInt32: Int] = [:]
    private var recordingKinds: NSSegmentedControl?
    private var hint: NSTextField?
    private var captureButton: ClosureButton?
    private var keyMonitor: Any?
    private var windowLocked = false
    private var recordingKind = 0
    private var hostDisplay: CaptureDisplay?
    private var priorApp: NSRunningApplication?

    override init() { super.init() }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    func present(catalog: CaptureCatalog, initialMode: CaptureMode = .area, frozenFrames: [UInt32: CGImage] = [:]) {
        dismiss()
        self.catalog = catalog
        if frozenFrames.isEmpty {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            windowRanks = Dictionary(uniqueKeysWithValues: info.enumerated().compactMap { offset, item -> (UInt32, Int)? in
                guard let id = item[kCGWindowNumber as String] as? NSNumber else { return nil }
                return (id.uint32Value, offset)
            })
        } else {
            // The snapshot catalog preserves the front-to-back order at freeze
            // time; live windows may have moved since those pixels were captured.
            windowRanks = Dictionary(catalog.windows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        }
        mode = initialMode
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
            panel.contentView = view
            panel.acceptsMouseMovedEvents = true
            panel.orderFrontRegardless()
            overlayPanels.append(panel)
        }
        makeToolbar(on: hostDisplay)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyEvent(event) ?? false
            }
            return consumed ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCursorAfterActivation),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NSApp.activate(ignoringOtherApps: true)
        toolbar?.makeKeyAndOrderFront(nil)
        setMode(initialMode)
        toolbar?.makeFirstResponder(toolbar?.contentView)
        refreshCursor(at: NSEvent.mouseLocation)
    }

    @objc private func refreshCursorAfterActivation() { refreshCursor(at: NSEvent.mouseLocation) }

    /// Apply the initial cursor without waiting for a mouse-moved event. The
    /// non-key selection windows cannot rely on AppKit cursor rectangles alone.
    func refreshCursor(at point: CGPoint) {
        if let toolbar, toolbar.frame.contains(point), let root = toolbar.contentView {
            let hit = root.hitTest(toolbar.convertPoint(fromScreen: point))
            let editable = (hit as? NSTextField)?.isEditable == true || (hit as? NSTextView)?.isEditable == true
            (editable ? NSCursor.iBeam : NSCursor.arrow).set()
        } else if overlays.contains(where: { $0.display.frame.contains(point) }) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Build the same event surface independently of ordering its window front.
    func makeSelectionOverlay(for display: CaptureDisplay, frozenFrame: CGImage? = nil) -> NSView {
        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: display.frame.size), display: display, frozenFrame: frozenFrame)
        view.controller = self
        updateAccessibilityHelp(for: view)
        view.showFrozenFrame(mode == .area || mode == .fullscreen || mode == .window)
        overlays.append(view)
        return view
    }

    func dismiss() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        toolbar?.orderOut(nil)
        toolbar = nil
        overlayPanels.forEach { $0.orderOut(nil) }
        overlayPanels.removeAll()
        overlays.forEach { $0.cancelInteraction(); $0.releaseFrozenFrame(); $0.controller = nil }
        overlays.removeAll()
        modeButtons.removeAll()
        dimensionStack = nil
        dimensionSurface = nil
        recordingKinds = nil
        captureButton = nil
        hint = nil
        target = nil
        NSCursor.arrow.set()
    }

    private func cancel() {
        let app = priorApp
        dismiss()
        app?.activate(options: [])
        onCancel?()
    }

    private func confirm() {
        guard let target else { NSSound.beep(); return }
        let selectedMode = mode
        let app = priorApp
        dismiss()
        app?.activate(options: [])
        onCapture?(selectedMode, target)
    }

    private var selectingWindow: Bool { mode == .window || (mode == .recording && recordingKind == 2) }
    private var selectingDisplay: Bool { mode == .fullscreen || (mode == .recording && recordingKind == 1) }

    fileprivate func pointerMoved(_ point: CGPoint, display: CaptureDisplay) {
        if selectingWindow && !windowLocked {
            // CGWindowList returns front-to-back order; catalog order is not a z-order contract.
            let hit = catalog.windows.filter { $0.frame.contains(point) }
                .min { (windowRanks[$0.id] ?? Int.max) < (windowRanks[$1.id] ?? Int.max) }
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

    fileprivate func clicked(_ point: CGPoint, display: CaptureDisplay) {
        if selectingWindow { windowLocked = false; pointerMoved(point, display: display); windowLocked = true }
        else if selectingDisplay { pointerMoved(point, display: display) }
    }

    fileprivate func areaChanged(_ rect: CGRect, display: CaptureDisplay) {
        guard !selectingWindow, !selectingDisplay else { return }
        let next: CaptureTarget? = rect.width >= 2 && rect.height >= 2 ? .area(displayID: display.id, rect: rect) : nil
        guard target != next else { return }
        target = next
        refreshSelection()
    }

    fileprivate func areaReleased(_ rect: CGRect, display: CaptureDisplay) {
        guard mode == .area, instantCapture, rect.width >= 2, rect.height >= 2,
              target == .area(displayID: display.id, rect: rect) else { return }
        confirm()
    }

    fileprivate var usesArea: Bool { !selectingWindow && !selectingDisplay }

    func setMode(_ newMode: CaptureMode) {
        mode = newMode
        windowLocked = false
        target = nil
        if selectingDisplay, let hostDisplay { target = .display(id: hostDisplay.id) }
        for (buttonMode, button) in modeButtons {
            button.state = buttonMode == mode ? .on : .off
            button.needsDisplay = true
        }
        recordingKinds?.isHidden = mode != .recording
        dimensionSurface?.isHidden = !usesArea
        overlays.forEach {
            $0.cancelInteraction()
            updateAccessibilityHelp(for: $0)
            $0.showFrozenFrame(mode == .area || mode == .fullscreen || mode == .window)
        }
        captureButton?.title = mode == .recording ? "Continue" : mode == .scrolling ? "Continue" : "Capture"
        refreshSelection()
    }

    private func refreshSelection() {
        var rect: CGRect?
        var text = ""
        switch target {
        case .area(_, let area): rect = area; text = "\(Int(area.width.rounded())) × \(Int(area.height.rounded())) pt"
        case .display(let id): rect = catalog.displays.first(where: { $0.id == id })?.frame
        case .window(let id):
            let window = catalog.windows.first(where: { $0.id == id })
            rect = window?.frame; text = window.map { $0.title.isEmpty ? $0.applicationName : $0.title } ?? ""
        case nil: break
        }
        for overlay in overlays {
            overlay.updateSelection(rect: rect, text: text, resizable: usesArea)
        }
        if let rect, usesArea {
            let width = String(Int(rect.width.rounded()))
            let height = String(Int(rect.height.rounded()))
            if widthField.currentEditor() == nil, widthField.stringValue != width { widthField.stringValue = width }
            if heightField.currentEditor() == nil, heightField.stringValue != height { heightField.stringValue = height }
        }
        let enabled = target != nil
        if captureButton?.isEnabled != enabled { captureButton?.isEnabled = enabled }
        let confirmation = keymap?.configuration.binding(for: .confirmCapture).map { "\($0.displayString) to capture" } ?? "Click Capture"
        let message = mode == .area && instantCapture ? "Drag to capture" : enabled ? confirmation : selectingWindow ? "Choose a window" : selectingDisplay ? "Choose a display" : "Drag to select"
        if hint?.stringValue != message { hint?.stringValue = message }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        (obj.object as? NSTextField)?.layer?.borderColor = NSColor.clear.cgColor
        applyDimensions()
    }

    private func applyDimensions() {
        guard usesArea, widthField.doubleValue >= 2, heightField.doubleValue >= 2 else { return }
        let display: CaptureDisplay?
        let existing: CGRect
        if case let .area(id, rect) = target {
            display = catalog.displays.first { $0.id == id }; existing = rect
        } else {
            display = hostDisplay
            existing = CGRect(x: hostDisplay?.frame.midX ?? 0, y: hostDisplay?.frame.midY ?? 0, width: 1, height: 1)
        }
        guard let display else { return }
        let rect = SelectionGeometry.resized(existing, size: CGSize(width: widthField.doubleValue, height: heightField.doubleValue), within: display.frame)
        target = .area(displayID: display.id, rect: rect)
        refreshSelection()
    }

    private func makeToolbar(on display: CaptureDisplay) {
        let width: CGFloat = min(672, display.frame.width - 32)
        let modeWidth = (width - 192) / 6
        let panel = CapturePanel(contentRect: CGRect(x: display.frame.midX - width / 2, y: display.frame.minY + 55, width: width, height: 112), level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3))
        let visibleFrame = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id })?.visibleFrame ?? display.frame
        if let previous = lastToolbarFrame, display.frame.contains(CGPoint(x: previous.midX, y: previous.midY)) {
            panel.setFrame(ToolbarGeometry.clamped(CGRect(origin: previous.origin, size: panel.frame.size), to: visibleFrame), display: false)
        } else {
            panel.setFrame(ToolbarGeometry.clamped(panel.frame, to: visibleFrame), display: false)
        }
        panel.appearance = NSAppearance(named: .darkAqua)
        let root = CaptureToolbarView(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("ScreenshotX capture toolbar")
        root.setAccessibilityHelp("Click a control to use it, or drag anywhere on the toolbar to move it.")
        root.onMove = { [weak self] frame in self?.lastToolbarFrame = frame }
        panel.contentView = root
        panel.initialFirstResponder = root
        let vertical = NSStackView()
        vertical.orientation = .vertical
        vertical.alignment = .centerX
        vertical.spacing = 10
        pinSubview(vertical, to: root)
        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = 16
        vertical.addArrangedSubview(top)
        let modesSurface = CaptureSurface()
        let modes = NSStackView()
        modes.spacing = 2
        pinSubview(modes, to: modesSurface.contentView, inset: 5)
        let symbols: [CaptureMode: String] = [.area: "viewfinder", .fullscreen: "display", .window: "macwindow", .scrolling: "arrow.down", .timer: "timer", .recording: "video"]
        for mode in CaptureMode.allCases {
            let button = CaptureModeButton(title: mode.title, symbol: symbols[mode]) { [weak self] in self?.setMode(mode) }
            button.imagePosition = .imageAbove
            button.font = .systemFont(ofSize: 13, weight: .regular)
            button.imageScaling = .scaleProportionallyDown
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            button.isBordered = false
            button.focusRingType = .none
            button.setButtonType(.toggle)
            button.setAccessibilityHelp("Choose " + mode.title.lowercased() + " capture mode")
            button.wantsLayer = true
            button.widthAnchor.constraint(equalToConstant: modeWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: 54).isActive = true
            modes.addArrangedSubview(button)
            modeButtons[mode] = button
        }
        top.addArrangedSubview(modesSurface)
        let dimensions = CaptureSurface()
        let stack = NSStackView()
        stack.spacing = 6
        pinSubview(stack, to: dimensions.contentView, inset: 12)
        widthField = NSTextField(string: "")
        heightField = NSTextField(string: "")
        for (field, label) in [(widthField, "Selection width"), (heightField, "Selection height")] {
            field.placeholderString = "—"
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            field.isBordered = false
            field.focusRingType = .none
            field.drawsBackground = true
            field.backgroundColor = NSColor.black.withAlphaComponent(0.2)
            field.wantsLayer = true
            field.layer?.cornerRadius = 6
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor.clear.cgColor
            field.layer?.masksToBounds = true
            field.delegate = self
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 54).isActive = true
        }
        stack.addArrangedSubview(widthField)
        let times = captureLabel("×", size: 16)
        times.widthAnchor.constraint(equalToConstant: 12).isActive = true
        stack.addArrangedSubview(times)
        stack.addArrangedSubview(heightField)
        dimensions.heightAnchor.constraint(equalToConstant: 64).isActive = true
        dimensions.widthAnchor.constraint(equalToConstant: 156).isActive = true
        top.addArrangedSubview(dimensions)
        dimensionStack = stack
        dimensionSurface = dimensions
        let footer = CaptureSurface()
        footer.cornerRadius = 11
        let bottom = NSStackView()
        bottom.spacing = 10
        bottom.translatesAutoresizingMaskIntoConstraints = false
        footer.contentView.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: footer.contentView.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: footer.contentView.trailingAnchor, constant: -12),
            bottom.topAnchor.constraint(equalTo: footer.contentView.topAnchor, constant: 6),
            bottom.bottomAnchor.constraint(equalTo: footer.contentView.bottomAnchor, constant: -6)
        ])
        let kinds = NSSegmentedControl(labels: ["Area", "Display", "Window"], trackingMode: .selectOne, target: self, action: #selector(recordingKindChanged(_:)))
        kinds.selectedSegment = recordingKind
        kinds.setAccessibilityLabel("Recording target")
        kinds.isHidden = true
        recordingKinds = kinds
        bottom.addArrangedSubview(kinds)
        let message = captureLabel("", size: 12, color: .white.withAlphaComponent(0.72))
        message.lineBreakMode = .byTruncatingTail
        hint = message
        bottom.addArrangedSubview(message)
        let confirm = CaptureActionButton(title: "Capture") { [weak self] in self?.confirm() }
        confirm.emphasized = true
        captureButton = confirm
        bottom.addArrangedSubview(confirm)
        let cancel = CaptureActionButton(title: "Cancel") { [weak self] in self?.cancel() }
        bottom.addArrangedSubview(cancel)
        let options = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Capture options")!, target: self, action: #selector(showOptions(_:)))
        options.isBordered = false
        options.imagePosition = .imageOnly
        options.contentTintColor = .white.withAlphaComponent(0.8)
        options.focusRingType = .none
        options.setAccessibilityLabel("Capture options")
        options.toolTip = "Instant capture and frozen display options"
        options.widthAnchor.constraint(equalToConstant: 26).isActive = true
        options.heightAnchor.constraint(equalToConstant: 26).isActive = true
        bottom.addArrangedSubview(options)
        vertical.addArrangedSubview(footer)
        footer.widthAnchor.constraint(lessThanOrEqualTo: vertical.widthAnchor, constant: -20).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 38).isActive = true
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbar = panel
    }

    func refreshKeymap() {
        overlays.forEach { updateAccessibilityHelp(for: $0) }
        refreshSelection()
    }

    private var confirmInstruction: String {
        keymap?.configuration.binding(for: .confirmCapture).map { "press \($0.displayString)" } ?? "click Capture"
    }

    private var cancelInstruction: String {
        keymap?.configuration.binding(for: .cancelCapture).map { "press \($0.displayString)" } ?? "click Cancel"
    }

    private func updateAccessibilityHelp(for view: SelectionOverlayView) {
        view.updateAccessibilityHelp(capturesOnRelease: mode == .area && instantCapture,
                                     confirmation: confirmInstruction, cancellation: cancelInstruction)
    }

    /// Only overlay commands are handled here; application commands use the
    /// application's monitor and global commands use the system hotkey registry.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !optionsMenuIsTracking, NSApp.modalWindow == nil, !event.isARepeat,
              let keymap, !keymap.isRecordingShortcut,
              let action = keymap.action(for: event, in: .overlay), action.scope == .overlay else { return false }
        if toolbar?.firstResponder is NSTextView,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.characters?.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) == true {
            // Typing dimensions must not activate plain-letter mode/toggle keys.
            return false
        }
        return handleShortcut(action)
    }

    /// Shared by event dispatch, menu actions, and offscreen interaction checks.
    @discardableResult
    func handleShortcut(_ action: ShortcutAction) -> Bool {
        guard !optionsMenuIsTracking else { return false }
        switch action {
        case .confirmCapture:
            // Commit the dimension field before confirming the capture.
            toolbar?.makeFirstResponder(nil)
            applyDimensions()
            confirm()
        case .cancelCapture: cancel()
        case .toggleInstantCapture: changeInstantCapture()
        case .toggleFreezeDisplay: changeFreezeDisplay()
        case .areaMode: setMode(.area)
        case .fullscreenMode: setMode(.fullscreen)
        case .windowMode: setMode(.window)
        case .scrollingMode: setMode(.scrolling)
        case .timerMode: setMode(.timer)
        case .recordingMode: setMode(.recording)
        default: return false
        }
        return true
    }

    private func assignShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
        guard let binding = keymap?.configuration.binding(for: action) else { return }
        item.keyEquivalent = binding.menuKeyEquivalent
        item.keyEquivalentModifierMask = binding.modifierFlags
    }

    func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture options")
        menu.font = .systemFont(ofSize: 14)
        menu.minimumWidth = 320
        menu.autoenablesItems = false
        let sessionHeading = NSMenuItem(title: "This capture only", action: nil, keyEquivalent: "")
        sessionHeading.isEnabled = false
        menu.addItem(sessionHeading)
        let instant = NSMenuItem(title: "Instant Capture", action: #selector(toggleInstantCapture(_:)), keyEquivalent: "")
        instant.target = self
        instant.state = instantCapture ? .on : .off
        instant.toolTip = "This session only. Capture on mouse release, or turn off to adjust the area and \(confirmInstruction)."
        assignShortcut(.toggleInstantCapture, to: instant)
        menu.addItem(instant)
        let freeze = NSMenuItem(title: "Freeze Display During Capture", action: #selector(toggleFreezeDisplay(_:)), keyEquivalent: "")
        freeze.target = self
        freeze.state = freezeDisplay ? .on : .off
        freeze.toolTip = "This session only. Changing this restarts selection; apps and audio keep running."
        assignShortcut(.toggleFreezeDisplay, to: freeze)
        menu.addItem(freeze)
        menu.addItem(.separator())
        let shortcuts = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(openKeymap(_:)), keyEquivalent: "")
        shortcuts.target = self
        assignShortcut(.keymap, to: shortcuts)
        menu.addItem(shortcuts)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openPreferences(_:)), keyEquivalent: "")
        preferences.target = self
        assignShortcut(.preferences, to: preferences)
        menu.addItem(preferences)
        return menu
    }

    @objc private func showOptions(_ sender: NSButton) {
        optionsMenuIsTracking = true
        let menu = makeOptionsMenu()
        menu.update()
        let anchor = sender.window?.convertToScreen(sender.convert(sender.bounds, to: nil)) ?? .zero
        let anchorCenter = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) }) ?? sender.window?.screen ?? NSScreen.main
        let placement = ToolbarGeometry.menuPlacement(anchor: anchor, menuSize: menu.size,
                                                       visibleFrame: screen?.visibleFrame ?? catalog.displays.first?.frame ?? anchor)
        // A screen-space top-left anchor lets the whole menu use the available
        // display space rather than being clipped below a near-bottom button.
        menu.popUp(positioning: nil, at: placement.topLeft, in: nil)
        optionsMenuIsTracking = false
        // Restart selection only after the menu has finished using its window.
        if let value = pendingFreezeChange {
            pendingFreezeChange = nil
            onFreezeDisplayChange?(value)
        }
        let navigation = pendingNavigation
        pendingNavigation = nil
        navigation?()
    }

    @objc private func openKeymap(_ sender: NSMenuItem) {
        if optionsMenuIsTracking { pendingNavigation = onOpenKeymap }
        else { onOpenKeymap?() }
    }

    @objc private func openPreferences(_ sender: NSMenuItem) {
        if optionsMenuIsTracking { pendingNavigation = onOpenPreferences }
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
        onInstantCaptureChange?(instantCapture)
    }

    private func changeFreezeDisplay() {
        freezeDisplay.toggle()
        if optionsMenuIsTracking { pendingFreezeChange = freezeDisplay }
        else { onFreezeDisplayChange?(freezeDisplay) }
    }

    @objc private func recordingKindChanged(_ sender: NSSegmentedControl) {
        recordingKind = sender.selectedSegment
        setMode(.recording)
    }
}

@MainActor
final class CaptureToolbarView: NSView, NSGestureRecognizerDelegate {
    var onMove: ((CGRect) -> Void)?
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
            onMove?(next)
        }
        if [.ended, .cancelled, .failed].contains(recognizer.state) { initialFrame = nil }
    }
}

@MainActor
private final class SelectionOverlayView: NSView {
    weak var controller: CaptureUIController?
    let display: CaptureDisplay
    private(set) var selectedRect: CGRect?
    private let renderer: SelectionOverlayRenderer
    private var frozenFrame: CGImage?
    private var tracking: NSTrackingArea?
    private var dragStart = CGPoint.zero
    private var originalRect: CGRect?
    private var areaInteractionActive = false
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
            ? "Drag to select an area and release to capture. To cancel, \(cancellation). For an exact size, enter width and height in the toolbar and \(confirmation)."
            : "Drag to select an area. Resize by dragging its edges. Enter width and height in the capture toolbar, then \(confirmation) to capture or \(cancellation) to cancel.")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.updateScale(window?.backingScaleFactor ?? display.scale)
    }

    func updateSelection(rect: CGRect?, text: String, resizable: Bool) {
        selectedRect = rect.flatMap { $0.intersects(display.frame) ? $0 : nil }
        let local = selectedRect.map { $0.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
        renderer.update(rect: local, text: text, resizable: resizable)
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
    override func mouseEntered(with event: NSEvent) { controller?.refreshCursor(at: global(event)) }
    override func mouseMoved(with event: NSEvent) {
        controller?.refreshCursor(at: global(event))
        controller?.pointerMoved(global(event), display: display)
    }
    override func mouseDown(with event: NSEvent) {
        let point = global(event)
        guard controller?.usesArea == true else { controller?.clicked(point, display: display); return }
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
        updateDrag(to: global(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard areaInteractionActive else { return }
        // The release event can contain a newer pointer location than the final
        // drag event. Commit it synchronously before Return/capture can observe it.
        let point = global(event)
        let rect = updateDrag(to: point)
        areaInteractionActive = false
        let moved = abs(point.x - dragStart.x) >= 2 || abs(point.y - dragStart.y) >= 2
        if moved, let rect { controller?.areaReleased(rect, display: display) }
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

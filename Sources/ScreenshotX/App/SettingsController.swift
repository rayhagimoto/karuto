import AppKit
import AVFoundation

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private var window: NSWindow?
    private var lastWindowFrame: NSRect?
    private var contentColumn: NSStackView?
    private var folderLabel: NSTextField?
    private var navigation: [SettingsSection: SettingsNavigationButton] = [:]
    private var selectedSection: SettingsSection = .general
    var keymap: KeymapController?
    private var keymapView: KeymapSettingsView?

    init(settings: AppSettings) { self.settings = settings }

    /// Only Preferences is intentionally shareable; capture/session panels stay hidden.
    var captureWindowIDs: Set<UInt32> {
        guard let window, window.isVisible, window.windowNumber > 0 else { return [] }
        return [UInt32(window.windowNumber)]
    }

    func show() {
        if let window {
            showSection(selectedSection)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ScreenshotX Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 900, height: 680)
        window.isOpaque = false
        window.backgroundColor = .clear
        let surface = SettingsGlassSurface()
        surface.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        let root = surface.content
        window.setContentSize(NSSize(width: 900, height: 680))

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220)
        ])
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 6
        nav.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(nav)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 72)
        ])
        for section in SettingsSection.allCases {
            let button = SettingsNavigationButton(title: section.rawValue, symbol: section.symbol) { [weak self] in self?.showSection(section) }
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            navigation[section] = button
        }
        let identity = NSStackView()
        identity.orientation = .horizontal
        identity.spacing = 8
        let appSymbol = NSImageView(image: NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)!)
        appSymbol.contentTintColor = .secondaryLabelColor
        appSymbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
        identity.addArrangedSubview(appSymbol)
        let name = captureLabel("ScreenshotX", size: 12, color: .secondaryLabelColor)
        identity.addArrangedSubview(name)
        identity.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(identity)
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 28),
            identity.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -28)
        ])

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 64),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -28)
        ])
        contentColumn = column
        self.window = window
        showSection(selectedSection)
        if let lastWindowFrame { window.setFrame(lastWindowFrame, display: false) }
        else { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(root)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showKeymap() {
        selectedSection = .shortcuts
        show()
    }

    func refreshKeymap() { keymapView?.refresh() }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        keymapView?.cancelRecording()
        lastWindowFrame = closingWindow.frame
        // Rebuild Preferences on demand instead of retaining its glass surfaces,
        // controls, and any discovered recording devices while the app is idle.
        keymapView = nil
        contentColumn = nil
        folderLabel = nil
        navigation.removeAll()
        window = nil
    }
    func windowDidResignKey(_ notification: Notification) { keymapView?.cancelRecording() }

    private func showSection(_ section: SettingsSection) {
        keymapView?.cancelRecording()
        keymapView = nil
        selectedSection = section
        for (item, button) in navigation {
            button.select(item == section)
        }
        guard let column = contentColumn else { return }
        column.arrangedSubviews.forEach { column.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSStackView()
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 8
        let title = captureLabel(section.rawValue, size: 24, color: .labelColor)
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.addArrangedSubview(title)
        heading.addArrangedSubview(captureLabel(section.detail, size: 12))
        column.addArrangedSubview(heading)
        switch section {
        case .general:
            let autoSave = NSButton(checkboxWithTitle: "", target: self, action: #selector(autoSaveChanged(_:)))
            autoSave.state = settings.autoSave ? .on : .off
            autoSave.setAccessibilityLabel("Automatically save captures")
            let group = SettingsCard()
            group.addRow(title: "Automatically save captures", detail: "Keep a copy in your save folder.", control: autoSave)
            let choose = ClosureButton(title: "Choose…") { [weak self] in self?.chooseFolder() }
            group.addRow(title: "Save folder", detail: settings.saveFolder.path, control: choose)
            folderLabel = group.lastDetailLabel
            let autoCopy = NSButton(checkboxWithTitle: "", target: self, action: #selector(autoCopyChanged(_:)))
            autoCopy.state = settings.autoCopyScreenshots ? .on : .off
            autoCopy.setAccessibilityLabel("Automatically copy screenshots")
            group.addRow(title: "Automatically copy screenshots", detail: "Copy each screenshot to the clipboard. Videos are excluded.", control: autoCopy)
            addCard(group, to: column)
            addCard(PreviewSettingsForm(settings: settings), to: column)
            column.addArrangedSubview(captureLabel("Captures are stored locally on your Mac.", size: 12))
        case .capture:
            let shadow = NSButton(checkboxWithTitle: "", target: self, action: #selector(shadowChanged(_:)))
            shadow.state = settings.includeShadow ? .on : .off
            shadow.setAccessibilityLabel("Include window shadows")
            let group = SettingsCard()
            group.addRow(title: "Window shadows", detail: "Include the natural shadow around windows.", control: shadow)
            let instant = NSButton(checkboxWithTitle: "", target: self, action: #selector(instantCaptureChanged(_:)))
            instant.state = settings.instantCapture ? .on : .off
            instant.setAccessibilityLabel("Instant Capture")
            group.addRow(title: "Instant Capture", detail: "Default for new sessions: capture on mouse release.", control: instant)
            let freeze = NSButton(checkboxWithTitle: "", target: self, action: #selector(freezeDisplayChanged(_:)))
            freeze.state = settings.freezeDisplay ? .on : .off
            freeze.setAccessibilityLabel("Freeze Display During Capture")
            group.addRow(title: "Freeze Display", detail: "Default for new sessions: select from a still image.", control: freeze)
            addCard(group, to: column)
            column.addArrangedSubview(captureLabel("Overlay changes apply to that session only.", size: 12))
        case .shortcuts:
            if let keymap {
                let editor = KeymapSettingsView(keymap: keymap)
                keymapView = editor
                column.addArrangedSubview(editor)
                editor.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                editor.heightAnchor.constraint(equalToConstant: 500).isActive = true
            }
        case .recording:
            let options = RecordingOptionsForm(options: settings.recording)
            options.onChange = { [weak self, weak options] in
                guard let self, let options else { return }
                self.settings.recording = options.options
            }
            addCard(options, to: column)
            column.addArrangedSubview(captureLabel("MP4 · H.264 · 30 fps · Three-second countdown", size: 12))
        }
    }

    private func addCard(_ card: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func autoSaveChanged(_ sender: NSButton) { settings.autoSave = sender.state == .on }
    @objc private func autoCopyChanged(_ sender: NSButton) { settings.autoCopyScreenshots = sender.state == .on }
    @objc private func shadowChanged(_ sender: NSButton) { settings.includeShadow = sender.state == .on }
    @objc private func instantCaptureChanged(_ sender: NSButton) { settings.instantCapture = sender.state == .on }
    @objc private func freezeDisplayChanged(_ sender: NSButton) { settings.freezeDisplay = sender.state == .on }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
            folderLabel?.stringValue = url.path
            folderLabel?.toolTip = url.path
        }
    }
    func chooseRecordingOptions() -> RecordingOptions? {
        let panel = RecordingOptionsPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 620), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Screen Recording"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 500, height: 620)
        let surface = SettingsGlassSurface()
        surface.frame = NSRect(x: 0, y: 0, width: 500, height: 620)
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        let root = surface.content
        panel.setContentSize(NSSize(width: 500, height: 620))
        let column = NSStackView()
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 18
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -28)
        ])
        let heading = captureLabel("Screen Recording", size: 20, color: .labelColor)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        column.addArrangedSubview(heading)
        let form = RecordingOptionsForm(options: settings.recording)
        addCard(form, to: column)
        column.addArrangedSubview(captureLabel("MP4 · 30 fps · Starts after a three-second countdown", size: 12))
        let buttons = NSStackView()
        buttons.orientation = .horizontal; buttons.spacing = 10
        let cancel = ClosureButton(title: "Cancel") { NSApp.stopModal(withCode: .cancel) }
        let start = ClosureButton(title: "Start Recording", symbol: "record.circle") { NSApp.stopModal(withCode: .OK) }
        styleSettingsButton(cancel)
        styleSettingsButton(start)
        buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(start)
        column.addArrangedSubview(buttons)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let panel, NSApp.modalWindow === panel,
                      let keymap = self.keymap, !keymap.isRecordingShortcut else { return false }
                switch keymap.action(for: event, in: .overlay) {
                case .confirmCapture: NSApp.stopModal(withCode: .OK); return true
                case .cancelCapture: NSApp.stopModal(withCode: .cancel); return true
                default: return false
                }
            }
            return consumed ? nil : event
        }
        let response = NSApp.runModal(for: panel)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        panel.orderOut(nil)
        guard response == .OK else { return nil }
        let options = form.options
        settings.recording = options
        return options
    }
}

private enum SettingsSection: String, CaseIterable {
    case general = "General", capture = "Capture", recording = "Recording", shortcuts = "Keyboard Shortcuts"
    var symbol: String {
        switch self { case .general: "gearshape"; case .capture: "viewfinder"; case .recording: "video"; case .shortcuts: "keyboard" }
    }
    var detail: String {
        switch self {
        case .general: "Files, clipboard, and previews"
        case .capture: "Defaults for your next capture session"
        case .recording: "Video and audio defaults"
        case .shortcuts: "Assign, clear, or restore every app shortcut"
        }
    }
}

@MainActor
private class SettingsCard: NSView {
    private let rows = NSStackView()
    private(set) var lastDetailLabel: NSTextField?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
        layer?.borderWidth = 0
        layer?.cornerRadius = 16
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 0
        pinSubview(rows, to: self, inset: 4)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func addRow(title: String, detail: String? = nil, control: NSView) {
        if !rows.arrangedSubviews.isEmpty {
            let divider = NSBox(); divider.boxType = .separator
            rows.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -40).isActive = true
        }
        let row = NSStackView()
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 20
        row.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        let labels = NSStackView()
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 6
        let name = captureLabel(title, size: 13, color: .labelColor)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        labels.addArrangedSubview(name)
        if let detail {
            let secondary = captureLabel(detail, size: 12)
            secondary.lineBreakMode = .byTruncatingMiddle
            secondary.toolTip = detail
            labels.addArrangedSubview(secondary)
            lastDetailLabel = secondary
        }
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let button = control as? NSButton { styleSettingsButton(button) }
        row.addArrangedSubview(labels)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
}

@MainActor
private final class PreviewSettingsForm: SettingsCard {
    private let settings: AppSettings
    private let behavior = NSPopUpButton()
    private let seconds = NSTextField()
    private let stepper = NSStepper()

    init(settings: AppSettings) {
        self.settings = settings
        super.init(frame: .zero)
        behavior.addItems(withTitles: ["Keep until dismissed", "Close automatically"])
        behavior.selectItem(at: settings.previewAutoDismiss ? 1 : 0)
        behavior.target = self; behavior.action = #selector(behaviorChanged)
        behavior.setAccessibilityLabel("Preview behavior")
        behavior.font = .systemFont(ofSize: 13)
        behavior.controlSize = .large
        addRow(title: "Capture preview", detail: "Actions or moving away after hovering dismiss the preview.", control: behavior)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 1; formatter.maximum = 300
        formatter.maximumFractionDigits = 1
        seconds.formatter = formatter
        seconds.font = .systemFont(ofSize: 13)
        seconds.alignment = .right
        seconds.controlSize = .large
        seconds.target = self; seconds.action = #selector(delayChanged(_:))
        seconds.cell?.sendsActionOnEndEditing = true
        seconds.setAccessibilityLabel("Preview duration in seconds")
        seconds.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stepper.minValue = 1; stepper.maxValue = 300; stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(delayChanged(_:))
        stepper.setAccessibilityLabel("Adjust preview duration")
        let duration = NSStackView(views: [seconds, captureLabel("seconds", size: 12), stepper])
        duration.orientation = .horizontal; duration.alignment = .centerY; duration.spacing = 8
        addRow(title: "Close after", detail: "Applies to new previews. Choose 1–300 seconds.", control: duration)
        refreshDuration()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func behaviorChanged() {
        settings.previewAutoDismiss = behavior.indexOfSelectedItem == 1
        refreshDuration()
    }

    @objc private func delayChanged(_ sender: NSControl) {
        settings.previewDismissDelay = sender.doubleValue
        refreshDuration()
    }

    private func refreshDuration() {
        seconds.doubleValue = settings.previewDismissDelay
        stepper.doubleValue = settings.previewDismissDelay
        seconds.isEnabled = settings.previewAutoDismiss
        stepper.isEnabled = settings.previewAutoDismiss
    }
}

@MainActor
private final class RecordingOptionsForm: SettingsCard {
    var onChange: (() -> Void)?
    private let system = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let microphone = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cursor = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let devices: [AVCaptureDevice]
    private let deviceMenu = NSPopUpButton()
    private let resolution = NSPopUpButton()

    init(options: RecordingOptions) {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        super.init(frame: .zero)
        system.state = options.systemAudio ? .on : .off
        microphone.state = options.microphone ? .on : .off
        cursor.state = options.showsCursor ? .on : .off
        for (button, title) in [(system, "System audio"), (microphone, "Microphone"), (cursor, "Show pointer")] {
            button.target = self; button.action = #selector(changed)
            button.setAccessibilityLabel(title)
        }
        deviceMenu.addItem(withTitle: "System default")
        devices.forEach { deviceMenu.addItem(withTitle: $0.localizedName) }
        if let id = options.microphoneID, let index = devices.firstIndex(where: { $0.uniqueID == id }) { deviceMenu.selectItem(at: index + 1) }
        deviceMenu.target = self; deviceMenu.action = #selector(changed)
        deviceMenu.setAccessibilityLabel("Microphone input")
        deviceMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        deviceMenu.isEnabled = microphone.state == .on
        resolution.addItems(withTitles: ["1080p", "Native resolution"])
        resolution.selectItem(at: options.resolution == .native ? 1 : 0)
        resolution.target = self; resolution.action = #selector(changed)
        resolution.setAccessibilityLabel("Video resolution")
        addRow(title: "Resolution", control: resolution)
        addRow(title: "System audio", control: system)
        addRow(title: "Microphone", control: microphone)
        addRow(title: "Input device", control: deviceMenu)
        addRow(title: "Show pointer", control: cursor)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func changed() { deviceMenu.isEnabled = microphone.state == .on; onChange?() }
    var options: RecordingOptions {
        let index = deviceMenu.indexOfSelectedItem - 1
        return RecordingOptions(systemAudio: system.state == .on, microphone: microphone.state == .on,
                                microphoneID: devices.indices.contains(index) ? devices[index].uniqueID : nil,
                                showsCursor: cursor.state == .on,
                                resolution: resolution.indexOfSelectedItem == 1 ? .native : .hd1080)
    }
}

@MainActor
private final class RecordingOptionsPanel: NSPanel {
    override func close() {
        if NSApp.modalWindow === self { NSApp.stopModal(withCode: .cancel) }
        super.close()
    }
}

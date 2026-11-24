import AppKit
import AVFoundation
import ServiceManagement

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
    private let setupSupport: any SetupSupporting
    private var setupView: SetupSettingsForm?
    private weak var appIconView: NSImageView?
    var onAppIconChange: (() -> Void)?

    init(settings: AppSettings, setupSupport: any SetupSupporting = SystemSetupSupport()) {
        self.settings = settings
        self.setupSupport = setupSupport
    }

    /// Only Preferences is intentionally shareable; capture/session panels stay hidden.
    var captureWindowIDs: Set<UInt32> {
        guard let window, window.isVisible, window.windowNumber > 0 else { return [] }
        return [UInt32(window.windowNumber)]
    }

    func close() { window?.performClose(nil) }

    func show() {
        if let window {
            showSection(selectedSection)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Karuto Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The full-size glass header extends below the native title-bar strip.
        window.isMovableByWindowBackground = true
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
        identity.alignment = .centerY
        identity.spacing = 8
        let appSymbol = NSImageView(image: NSApp.applicationIconImage)
        appSymbol.imageScaling = .scaleProportionallyDown
        appIconView = appSymbol
        appSymbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
        appSymbol.heightAnchor.constraint(equalToConstant: 20).isActive = true
        identity.addArrangedSubview(appSymbol)
        let name = captureLabel("Karuto", size: 12, color: .secondaryLabelColor)
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
    func refreshAppIcon() { appIconView?.image = NSApp.applicationIconImage }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        keymapView?.cancelRecording()
        lastWindowFrame = closingWindow.frame
        // Rebuild Preferences on demand instead of retaining its glass surfaces,
        // controls, and any discovered recording devices while the app is idle.
        keymapView = nil
        setupView = nil
        appIconView = nil
        contentColumn = nil
        folderLabel = nil
        navigation.removeAll()
        window = nil
    }
    func windowDidResignKey(_ notification: Notification) { keymapView?.cancelRecording() }
    func windowDidBecomeKey(_ notification: Notification) { setupView?.refresh() }

    private func showSection(_ section: SettingsSection) {
        keymapView?.cancelRecording()
        keymapView = nil
        setupView = nil
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
        case .setup:
            let form = SetupSettingsForm(support: setupSupport)
            setupView = form
            addCard(form, to: column)
        case .general:
            let autoSave = NSButton(checkboxWithTitle: "", target: self, action: #selector(autoSaveChanged(_:)))
            autoSave.state = settings.autoSave ? .on : .off
            autoSave.setAccessibilityLabel("Automatically save captures")
            let group = SettingsCard()
            group.addRow(title: "Automatically save captures", detail: "Save image captures to your save folder. Screen recordings always save there.", control: autoSave)
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
        case .appearance:
            let appearance = NSPopUpButton()
            appearance.addItems(withTitles: AppearancePreference.allCases.map(\.rawValue))
            appearance.selectItem(withTitle: settings.appearance.rawValue)
            appearance.target = self
            appearance.action = #selector(appearanceChanged(_:))
            appearance.setAccessibilityLabel("Appearance")
            let appearanceCard = SettingsCard()
            appearanceCard.addRow(title: "Appearance", detail: "Choose the app’s appearance.", control: appearance)
            let appIcon = NSPopUpButton()
            appIcon.addItems(withTitles: AppIconPreference.allCases.map(\.rawValue))
            appIcon.selectItem(withTitle: settings.appIcon.rawValue)
            appIcon.target = self
            appIcon.action = #selector(appIconChanged(_:))
            appIcon.setAccessibilityLabel("App icon")
            appearanceCard.addRow(title: "App icon", detail: "Choose Karuto’s icon independently of app appearance.", control: appIcon)
            addCard(appearanceCard, to: column)
        case .capture:
            let shadow = NSButton(checkboxWithTitle: "", target: self, action: #selector(shadowChanged(_:)))
            shadow.state = settings.includeShadow ? .on : .off
            shadow.setAccessibilityLabel("Include window shadows")
            let group = SettingsCard()
            group.addRow(title: "Window shadows", detail: "Include the natural shadow around windows.", control: shadow)
            let instant = NSButton(checkboxWithTitle: "", target: self, action: #selector(instantCaptureChanged(_:)))
            instant.state = settings.instantCapture ? .on : .off
            instant.setAccessibilityLabel("Instant Capture")
            group.addRow(title: "Instant Capture", detail: "Capture Area snapshots on mouse release.", control: instant)
            let freeze = NSButton(checkboxWithTitle: "", target: self, action: #selector(freezeDisplayChanged(_:)))
            freeze.state = settings.freezeDisplay ? .on : .off
            freeze.setAccessibilityLabel("Freeze Display During Capture")
            group.addRow(title: "Freeze Display", detail: "Select from a still image when taking a snapshot with the timer off.", control: freeze)
            let automatic = NSButton(checkboxWithTitle: "", target: self, action: #selector(automaticScrollingChanged(_:)))
            automatic.state = settings.automaticScrolling ? .on : .off
            automatic.setAccessibilityLabel("Automatically scroll")
            group.addRow(title: "Automatically scroll", detail: "Scroll for you during Appshot capture. Switch to manual at any time.", control: automatic)
            addCard(group, to: column)
            column.addArrangedSubview(captureLabel("The capture toolbar remembers options separately for Snapshot and Screen Recording.", size: 12))
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
            column.addArrangedSubview(captureLabel("MP4 · H.264", size: 12))
        }
    }

    private func addCard(_ card: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title, let preference = AppearancePreference(rawValue: title) else { return }
        settings.appearance = preference
        NSApp.appearance = preference.appearance
    }
    @objc private func appIconChanged(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title, let preference = AppIconPreference(rawValue: title) else { return }
        settings.appIcon = preference
        onAppIconChange?()
    }
    @objc private func autoSaveChanged(_ sender: NSButton) { settings.autoSave = sender.state == .on }
    @objc private func autoCopyChanged(_ sender: NSButton) { settings.autoCopyScreenshots = sender.state == .on }
    @objc private func shadowChanged(_ sender: NSButton) { settings.includeShadow = sender.state == .on }
    @objc private func instantCaptureChanged(_ sender: NSButton) { settings.instantCapture = sender.state == .on }
    @objc private func automaticScrollingChanged(_ sender: NSButton) { settings.automaticScrolling = sender.state == .on }
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
    func chooseRecordingOptions(delaySeconds: Int) -> RecordingOptions? {
        let size = NSSize(width: 480, height: 372)
        let frame = NSRect(origin: .zero, size: size)
        let panel = RecordingOptionsPanel(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Screen Recording"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = size
        let surface = SettingsGlassSurface()
        surface.frame = frame
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        let root = surface.content
        panel.setContentSize(size)
        let column = NSStackView()
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 20
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        let heading = captureLabel("Screen Recording", size: 24, color: .labelColor)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        column.addArrangedSubview(heading)
        let form = RecordingOptionsForm(options: settings.recording)
        addCard(form, to: column)

        let format = NSStackView(views: [
            captureLabel("MP4 · H.264"),
            captureLabel(delaySeconds == 0 ? "No countdown" : "\(delaySeconds)-second countdown")
        ])
        format.orientation = .vertical
        format.alignment = .leading
        format.spacing = 2
        let cancel = CaptureActionButton(title: "Cancel") { NSApp.stopModal(withCode: .cancel) }
        let start = CaptureActionButton(title: "Start Recording") { NSApp.stopModal(withCode: .OK) }
        start.emphasized = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [format, spacer, cancel, start])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        addCard(footer, to: column)
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
    case general = "General", setup = "Setup", appearance = "Appearance", capture = "Capture", recording = "Recording", shortcuts = "Keyboard Shortcuts"
    var symbol: String {
        switch self { case .general: "gearshape"; case .setup: "checklist"; case .appearance: "circle.lefthalf.filled"; case .capture: "viewfinder"; case .recording: "video"; case .shortcuts: "keyboard" }
    }
    var detail: String {
        switch self {
        case .general: "Files, clipboard, and previews"
        case .setup: "Permissions and a quiet start at login"
        case .appearance: "Light, dark, or follow macOS"
        case .capture: "Defaults for your next capture session"
        case .recording: "Video and audio defaults"
        case .shortcuts: "Assign, clear, or restore every app shortcut"
        }
    }
}

@MainActor
private class SettingsCard: NSView {
    private let rows = NSStackView()
    var showsDividers = true
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
        addRow(row)
    }

    func addRow(_ row: NSView) {
        if showsDividers && !rows.arrangedSubviews.isEmpty {
            let divider = NSBox(); divider.boxType = .separator
            rows.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -40).isActive = true
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
}

@MainActor
private final class SetupSettingsForm: NSStackView {
    private let support: any SetupSupporting
    private var permissionLabels: [SetupPermission: NSTextField] = [:]
    private let startup = NSSwitch()
    private var loginDetail: NSTextField?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var updatingLogin = false

    init(support: any SetupSupporting) {
        self.support = support
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 20
        let permissions = SettingsCard()
        for permission in SetupPermission.allCases {
            let status = captureLabel("", size: 11)
            status.setContentHuggingPriority(.required, for: .horizontal)
            status.setAccessibilityLabel(permission.title + " access")
            permissionLabels[permission] = status
            let open = ClosureButton(title: "Open Settings…") { [weak self] in
                guard let self else { return }
                do { try self.support.openSettings(for: permission) }
                catch { self.showError(error.localizedDescription) }
            }
            open.setAccessibilityLabel("Open \(permission.title) settings")
            styleSettingsButton(open)
            open.widthAnchor.constraint(equalToConstant: 124).isActive = true
            let actions = NSStackView(views: [status, open])
            actions.orientation = .horizontal
            actions.alignment = .centerY
            actions.spacing = 12
            permissions.addRow(title: permission.title, detail: permission.detail, control: actions)
        }
        addCard(permissions)

        let login = SettingsCard()
        startup.target = self
        startup.action = #selector(startupChanged)
        startup.setAccessibilityLabel("Launch Karuto at login")
        login.addRow(title: "Launch at login", detail: "Start quietly with only the menu bar icon.", control: startup)
        let loginSettings = ClosureButton(title: "Open Settings…") { [weak self] in self?.support.openLoginItems() }
        loginSettings.setAccessibilityLabel("Open Login Items settings")
        loginSettings.widthAnchor.constraint(equalToConstant: 124).isActive = true
        login.addRow(title: "Login Items", detail: "", control: loginSettings)
        loginDetail = login.lastDetailLabel
        addCard(login)

        let hint = NSTextField(wrappingLabelWithString: "Accessibility and microphone access are optional. Karuto requests access when you use those features. Reopen Karuto if macOS asks after granting permission.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        hint.maximumNumberOfLines = 0
        addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isSelectable = false
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.setAccessibilityLabel("Setup error")
        addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addCard(_ card: NSView) {
        addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func refresh() {
        for (permission, label) in permissionLabels {
            let status = support.authorization(for: permission)
            label.stringValue = status.title
            label.textColor = status == .allowed ? .systemGreen : .secondaryLabelColor
        }
        let status = support.loginStatus
        startup.state = status == .enabled || status == .requiresApproval ? .on : .off
        startup.isEnabled = !updatingLogin
        switch status {
        case .enabled: loginDetail?.stringValue = "Enabled. Karuto will stay in the menu bar at login."
        case .requiresApproval: loginDetail?.stringValue = "Approval needed. Allow Karuto in Login Items."
        case .notRegistered, .notFound: loginDetail?.stringValue = "Not enabled. Turn on Launch at login to add Karuto."
        @unknown default: loginDetail?.stringValue = "Check Karuto’s status in System Settings."
        }
    }

    @objc private func startupChanged() {
        guard !updatingLogin else { return }
        let enabled = startup.state == .on
        updatingLogin = true
        errorLabel.isHidden = true
        refresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await support.setLaunchAtLogin(enabled) }
            catch { showError("Couldn’t update launch at login. \(error.localizedDescription)") }
            updatingLogin = false
            refresh()
        }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
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
private final class RecordingAudioButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

@MainActor
private final class RecordingOptionsForm: NSStackView {
    var onChange: (() -> Void)?
    private let systemAudio = RecordingAudioButton()
    private let microphone = RecordingAudioButton()
    private let microphoneStatus = captureLabel("", size: 10)
    private let cursor = NSButton(checkboxWithTitle: "Show pointer", target: nil, action: nil)
    private let devices: [AVCaptureDevice]
    private let deviceMenu = NSPopUpButton()
    private let resolution = NSPopUpButton()
    private let frameRate = NSPopUpButton()

    init(options: RecordingOptions) {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 16
        systemAudio.state = options.systemAudio ? .on : .off
        microphone.state = options.microphone ? .on : .off
        cursor.state = options.showsCursor ? .on : .off
        for (control, title) in [(systemAudio, "System audio"), (microphone, "Microphone"), (cursor, "Show pointer")] {
            control.target = self
            control.action = #selector(changed)
            control.setAccessibilityLabel(title)
        }
        deviceMenu.addItem(withTitle: "System default")
        devices.forEach { deviceMenu.addItem(withTitle: $0.localizedName) }
        if let id = options.microphoneID, let index = devices.firstIndex(where: { $0.uniqueID == id }) { deviceMenu.selectItem(at: index + 1) }
        deviceMenu.target = self; deviceMenu.action = #selector(changed)
        deviceMenu.setAccessibilityLabel("Microphone input")
        deviceMenu.widthAnchor.constraint(equalToConstant: 150).isActive = true
        resolution.addItems(withTitles: ["1080p", "Native"])
        resolution.selectItem(at: options.resolution == .native ? 1 : 0)
        resolution.target = self; resolution.action = #selector(changed)
        resolution.setAccessibilityLabel("Video resolution")
        for rate in RecordingFrameRate.allCases {
            frameRate.addItem(withTitle: "\(rate.rawValue) fps")
            frameRate.lastItem?.tag = rate.rawValue
        }
        frameRate.selectItem(withTag: options.frameRate.rawValue)
        frameRate.target = self
        frameRate.action = #selector(changed)
        frameRate.setAccessibilityLabel("Frame rate")
        let audio = SettingsCard()
        audio.showsDividers = false
        audio.addRow(audioRow("System audio", toggle: systemAudio, detail: captureLabel("Sound from apps on your Mac")))
        audio.addRow(audioRow("Microphone", toggle: microphone, detail: microphoneStatus, input: deviceMenu))
        let resolutionLabel = captureLabel("Resolution", size: 13, color: .labelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let video = NSStackView(views: [resolutionLabel, resolution, spacer, cursor])
        video.orientation = .horizontal
        video.alignment = .centerY
        video.spacing = 8
        video.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        let rateRow = NSStackView(views: [captureLabel("Frame rate", size: 13, color: .labelColor), frameRate])
        rateRow.alignment = .centerY
        rateRow.spacing = video.spacing
        rateRow.edgeInsets = video.edgeInsets
        rateRow.addArrangedSubview(NSView())
        for group in [audio as NSView, video, rateRow] {
            addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        refreshAudioControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func audioRow(_ title: String, toggle: NSButton, detail: NSTextField, input: NSPopUpButton? = nil) -> NSView {
        toggle.setButtonType(.pushOnPushOff)
        toggle.isBordered = false
        toggle.focusRingType = .exterior
        toggle.imagePosition = .imageOnly
        toggle.wantsLayer = true
        toggle.layer?.cornerRadius = 18
        toggle.widthAnchor.constraint(equalToConstant: 36).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let name = captureLabel(title, size: 13, color: .labelColor)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        let row = NSStackView(views: [toggle, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let input {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(input)
        }
        return row
    }

    private func refreshAudioControls() {
        for (toggle, title, enabledSymbol, disabledSymbol) in [
            (systemAudio, "System audio", "speaker.wave.2.fill", "speaker.slash.fill"),
            (microphone, "Microphone", "mic.fill", "mic.slash.fill")
        ] {
            let enabled = toggle.state == .on
            let symbol = enabled ? enabledSymbol : disabledSymbol
            toggle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            toggle.contentTintColor = enabled ? .alternateSelectedControlTextColor : .secondaryLabelColor
            toggle.effectiveAppearance.performAsCurrentDrawingAppearance {
                let background = enabled ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.08)
                toggle.layer?.backgroundColor = background.cgColor
            }
            toggle.toolTip = enabled ? "Turn off \(title.lowercased()) recording" : "Turn on \(title.lowercased()) recording"
        }
        let microphoneEnabled = microphone.state == .on
        microphoneStatus.stringValue = microphoneEnabled ? "Microphone recording is enabled" : "Microphone recording is disabled"
        deviceMenu.isEnabled = microphoneEnabled
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAudioControls()
    }

    @objc private func changed() {
        refreshAudioControls()
        onChange?()
    }

    var options: RecordingOptions {
        let index = deviceMenu.indexOfSelectedItem - 1
        return RecordingOptions(systemAudio: systemAudio.state == .on, microphone: microphone.state == .on,
                                microphoneID: devices.indices.contains(index) ? devices[index].uniqueID : nil,
                                showsCursor: cursor.state == .on,
                                resolution: resolution.indexOfSelectedItem == 1 ? .native : .hd1080,
                                frameRate: RecordingFrameRate(rawValue: frameRate.selectedTag()) ?? .fps30)
    }
}

@MainActor
private final class RecordingOptionsPanel: NSPanel {
    override func close() {
        if NSApp.modalWindow === self { NSApp.stopModal(withCode: .cancel) }
        super.close()
    }
}

import AppKit

/// A recorder edits the command registry, never a separate set of UI shortcuts.
@MainActor
final class KeymapSettingsView: NSView {
    private let keymap: KeymapController
    private let rows = NSStackView()
    private let feedback = NSTextField(wrappingLabelWithString: "Choose Record, then press a shortcut. Clear removes an assignment.")
    private let cancelButton = ClosureButton(title: "Cancel Recording")
    private let restoreButton = ClosureButton(title: "Restore Defaults")
    private var recordButtons: [ShortcutAction: ClosureButton] = [:]
    private var bindingLabels: [ShortcutAction: NSTextField] = [:]
    private var clearButtons: [ShortcutAction: ClosureButton] = [:]
    private var recordingAction: ShortcutAction?
    private var eventMonitor: Any?

    init(keymap: KeymapController) {
        self.keymap = keymap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let document = FlippedKeymapDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        var previousGroup: String?
        for action in ShortcutAction.allCases {
            if action.group != previousGroup {
                let group = NSTextField(labelWithString: action.group)
                group.font = .systemFont(ofSize: 12, weight: .semibold)
                group.textColor = .secondaryLabelColor
                let header = NSStackView(views: [group])
                header.edgeInsets = NSEdgeInsets(top: previousGroup == nil ? 4 : 28, left: 16, bottom: 12, right: 16)
                rows.addArrangedSubview(header)
                previousGroup = action.group
            }
            addRow(for: action)
        }
        feedback.font = .systemFont(ofSize: 12)
        feedback.textColor = .secondaryLabelColor
        feedback.maximumNumberOfLines = 3
        feedback.translatesAutoresizingMaskIntoConstraints = false
        addSubview(feedback)
        cancelButton.handler = { [weak self] in self?.cancelRecording() }
        restoreButton.handler = { [weak self] in self?.restoreDefaults() }
        styleSettingsButton(restoreButton)
        styleSettingsButton(cancelButton)
        let footer = NSStackView(views: [restoreButton, NSView(), cancelButton])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: feedback.topAnchor, constant: -16),
            feedback.leadingAnchor.constraint(equalTo: leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: trailingAnchor),
            feedback.heightAnchor.constraint(equalToConstant: 42),
            feedback.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func addRow(for action: ShortcutAction) {
        let title = NSTextField(wrappingLabelWithString: action.title)
        title.font = .systemFont(ofSize: 13)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.toolTip = action.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let binding = NSTextField(labelWithString: "")
        binding.alignment = .right
        binding.font = .systemFont(ofSize: 13, weight: .medium)
        binding.widthAnchor.constraint(equalToConstant: 94).isActive = true
        let record = ClosureButton(title: "Record") { [weak self] in self?.beginRecording(action) }
        record.setAccessibilityLabel("Record shortcut for " + action.title)
        styleSettingsButton(record)
        record.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let clear = ClosureButton(title: "", symbol: "xmark.circle") { [weak self] in self?.clear(action) }
        clear.isBordered = false
        clear.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        clear.heightAnchor.constraint(equalToConstant: 32).isActive = true
        clear.contentTintColor = .secondaryLabelColor
        clear.toolTip = "Clear shortcut"
        clear.setAccessibilityLabel("Clear shortcut for " + action.title)
        clear.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [title, spacer, binding, record, clear])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 12)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        row.heightAnchor.constraint(equalToConstant: 56).isActive = true
        recordButtons[action] = record
        bindingLabels[action] = binding
        clearButtons[action] = clear
    }

    func refresh() {
        for action in ShortcutAction.allCases {
            let binding = keymap.configuration.binding(for: action)
            bindingLabels[action]?.stringValue = binding?.displayString ?? "Unassigned"
            bindingLabels[action]?.textColor = binding == nil ? .secondaryLabelColor : .labelColor
            bindingLabels[action]?.setAccessibilityLabel(action.title + ": " + (binding?.displayString ?? "Unassigned"))
            recordButtons[action]?.title = recordingAction == action ? "Listening…" : "Record"
            recordButtons[action]?.isEnabled = recordingAction == nil
            clearButtons[action]?.isEnabled = recordingAction == nil && binding != nil
        }
        cancelButton.isHidden = recordingAction == nil
        restoreButton.isEnabled = recordingAction == nil
    }

    private func beginRecording(_ action: ShortcutAction) {
        guard recordingAction == nil else { return }
        keymap.beginRecording()
        recordingAction = action
        feedback.stringValue = "Press a shortcut for “\(action.title)”. Escape can be assigned; use Cancel Recording to stop."
        feedback.textColor = .secondaryLabelColor
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.recordingAction != nil else { return false }
                if let binding = ShortcutBinding(event: event) { self.assign(binding) }
                // Consume command keys before native menu equivalents or controls.
                return true
            }
            return consumed ? nil : event
        }
        refresh()
    }

    private func assign(_ binding: ShortcutBinding) {
        guard let action = recordingAction else { return }
        do {
            try keymap.update(action: action, binding: binding)
            finishRecording()
            feedback.stringValue = "\(action.title): \(binding.displayString)"
            feedback.textColor = .secondaryLabelColor
        } catch { show(error) }
        refresh()
    }

    func cancelRecording() {
        guard recordingAction != nil else { return }
        finishRecording()
        do {
            try keymap.endRecording()
            feedback.stringValue = "Recording canceled. Your shortcuts are unchanged."
            feedback.textColor = .secondaryLabelColor
        } catch { show(error) }
        refresh()
    }

    private func finishRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        recordingAction = nil
    }

    private func clear(_ action: ShortcutAction) {
        do {
            try keymap.update(action: action, binding: nil)
            feedback.stringValue = "\(action.title) is unassigned."
            feedback.textColor = .secondaryLabelColor
        } catch { show(error) }
        refresh()
    }

    private func restoreDefaults() {
        do {
            try keymap.resetDefaults()
            feedback.stringValue = "Default shortcuts restored. Session toggles are unassigned."
            feedback.textColor = .secondaryLabelColor
        } catch { show(error) }
        refresh()
    }

    private func show(_ error: Error) {
        feedback.stringValue = error.localizedDescription
        feedback.textColor = .systemOrange
    }
}

@MainActor
private final class FlippedKeymapDocument: NSView {
    override var isFlipped: Bool { true }
}

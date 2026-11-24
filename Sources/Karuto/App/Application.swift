import AppKit

@main
struct KarutoApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.dropFirst().first == "--cli" {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let status = await KarutoCLI.run(Array(CommandLine.arguments.dropFirst(2)))
                exit(status)
            }
            app.run()
            return
        }
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var coordinator: CaptureCoordinator?
    private var keymap: KeymapController?
    private var keyMonitor: Any?
    private var actionItems: [ShortcutAction: [NSMenuItem]] = [:]
    private var stopItem: NSMenuItem?
    private var isTerminating = false
    private var appIconController: AppIconController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let settings = AppSettings()
            NSApp.appearance = settings.appearance.appearance
            let appIconController = AppIconController(settings: settings)
            self.appIconController = appIconController
            let store = try CaptureStore(); store.cleanExpired()
            let coordinator = CaptureCoordinator(settings: settings, store: store)
            self.coordinator = coordinator
            coordinator.settingsUI.onAppIconChange = { [weak appIconController] in appIconController?.refresh() }
            appIconController.onChange = { [weak coordinator] in
                coordinator?.settingsUI.refreshAppIcon()
            }
            let keymap = KeymapController(settings: settings)
            self.keymap = keymap
            coordinator.configureKeymap(keymap)
            let mainMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            let appMenu = NSMenu()
            add("Open Capture Toolbar", action: #selector(openCapture), command: .openCapture, to: appMenu)
            add("Settings…", action: #selector(settingsAction), command: .preferences, to: appMenu)
            add("Keyboard Shortcuts…", action: #selector(keymapAction), command: .keymap, to: appMenu)
            add("Close Preferences", action: #selector(closePreferencesAction), command: .closePreferences, to: appMenu)
            appMenu.addItem(.separator())
            add("Quit Karuto", action: #selector(quit), command: .quit, to: appMenu)
            appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
            NSApp.mainMenu = mainMenu
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.toolTip = "Karuto"
            let menu = NSMenu()
            add("Open Capture Toolbar", action: #selector(openCapture), command: .openCapture, to: menu)
            add("Capture Previous Area", action: #selector(previousCapture), command: .previousArea, to: menu)
            add("Restore Last Capture", action: #selector(restore), command: .restoreCapture, to: menu)
            menu.addItem(.separator())
            let stop = add("Stop Capture", action: #selector(stopCapture), command: .stopCapture, to: menu); stop.isHidden = true; stopItem = stop
            add("Settings…", action: #selector(settingsAction), command: .preferences, to: menu)
            add("Keyboard Shortcuts…", action: #selector(keymapAction), command: .keymap, to: menu)
            add("About Karuto", action: #selector(about), to: menu)
            menu.addItem(.separator())
            add("Quit Karuto", action: #selector(quit), command: .quit, to: menu)
            item.menu = menu; statusItem = item
            refreshStatusIcon()
            coordinator.onStateChange = { [weak self, weak coordinator] in
                guard let self, let coordinator else { return }
                self.stopItem?.isHidden = !(coordinator.phase == .recording || coordinator.phase == .scrolling)
                self.refreshStatusIcon()
            }
            keymap.onAction = { [weak self] action in self?.dispatch(action) }
            keymap.onChange = { [weak self] in self?.refreshKeymap() }
            keymap.onError = { [weak coordinator] error in
                Task { @MainActor in coordinator?.showError(error, title: "Keyboard shortcut unavailable") }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let keymap = self.keymap,
                          !keymap.isRecordingShortcut, NSApp.modalWindow == nil,
                          self.coordinator?.isCaptureMenuTracking != true,
                          let action = keymap.action(for: event, in: .application) else { return false }
                    self.dispatch(action)
                    return true
                }
                return handled ? nil : event
            }
            refreshKeymap()
            do { try keymap.start() }
            catch {
                item.button?.toolTip = "Karuto · Keyboard shortcut unavailable. Choose another in Settings."
            }
        } catch {
            let alert = NSAlert(error: error); alert.runModal(); NSApp.terminate(nil)
        }
    }

    @discardableResult private func add(_ title: String, action: Selector, command: ShortcutAction? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        if let command { actionItems[command, default: []].append(item) }
        return item
    }

    private func refreshKeymap() {
        guard let keymap else { return }
        for (action, items) in actionItems {
            let binding = keymap.configuration.binding(for: action)
            for item in items {
                item.keyEquivalent = binding?.menuKeyEquivalent ?? ""
                item.keyEquivalentModifierMask = binding?.modifierFlags ?? []
            }
        }
        let shortcut = keymap.configuration.binding(for: .openCapture)?.displayString
        statusItem?.button?.toolTip = shortcut.map { "Karuto · \($0)" } ?? "Karuto · Open capture from this menu"
        coordinator?.refreshKeymap()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        if coordinator?.phase == .recording {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Karuto recording")
        } else {
            button.image = Self.menuBarImage()
        }
    }

    private static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let corners = NSBezierPath()
            corners.lineWidth = 1.35
            corners.lineCapStyle = .round
            for (x, y, dx, dy) in [(2.0, 2.0, 1.0, 1.0), (16, 2, -1, 1), (2, 16, 1, -1), (16, 16, -1, -1)] {
                corners.move(to: NSPoint(x: x + 3 * dx, y: y))
                corners.line(to: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x, y: y + 3 * dy))
            }
            corners.stroke()
            NSColor.black.setFill()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 6, y: 5))
            mark.line(to: NSPoint(x: 7.7, y: 5))
            mark.line(to: NSPoint(x: 7.7, y: 8))
            mark.line(to: NSPoint(x: 10.8, y: 5))
            mark.line(to: NSPoint(x: 13, y: 5))
            mark.line(to: NSPoint(x: 9.2, y: 9))
            mark.line(to: NSPoint(x: 12.8, y: 13))
            mark.line(to: NSPoint(x: 10.7, y: 13))
            mark.line(to: NSPoint(x: 7.7, y: 9.7))
            mark.line(to: NSPoint(x: 7.7, y: 13))
            mark.line(to: NSPoint(x: 6, y: 13))
            mark.close()
            mark.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Karuto"
        return image
    }

    private func dispatch(_ action: ShortcutAction) {
        switch action {
        case .openCapture: coordinator?.openToolbar()
        case .previousArea: coordinator?.capturePrevious()
        case .restoreCapture: coordinator?.restoreRecent()
        case .stopCapture: coordinator?.stop()
        case .preferences: coordinator?.showSettings()
        case .closePreferences: coordinator?.settingsUI.close()
        case .keymap: coordinator?.showKeymap()
        case .quit: NSApp.terminate(nil)
        default: break // Overlay commands are owned by the selection controller.
        }
    }
    @objc private func openCapture() { coordinator?.openToolbar() }
    @objc private func previousCapture() { coordinator?.capturePrevious() }
    @objc private func restore() { coordinator?.restoreRecent() }
    @objc private func settingsAction() { coordinator?.showSettings() }
    @objc private func closePreferencesAction() { coordinator?.settingsUI.close() }
    @objc private func keymapAction() { coordinator?.showKeymap() }
    @objc private func stopCapture() { coordinator?.stop() }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "Karuto 0.1 Alpha"
        alert.informativeText = "Native screenshots, screen recording, and scrolling appshots. Files stay on your Mac.\n\nConfigure every app shortcut in Settings → Keyboard Shortcuts."
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app only makes its menu bar item available. Capture is an
        // explicit action from the configured shortcut or menu bar menu.
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard let coordinator else { return .terminateNow }
        if coordinator.phase == .recording || coordinator.phase == .scrolling {
            isTerminating = true
            coordinator.stop { [weak self, weak coordinator] in
                let finished = coordinator?.phase != .scrolling
                if !finished { self?.isTerminating = false }
                NSApp.reply(toApplicationShouldTerminate: finished)
            }
            return .terminateLater
        }
        if coordinator.phase == .finalizing { return .terminateCancel }
        if coordinator.phase != .idle {
            isTerminating = true
            coordinator.cancel { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        keymap?.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keymap?.shutdown()
    }
}

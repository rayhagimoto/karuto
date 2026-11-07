import AppKit

@main
struct ScreenshotXApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let settings = AppSettings()
            let store = try CaptureStore(); store.cleanExpired()
            let coordinator = CaptureCoordinator(settings: settings, store: store)
            self.coordinator = coordinator
            let keymap = KeymapController(settings: settings)
            self.keymap = keymap
            coordinator.configureKeymap(keymap)
            let mainMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            let appMenu = NSMenu()
            add("Open Capture Toolbar", action: #selector(openCapture), command: .openCapture, to: appMenu)
            add("Settings…", action: #selector(settingsAction), command: .preferences, to: appMenu)
            add("Keyboard Shortcuts…", action: #selector(keymapAction), command: .keymap, to: appMenu)
            appMenu.addItem(.separator())
            add("Quit ScreenshotX", action: #selector(quit), command: .quit, to: appMenu)
            appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
            NSApp.mainMenu = mainMenu
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ScreenshotX")
            item.button?.toolTip = "ScreenshotX"
            let menu = NSMenu()
            add("Open Capture Toolbar", action: #selector(openCapture), command: .openCapture, to: menu)
            add("Capture Previous Area", action: #selector(previousCapture), command: .previousArea, to: menu)
            add("Restore Last Capture", action: #selector(restore), command: .restoreCapture, to: menu)
            menu.addItem(.separator())
            let stop = add("Stop Capture", action: #selector(stopCapture), command: .stopCapture, to: menu); stop.isHidden = true; stopItem = stop
            add("Settings…", action: #selector(settingsAction), command: .preferences, to: menu)
            add("Keyboard Shortcuts…", action: #selector(keymapAction), command: .keymap, to: menu)
            add("About ScreenshotX", action: #selector(about), to: menu)
            menu.addItem(.separator())
            add("Quit ScreenshotX", action: #selector(quit), command: .quit, to: menu)
            item.menu = menu; statusItem = item
            coordinator.onStateChange = { [weak self, weak coordinator] in
                guard let self, let coordinator else { return }
                self.stopItem?.isHidden = !(coordinator.phase == .recording || coordinator.phase == .scrolling)
                self.statusItem?.button?.image = NSImage(systemSymbolName: coordinator.phase == .recording ? "record.circle.fill" : "viewfinder", accessibilityDescription: "ScreenshotX")
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
            catch { coordinator.showError(error, title: "Keyboard shortcut unavailable") }
            if !CommandLine.arguments.contains("--background") { coordinator.openToolbar() }
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
        statusItem?.button?.toolTip = shortcut.map { "ScreenshotX · \($0)" } ?? "ScreenshotX · Open capture from this menu"
        coordinator?.refreshKeymap()
    }

    private func dispatch(_ action: ShortcutAction) {
        switch action {
        case .openCapture: coordinator?.openToolbar()
        case .previousArea: coordinator?.capturePrevious()
        case .restoreCapture: coordinator?.restoreRecent()
        case .stopCapture: coordinator?.stop()
        case .preferences: coordinator?.showSettings()
        case .keymap: coordinator?.showKeymap()
        case .quit: NSApp.terminate(nil)
        default: break // Overlay commands are owned by the selection controller.
        }
    }
    @objc private func openCapture() { coordinator?.openToolbar() }
    @objc private func previousCapture() { coordinator?.capturePrevious() }
    @objc private func restore() { coordinator?.restoreRecent() }
    @objc private func settingsAction() { coordinator?.showSettings() }
    @objc private func keymapAction() { coordinator?.showKeymap() }
    @objc private func stopCapture() { coordinator?.stop() }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "ScreenshotX 0.1 Alpha"
        alert.informativeText = "Native screenshots, screen recording, and scrolling appshots. Files stay on your Mac.\n\nConfigure every app shortcut in Settings → Keyboard Shortcuts."
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.openToolbar()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard let coordinator else { return .terminateNow }
        if coordinator.phase == .recording || coordinator.phase == .scrolling {
            isTerminating = true
            coordinator.stop { NSApp.reply(toApplicationShouldTerminate: true) }
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

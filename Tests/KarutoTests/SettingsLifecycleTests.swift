import AppKit
import Testing
@testable import Karuto

@MainActor
struct SettingsLifecycleTests {
    @Test func sidebarIdentityDoesNotOverlapNavigation() throws {
        _ = NSApplication.shared
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsController(settings: AppSettings(defaults: defaults))
        controller.show()
        let window = try #require(NSApp.windows.first { $0.title == "Karuto Settings" })
        window.orderOut(nil)
        defer { window.close() }
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(root)
        let identityLabel = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Karuto" })
        let identity = try #require(identityLabel.superview as? NSStackView)
        let icon = try #require(identity.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
        #expect(icon.frame.height == 20)
        let identityFrame = identity.convert(identity.bounds, to: root)
        for button in views.compactMap({ $0 as? SettingsNavigationButton }) {
            #expect(!identityFrame.intersects(button.convert(button.bounds, to: root)))
        }
    }

    @Test func closePreferencesHasConfigurableCommandWAndClosesWindow() throws {
        _ = NSApplication.shared
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let keymap = KeymapController(settings: settings)
        defer { keymap.shutdown() }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(keymap.action(for: event, in: .application) == .closePreferences)
        let controller = SettingsController(settings: settings)
        controller.show()
        let window = try #require(NSApp.windows.first { $0.title == "Karuto Settings" })
        window.orderOut(nil)
        let probe = SettingsCloseProbe(window: window)
        controller.close()
        #expect(probe.closed)
        #expect(!window.isVisible)
        try keymap.update(action: .closePreferences, binding: nil)
        #expect(keymap.action(for: event, in: .application) == nil)
    }

    @Test func closingSettingsReleasesWindowAndViewsAndPreservesNavigation() throws {
        _ = NSApplication.shared
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsController(settings: AppSettings(defaults: defaults))
        weak var closedWindow: NSWindow?
        weak var closedContent: NSView?
        var savedFrame = CGRect.zero

        try autoreleasepool {
            controller.showKeymap()
            let window = try #require(NSApp.windows.first { $0.title == "Karuto Settings" })
            window.orderOut(nil)
            closedWindow = window
            closedContent = window.contentView
            // Headless test hosts have no screen; AppKit normalizes any origin there.
            if !NSScreen.screens.isEmpty {
                window.setFrameOrigin(window.frame.origin.applying(CGAffineTransform(translationX: 12, y: 12)))
            }
            savedFrame = window.frame
            window.close()
        }

        #expect(closedWindow == nil)
        #expect(closedContent == nil)
        #expect(controller.captureWindowIDs.isEmpty)

        try autoreleasepool {
            controller.show()
            let reopened = try #require(NSApp.windows.first { $0.title == "Karuto Settings" })
            reopened.orderOut(nil)
            defer { reopened.close() }
            #expect(reopened.frame == savedFrame)
            let content = try #require(reopened.contentView)
            #expect(labels(in: content).contains("Assign, clear, or restore every app shortcut"))

            // A close notification from another window must not discard Preferences.
            let unrelated = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            unrelated.isReleasedWhenClosed = false
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: unrelated))
            controller.show()
            reopened.orderOut(nil)
            #expect(reopened.contentView === content)
            #expect(NSApp.windows.filter { $0.title == "Karuto Settings" }.count == 1)
        }
    }

    private func labels(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}

@MainActor
private final class SettingsCloseProbe: NSObject {
    private(set) var closed = false
    init(window: NSWindow) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didClose), name: NSWindow.willCloseNotification, object: window)
    }
    @objc private func didClose() { closed = true }
    deinit { NotificationCenter.default.removeObserver(self) }
}

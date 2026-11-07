import AppKit
import Testing
@testable import ScreenshotX

@MainActor
struct SettingsLifecycleTests {
    @Test func closingSettingsReleasesWindowAndViewsAndPreservesNavigation() throws {
        _ = NSApplication.shared
        let suite = "ScreenshotXTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsController(settings: AppSettings(defaults: defaults))
        weak var closedWindow: NSWindow?
        weak var closedContent: NSView?
        var savedFrame = CGRect.zero

        try autoreleasepool {
            controller.showKeymap()
            let window = try #require(NSApp.windows.first { $0.title == "ScreenshotX Settings" })
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
            let reopened = try #require(NSApp.windows.first { $0.title == "ScreenshotX Settings" })
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
            #expect(NSApp.windows.filter { $0.title == "ScreenshotX Settings" }.count == 1)
        }
    }

    private func labels(in view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}

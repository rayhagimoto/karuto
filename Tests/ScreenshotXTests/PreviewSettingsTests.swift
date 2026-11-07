import AppKit
import Testing
@testable import ScreenshotX

@MainActor
struct PreviewSettingsTests {
    @Test func defaultsCopyScreenshotsAndKeepPreviews() throws {
        try withSettings { settings, _ in
            #expect(settings.autoCopyScreenshots)
            #expect(!settings.previewAutoDismiss)
            #expect(settings.previewDismissDelay == 5)
            #expect(settings.previewDismissInterval == nil)
        }
    }

    @Test func preferencesPersistAndDurationOnlyAppliesWhenEnabled() throws {
        try withSettings { settings, defaults in
            settings.autoCopyScreenshots = false
            settings.previewAutoDismiss = true
            settings.previewDismissDelay = 12.5
            let reopened = AppSettings(defaults: defaults)
            #expect(!reopened.autoCopyScreenshots)
            #expect(reopened.previewDismissInterval == 12.5)
            reopened.previewAutoDismiss = false
            #expect(settings.previewDismissInterval == nil)
            #expect(settings.previewDismissDelay == 12.5)
            reopened.autoCopyScreenshots = true
            #expect(settings.autoCopyScreenshots)
        }
    }

    @Test func durationsAreFiniteAndBoundedOnWriteAndRead() throws {
        try withSettings { settings, defaults in
            settings.previewDismissDelay = -4
            #expect(settings.previewDismissDelay == 1)
            settings.previewDismissDelay = 900
            #expect(settings.previewDismissDelay == 300)
            for invalid in [Double.nan, Double.infinity, -Double.infinity] {
                settings.previewDismissDelay = invalid
                #expect(settings.previewDismissDelay == 5)
            }
            // Validate previously stored or externally edited defaults as well.
            defaults.set(-200, forKey: "previewDismissDelay")
            #expect(settings.previewDismissDelay == 1)
            defaults.set(900, forKey: "previewDismissDelay")
            #expect(settings.previewDismissDelay == 300)
            defaults.set("invalid", forKey: "previewDismissDelay")
            #expect(settings.previewDismissDelay == 5)
            defaults.set(Double.infinity, forKey: "previewDismissDelay")
            #expect(settings.previewDismissDelay == 5)
        }
    }

    @Test func generalControlsFitAndOnlyEnableDurationForAutomaticDismissal() throws {
        _ = NSApplication.shared
        try withSettings { settings, _ in
            let controller = SettingsController(settings: settings)
            controller.show()
            let window = try #require(NSApp.windows.first { $0.title == "ScreenshotX Settings" })
            window.orderOut(nil)
            defer { window.close() }
            let root = try #require(window.contentView)
            root.layoutSubtreeIfNeeded()
            let views = descendants(of: root)
            let behavior = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
            let seconds = try #require(views.compactMap { $0 as? NSTextField }.first { $0.formatter is NumberFormatter })
            let stepper = try #require(views.compactMap { $0 as? NSStepper }.first)
            #expect(behavior.titleOfSelectedItem == "Keep until dismissed")
            #expect(!seconds.isEnabled)
            #expect(!stepper.isEnabled)
            for control in [behavior as NSView, seconds, stepper] {
                #expect(root.bounds.contains(control.convert(control.bounds, to: root)))
            }
            behavior.selectItem(at: 1)
            _ = behavior.sendAction(behavior.action, to: behavior.target)
            #expect(settings.previewAutoDismiss)
            #expect(seconds.isEnabled)
            #expect(stepper.isEnabled)
            seconds.doubleValue = 12.5
            _ = seconds.sendAction(seconds.action, to: seconds.target)
            #expect(settings.previewDismissInterval == 12.5)
            #expect(stepper.doubleValue == 12.5)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "ScreenshotXTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }
}

import AppKit
import Testing
@testable import Karuto

@MainActor
struct SessionControlsTests {
    @Test func automaticCaptureOffersManualFallbackAlongsideFinishAndCancel() throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = SessionControlsController()
        var manualCount = 0
        var stopCount = 0
        var cancelCount = 0
        controller.onManual = { manualCount += 1 }
        controller.onStop = { stopCount += 1 }
        controller.onCancel = { cancelCount += 1 }
        controller.show(title: "Scrolling capture", message: "Capturing automatically. Keep the content visible.", stopTitle: "Finish", allowsManual: true)
        defer { controller.dismiss() }
        let window = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        window.orderOut(nil)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
        let manual = try #require(buttons.first { $0.title == "Scroll Manually" })
        let finish = try #require(buttons.first { $0.title == "Finish" })
        let cancel = try #require(buttons.first { $0.title == "Cancel" })
        for button in [manual, finish, cancel] {
            #expect(content.bounds.contains(button.convert(button.bounds, to: content)))
        }
        manual.performClick(nil)
        finish.performClick(nil)
        cancel.performClick(nil)
        #expect(manualCount == 1)
        #expect(stopCount == 1)
        #expect(cancelCount == 1)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

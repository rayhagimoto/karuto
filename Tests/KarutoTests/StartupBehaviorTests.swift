import AppKit
import Testing
@testable import Karuto

@MainActor
struct StartupBehaviorTests {
    @Test(arguments: [false, true])
    func reopeningNeverRequestsWindowPresentation(hasVisibleWindows: Bool) {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: hasVisibleWindows))
    }
}

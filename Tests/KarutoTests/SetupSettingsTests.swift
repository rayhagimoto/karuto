import AppKit
import ServiceManagement
import Testing
@testable import Karuto

@MainActor
struct SetupSettingsTests {
    @Test func setupShowsCurrentAccessAndOpensTheCorrectSystemPages() throws {
        let support = SetupSupportProbe()
        let (controller, window, root) = try fixture(support: support)
        defer { controller.close() }
        root.layoutSubtreeIfNeeded()
        let views = descendants(root)
        #expect(texts(root).contains("Not requested"))
        for permission in SetupPermission.allCases {
            let button = try #require(views.compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Open \(permission.title) settings"
            })
            #expect(root.bounds.contains(button.convert(button.bounds, to: root)))
            #expect(button.frame.width >= 120)
            _ = button.sendAction(button.action, to: button.target)
        }
        #expect(support.openedURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ])
        let login = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == "Open Login Items settings"
        })
        #expect(root.bounds.contains(login.convert(login.bounds, to: root)))
        _ = login.sendAction(login.action, to: login.target)
        #expect(support.loginPagesOpened == 1)

        support.loginStatus = .notFound
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(texts(root).contains("Not enabled. Turn on Launch at login to add Karuto."))
        support.microphone = .allowed
        support.loginStatus = .enabled
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(!texts(root).contains("Not requested"))
        #expect(texts(root).contains("Enabled. Karuto will stay in the menu bar at login."))
    }

    @Test func loginToggleReflectsApprovalAndRollsBackOnFailure() async throws {
        let support = SetupSupportProbe()
        let (controller, _, root) = try fixture(support: support)
        defer { controller.close() }
        let toggle = try #require(descendants(root).compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "Launch Karuto at login"
        })
        #expect(toggle.state == .off)
        support.nextLoginStatus = .requiresApproval
        toggle.state = .on
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        #expect(!toggle.isEnabled)
        try await waitUntilEnabled(toggle)
        #expect(toggle.state == .on)
        #expect(support.updates == [true])
        #expect(texts(root).contains("Approval needed. Allow Karuto in Login Items."))

        support.loginError = NSError(domain: "SetupTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test registration failure"])
        toggle.state = .off
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        try await waitUntilEnabled(toggle)
        #expect(toggle.state == .on)
        #expect(support.loginStatus == .requiresApproval)
        #expect(texts(root).contains { $0.contains("Test registration failure") })

        support.loginError = nil
        support.nextLoginStatus = .notRegistered
        toggle.state = .off
        _ = toggle.sendAction(toggle.action, to: toggle.target)
        try await waitUntilEnabled(toggle)
        #expect(toggle.state == .off)
        #expect(support.updates == [true, false, false])
    }

    private func waitUntilEnabled(_ button: NSControl) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !button.isEnabled && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(button.isEnabled)
    }

    private func fixture(support: SetupSupportProbe) throws -> (SettingsController, NSWindow, NSView) {
        _ = NSApplication.shared
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsController(settings: AppSettings(defaults: defaults), setupSupport: support)
        controller.show()
        let window = try #require(NSApp.windows.first { $0.title == "Karuto Settings" })
        // Async tests must not look like another suite's live Preferences window.
        window.title = "Setup fixture " + UUID().uuidString
        window.orderOut(nil)
        let root = try #require(window.contentView)
        let setup = try #require(descendants(root).compactMap { $0 as? SettingsNavigationButton }.first { $0.title == "Setup" })
        _ = setup.sendAction(setup.action, to: setup.target)
        return (controller, window, root)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func texts(_ view: NSView) -> [String] { descendants(view).compactMap { ($0 as? NSTextField)?.stringValue } }
}

@MainActor
private final class SetupSupportProbe: SetupSupporting {
    var microphone: SetupAuthorization = .notRequested
    var loginStatus: SMAppService.Status = .notRegistered
    var nextLoginStatus: SMAppService.Status = .enabled
    var loginError: Error?
    var updates: [Bool] = []
    var openedURLs: [URL] = []
    var loginPagesOpened = 0
    func authorization(for permission: SetupPermission) -> SetupAuthorization { permission == .microphone ? microphone : .allowed }
    func setLaunchAtLogin(_ enabled: Bool) async throws {
        updates.append(enabled)
        if let loginError { throw loginError }
        loginStatus = nextLoginStatus
    }
    func openSettings(for permission: SetupPermission) throws { openedURLs.append(permission.settingsURL) }
    func openLoginItems() { loginPagesOpened += 1 }
}

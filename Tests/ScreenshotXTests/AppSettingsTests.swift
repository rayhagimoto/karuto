import Foundation
import Testing
@testable import ScreenshotX

@MainActor
struct AppSettingsTests {
    @Test func capturePreferencesHaveDefaultsAndPersistBothStates() throws {
        let suite = "ScreenshotXTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.instantCapture)
        #expect(!settings.freezeDisplay)
        settings.instantCapture = false
        settings.freezeDisplay = true
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.instantCapture)
        #expect(reopened.freezeDisplay)
        reopened.instantCapture = true
        reopened.freezeDisplay = false
        #expect(settings.instantCapture)
        #expect(!settings.freezeDisplay)
    }
}

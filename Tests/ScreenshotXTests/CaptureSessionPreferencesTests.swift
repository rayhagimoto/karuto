import Foundation
import Testing
@testable import ScreenshotX

@MainActor
struct CaptureSessionPreferencesTests {
    @Test func sessionOverridesDoNotWriteDefaultsAndNewSessionReadsCurrentDefaults() throws {
        let name = "ScreenshotXTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var session = CaptureSessionPreferences(defaults: settings)
        session.instantCapture = false
        session.freezeDisplay = true
        #expect(settings.instantCapture)
        #expect(!settings.freezeDisplay)
        // Opening another selection starts from saved defaults again.
        let next = CaptureSessionPreferences(defaults: settings)
        #expect(next.instantCapture)
        #expect(!next.freezeDisplay)
        // A preferences change applies to the next session, not a value snapshot
        // already being used by an active selection.
        settings.instantCapture = false
        settings.freezeDisplay = true
        #expect(next.instantCapture)
        #expect(!next.freezeDisplay)
        #expect(CaptureSessionPreferences(defaults: settings) == session)
    }
}

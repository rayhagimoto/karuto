import Foundation
import Testing
@testable import Karuto

@MainActor
struct AppSettingsTests {
    @Test func appearanceDefaultsAndPersists() throws {
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.appearance == .system)
        for preference in AppearancePreference.allCases {
            settings.appearance = preference
            #expect(AppSettings(defaults: defaults).appearance == preference)
        }
        defaults.set("unknown", forKey: "appearance")
        #expect(settings.appearance == .system)
    }
    @Test func appIconDefaultsAndPersists() throws {
        let suite = "KarutoIconTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.appIcon == .system)
        for preference in AppIconPreference.allCases {
            settings.appIcon = preference
            #expect(AppSettings(defaults: defaults).appIcon == preference)
        }
        defaults.set("unknown", forKey: "appIcon")
        #expect(settings.appIcon == .system)
    }
    @Test func capturePreferencesHaveDefaultsAndPersistBothStates() throws {
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.instantCapture)
        #expect(!settings.freezeDisplay)
        #expect(settings.automaticScrolling)
        settings.instantCapture = false
        settings.freezeDisplay = true
        settings.automaticScrolling = false
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.instantCapture)
        #expect(reopened.freezeDisplay)
        #expect(!reopened.automaticScrolling)
        reopened.instantCapture = true
        reopened.freezeDisplay = false
        #expect(settings.instantCapture)
        #expect(!settings.freezeDisplay)
    }
}

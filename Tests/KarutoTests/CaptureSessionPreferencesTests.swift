import Foundation
import Testing
@testable import Karuto

@MainActor
struct CaptureSessionPreferencesTests {
    @Test func captureModesRestoreTheirOwnTimerAndRegionAcrossSessions() throws {
        let name = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let first = CaptureUIController(settings: settings)
        #expect(first.delaySeconds == 0)
        first.setRegion(.scrolling)
        first.setMode(.screenRecording)
        #expect(first.delaySeconds == 0)
        #expect(first.selectedRegion == .area)
        #expect(!first.instantCapture)
        first.setDelay(3)
        first.setRegion(.window)
        first.handleShortcut(.toggleInstantCapture)
        #expect(!first.handleShortcut(.scrollingMode))
        #expect(first.selectedRegion == .window)

        let reopened = CaptureUIController(settings: AppSettings(defaults: defaults))
        #expect(reopened.mode == .snapshot)
        #expect(reopened.delaySeconds == 0)
        #expect(reopened.selectedRegion == .scrolling)
        #expect(!reopened.instantCapture)
        reopened.handleShortcut(.recordingMode)
        #expect(reopened.delaySeconds == 3)
        #expect(reopened.selectedRegion == .window)
        #expect(reopened.instantCapture)
        reopened.handleShortcut(.timerMode)
        #expect(reopened.delaySeconds == 0)
        reopened.handleShortcut(.snapshotMode)
        #expect(reopened.delaySeconds == 0)
        #expect(reopened.selectedRegion == .scrolling)
    }

    @Test func snapshotKeepsExistingSelectionDefaults() throws {
        let name = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "instantCapture")
        defaults.set(true, forKey: "freezeDisplay")
        let settings = AppSettings(defaults: defaults)
        let snapshot = settings.capturePreferences(for: .snapshot)
        #expect(!snapshot.instantCapture)
        #expect(snapshot.freezeDisplay)
        #expect(snapshot.delaySeconds == 0)
        #expect(!settings.capturePreferences(for: .screenRecording).freezeDisplay)
    }
}

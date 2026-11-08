import AppKit
import Testing
@testable import Karuto

@MainActor
struct KeymapTests {
    @Test func defaultsUnassignmentAndNewActionsSurviveRoundTrip() throws {
        let defaults = KeymapConfiguration()
        #expect(defaults.binding(for: .preferences) == ShortcutBinding(keyCode: 43, modifiers: .command))
        #expect(defaults.binding(for: .toggleInstantCapture) == nil)
        #expect(defaults.binding(for: .toggleFreezeDisplay) == nil)
        let edited = defaults.setting(nil, for: .confirmCapture)
        let decoded = try JSONDecoder().decode(KeymapConfiguration.self, from: JSONEncoder().encode(edited))
        #expect(decoded.binding(for: .confirmCapture) == nil)
        #expect(decoded.binding(for: .cancelCapture) == defaults.binding(for: .cancelCapture))
        #expect(try decoded.validated() == edited)
    }

    @Test func duplicateAcrossScopesAndUnsafeGlobalBindingAreRejected() throws {
        let defaults = KeymapConfiguration()
        let appChord = try #require(defaults.binding(for: .preferences))
        #expect(throws: KeymapError.self) { try defaults.setting(appChord, for: .areaMode).validated() }
        #expect(throws: KeymapError.self) { try defaults.setting(ShortcutBinding(keyCode: 0, modifiers: []), for: .openCapture).validated() }
        #expect(throws: KeymapError.self) { try defaults.setting(ShortcutBinding(keyCode: 55, modifiers: .command), for: .areaMode).validated() }
        var future = defaults; future.version = 99
        #expect(throws: KeymapError.self) { try future.validated() }
    }

    @Test func legacyMigrationAndCorruptStorageNeverTrapOrLoseExplicitClear() throws {
        let fixture = Fixture()
        fixture.defaults.set(21, forKey: "shortcutKey")
        #expect(fixture.settings.keymap.binding(for: .openCapture) == ShortcutBinding(keyCode: 21, modifiers: [.control, .shift]))
        fixture.settings.keymap = fixture.settings.keymap.setting(nil, for: .openCapture)
        #expect(AppSettings(defaults: fixture.defaults).keymap.binding(for: .openCapture) == nil)
        fixture.defaults.set(Data("not JSON".utf8), forKey: "keymap.v1")
        #expect(fixture.settings.keymap == KeymapConfiguration())
        fixture.defaults.removeObject(forKey: "keymap.v1")
        fixture.defaults.set(-1, forKey: "shortcutKey")
        #expect(fixture.settings.keymap == KeymapConfiguration())
        fixture.defaults.set(Int.max, forKey: "shortcutKey")
        #expect(fixture.settings.keymap == KeymapConfiguration())
    }

    @Test func normalizationAndExactScopesAvoidRepeatOrDuplicateDispatch() throws {
        let fixture = Fixture()
        let controller = KeymapController(settings: fixture.settings, global: GlobalShortcut(backend: fixture.backend))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.capsLock, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 76))
        #expect(controller.action(for: enter, in: .overlay) == .confirmCapture)
        #expect(controller.action(for: enter, in: .application) == nil)
        #expect(controller.action(for: enter, in: .global) == nil)
        let repeatEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36))
        #expect(controller.action(for: repeatEvent, in: .overlay) == nil)
        try controller.update(action: .confirmCapture, binding: nil)
        #expect(controller.action(for: enter, in: .overlay) == nil)
        controller.beginRecording()
        #expect(controller.action(for: enter, in: .overlay) == nil)
        try controller.endRecording()
    }

    @Test func failedReplacementKeepsOldBindingsAndDispatch() throws {
        let backend = FakeBackend()
        let registry = GlobalShortcut(backend: backend)
        let original = ShortcutBinding(keyCode: 19, modifiers: [.control, .shift])
        let addition = ShortcutBinding(keyCode: 20, modifiers: [.control, .shift])
        let unavailable = ShortcutBinding(keyCode: 21, modifiers: [.control, .shift])
        try registry.replace(with: [.openCapture: original])
        let oldIDs = backend.bindings
        backend.denied.insert(unavailable)
        #expect(throws: KeymapError.self) {
            try registry.replace(with: [.openCapture: addition, .previousArea: unavailable])
        }
        #expect(backend.bindings == oldIDs)
        var actions: [ShortcutAction] = []
        registry.onAction = { actions.append($0) }
        backend.onPress?(try #require(oldIDs.keys.first))
        #expect(actions == [.openCapture])
        // Moving an existing chord to a different action needs no new registration.
        try registry.replace(with: [.previousArea: original])
        #expect(backend.bindings == oldIDs)
        backend.onPress?(try #require(oldIDs.keys.first))
        #expect(actions == [.openCapture, .previousArea])
        registry.shutdown()
        #expect(backend.bindings.isEmpty)
    }

    @Test func failedStartupStillRegistersSubsequentEditsAndNeverSavesFailedEdits() throws {
        let fixture = Fixture()
        let controller = KeymapController(settings: fixture.settings, global: GlobalShortcut(backend: fixture.backend))
        let initial = try #require(controller.configuration.binding(for: .openCapture))
        fixture.backend.denied.insert(initial)
        #expect(throws: KeymapError.self) { try controller.start() }
        let replacement = ShortcutBinding(keyCode: 20, modifiers: [.control, .shift])
        try controller.update(action: .openCapture, binding: replacement)
        #expect(fixture.backend.bindings.values.contains(replacement))
        #expect(fixture.settings.keymap.binding(for: .openCapture) == replacement)
        #expect(throws: KeymapError.self) { try controller.update(action: .openCapture, binding: initial) }
        #expect(controller.configuration.binding(for: .openCapture) == replacement)
        #expect(fixture.settings.keymap.binding(for: .openCapture) == replacement)
        #expect(fixture.backend.bindings.values.contains(replacement))
        controller.shutdown()
    }

    @Test func recordingSuspendsGlobalsAndRestoresOrReportsConflict() throws {
        let fixture = Fixture()
        let controller = KeymapController(settings: fixture.settings, global: GlobalShortcut(backend: fixture.backend))
        try controller.start()
        let oldBinding = try #require(controller.configuration.binding(for: .openCapture))
        controller.beginRecording()
        #expect(controller.isRecordingShortcut)
        #expect(fixture.backend.bindings.isEmpty)
        try controller.endRecording()
        #expect(!controller.isRecordingShortcut)
        #expect(fixture.backend.bindings.values.contains(oldBinding))
        controller.beginRecording()
        fixture.backend.denied.insert(oldBinding)
        var errors = 0
        controller.onError = { _ in errors += 1 }
        #expect(throws: KeymapError.self) { try controller.endRecording() }
        #expect(!controller.isRecordingShortcut)
        #expect(errors == 1)
        #expect(controller.configuration.binding(for: .openCapture) == oldBinding)
        let replacement = ShortcutBinding(keyCode: 20, modifiers: [.control, .shift])
        controller.beginRecording()
        try controller.update(action: .openCapture, binding: replacement)
        #expect(!controller.isRecordingShortcut)
        #expect(fixture.backend.bindings.values.contains(replacement))
        controller.shutdown()
    }

    @MainActor
    private final class Fixture {
        let suite = "KarutoTests.Keymap." + UUID().uuidString
        let defaults: UserDefaults
        let settings: AppSettings
        let backend = FakeBackend()
        init() {
            defaults = UserDefaults(suiteName: suite)!
            settings = AppSettings(defaults: defaults)
        }
        isolated deinit { defaults.removePersistentDomain(forName: suite) }
    }
    @MainActor
    private final class FakeBackend: GlobalHotKeyBackend {
        var onPress: ((UInt32) -> Void)?
        var bindings: [UInt32: ShortcutBinding] = [:]
        var denied: Set<ShortcutBinding> = []
        func register(_ binding: ShortcutBinding, id: UInt32) -> Bool {
            guard !denied.contains(binding), !bindings.values.contains(binding) else { return false }
            bindings[id] = binding
            return true
        }
        func unregister(id: UInt32) { bindings.removeValue(forKey: id) }
        func shutdown() { bindings.removeAll() }
    }
}

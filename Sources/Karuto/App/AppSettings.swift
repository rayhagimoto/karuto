import AppKit

enum AppearancePreference: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppIconPreference: String, CaseIterable {
    case system = "Follow System", light = "Light", dark = "Dark"
}


@MainActor
final class AppSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var appearance: AppearancePreference {
        get { AppearancePreference(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }
    var appIcon: AppIconPreference {
        get { AppIconPreference(rawValue: defaults.string(forKey: "appIcon") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appIcon") }
    }
    var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: "saveFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Karuto", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "saveFolder") }
    }
    var autoSave: Bool {
        get { defaults.bool(forKey: "autoSave") }
        set { defaults.set(newValue, forKey: "autoSave") }
    }
    var autoSaveScrollingScreenshots: Bool {
        get { defaults.object(forKey: "autoSaveScrollingScreenshots") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSaveScrollingScreenshots") }
    }
    func automaticallySaves(_ kind: ArtifactKind) -> Bool {
        kind == .video || autoSave
    }
    var autoCopyScreenshots: Bool {
        get { defaults.object(forKey: "autoCopyScreenshots") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCopyScreenshots") }
    }
    var previewAutoDismiss: Bool {
        get { defaults.bool(forKey: "previewAutoDismiss") }
        set { defaults.set(newValue, forKey: "previewAutoDismiss") }
    }
    var previewDismissDelay: TimeInterval {
        get {
            let value = (defaults.object(forKey: "previewDismissDelay") as? NSNumber)?.doubleValue ?? 5
            return value.isFinite ? min(300, max(1, value)) : 5
        }
        set { defaults.set(newValue.isFinite ? min(300, max(1, newValue)) : 5, forKey: "previewDismissDelay") }
    }
    var previewDismissInterval: TimeInterval? { previewAutoDismiss ? previewDismissDelay : nil }
    var instantCapture: Bool {
        get { defaults.bool(forKey: "instantCapture") }
        set { defaults.set(newValue, forKey: "instantCapture") }
    }
    var freezeDisplay: Bool {
        get { defaults.bool(forKey: "freezeDisplay") }
        set { defaults.set(newValue, forKey: "freezeDisplay") }
    }
    func capturePreferences(for mode: CaptureMode) -> CaptureSessionPreferences {
        let prefix = "capture.\(mode.rawValue)"
        let region = CaptureRegion(rawValue: defaults.string(forKey: prefix + ".region") ?? "") ?? .area
        let delay = defaults.integer(forKey: prefix + ".delay")
        return CaptureSessionPreferences(
            region: region == .scrolling ? .area : region,
            delaySeconds: CaptureSessionPreferences.delays.contains(delay) ? delay : 0,
            instantCapture: mode == .snapshot ? instantCapture : defaults.bool(forKey: prefix + ".instant"),
            freezeDisplay: mode == .snapshot && freezeDisplay
        )
    }
    func saveCapturePreferences(_ preferences: CaptureSessionPreferences, for mode: CaptureMode) {
        let prefix = "capture.\(mode.rawValue)"
        // Scrolling belongs to the current overlay. Preserve the last regular region.
        if preferences.region != .scrolling {
            defaults.set(preferences.region.rawValue, forKey: prefix + ".region")
        }
        defaults.set(preferences.delaySeconds, forKey: prefix + ".delay")
        if mode == .snapshot {
            instantCapture = preferences.instantCapture
            freezeDisplay = preferences.freezeDisplay
        } else {
            defaults.set(preferences.instantCapture, forKey: prefix + ".instant")
        }
    }
    var automaticScrolling: Bool {
        get { defaults.object(forKey: "automaticScrolling") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticScrolling") }
    }
    var includeShadow: Bool {
        get { defaults.object(forKey: "includeShadow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "includeShadow") }
    }
    var recording: RecordingOptions {
        get {
            RecordingOptions(systemAudio: defaults.bool(forKey: "systemAudio"),
                             microphone: defaults.bool(forKey: "microphone"),
                             microphoneID: defaults.string(forKey: "microphoneID"),
                             showsCursor: defaults.object(forKey: "showsCursor") as? Bool ?? true,
                             resolution: RecordingResolution(rawValue: defaults.string(forKey: "resolution") ?? "") ?? .hd1080,
                             frameRate: RecordingFrameRate(rawValue: defaults.integer(forKey: "recordingFrameRate")) ?? .fps30)
        }
        set {
            defaults.set(newValue.systemAudio, forKey: "systemAudio")
            defaults.set(newValue.microphone, forKey: "microphone")
            defaults.set(newValue.microphoneID, forKey: "microphoneID")
            defaults.set(newValue.showsCursor, forKey: "showsCursor")
            defaults.set(newValue.resolution.rawValue, forKey: "resolution")
            defaults.set(newValue.frameRate.rawValue, forKey: "recordingFrameRate")
        }
    }
    var keymap: KeymapConfiguration {
        get {
            if let data = defaults.data(forKey: "keymap.v1"),
               let decoded = try? JSONDecoder().decode(KeymapConfiguration.self, from: data),
               let validated = try? decoded.adoptingEditorDefaults().validated() { return validated }
            var configuration = KeymapConfiguration()
            // Preserve the old Control-Shift digit choice on first migration.
            if defaults.data(forKey: "keymap.v1") == nil,
               let legacy = defaults.object(forKey: "shortcutKey") as? Int,
               (0..<128).contains(legacy) {
                let binding = ShortcutBinding(keyCode: UInt16(legacy), modifiers: [.control, .shift])
                if binding.isValid { configuration = configuration.setting(binding, for: .openCapture) }
            }
            return configuration
        }
        set {
            guard let validated = try? newValue.validated(),
                  let data = try? JSONEncoder().encode(validated) else { return }
            defaults.set(data, forKey: "keymap.v1")
        }
    }
}

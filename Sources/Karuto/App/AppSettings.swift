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
        get { defaults.object(forKey: "instantCapture") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "instantCapture") }
    }
    var freezeDisplay: Bool {
        get { defaults.bool(forKey: "freezeDisplay") }
        set { defaults.set(newValue, forKey: "freezeDisplay") }
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
            RecordingOptions(systemAudio: defaults.bool(forKey: "systemAudio"), microphone: defaults.bool(forKey: "microphone"), microphoneID: defaults.string(forKey: "microphoneID"), showsCursor: defaults.object(forKey: "showsCursor") as? Bool ?? true, resolution: RecordingResolution(rawValue: defaults.string(forKey: "resolution") ?? "") ?? .hd1080)
        }
        set {
            defaults.set(newValue.systemAudio, forKey: "systemAudio")
            defaults.set(newValue.microphone, forKey: "microphone")
            defaults.set(newValue.microphoneID, forKey: "microphoneID")
            defaults.set(newValue.showsCursor, forKey: "showsCursor")
            defaults.set(newValue.resolution.rawValue, forKey: "resolution")
        }
    }
    var keymap: KeymapConfiguration {
        get {
            if let data = defaults.data(forKey: "keymap.v1"),
               let decoded = try? JSONDecoder().decode(KeymapConfiguration.self, from: data),
               let validated = try? decoded.validated() { return validated }
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

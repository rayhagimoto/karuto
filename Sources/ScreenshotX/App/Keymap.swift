import AppKit
import Carbon

/// Action IDs are the stable persistence contract; titles and presentation may change.
enum ShortcutScope: String, Codable, Sendable { case global, application, overlay }

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case openCapture, previousArea, restoreCapture, stopCapture
    case preferences, keymap, quit
    case confirmCapture, cancelCapture, toggleInstantCapture, toggleFreezeDisplay
    case areaMode, fullscreenMode, windowMode, scrollingMode, timerMode, recordingMode

    var scope: ShortcutScope {
        switch self {
        case .openCapture, .previousArea, .restoreCapture, .stopCapture: .global
        case .preferences, .keymap, .quit: .application
        default: .overlay
        }
    }
    var group: String {
        switch scope {
        case .global: "Anywhere on your Mac"
        case .application: "While ScreenshotX is active"
        case .overlay: "Capture overlay"
        }
    }
    var title: String {
        switch self {
        case .openCapture: "Open capture toolbar"
        case .previousArea: "Capture previous area"
        case .restoreCapture: "Restore last capture"
        case .stopCapture: "Stop capture"
        case .preferences: "Open Preferences"
        case .keymap: "Open keyboard shortcuts"
        case .quit: "Quit ScreenshotX"
        case .confirmCapture: "Confirm capture"
        case .cancelCapture: "Cancel capture"
        case .toggleInstantCapture: "Toggle Instant Capture for this session"
        case .toggleFreezeDisplay: "Toggle Freeze Display for this session"
        case .areaMode: "Select Area mode"
        case .fullscreenMode: "Select Fullscreen mode"
        case .windowMode: "Select Window mode"
        case .scrollingMode: "Select Scrolling mode"
        case .timerMode: "Select Timer mode"
        case .recordingMode: "Select Recording mode"
        }
    }
    var defaultBinding: ShortcutBinding? {
        switch self {
        case .openCapture: ShortcutBinding(keyCode: 19, modifiers: [.control, .shift])
        case .preferences: ShortcutBinding(keyCode: 43, modifiers: .command)
        case .keymap: ShortcutBinding(keyCode: 43, modifiers: [.command, .option])
        case .quit: ShortcutBinding(keyCode: 12, modifiers: .command)
        case .confirmCapture: ShortcutBinding(keyCode: 36, modifiers: [])
        case .cancelCapture: ShortcutBinding(keyCode: 53, modifiers: [])
        default: nil
        }
    }
}

/// Physical keys remain stable across layouts; labels use the active keyboard layout.
struct ShortcutBinding: Codable, Hashable, Sendable {
    let keyCode: UInt16
    private let modifiers: UInt
    private static let allowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode == 76 ? 36 : keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers).rawValue
    }
    init?(event: NSEvent) {
        guard event.type == .keyDown, !event.isARepeat,
              !Self.modifierKeys.contains(event.keyCode) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }
    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isValid: Bool {
        keyCode < 128 && keyCode != 76 && !Self.modifierKeys.contains(keyCode)
            && modifiers == modifierFlags.intersection(Self.allowedModifiers).rawValue
    }
    var hasCommandModifier: Bool { !modifierFlags.intersection([.command, .control, .option]).isEmpty }
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifierFlags.contains(.command) { value |= UInt32(cmdKey) }
        if modifierFlags.contains(.control) { value |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { value |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
    @MainActor var displayString: String {
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        return result + (Self.specialLabels[keyCode] ?? translatedKey()?.uppercased() ?? "Key \(keyCode)")
    }
    @MainActor var menuKeyEquivalent: String {
        switch keyCode {
        case 36: return "\r"
        case 53: return "\u{1b}"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 117: return String(UnicodeScalar(NSDeleteFunctionKey)!)
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default:
            if let number = Self.functionKeys[keyCode] { return String(UnicodeScalar(NSF1FunctionKey + number - 1)!) }
            return translatedKey()?.lowercased() ?? ""
        }
    }
    private static let functionKeys: [UInt16: Int] = [122:1,120:2,99:3,118:4,96:5,97:6,98:7,100:8,101:9,109:10,103:11,111:12,105:13,107:14,113:15,106:16,64:17,79:18,80:19,90:20]
    private static let specialLabels: [UInt16: String] = {
        var labels: [UInt16: String] = [36:"↩",53:"⎋",48:"⇥",49:"Space",51:"⌫",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"Page Up",121:"Page Down",71:"Clear"]
        for (key, number) in functionKeys { labels[key] = "F\(number)" }
        return labels
    }()
    @MainActor private func translatedKey() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

/// An absent action inherits its default; an explicit nil assignment means unassigned.
struct KeymapConfiguration: Codable, Equatable, Sendable {
    struct Assignment: Codable, Equatable, Sendable { var binding: ShortcutBinding? }
    var version = 1
    private var assignments: [String: Assignment] = [:]

    func binding(for action: ShortcutAction) -> ShortcutBinding? {
        if let assignment = assignments[action.rawValue] { return assignment.binding }
        return action.defaultBinding
    }
    func setting(_ binding: ShortcutBinding?, for action: ShortcutAction) -> Self {
        var result = self
        result.assignments[action.rawValue] = Assignment(binding: binding)
        return result
    }
    func validated() throws -> Self {
        guard version == 1 else { throw KeymapError.unsupportedVersion }
        var used: [ShortcutBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            guard let binding = binding(for: action) else { continue }
            guard binding.isValid else { throw KeymapError.invalidBinding }
            if action.scope != .overlay && !binding.hasCommandModifier { throw KeymapError.modifierRequired }
            if let previous = used[binding] { throw KeymapError.conflict(previous, action) }
            used[binding] = action
        }
        return self
    }
    var globalBindings: [ShortcutAction: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.filter { $0.scope == .global }.compactMap { action in
            binding(for: action).map { (action, $0) }
        })
    }
}

enum KeymapError: LocalizedError {
    case invalidBinding, modifierRequired, unsupportedVersion
    case conflict(ShortcutAction, ShortcutAction)
    case unavailable(ShortcutAction)
    var errorDescription: String? {
        switch self {
        case .invalidBinding: "Choose a key with optional Command, Control, Option, or Shift modifiers."
        case .modifierRequired: "App and system-wide shortcuts need Command, Control, or Option to avoid intercepting typing."
        case .unsupportedVersion: "This keyboard configuration was saved by a newer version of ScreenshotX."
        case .conflict(let first, let second): "That shortcut is already assigned to \(first.title). Clear it before assigning \(second.title)."
        case .unavailable(let action): "The shortcut for \(action.title) could not be registered. Another app or macOS may already use it. Your saved shortcuts have not changed."
        }
    }
}

@MainActor
final class KeymapController {
    private let settings: AppSettings
    private let global: GlobalShortcut
    private(set) var configuration: KeymapConfiguration
    private(set) var isRecordingShortcut = false
    private var started = false
    var onAction: ((ShortcutAction) -> Void)?
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(settings: AppSettings, global: GlobalShortcut = GlobalShortcut()) {
        self.settings = settings
        self.global = global
        configuration = settings.keymap
        global.onAction = { [weak self] in self?.onAction?($0) }
    }
    func start() throws {
        started = true
        try global.replace(with: configuration.globalBindings)
    }
    func update(action: ShortcutAction, binding: ShortcutBinding?) throws {
        try apply(configuration.setting(binding, for: action))
    }
    func resetDefaults() throws { try apply(KeymapConfiguration()) }
    private func apply(_ candidate: KeymapConfiguration) throws {
        let candidate = try candidate.validated()
        // Acquire new global registrations before releasing old ones or saving.
        if started { try global.replace(with: candidate.globalBindings) }
        configuration = candidate
        settings.keymap = candidate
        isRecordingShortcut = false
        onChange?()
    }
    func beginRecording() {
        guard !isRecordingShortcut else { return }
        global.removeAll()
        isRecordingShortcut = true
    }
    func endRecording() throws {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        if started {
            do { try global.replace(with: configuration.globalBindings) }
            catch { onError?(error); throw error }
        }
    }
    func action(for event: NSEvent, in scope: ShortcutScope) -> ShortcutAction? {
        guard !isRecordingShortcut, scope != .global, let binding = ShortcutBinding(event: event) else { return nil }
        return ShortcutAction.allCases.first { $0.scope == scope && configuration.binding(for: $0) == binding }
    }
    func shutdown() {
        global.shutdown()
        started = false
        isRecordingShortcut = false
    }
}

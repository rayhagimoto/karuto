import AppKit
import Carbon

/// Abstracts registration so conflict and rollback behavior can be checked without
/// taking system-wide shortcuts from the person running the test suite.
@MainActor
protocol GlobalHotKeyBackend: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    func register(_ binding: ShortcutBinding, id: UInt32) -> Bool
    func unregister(id: UInt32)
    func shutdown()
}

@MainActor
final class GlobalShortcut {
    private let backend: any GlobalHotKeyBackend
    private var registrations: [ShortcutBinding: UInt32] = [:]
    private var actions: [UInt32: ShortcutAction] = [:]
    private var nextID: UInt32 = 1
    var onAction: ((ShortcutAction) -> Void)?

    init(backend: (any GlobalHotKeyBackend)? = nil) {
        self.backend = backend ?? CarbonHotKeyBackend()
        self.backend.onPress = { [weak self] id in
            guard let self, let action = self.actions[id] else { return }
            self.onAction?(action)
        }
    }

    isolated deinit { shutdown() }

    /// Registration is keyed by chord, so moving an existing chord to another
    /// action does not briefly release it. Failed additions roll back only additions.
    func replace(with bindings: [ShortcutAction: ShortcutBinding]) throws {
        var owners: [ShortcutBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action] else { continue }
            if let prior = owners[binding] { throw KeymapError.conflict(prior, action) }
            owners[binding] = action
        }
        var additions: [ShortcutBinding: UInt32] = [:]
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action], registrations[binding] == nil else { continue }
            let id = nextID
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            guard backend.register(binding, id: id) else {
                for id in additions.values { backend.unregister(id: id) }
                throw KeymapError.unavailable(action)
            }
            additions[binding] = id
        }
        let desired = Set(bindings.values)
        for (binding, id) in registrations where !desired.contains(binding) { backend.unregister(id: id) }
        registrations = registrations.filter { desired.contains($0.key) }.merging(additions) { existing, _ in existing }
        actions = Dictionary(uniqueKeysWithValues: bindings.map { (registrations[$0.value]!, $0.key) })
    }
    func removeAll() {
        for id in registrations.values { backend.unregister(id: id) }
        registrations.removeAll(); actions.removeAll()
    }
    func shutdown() { removeAll(); backend.shutdown() }
}

@MainActor
private final class CarbonHotKeyBackend: GlobalHotKeyBackend {
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var heldIDs: Set<UInt32> = []
    var onPress: ((UInt32) -> Void)?
    private static let signature: OSType = 0x53535841

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53535841 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(data).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    backend.heldIDs.remove(id.id)
                } else if backend.heldIDs.insert(id.id).inserted {
                    backend.onPress?(id.id)
                }
            }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    isolated deinit { shutdown() }

    func register(_ binding: ShortcutBinding, id: UInt32) -> Bool {
        guard handler != nil else { return false }
        var reference: EventHotKeyRef?
        guard RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers,
                                  EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference) == noErr,
              let reference else { return false }
        hotKeys[id] = reference
        return true
    }
    func unregister(id: UInt32) {
        heldIDs.remove(id)
        if let reference = hotKeys.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }
    func shutdown() {
        for reference in hotKeys.values { UnregisterEventHotKey(reference) }
        hotKeys.removeAll(); heldIDs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

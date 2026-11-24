import ApplicationServices
import Carbon.HIToolbox

/// Filter input routed to the selected app for the lifetime of manual capture.
@MainActor
final class ManualScrollInput {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held: Set<Int> = []
    private var scroll: ((Int32) -> Bool)?
    private var paceWheel: ((CGEvent) -> Void)?

    func start(pid: pid_t, paceWheel: @escaping (CGEvent) -> Void, scroll: @escaping (Int32) -> Bool) {
        stop()
        let mask = [CGEventType.keyDown, .keyUp, .scrollWheel].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
                                                eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated {
                let keys = Unmanaged<ManualScrollInput>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout, let tap = keys.tap {
                    keys.held.removeAll()
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                if type == .scrollWheel {
                    keys.paceWheel?(event)
                    return false
                }
                guard type == .keyDown || type == .keyUp, let scroll = keys.scroll else { return false }
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                return keys.handle(type: type, code: code, flags: event.flags, scroll: scroll)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        self.paceWheel = paceWheel
        self.scroll = scroll
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func handle(type: CGEventType, code: Int, flags: CGEventFlags, scroll: (Int32) -> Bool) -> Bool {
        if type == .keyUp { return held.remove(code) != nil }
        guard type == .keyDown, code == kVK_DownArrow || code == kVK_UpArrow,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              scroll(code == kVK_DownArrow ? -1 : 1) else {
            held.remove(code)
            return false
        }
        held.insert(code)
        return true
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        paceWheel = nil
        scroll = nil
        held.removeAll()
    }

    isolated deinit { stop() }
}

/// Keep enough overlap even when the target redraws several wheel events at once.
/// A new frame replenishes the budget. Excess motion is never queued for later.
struct ManualScrollPacing {
    private var used = 0
    private var previousDelta: Int64 = 0
    private var lastEvent: CGEventTimestamp = 0

    mutating func receivedFrame() { used = 0 }

    mutating func apply(to event: CGEvent, budget: Int) {
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let points = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let delta = points == 0 ? lines * 10 : points
        guard delta != 0 else { return } // Preserve stationary and end-of-gesture events.
        let time = event.timestamp
        if (delta < 0) != (previousDelta < 0) || (time > lastEvent && time - lastEvent > 250_000_000) {
            used = 0
        }
        previousDelta = delta
        lastEvent = time
        let allowed = min(Int(abs(delta)), max(0, budget - used))
        used += allowed
        guard allowed < abs(delta) else { return }
        let fraction = Double(allowed) / Double(abs(delta))
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        // CoreGraphics also rewrites the point delta when setting line units.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((Double(lines) * fraction).rounded()))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed * fraction)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta < 0 ? -allowed : allowed))
    }
}

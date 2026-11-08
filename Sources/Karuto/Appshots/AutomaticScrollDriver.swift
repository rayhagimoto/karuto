import AppKit
import ApplicationServices

/// Drives an existing frame/stitch session. It never owns capture output or presents UI.
/// End detection is conservative: several settled scroll attempts must add no pixels.
@MainActor
final class AutomaticScrollDriver {
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private var finish: (() -> Void)?
    private var fallback: ((String) -> Void)?
    private var progress = AutomaticScrollProgress()
    private static let eventMarker: Int64 = 0x4B415255544F

    /// Call before starting the frame stream so an early baseline frame is retained.
    func prepare() {
        stop()
        progress = AutomaticScrollProgress()
    }
    func observe(_ value: StitchProgress) { progress.observe(value) }

    func start(target: CaptureTarget, catalog: CaptureCatalog, inputPoint: CGPoint? = nil,
               onFinish: @escaping () -> Void,
               onManualFallback: @escaping (String) -> Void) {
        stop()
        finish = onFinish
        fallback = onManualFallback
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            useManual("Automatic scrolling needs Accessibility access. Scroll manually, or enable Karuto in System Settings → Privacy & Security → Accessibility.")
            return
        }
        let rect: CGRect?
        switch target {
        case .area(_, let area): rect = area
        case .display(let id): rect = catalog.displays.first { $0.id == id }?.frame
        case .window(let id): rect = catalog.windows.first { $0.id == id }?.frame
        }
        guard let rect, rect.width > 1, rect.height > 1 else {
            useManual("The selected content is unavailable. Scroll manually or choose another area.")
            return
        }
        let point = inputPoint.flatMap { rect.contains($0) ? $0 : nil } ?? CGPoint(x: rect.midX, y: rect.midY)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let owner = Self.window(at: quartzPoint),
              owner.pid != ProcessInfo.processInfo.processIdentifier else {
            useManual("Place the selected content in front, then scroll manually.")
            return
        }
        if case .window(let id) = target, owner.id != id {
            useManual("The selected window is covered. Bring it forward and scroll manually.")
            return
        }
        let source = CGEventSource(stateID: .privateState)
        source?.userData = Self.eventMarker
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return }
            Task { @MainActor [weak self] in
                self?.useManual("Automatic scrolling paused after your input. Continue scrolling manually, or choose Finish.")
            }
        }
        task = Task { [weak self] in
            // Let the stream record the initial viewport before issuing any scroll.
            for _ in 0..<20 {
                guard let self, !Task.isCancelled else { return }
                if self.progress.hasFrame { break }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            guard self.progress.hasFrame else {
                self.useManual("No capture frames arrived. Continue manually or restart capture.")
                return
            }
            let began = Date()
            var noGrowthAttempts = 0
            var mismatchAttempts = 0
            while !Task.isCancelled {
                guard Date().timeIntervalSince(began) < 110 else {
                    self.useManual("Automatic scrolling reached its time limit. Continue manually or choose Finish.")
                    return
                }
                guard let current = Self.window(at: quartzPoint), current == owner,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid else {
                    self.useManual("The target window moved, was covered, or lost focus. Continue manually when ready.")
                    return
                }
                let viewportHeight = rect.height * self.progress.viewportFraction
                let step = Int32(max(8, min(self.progress.isCalibrating ? 48 : 240, viewportHeight / 4)))
                let before = self.progress.height
                let rejectedBefore = self.progress.rejectedFrames
                guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                          wheel1: -step, wheel2: 0, wheel3: 0) else {
                    self.useManual("Could not send a scroll event. Continue scrolling manually.")
                    return
                }
                event.location = quartzPoint
                event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
                // Use the normal session input pipeline after validating focus and
                // the window under the point. Bare PID-posted wheel events do
                // not receive the window routing metadata Chromium expects.
                event.post(tap: .cghidEventTap)
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                if self.progress.height > before {
                    noGrowthAttempts = 0
                    mismatchAttempts = 0
                } else if self.progress.rejectedFrames > rejectedBefore {
                    mismatchAttempts += 1
                    if mismatchAttempts >= 2 {
                        self.useManual("Content could not be aligned. Scroll back slowly, or restart with fixed headers and sidebars outside the selection.")
                        return
                    }
                } else {
                    noGrowthAttempts += 1
                    if noGrowthAttempts >= 4 {
                        if self.progress.hasExtended {
                            self.complete()
                        } else {
                            self.useManual("Automatic scrolling added no content. Move the pointer over the scrollable content and scroll manually.")
                        }
                        return
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finish = nil; fallback = nil
    }

    private func useManual(_ message: String) {
        let callback = fallback
        stop()
        callback?(message)
    }
    private func complete() {
        let callback = finish
        stop()
        callback?()
    }

    private struct Owner: Equatable {
        let id: UInt32
        let pid: Int32
        let frame: CGRect
    }
    private static func window(at point: CGPoint) -> Owner? {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infos {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.contains(point),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return Owner(id: id, pid: pid, frame: rect)
        }
        return nil
    }
}

/// Frame evidence is independent of timing and UI, so a duplicate never counts as growth.
struct AutomaticScrollProgress {
    private(set) var height = 0
    private(set) var firstHeight: Int?
    private(set) var rejectedFrames = 0
    private(set) var receivedFrame = false
    private(set) var isCalibrating = false
    private(set) var viewportFraction: CGFloat = 1
    var hasFrame: Bool { receivedFrame }
    var hasExtended: Bool { height > (firstHeight ?? height) }
    mutating func observe(_ progress: StitchProgress) {
        receivedFrame = true
        if progress.disposition == 4 { isCalibrating = true; return }
        if progress.disposition == 0 {
            isCalibrating = false
            if let viewportHeight = progress.viewportHeight, progress.sourceSize.height > 0 {
                viewportFraction = min(1, CGFloat(viewportHeight) / progress.sourceSize.height)
            }
            if firstHeight == nil { firstHeight = progress.viewportHeight ?? progress.height }
            height = max(height, progress.height)
        } else if progress.disposition == 2 {
            rejectedFrames += 1
        }
    }
}

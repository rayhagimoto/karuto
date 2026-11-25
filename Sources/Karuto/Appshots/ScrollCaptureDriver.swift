import AppKit
import ApplicationServices

/// Drives an existing frame/stitch session. It never owns capture output or presents UI.
@MainActor
final class ScrollCaptureDriver {
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private let manualInput = ManualScrollInput()
    private let regionResolver = ScrollRegionResolver()
    private var pacing = ManualScrollPacing()
    private var destination: Destination?
    private var verifiedBounds: CGRect?
    private var finish: (() -> Void)?
    private var fallback: ((String) -> Void)?
    private var progress = AutomaticScrollProgress()
    private static let eventMarker: Int64 = 0x4B415255544F

    /// Call before starting the frame stream so an early baseline frame is retained.
    func prepare(target: CaptureTarget, catalog: CaptureCatalog?, inputPoint: CGPoint? = nil) {
        stop()
        progress = AutomaticScrollProgress()
        destination = nil
        verifiedBounds = nil
        guard let catalog else { return }
        let rect: CGRect?
        switch target {
        case .area(_, let area): rect = area
        case .display(let id): rect = catalog.displays.first { $0.id == id }?.frame
        case .window(let id): rect = catalog.windows.first { $0.id == id }?.frame
        }
        guard let rect, rect.width > 1, rect.height > 1 else { return }
        let point = inputPoint.flatMap { rect.contains($0) ? $0 : nil } ?? CGPoint(x: rect.midX, y: rect.midY)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        let selected: CaptureWindow?
        if case .window(let id) = target {
            selected = catalog.windows.first { $0.id == id }
        } else {
            selected = catalog.windows.first { $0.frame.contains(point) }
        }
        guard let selected, let pid = selected.processID, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let windowFrame = CGRect(x: selected.frame.minX, y: primaryHeight - selected.frame.maxY,
                                 width: selected.frame.width, height: selected.frame.height)
        let owner = Owner(id: selected.id, pid: pid, frame: windowFrame)
        let bounds = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        destination = Destination(owner: owner, point: quartzPoint, bounds: bounds)
    }

    func contentHint() async -> CGRect? {
        guard let destination else { return nil }
        let bounds = destination.bounds
        guard let pane = await regionResolver.paneBounds(pid: destination.owner.pid, point: destination.point,
                                                         selection: bounds, window: destination.owner.frame),
              !Task.isCancelled else { return nil }
        return CGRect(x: (pane.minX - bounds.minX) / bounds.width, y: (pane.minY - bounds.minY) / bounds.height,
                      width: pane.width / bounds.width, height: pane.height / bounds.height)
    }

    func observe(_ value: StitchProgress) {
        progress.observe(value)
        pacing.receivedFrame()
        if verifiedBounds == nil, let bounds = destination?.bounds, let crop = value.contentRect,
           value.sourceSize.width > 0, value.sourceSize.height > 0 {
            let scaled = crop.applying(CGAffineTransform(scaleX: bounds.width / value.sourceSize.width,
                                                        y: bounds.height / value.sourceSize.height))
            verifiedBounds = scaled.offsetBy(dx: bounds.minX, dy: bounds.minY)
        }
    }

    func startManual() {
        stop()
        guard let destination, CGPreflightPostEventAccess() else { return }
        pacing = ManualScrollPacing()
        manualInput.start(pid: destination.owner.pid, paceWheel: { [weak self] event in
            guard let self else { return }
            let bounds = self.verifiedBounds ?? destination.bounds
            guard bounds.contains(event.location),
                  event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return }
            let windowID = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            if windowID == 0 {
                guard Self.window(at: event.location) == destination.owner else { return }
            } else if windowID != Int64(destination.owner.id) { return }
            let budget = self.verifiedBounds == nil ? min(48, bounds.height / 3) : bounds.height / 3
            self.pacing.apply(to: event, budget: max(1, Int(budget)))
        }) { [weak self] direction in
            guard let self else { return false }
            let bounds = self.verifiedBounds ?? destination.bounds
            let point = bounds.contains(destination.point) ? destination.point : CGPoint(x: bounds.midX, y: bounds.midY)
            guard destination.isFocused(at: point, requireFrontWindow: true) else { return false }
            let step = Int32(max(1, min(48, bounds.height / 4)))
            return self.postScroll(direction * step, at: point)
        }
    }

    func startAutomatic(drainFrames: @escaping @MainActor () async -> Void,
                        beginMotion: @escaping @MainActor (Bool) throws -> Bool,
                        onFinish: @escaping () -> Void, onManualFallback: @escaping (String) -> Void) {
        stop()
        finish = onFinish
        fallback = onManualFallback
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            useManual("Automatic scrolling needs Accessibility access. Scroll manually, or enable Karuto in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard let destination else {
            useManual("Place the selected content in front, then scroll manually.")
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return }
            Task { @MainActor [weak self] in
                self?.useManual("Automatic scrolling paused after your input. Continue scrolling manually, or choose Finish.")
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !Task.isCancelled {
                await drainFrames()
                guard !Task.isCancelled else { return }
                let force = ContinuousClock.now >= deadline
                do {
                    if try beginMotion(force) { break }
                } catch {
                    self.useManual(error.localizedDescription)
                    return
                }
                if force {
                    self.useManual("No capture frames arrived. Continue manually or restart capture.")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let began = Date()
            var noGrowthAttempts = 0
            var lastProgress: ContinuousClock.Instant?
            var lastKnownPosition = ScrollRegionResolver.ScrollPosition.unknown
            var timing = AutomaticScrollTiming()
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard Date().timeIntervalSince(began) < 110 else {
                    self.useManual("Automatic scrolling reached its time limit. Continue manually or choose Finish.")
                    return
                }
                let point = self.verifiedBounds.flatMap { bounds in
                    bounds.contains(destination.point) ? nil : CGPoint(x: bounds.midX, y: bounds.midY)
                } ?? destination.point
                guard destination.isFocused(at: point) else {
                    self.useManual("The target window moved, was covered, or lost focus. Continue manually when ready.")
                    return
                }
                let before = self.progress
                let sourceHeight = destination.bounds.height
                let step = before.scrollStep(sourceHeight: sourceHeight, retrying: noGrowthAttempts > 0)
                guard self.postScroll(-step, at: point) else {
                    self.useManual("Could not send a scroll event. Continue scrolling manually.")
                    return
                }
                // A smooth scroll can render several partial frames. Only a verified
                // full step releases the next large input. Use a small probe on stalls.
                let sent = clock.now
                var lastGrowth = sent
                var lastHeight = before.height
                var scrollPosition = ScrollRegionResolver.ScrollPosition.unknown
                let quietInterval = before.hasExtended ? timing.quietInterval : .milliseconds(750)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    let elapsed = sent.duration(to: clock.now)
                    if self.progress.covered(step: step, since: before, sourceHeight: sourceHeight) {
                        if before.hasExtended { timing.record(stepDuration: elapsed) }
                        break
                    }
                    if self.progress.height > lastHeight {
                        lastHeight = self.progress.height
                        lastGrowth = clock.now
                    }
                    if before.isCalibrating, noGrowthAttempts < 3, self.progress.frameCount > before.frameCount,
                       !self.progress.hasUnresolvedOverlap, elapsed >= .milliseconds(160) { break }
                    let rejected = self.progress.hasUnresolvedOverlap
                    let settling = rejected ? max(quietInterval, .milliseconds(550)) : quietInterval
                    if lastGrowth.duration(to: clock.now) >= settling {
                        // A busy stitcher can still have growth to report for this input.
                        await drainFrames()
                        if !Task.isCancelled, before.hasExtended, lastHeight == self.progress.height,
                           !self.progress.hasUnresolvedOverlap, let bounds = self.verifiedBounds {
                            let point = CGPoint(x: bounds.midX, y: bounds.midY)
                            scrollPosition = await self.regionResolver.scrollPosition(pid: destination.owner.pid, point: point, verifiedBounds: bounds)
                            await drainFrames()
                        }
                        break
                    }
                }
                guard !Task.isCancelled else { return }
                if self.progress.hasUnresolvedOverlap {
                    self.useManual("The overlap could not be verified. Return to the last captured area and scroll slowly, or choose Finish to review the partial capture.")
                    return
                } else if self.progress.height > before.height {
                    noGrowthAttempts = 0
                    lastProgress = nil
                    lastKnownPosition = .unknown
                } else {
                    noGrowthAttempts += 1
                    if scrollPosition != .unknown { lastKnownPosition = scrollPosition }
                    if lastKnownPosition == .aboveBottom {
                        lastProgress = nil
                        if noGrowthAttempts >= 4 {
                            self.useManual("The pane stopped responding before the bottom. Continue scrolling manually or choose Finish.")
                            return
                        }
                    } else if self.progress.hasExtended {
                        let since = lastProgress ?? sent
                        lastProgress = since
                        if timing.hasConfirmedEnd(quietFor: since.duration(to: clock.now), probes: noGrowthAttempts,
                                                  reportsBottom: lastKnownPosition == .atBottom) {
                            self.complete()
                            return
                        }
                    } else if noGrowthAttempts >= 4 {
                        self.useManual("No vertical scrolling was captured. Select one vertical pane, then scroll slowly inside it.")
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
        manualInput.stop()
        finish = nil; fallback = nil
    }

    private func useManual(_ message: String) {
        guard let callback = fallback else { return }
        stop()
        callback(message)
    }
    private func complete() {
        let callback = finish
        stop()
        callback?()
    }

    private func postScroll(_ delta: Int32, at point: CGPoint) -> Bool {
        guard let destination, let event = Self.windowScrollEvent(delta, at: point, windowID: destination.owner.id,
                                                                   windowFrame: destination.owner.frame) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        event.postToPid(destination.owner.pid)
        return true
    }

    static func windowScrollEvent(_ delta: Int32, at point: CGPoint, windowID: UInt32, windowFrame: CGRect) -> CGEvent? {
        // A PID-posted wheel has no AppKit window number. Seed the event with
        // AppKit's window-local routing data, then send it only as a wheel event.
        guard let setWindowLocation,
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID),
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0)?.cgEvent,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
        event.type = .scrollWheel
        event.location = point
        setWindowLocation(event, CGPoint(x: point.x - windowFrame.minX, y: point.y - windowFrame.minY))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: wheel.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
        return event
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    // Direct delivery bypasses WindowServer hit testing. Without a window-local
    // Quartz point, AppKit receives (-1, -1) even when the global point is correct.
    // This CoreGraphics setter is undocumented. Fail into manual input if absent.
    private static let setWindowLocation: SetWindowLocation? = {
        guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.CoreGraphics" as CFString),
              let symbol = CFBundleGetFunctionPointerForName(bundle, "CGEventSetWindowLocation" as CFString) else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    private struct Destination {
        let owner: Owner
        let point: CGPoint
        let bounds: CGRect

        @MainActor func isFocused(at inputPoint: CGPoint? = nil, requireFrontWindow: Bool = false) -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid
                && ScrollCaptureDriver.window(at: inputPoint ?? point, frontWindowOf: requireFrontWindow ? owner.pid : nil) == owner
        }
    }

    private struct Owner: Equatable {
        let id: UInt32
        let pid: Int32
        let frame: CGRect
    }
    private static func window(at point: CGPoint, frontWindowOf pid: Int32? = nil) -> Owner? {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infos {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if rect.contains(point) { return Owner(id: id, pid: ownerPID, frame: rect) }
            if ownerPID == pid { return nil }
        }
        return nil
    }
}

struct AutomaticScrollTiming {
    private(set) var quietInterval: Duration = .milliseconds(750)

    func hasConfirmedEnd(quietFor duration: Duration, probes: Int, reportsBottom: Bool) -> Bool {
        // Accessibility can report the current end before an infinite feed loads.
        duration >= .milliseconds(850) && (reportsBottom || probes >= 2)
    }

    mutating func record(stepDuration: Duration) {
        // Slow redraws lengthen the wait immediately. Several fast steps shorten it.
        quietInterval = min(.milliseconds(750), max(.milliseconds(220), quietInterval * 0.75, stepDuration * 3))
    }
}

/// Frame evidence is independent of timing and UI, so a duplicate never counts as growth.
struct AutomaticScrollProgress {
    private(set) var height = 0
    private(set) var firstHeight: Int?
    private(set) var hasUnresolvedOverlap = false
    private(set) var frameCount = 0
    private var sourcePixels: CGFloat = 0
    private(set) var isCalibrating = false
    private(set) var viewportFraction: CGFloat = 1
    var hasFrame: Bool { frameCount > 0 }
    var hasExtended: Bool { height > (firstHeight ?? height) }
    func scrollStep(sourceHeight: CGFloat, retrying: Bool) -> Int32 {
        let viewport = sourceHeight * viewportFraction
        let scale = sourcePixels > 0 ? sourcePixels / sourceHeight : 1
        // The matcher needs at least 24 overlapping pixels even on tiny panes.
        let step = isCalibrating || retrying ? min(48, viewport / 4) : viewport / 3
        return Int32(max(1, min(step, viewport - 24 / scale)))
    }

    func covered(step: Int32, since before: Self, sourceHeight: CGFloat) -> Bool {
        guard !hasUnresolvedOverlap else { return false }
        if before.isCalibrating { return hasExtended }
        let scale = sourcePixels > 0 ? sourcePixels / sourceHeight : 1
        return CGFloat(height - before.height) >= ceil(CGFloat(step) * scale)
    }

    mutating func observe(_ progress: StitchProgress) {
        frameCount += 1
        sourcePixels = progress.sourceSize.height
        if progress.disposition == 4 { isCalibrating = true; return }
        if progress.disposition == 0 {
            hasUnresolvedOverlap = false
            isCalibrating = false
            if let viewportHeight = progress.viewportHeight, progress.sourceSize.height > 0 {
                viewportFraction = min(1, CGFloat(viewportHeight) / progress.sourceSize.height)
            }
            if firstHeight == nil { firstHeight = progress.viewportHeight ?? progress.height }
            height = max(height, progress.height)
        } else if progress.disposition == 2 {
            hasUnresolvedOverlap = true
        } else if progress.disposition == 5 {
            hasUnresolvedOverlap = false
        }
    }
}

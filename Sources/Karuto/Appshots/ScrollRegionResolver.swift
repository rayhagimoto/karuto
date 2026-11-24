import Foundation
import CoreGraphics
import ApplicationServices

struct ScrollRegionRequest: Sendable {
    let point: CGPoint
    let window: CaptureWindow
    let display: CaptureDisplay
    let generation: UInt64
}

/// App-scoped accessibility queries are serialized away from pointer rendering.
/// Failure is an ordinary result: a raw window remains an explicitly unverified fallback.
actor ScrollRegionResolver {
    enum ScrollPosition { case atBottom, aboveBottom, unknown }
    private struct CacheEntry {
        let windowID: UInt32
        let processID: Int32
        let windowFrame: CGRect
        let cell: CGPoint
        let date: Date
        let candidate: CGRect?
    }
    private var cache: [CacheEntry] = []

    func resolve(_ request: ScrollRegionRequest) -> CGRect? {
        guard let pid = request.window.processID, AXIsProcessTrusted() else { return nil }
        let cell = CGPoint(x: floor(request.point.x / 24), y: floor(request.point.y / 24))
        let now = Date()
        cache.removeAll { now.timeIntervalSince($0.date) > 1 }
        if let hit = cache.first(where: { $0.windowID == request.window.id && $0.processID == pid && $0.windowFrame == request.window.frame && $0.cell == cell }) {
            return hit.candidate
        }
        let candidate = discover(request, pid: pid)
        if cache.count >= 32 { cache.removeFirst() }
        cache.append(CacheEntry(windowID: request.window.id, processID: pid, windowFrame: request.window.frame, cell: cell, date: now, candidate: candidate))
        return candidate
    }

    private func discover(_ request: ScrollRegionRequest, pid: Int32) -> CGRect? {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let quartzPoint = CGPoint(x: request.point.x, y: primaryHeight - request.point.y)
        return firstScrollArea(pid: pid, at: quartzPoint) { _, quartzFrame in
            let frame = CaptureGeometry.appKitRect(fromQuartz: quartzFrame, primaryHeight: primaryHeight)
            return Self.clippedCandidate(frame, point: request.point, window: request.window.frame, display: request.display.frame)
        }
    }

    func paneBounds(pid: Int32, point: CGPoint, selection: CGRect, window: CGRect) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        return firstScrollArea(pid: pid, at: point) { _, bounds in
            Self.clippedCandidate(bounds, point: point, window: window, display: selection)
        }
    }

    /// Only trust the nearest scroll area's range when its bounds agree with
    /// the moving pixels. An enclosing page can be at its end while a child scrolls.
    func scrollPosition(pid: Int32, point: CGPoint, verifiedBounds: CGRect) -> ScrollPosition {
        firstScrollArea(pid: pid, at: point) { area, frame -> ScrollPosition? in
            let tolerance: CGFloat = 18 // Allow for a native scrollbar or border.
            guard abs(frame.minX - verifiedBounds.minX) <= tolerance, abs(frame.maxX - verifiedBounds.maxX) <= tolerance,
                  abs(frame.minY - verifiedBounds.minY) <= tolerance, abs(frame.maxY - verifiedBounds.maxY) <= tolerance,
                  let raw = attribute(area, kAXVerticalScrollBarAttribute as CFString),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .unknown }
            let bar = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(bar, 0.025)
            guard let value = attribute(bar, kAXValueAttribute as CFString) as? NSNumber else { return .unknown }
            var maximum: CFTypeRef?
            let upper: Double
            switch AXUIElementCopyAttributeValue(bar, kAXMaxValueAttribute as CFString, &maximum) {
            case .success:
                guard let max = maximum as? NSNumber,
                      let min = attribute(bar, kAXMinValueAttribute as CFString) as? NSNumber,
                      max.doubleValue > min.doubleValue, value.doubleValue >= min.doubleValue else { return .unknown }
                upper = max.doubleValue
            case .attributeUnsupported:
                // NSScroller exposes a normalized value and omits both range attributes.
                guard attribute(bar, kAXRoleAttribute as CFString) as? String == kAXScrollBarRole as String,
                      value.doubleValue >= 0 else { return .unknown }
                upper = 1
            default: return .unknown
            }
            guard value.doubleValue <= upper else { return .unknown }
            return value.doubleValue == upper ? .atBottom : .aboveBottom
        } ?? .unknown
    }

    private func firstScrollArea<T>(pid: Int32, at point: CGPoint, match: (AXUIElement, CGRect) -> T?) -> T? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.025)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success else { return nil }
        let deadline = Date().addingTimeInterval(0.25)
        for _ in 0..<16 {
            guard let current = element, Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(current, 0.025)
            let role = attribute(current, kAXRoleAttribute as CFString) as? String
            let hasVerticalScrollBar = attribute(current, kAXVerticalScrollBarAttribute as CFString) != nil
            if role == (kAXScrollAreaRole as String) || hasVerticalScrollBar,
               let bounds = frame(current), let result = match(current, bounds) { return result }
            guard let parent = attribute(current, kAXParentAttribute as CFString), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = (parent as! AXUIElement)
        }
        return nil
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
        return result
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute as CFString), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = attribute(element, kAXSizeAttribute as CFString), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position), AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    nonisolated static func clippedCandidate(_ frame: CGRect, point: CGPoint, window: CGRect, display: CGRect) -> CGRect? {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
        let clipped = frame.intersection(window).intersection(display)
        guard !clipped.isNull, clipped.width >= 16, clipped.height >= 32, clipped.contains(point) else { return nil }
        return clipped
    }

    nonisolated static func isCurrent(_ request: ScrollRegionRequest, generation: UInt64, point: CGPoint, windowID: UInt32?) -> Bool {
        request.generation == generation && request.point == point && request.window.id == windowID
    }
}

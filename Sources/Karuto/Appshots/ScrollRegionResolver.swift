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
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.025)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(request.point.x), Float(primaryHeight - request.point.y), &element) == .success else { return nil }
        let deadline = Date().addingTimeInterval(0.25)
        for _ in 0..<16 {
            guard let current = element, Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(current, 0.025)
            let role = attribute(current, kAXRoleAttribute as CFString) as? String
            let hasVerticalScrollBar = attribute(current, kAXVerticalScrollBarAttribute as CFString) != nil
            if role == (kAXScrollAreaRole as String) || hasVerticalScrollBar,
               let quartzFrame = frame(current) {
                let appKitFrame = CGRect(x: quartzFrame.minX, y: primaryHeight - quartzFrame.maxY, width: quartzFrame.width, height: quartzFrame.height)
                if let candidate = Self.clippedCandidate(appKitFrame, point: request.point, window: request.window.frame, display: request.display.frame) { return candidate }
            }
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

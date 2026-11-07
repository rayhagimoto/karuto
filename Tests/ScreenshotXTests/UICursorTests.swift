import AppKit
import Testing
@testable import ScreenshotX

@MainActor
struct UICursorTests {
    @Test func presentationSetsCrosshairWithoutMovementAndDismissRestoresArrow() throws {
        _ = NSApplication.shared
        let pointer = NSEvent.mouseLocation
        let display = CaptureDisplay(id: 71, name: "Cursor fixture", frame: CGRect(x: pointer.x - 500, y: pointer.y - 400, width: 1000, height: 800), scale: 1)
        let controller = CaptureUIController()
        defer { controller.dismiss() }
        NSCursor.arrow.set()
        controller.present(catalog: CaptureCatalog(displays: [display], windows: []))
        #expect(NSCursor.current === NSCursor.crosshair)
        let toolbar = try #require(NSApp.windows.first { $0.contentView is CaptureToolbarView })
        toolbar.contentView?.layoutSubtreeIfNeeded()
        let button = try #require(descendants(toolbar.contentView).first { $0 is CaptureModeButton })
        controller.refreshCursor(at: toolbar.convertPoint(toScreen: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)))
        #expect(NSCursor.current === NSCursor.arrow)
        let field = try #require(descendants(toolbar.contentView).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        controller.refreshCursor(at: toolbar.convertPoint(toScreen: field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)))
        #expect(NSCursor.current === NSCursor.iBeam)
        controller.refreshCursor(at: pointer)
        #expect(NSCursor.current === NSCursor.crosshair)
        controller.dismiss()
        #expect(NSCursor.current === NSCursor.arrow)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func nonKeyCanvasEntryAndMovementRefreshCrosshair() throws {
        _ = NSApplication.shared
        let display = CaptureDisplay(id: 72, name: "Non-key cursor fixture", frame: CGRect(x: -1000, y: 100, width: 800, height: 600), scale: 1)
        let controller = CaptureUIController()
        let view = controller.makeSelectionOverlay(for: display)
        let window = CapturePanel(contentRect: display.frame)
        window.contentView = view
        defer { controller.dismiss(); window.close() }
        #expect(!window.isKeyWindow)
        view.updateTrackingAreas()
        let tracking = try #require(view.trackingAreas.first)
        #expect(tracking.options.contains(.activeAlways))
        #expect(tracking.options.contains(.mouseEnteredAndExited))
        #expect(tracking.options.contains(.mouseMoved))
        #expect(!tracking.options.contains(.cursorUpdate))
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        NSCursor.arrow.set()
        view.mouseEntered(with: moved)
        #expect(NSCursor.current === NSCursor.crosshair)
        NSCursor.arrow.set()
        view.mouseMoved(with: moved)
        #expect(NSCursor.current === NSCursor.crosshair)
        controller.dismiss()
        view.mouseMoved(with: moved)
        #expect(NSCursor.current === NSCursor.arrow)
    }

    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
}

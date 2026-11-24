import AppKit
import Testing
@testable import Karuto

@MainActor
struct UICursorTests {
    @Test func toolbarModeButtonsAndTimerMenuStayInSync() throws {
        _ = NSApplication.shared
        let pointer = NSEvent.mouseLocation
        let display = CaptureDisplay(id: 73, name: "Toolbar fixture", frame: CGRect(x: pointer.x - 500, y: pointer.y - 400, width: 1000, height: 800), scale: 1)
        let controller = CaptureUIController()
        defer { controller.dismiss() }
        controller.present(catalog: CaptureCatalog(displays: [display], windows: []))
        let toolbar = try #require(NSApp.windows.first { $0.contentView is CaptureToolbarView && $0.isVisible && display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        toolbar.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(toolbar.contentView)
        let selector = try #require(views.compactMap { $0 as? CaptureModeSelector }.first)
        let buttons = selector.arrangedSubviews.compactMap { $0 as? CaptureToolbarButton }
        let snapshot = try #require(buttons.first)
        let recording = try #require(buttons.last)
        let timer = try #require(views.compactMap { $0 as? CaptureToolbarButton }.first { $0.accessibilityLabel() == "Capture timer" })
        #expect(buttons.map { $0.accessibilityLabel() } == CaptureMode.allCases.map(\.title))
        #expect(buttons.map(\.symbolName) == ["camera", "record.circle"])
        #expect(timer.title.isEmpty)
        #expect(timer.symbolName == "clock")
        #expect(timer.accessibilityValue() as? String == "Off")
        #expect(snapshot.accessibilityValue() as? Int == 1)
        #expect(snapshot.frame.width >= recording.intrinsicContentSize.width)
        let highlight = try #require(selector.layer?.sublayers?.first { $0.backgroundColor != nil })
        #expect(highlight.frame == snapshot.frame)

        recording.performClick(nil)
        #expect(controller.mode == .screenRecording)
        #expect(recording.accessibilityValue() as? Int == 1)
        #expect(snapshot.accessibilityValue() as? Int == 0)
        #expect(highlight.frame == recording.frame)
        #expect((highlight.animation(forKey: "position") != nil) != NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let menu = controller.makeTimerMenu()
        #expect(menu.items.map(\.tag) == CaptureSessionPreferences.delays)
        let threeSeconds = try #require(menu.item(withTag: 3))
        let action = try #require(threeSeconds.action)
        #expect(NSApp.sendAction(action, to: threeSeconds.target, from: threeSeconds))
        #expect(timer.accessibilityValue() as? String == "3 seconds")
        #expect(controller.makeTimerMenu().item(withTag: 3)?.state == .on)
        let icons = views.compactMap { $0 as? CaptureToolbarButton }
        #expect(icons.allSatisfy { $0.toolTip == $0.accessibilityLabel() })

        #expect(controller.handleShortcut(.snapshotMode))
        #expect(snapshot.accessibilityValue() as? Int == 1)
        #expect(timer.accessibilityValue() as? String == "Off")
        #expect(controller.handleShortcut(.recordingMode))
        #expect(timer.accessibilityValue() as? String == "3 seconds")
    }

    @Test func keyboardMovesBetweenGroupsAndActivatesTools() throws {
        _ = NSApplication.shared
        let display = CaptureDisplay(id: 73, name: "Keyboard", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1)
        let controller = CaptureUIController()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        controller.keymap = KeymapController(settings: AppSettings(defaults: defaults))
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.present(catalog: CaptureCatalog(displays: [display], windows: []))
        defer { controller.dismiss() }
        let panel = try #require(NSApp.windows.first { $0.contentView is CaptureToolbarView && !existing.contains(ObjectIdentifier($0)) })
        func key(_ code: UInt16, shift: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            #expect(controller.handleKeyEvent(event))
        }
        func focused() -> String? { (panel.firstResponder as? NSButton)?.accessibilityLabel() }
        try key(48)
        #expect(focused() == "Snapshot")
        try key(48)
        #expect(focused() == "Area")
        try key(124)
        #expect(focused() == "Fullscreen")
        #expect(controller.selectedRegion == .fullscreen)
        try key(48)
        #expect(focused() == "Recognize text")
        let ocr = try #require(panel.firstResponder as? CaptureToolbarButton)
        #expect(ocr.toolTip == "Recognize text")
        let shortcut = try #require(controller.keymap?.configuration.binding(for: .toggleOCR))
        #expect(ocr.focusHint.contains(shortcut.displayString))
        try key(49)
        #expect(controller.capturesText)
        try key(31)
        #expect(!controller.capturesText)
        try key(124)
        #expect(focused() == "Capture timer")
        try key(48, shift: true)
        #expect(focused() == "Fullscreen")
    }

    @Test func presentationSetsCrosshairWithoutMovementAndDismissRestoresArrow() throws {
        _ = NSApplication.shared
        let pointer = NSEvent.mouseLocation
        let display = CaptureDisplay(id: 71, name: "Cursor fixture", frame: CGRect(x: pointer.x - 500, y: pointer.y - 400, width: 1000, height: 800), scale: 1)
        let controller = CaptureUIController()
        defer { controller.dismiss() }
        NSCursor.arrow.set()
        controller.present(catalog: CaptureCatalog(displays: [display], windows: []))
        #expect(NSCursor.current === NSCursor.crosshair)
        let toolbar = try #require(NSApp.windows.first { $0.contentView is CaptureToolbarView && $0.isVisible && display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        toolbar.contentView?.layoutSubtreeIfNeeded()
        let button = try #require(descendants(toolbar.contentView).first { $0.accessibilityLabel() == "Area" })
        controller.refreshCursor(at: toolbar.convertPoint(toScreen: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)))
        #expect(NSCursor.current === NSCursor.arrow)
        #expect(!descendants(toolbar.contentView).contains { ($0 as? NSTextField)?.isEditable == true })
        let rect = CGRect(x: display.frame.minX + 30, y: display.frame.minY + 400, width: 240, height: 120)
        controller.previousArea = { (.area(displayID: display.id, rect: rect), display.frame) }
        #expect(controller.handleShortcut(.selectLastArea))
        let control = try #require(NSApp.windows.compactMap { descendants($0.contentView).compactMap { $0 as? SelectionSizeControl }.first }.first)
        let field = try #require(descendants(control).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let overlay = try #require(control.window)
        #expect(overlay !== toolbar)
        #expect(field.integerValue == 240)
        toolbar.makeFirstResponder(toolbar.contentView)
        let tab = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: toolbar.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        #expect(controller.handleKeyEvent(tab))
        #expect(field.currentEditor() != nil)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        controller.keymap = KeymapController(settings: AppSettings(defaults: defaults))
        let o = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: overlay.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o",
            isARepeat: false, keyCode: 31))
        #expect(!controller.handleKeyEvent(o))
        #expect(!controller.capturesText)
        control.endEditing()
        controller.refreshCursor(at: overlay.convertPoint(toScreen: field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)))
        #expect(NSCursor.current === NSCursor.iBeam)
        controller.refreshCursor(at: pointer)
        #expect(NSCursor.current === NSCursor.crosshair)
        controller.dismiss()
        #expect(NSCursor.current === NSCursor.arrow)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(NSCursor.current === NSCursor.arrow)
    }

    @Test func selectionDimensionsFollowDragsAndCommitFieldEdits() throws {
        _ = NSApplication.shared
        let screen = CGRect(x: -1800, y: 200, width: 900, height: 700)
        let display = CaptureDisplay(id: 74, name: "Size fixture", frame: screen, scale: 2)
        let controller = CaptureUIController()
        defer { controller.dismiss() }
        var captured: CaptureTarget?
        controller.onCapture = { _, _, target, _, _ in captured = target }
        controller.present(catalog: CaptureCatalog(displays: [display], windows: []))
        let canvas = try #require(NSApp.windows.flatMap { descendants($0.contentView) }.first {
            $0.accessibilityLabel() == "Capture selection on Size fixture"
        })
        let overlay = try #require(canvas.window)
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                timestamp: 0, windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }
        func inputs() -> [NSTextField] {
            descendants(overlay.contentView).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        }
        #expect(inputs().isEmpty)
        try mouse(.leftMouseDown, 160, 280)
        try mouse(.leftMouseDragged, 400, 440)
        #expect(inputs().isEmpty)
        try mouse(.leftMouseUp, 400, 440)
        let width = try #require(inputs().first { $0.accessibilityLabel() == "Selection width" })
        let height = try #require(inputs().first { $0.accessibilityLabel() == "Selection height" })
        #expect(width.integerValue == 240 && height.integerValue == 160)
        let control = try #require(width.superview as? SelectionSizeControl)
        let initialOrigin = control.frame.origin
        try mouse(.leftMouseDown, 250, 350)
        try mouse(.leftMouseDragged, 290, 370)
        #expect(control.isHidden)
        try mouse(.leftMouseUp, 290, 370)
        #expect(!control.isHidden)
        #expect(control.frame.origin == CGPoint(x: initialOrigin.x + 40, y: initialOrigin.y + 20))
        try mouse(.leftMouseDown, 440, 460)
        try mouse(.leftMouseUp, 470, 490)
        #expect(width.integerValue == 270 && height.integerValue == 190)
        overlay.makeKey()
        func edit(_ field: NSTextField, value: String, command: Selector) throws {
            field.selectText(nil)
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.string = value
            editor.doCommand(by: command)
        }
        try edit(width, value: "315", command: #selector(NSResponder.insertTab(_:)))
        #expect(width.integerValue == 315 && height.currentEditor() != nil)
        try edit(height, value: "888", command: #selector(NSResponder.cancelOperation(_:)))
        #expect(height.integerValue == 190)
        try edit(width, value: "oops", command: #selector(NSResponder.insertNewline(_:)))
        #expect(width.integerValue == 315)
        try edit(height, value: "9999", command: #selector(NSResponder.insertNewline(_:)))
        #expect(height.integerValue == 700)
        #expect(captured == nil)
        #expect(controller.handleShortcut(.confirmCapture))
        #expect(captured == .area(displayID: display.id, rect: CGRect(x: screen.minX + 200, y: screen.minY, width: 315, height: 700)))
        #expect(control.superview == nil)
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

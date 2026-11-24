import AppKit
import Testing
import VisionKit
@testable import Karuto

@MainActor
struct TextCaptureTests {
    @Test func doubleClickCopiesOnlyTheWordInTheExistingOverlay() async throws {
        guard ImageAnalyzer.isSupported else { return }
        let ui = CaptureUIController()
        let board = NSPasteboard(name: .init("Karuto-Inline-OCR-\(UUID())"))
        defer { ui.dismiss(); board.releaseGlobally() }
        board.setString("Original clipboard", forType: .string)
        ui.copyRecognizedText = { try TextCaptureService.copy($0, to: board) }
        let display = CaptureDisplay(id: 41, name: "OCR fixture", frame: CGRect(x: 30, y: 40, width: 640, height: 360), scale: 1)
        let font = NSFont.systemFont(ofSize: 40)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let image = NSImage(size: display.frame.size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Karuto zebra preview" as NSString).draw(at: CGPoint(x: 30, y: 225), withAttributes: attributes)
            return true
        }
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var samples: [CaptureTarget] = []
        ui.samplePreview = { target in samples.append(target); return pixels }
        var captures = 0
        ui.onCapture = { _, _, _, _, _ in captures += 1 }
        ui.present(catalog: CaptureCatalog(displays: [display], windows: []))
        ui.instantCapture = true
        let windowsBefore = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        ui.handleShortcut(.toggleOCR)
        let preview = try #require(NSApp.windows.compactMap(\.contentView).flatMap(\.subviews).compactMap { $0 as? InlineTextPreview }.first)
        let window = try #require(preview.window)
        let deadline = ContinuousClock.now + .seconds(15)
        while preview.isReading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(preview.text.text.contains("Karuto zebra preview"))
        #expect(board.string(forType: .string) == "Original clipboard")
        #expect(samples == [.display(id: display.id)])
        let x = 30 + ("Karuto " as NSString).size(withAttributes: attributes).width
            + ("zebra" as NSString).size(withAttributes: attributes).width / 2
        let point = preview.convert(CGPoint(x: x, y: 248), to: nil)
        try #require(preview.hasText(at: preview.convert(point, from: nil)))
        let hit = try #require(window.contentView?.hitTest(point))
        try #require(hit === preview.text || hit.isDescendant(of: preview.text))
        // Give AppKit a turn to transfer focus from the toolbar between the two clicks.
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            if count == 1 {
                let focusDeadline = ContinuousClock.now + .seconds(2)
                while !window.isKeyWindow, ContinuousClock.now < focusDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        let copyDeadline = ContinuousClock.now + .seconds(3)
        while board.string(forType: .string) != "zebra", ContinuousClock.now < copyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(preview.text.selectedText == "zebra")
        #expect(board.string(forType: .string) == "zebra")
        let passage = try #require(preview.text.text.range(of: "zebra preview"))
        preview.text.selectedRanges = [passage]
        let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(ui.handleKeyEvent(copy))
        #expect(board.string(forType: .string) == "zebra preview")
        #expect(ui.handleShortcut(.confirmCapture))
        #expect(board.string(forType: .string) == preview.text.text)
        #expect(window.isVisible)
        #expect(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)) == windowsBefore)
        #expect(captures == 0)
        ui.handleShortcut(.toggleOCR)
        #expect(preview.superview == nil)
        #expect(preview.text.analysis == nil)
    }

    @Test func changingTheAreaWithInstantCaptureCancelsStaleOCR() async throws {
        let ui = CaptureUIController()
        defer { ui.dismiss() }
        let display = CaptureDisplay(id: 74, name: "Offset display", frame: CGRect(x: -900, y: 120, width: 640, height: 400), scale: 2)
        var samples: [CaptureTarget] = []
        var cancelled: [CaptureTarget] = []
        ui.samplePreview = { target in
            samples.append(target)
            do { try await Task.sleep(for: .seconds(20)) }
            catch { cancelled.append(target); throw error }
            throw CaptureError.targetMissing
        }
        var captures = 0
        ui.onCapture = { _, _, _, _, _ in captures += 1 }
        ui.present(catalog: CaptureCatalog(displays: [display], windows: []))
        ui.instantCapture = true
        ui.ocrEnabled = true
        let original = try #require(NSApp.windows.compactMap(\.contentView).flatMap(\.subviews).compactMap { $0 as? InlineTextPreview }.first)
        let window = try #require(original.window)
        let canvas = try #require(window.contentView?.subviews.first)
        await Task.yield()
        let points: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, CGPoint(x: 80, y: 70)), (.leftMouseDragged, CGPoint(x: 430, y: 280)), (.leftMouseUp, CGPoint(x: 430, y: 280))]
        for (type, point) in points {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        let crop = try #require(window.contentView?.subviews.compactMap { $0 as? InlineTextPreview }.first)
        let area = CGRect(x: 80, y: 70, width: 350, height: 210)
        #expect(crop.frame == area)
        #expect(original.superview == nil)
        let target = CaptureTarget.area(displayID: display.id, rect: area.offsetBy(dx: window.frame.minX, dy: window.frame.minY))
        #expect(crop.target == target)
        let deadline = ContinuousClock.now + .seconds(2)
        while samples.count < 2 || cancelled.isEmpty {
            if ContinuousClock.now > deadline { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(samples == [.display(id: display.id), target])
        #expect(cancelled == [.display(id: display.id)])
        ui.handleShortcut(.confirmCapture)
        #expect(captures == 0)
        ui.ocrEnabled = false
        #expect(crop.superview == nil)
        ui.handleShortcut(.confirmCapture)
        #expect(captures == 1)
    }

    @Test func fullscreenAndWindowReadVisiblePixelsAndBlankTextLeavesClipboardAlone() async throws {
        guard ImageAnalyzer.isSupported else { return }
        let ui = CaptureUIController()
        defer { ui.dismiss() }
        let display = CaptureDisplay(id: 42, name: "Preview", frame: CGRect(x: 20, y: 35, width: 700, height: 450), scale: 1)
        let frame = CGRect(x: 100, y: 200, width: 260, height: 140)
        let source = CaptureWindow(id: 19, title: "Example", applicationName: "Test", frame: frame)
        var copies = 0
        ui.copyRecognizedText = { _ in copies += 1; return true }
        var samples: [CaptureTarget] = []
        let blank = NSImage(size: frame.size, flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let image = try #require(blank.cgImage(forProposedRect: nil, context: nil, hints: nil))
        ui.samplePreview = { samples.append($0); return image }
        ui.present(catalog: CaptureCatalog(displays: [display], windows: [source]), initialRegion: .fullscreen)
        ui.ocrEnabled = true
        let preview = try #require(NSApp.windows.compactMap(\.contentView).flatMap(\.subviews).compactMap { $0 as? InlineTextPreview }.first)
        let window = try #require(preview.window)
        let deadline = ContinuousClock.now + .seconds(10)
        while preview.isReading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(preview.status == "No text found")
        ui.handleShortcut(.confirmCapture)
        #expect(copies == 0)
        #expect(samples == [.display(id: display.id)])
        ui.setRegion(.window)
        let canvas = try #require(window.contentView?.subviews.first)
        let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: click)
        let cropped = try #require(window.contentView?.subviews.compactMap { $0 as? InlineTextPreview }.first)
        #expect(cropped.target == .area(displayID: display.id, rect: frame))
        #expect(cropped.frame == frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
        ui.setRegion(.scrolling)
        #expect(!ui.capturesText)
        #expect(cropped.superview == nil)
        #expect(copies == 0)
    }

    @Test func OCRToolbarKeepsItsPositionWithoutAConfirmationButton() throws {
        _ = NSApplication.shared
        let ui = CaptureUIController()
        let display = CaptureDisplay(id: 41, name: "Test", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        ui.present(catalog: CaptureCatalog(displays: [display], windows: []))
        defer { ui.dismiss() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).filter { $0 is CaptureToolbarView }
            .flatMap(descendants).compactMap { $0 as? CaptureToolbarButton }
        let button = try #require(buttons.first { $0.accessibilityLabel() == "Recognize text" })
        button.window?.contentView?.layoutSubtreeIfNeeded()
        let frame = button.convert(button.bounds, to: nil)
        for enabled in [true, false] {
            ui.ocrEnabled = enabled
            button.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(button.symbolName == "text.viewfinder")
            #expect(button.state == (enabled ? .on : .off))
            #expect(!buttons.contains { ["Capture", "Copy All Text", "Continue"].contains($0.accessibilityLabel() ?? "") })
            #expect(button.convert(button.bounds, to: nil) == frame)
        }
        ui.setRegion(.scrolling)
        #expect(!button.isEnabled)
        #expect(!button.isHidden)
    }

    @Test func OCRIsIndependentOfTargetAndUnavailableForOtherModes() {
        let ui = CaptureUIController()
        #expect(!ui.capturesText)
        #expect(ui.handleShortcut(.toggleOCR))
        for region in [CaptureRegion.area, .window, .fullscreen] {
            ui.setRegion(region)
            #expect(ui.capturesText)
        }
        ui.setRegion(.scrolling)
        #expect(!ui.capturesText)
        #expect(!ui.handleShortcut(.toggleOCR))
        ui.setMode(.screenRecording)
        #expect(!ui.capturesText)
        #expect(!ui.handleShortcut(.toggleOCR))
        ui.setMode(.snapshot)
        ui.setRegion(.area)
        #expect(ui.capturesText)
        ui.handleShortcut(.toggleOCR)
        #expect(!ui.capturesText)
    }

    @Test func OCRShortcutPersistsWithoutChangingOpenCapture() throws {
        let original = KeymapConfiguration()
        let updated = try original.setting(ShortcutBinding(keyCode: 31, modifiers: []), for: .toggleOCR).validated()
        let restored = try JSONDecoder().decode(KeymapConfiguration.self, from: JSONEncoder().encode(updated))
        #expect(restored.binding(for: .toggleOCR) == updated.binding(for: .toggleOCR))
        #expect(restored.binding(for: .openCapture) == original.binding(for: .openCapture))
        #expect(ShortcutAction.toggleOCR.scope == .overlay)
    }

    @Test func EmptyAndCancelledOCRPreserveClipboard() async throws {
        let board = NSPasteboard(name: .init("Karuto-OCR-\(UUID())"))
        defer { board.releaseGlobally() }
        try #require(board.setString("Keep me", forType: .string))
        #expect(try !TextCaptureService.copy(" \n", to: board))
        #expect(board.string(forType: .string) == "Keep me")
        let pending = Task { try TextCaptureService.copy("Late result", to: board) }
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled OCR published text") }
        catch is CancellationError { }
        #expect(board.string(forType: .string) == "Keep me")
        #expect(try TextCaptureService.copy("First line\nSecond line", to: board))
        #expect(board.string(forType: .string) == "First line\nSecond line")
        #expect(board.data(forType: .png) == nil)
    }
}

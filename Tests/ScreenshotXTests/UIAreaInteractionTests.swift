import AppKit
import Testing
@testable import ScreenshotX

@MainActor
struct UIAreaInteractionTests {
    @Test func firstDragCapturesFinalReleaseEndpointExactlyOnce() throws {
        let fixture = Fixture()
        #expect(!fixture.window.isVisible)
        #expect(!fixture.window.isKeyWindow)
        #expect(fixture.view.acceptsFirstMouse(for: nil))
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 350, y: 250))
        #expect(fixture.captures.isEmpty)
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        #expect(fixture.captures.count == 1)
        let result = try #require(fixture.captures.first)
        #expect(result.0 == .area)
        #expect(result.1 == .area(displayID: 41, rect: CGRect(x: -900, y: 300, width: 300, height: 200)))
        fixture.send(.leftMouseUp, at: CGPoint(x: 500, y: 400))
        #expect(fixture.captures.count == 1)
    }

    @Test func clickTinyGestureAndReleaseWithoutDownDoNotCapture() {
        let fixture = Fixture()
        fixture.send(.leftMouseUp, at: CGPoint(x: 500, y: 400))
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 101, y: 101))
        fixture.send(.leftMouseUp, at: CGPoint(x: 101, y: 101))
        #expect(fixture.captures.isEmpty)
    }

    @Test func dismissedGestureCannotCaptureOnLateRelease() {
        let fixture = Fixture()
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        fixture.controller.dismiss()
        fixture.send(.leftMouseUp, at: CGPoint(x: 450, y: 350))
        #expect(fixture.captures.isEmpty)
    }

    @Test func resettingModeCancelsGestureBeforeRelease() {
        let fixture = Fixture()
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        fixture.controller.setMode(.area)
        fixture.send(.leftMouseUp, at: CGPoint(x: 450, y: 350))
        #expect(fixture.captures.isEmpty)
    }

    @Test(arguments: [CaptureMode.scrolling, .recording, .timer])
    func otherAreaBasedModesRemainStaged(mode: CaptureMode) {
        let fixture = Fixture(mode: mode)
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        fixture.send(.leftMouseUp, at: CGPoint(x: 450, y: 350))
        #expect(fixture.captures.isEmpty)
    }

    @Test func clickOverExistingSelectionNeverCapturesStaleRectangle() {
        let fixture = Fixture()
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        // A new down event replaces the in-flight gesture while its rectangle
        // remains available for moving/resizing. A click alone must not capture it.
        fixture.send(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        fixture.send(.leftMouseUp, at: CGPoint(x: 250, y: 200))
        #expect(fixture.captures.isEmpty)
    }

    @Test func nonInstantSelectionCanMoveAndResizeBeforeReturn() throws {
        let fixture = Fixture()
        fixture.controller.instantCapture = false
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 350, y: 250))
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        #expect(fixture.captures.isEmpty)
        // Move the retained selection, then resize its top-right corner.
        fixture.send(.leftMouseDown, at: CGPoint(x: 200, y: 200))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 220, y: 230))
        fixture.send(.leftMouseUp, at: CGPoint(x: 220, y: 230))
        fixture.send(.leftMouseDown, at: CGPoint(x: 420, y: 330))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 470, y: 380))
        fixture.send(.leftMouseUp, at: CGPoint(x: 470, y: 380))
        #expect(fixture.captures.isEmpty)
        #expect(fixture.controller.handleShortcut(.confirmCapture))
        #expect(fixture.captures.count == 1)
        let result = try #require(fixture.captures.first)
        #expect(result.1 == .area(displayID: 41, rect: CGRect(x: -880, y: 330, width: 350, height: 250)))
    }

    @Test func menuTogglesExposeCurrentValuesAndNotifyOnce() {
        let fixture = Fixture()
        var instantChanges: [Bool] = []
        var freezeChanges: [Bool] = []
        fixture.controller.onInstantCaptureChange = { instantChanges.append($0) }
        fixture.controller.onFreezeDisplayChange = { freezeChanges.append($0) }
        let menu = fixture.controller.makeOptionsMenu()
        #expect(menu.items.filter { $0.action != nil }.map(\.title) == ["Instant Capture", "Freeze Display During Capture", "Keyboard Shortcuts…", "Settings…"])
        #expect(menu.items.dropFirst().prefix(2).map(\.state) == [.on, .off])
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 2)
        #expect(instantChanges == [false])
        #expect(freezeChanges == [true])
        #expect(!fixture.controller.instantCapture)
        #expect(fixture.controller.freezeDisplay)
        #expect(fixture.controller.makeOptionsMenu().items.dropFirst().prefix(2).map(\.state) == [.off, .on])
    }

    @Test func overlayActionsAndMenuNavigationStayDistinct() {
        let fixture = Fixture()
        var openedKeymap = 0
        var openedPreferences = 0
        var instantChanges: [Bool] = []
        var freezeChanges: [Bool] = []
        fixture.controller.onOpenKeymap = { openedKeymap += 1 }
        fixture.controller.onOpenPreferences = { openedPreferences += 1 }
        fixture.controller.onInstantCaptureChange = { instantChanges.append($0) }
        fixture.controller.onFreezeDisplayChange = { freezeChanges.append($0) }
        #expect(!fixture.controller.handleShortcut(.preferences))
        #expect(!fixture.controller.handleShortcut(.keymap))
        #expect(fixture.controller.handleShortcut(.toggleInstantCapture))
        #expect(fixture.controller.handleShortcut(.toggleFreezeDisplay))
        #expect(instantChanges == [false])
        #expect(freezeChanges == [true])
        let menu = fixture.controller.makeOptionsMenu()
        menu.performActionForItem(at: 4)
        menu.performActionForItem(at: 5)
        #expect(openedKeymap == 1)
        #expect(openedPreferences == 1)
        #expect(fixture.controller.handleShortcut(.windowMode))
        #expect(fixture.controller.selectedMode == .window)
        #expect(fixture.controller.handleShortcut(.areaMode))
        #expect(fixture.controller.selectedMode == .area)
    }

    @Test func missingKeymapDoesNotInstallImplicitReturnShortcut() throws {
        let fixture = Fixture()
        fixture.controller.instantCapture = false
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        #expect(!fixture.controller.handleKeyEvent(event))
        #expect(fixture.captures.isEmpty)
        #expect(fixture.controller.handleShortcut(.confirmCapture))
        #expect(fixture.captures.count == 1)
    }

    @Test func clearingConfirmBindingRemovesReturnAndKeypadEnter() throws {
        let fixture = Fixture()
        fixture.controller.instantCapture = false
        let suite = "ScreenshotXTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.keymap = KeymapConfiguration().setting(nil, for: .confirmCapture)
        let keymap = KeymapController(settings: settings)
        defer { keymap.shutdown() }
        fixture.controller.keymap = keymap
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        for keyCode in [UInt16(36), 76] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: keyCode))
            #expect(!fixture.controller.handleKeyEvent(event))
        }
        #expect(fixture.captures.isEmpty)
        #expect(fixture.view.accessibilityHelp()?.contains("click Capture") == true)
        #expect(fixture.controller.handleShortcut(.confirmCapture))
        #expect(fixture.captures.count == 1)
    }

    @Test func frozenBackdropOrientationModeVisibilityAndRelease() throws {
        _ = NSApplication.shared
        let controller = CaptureUIController()
        let display = CaptureDisplay(id: 42, name: "Frozen test", frame: CGRect(x: 0, y: 0, width: 40, height: 40), scale: 1)
        // CGImage scanlines are top-to-bottom: red top, blue bottom.
        let pixels: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let view = controller.makeSelectionOverlay(for: display, frozenFrame: image)
        let layer = try #require(view.layer)
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        layer.render(in: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Calibrate memory rows independently of CALayer: the context uses
        // bottom-left coordinates, but its bitmap memory starts at the top row.
        let calibration = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        calibration.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        calibration.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        calibration.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        calibration.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let reference = try #require(calibration.data).assumingMemoryBound(to: UInt8.self)
        let top = 5 * 160 + 20 * 4
        let bottom = 35 * 160 + 20 * 4
        #expect(reference[top] > reference[top + 2])
        #expect(reference[bottom + 2] > reference[bottom])
        #expect(bytes[top] > bytes[top + 2])
        #expect(bytes[bottom + 2] > bytes[bottom])
        for mode in [CaptureMode.recording, .scrolling, .timer] {
            controller.setMode(mode)
            #expect(layer.contents == nil)
        }
        for mode in [CaptureMode.area, .fullscreen, .window] {
            controller.setMode(mode)
            #expect(layer.contents != nil)
        }
        controller.dismiss()
        #expect(layer.contents == nil)
    }

    @MainActor
    private final class Fixture {
        let controller = CaptureUIController()
        let window: NSWindow
        let view: NSView
        var captures: [(CaptureMode, CaptureTarget)] = []

        init(mode: CaptureMode = .area) {
            _ = NSApplication.shared
            let display = CaptureDisplay(id: 41, name: "Offscreen test", frame: CGRect(x: -1000, y: 200, width: 800, height: 600), scale: 2)
            controller.setMode(mode)
            view = controller.makeSelectionOverlay(for: display)
            window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            controller.onCapture = { [weak self] mode, target in self?.captures.append((mode, target)) }
        }

        func send(_ type: NSEvent.EventType, at location: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: preconditionFailure("Unsupported test event")
            }
        }
    }
}

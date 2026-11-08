import AppKit
import Testing
@testable import Karuto

@MainActor
struct UIAreaInteractionTests {
    @Test func scrollingSuggestionDiscardsStaleQueryAndPreservesInputPoint() async throws {
        let first = CGRect(x: -940, y: 260, width: 180, height: 200)
        let second = CGRect(x: -690, y: 270, width: 140, height: 160)
        let window = CaptureWindow(id: 902, title: "Panes", applicationName: "Example", frame: CGRect(x: -950, y: 250, width: 500, height: 350))
        let fixture = Fixture(mode: .scrolling, windows: [window])
        defer { fixture.controller.dismiss() }
        let gate = ScrollQueryGate(first: first, second: second)
        fixture.controller.scrollRegionQuery = { request in await gate.resolve(request) }
        fixture.send(.mouseMoved, at: CGPoint(x: 100, y: 100))
        // Other native UI tests share MainActor and can delay this task's first
        // scheduling opportunity. Wait for the query, not a fixed sleep.
        let startedDeadline = ContinuousClock.now + .seconds(10)
        while await gate.count == 0 && ContinuousClock.now < startedDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.count == 1)
        fixture.send(.mouseMoved, at: CGPoint(x: 350, y: 120))
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(10)
        while !layerText(fixture.view.layer).contains("Suggested scrolling area") && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(layerText(fixture.view.layer).contains("Suggested scrolling area"))
        var inputPoint: CGPoint?
        fixture.controller.onScrollInputPoint = { inputPoint = $0 }
        fixture.send(.leftMouseDown, at: CGPoint(x: 350, y: 120))
        fixture.send(.leftMouseUp, at: CGPoint(x: 350, y: 120))
        fixture.controller.handleShortcut(.confirmCapture)
        #expect(fixture.captures.first?.1 == .area(displayID: 41, rect: second))
        #expect(inputPoint == CGPoint(x: -650, y: 320))
    }

    private func layerText(_ layer: CALayer?) -> String {
        guard let layer else { return "" }
        let own = (layer as? CATextLayer)?.string as? NSAttributedString
        return (own?.string ?? "") + (layer.sublayers ?? []).map { layerText($0) }.joined()
    }

    @Test(arguments: [true, false])
    func cancelDuringDragClearsAndIgnoresLateMouseEvents(instant: Bool) throws {
        let fixture = Fixture()
        fixture.controller.instantCapture = instant
        let keymap = try cancelKeymap()
        fixture.controller.keymap = keymap
        defer { keymap.shutdown() }
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 350, y: 250))
        #expect(try fixture.controller.handleKeyEvent(cancelEvent(fixture.window)))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        #expect(fixture.captures.isEmpty)
        #expect(fixture.cancellations == 0)
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        if !instant { fixture.controller.handleShortcut(.confirmCapture) }
        #expect(fixture.captures.count == 1)
    }

    @Test func cancelClearsStagedAreaThenClosesOverlay() throws {
        let fixture = Fixture()
        fixture.controller.instantCapture = false
        let keymap = try cancelKeymap()
        fixture.controller.keymap = keymap
        defer { keymap.shutdown() }
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 400, y: 300))
        #expect(try fixture.controller.handleKeyEvent(cancelEvent(fixture.window)))
        #expect(fixture.cancellations == 0)
        fixture.controller.handleShortcut(.confirmCapture)
        #expect(fixture.captures.isEmpty)
        #expect(try fixture.controller.handleKeyEvent(cancelEvent(fixture.window)))
        #expect(fixture.cancellations == 1)
    }

    @Test func emptyOverlayClosesAndCancelBindingRemainsConfigurable() throws {
        let fixture = Fixture()
        let keymap = try cancelKeymap(binding: ShortcutBinding(keyCode: 7, modifiers: [.control]))
        fixture.controller.keymap = keymap
        defer { keymap.shutdown() }
        #expect(try !fixture.controller.handleKeyEvent(cancelEvent(fixture.window)))
        #expect(fixture.cancellations == 0)
        let custom = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(fixture.controller.handleKeyEvent(custom))
        #expect(fixture.cancellations == 1)
    }

    private func cancelKeymap(binding: ShortcutBinding = ShortcutBinding(keyCode: 53, modifiers: [])) throws -> KeymapController {
        let suite = "KarutoTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.keymap = KeymapConfiguration().setting(binding, for: .cancelCapture)
        return KeymapController(settings: settings)
    }

    private func cancelEvent(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    @Test(arguments: [CaptureMode.area, .scrolling])
    func windowProposalUsesAreaCompletionAndRemainsAdjustable(mode: CaptureMode) throws {
        let bounds = CGRect(x: -950, y: 250, width: 400, height: 300)
        let candidate = CaptureWindow(id: 901, title: "Example", applicationName: "Example", frame: bounds)
        let fixture = Fixture(mode: mode, windows: [candidate])
        fixture.controller.instantCapture = false
        fixture.send(.mouseMoved, at: CGPoint(x: 100, y: 100))
        #expect(fixture.captures.isEmpty)
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 100, y: 100))
        #expect(fixture.captures.isEmpty)
        #expect(fixture.controller.handleShortcut(.confirmCapture))
        #expect(fixture.captures.first?.1 == .area(displayID: 41, rect: bounds))
    }

    @Test func windowProposalInstantClickAndManualDragShareCompletion() {
        let candidate = CaptureWindow(id: 901, title: "Example", applicationName: "Example", frame: CGRect(x: -950, y: 250, width: 400, height: 300))
        let fixture = Fixture(windows: [candidate])
        fixture.send(.mouseMoved, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 100, y: 100))
        #expect(fixture.captures.first?.1 == .area(displayID: 41, rect: candidate.frame))
        let dragged = Fixture(windows: [candidate])
        dragged.send(.mouseMoved, at: CGPoint(x: 100, y: 100))
        dragged.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        dragged.send(.leftMouseDragged, at: CGPoint(x: 200, y: 200))
        dragged.send(.leftMouseUp, at: CGPoint(x: 200, y: 200))
        #expect(dragged.captures.first?.1 == .area(displayID: 41, rect: CGRect(x: -900, y: 300, width: 100, height: 100)))
    }

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
        let suite = "KarutoTests." + UUID().uuidString
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
        var cancellations = 0

        init(mode: CaptureMode = .area, windows: [CaptureWindow] = []) {
            _ = NSApplication.shared
            let display = CaptureDisplay(id: 41, name: "Offscreen test", frame: CGRect(x: -1000, y: 200, width: 800, height: 600), scale: 2)
            if !windows.isEmpty {
                controller.present(catalog: CaptureCatalog(displays: [display], windows: windows), initialMode: mode)
                NSApp.windows.forEach { $0.orderOut(nil) }
            }
            controller.setMode(mode)
            view = controller.makeSelectionOverlay(for: display)
            window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            controller.onCapture = { [weak self] mode, target in self?.captures.append((mode, target)) }
            controller.onCancel = { [weak self] in self?.cancellations += 1 }
        }

        func send(_ type: NSEvent.EventType, at location: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            case .mouseMoved: view.mouseMoved(with: event)
            default: preconditionFailure("Unsupported test event")
            }
        }
    }
}

private actor ScrollQueryGate {
    private let first: CGRect
    private let second: CGRect
    private(set) var count = 0
    private var continuation: CheckedContinuation<CGRect?, Never>?
    init(first: CGRect, second: CGRect) { self.first = first; self.second = second }
    func resolve(_ request: ScrollRegionRequest) async -> CGRect? {
        count += 1
        if count == 1 { return await withCheckedContinuation { continuation = $0 } }
        return second
    }
    func release() { continuation?.resume(returning: first); continuation = nil }
}

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

    @Test(arguments: [CaptureRegion.area, .scrolling])
    func windowProposalUsesAreaCompletionAndRemainsAdjustable(mode: CaptureRegion) throws {
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

    @Test func toolbarHidesDuringDragAndWaitsAfterRelease() async throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let fixture = Fixture(showsToolbar: true)
        defer { fixture.controller.dismiss() }
        fixture.controller.instantCapture = false
        let toolbar = try #require(NSApp.windows.first {
            $0.contentView is CaptureToolbarView && !existing.contains(ObjectIdentifier($0))
        })
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        #expect(toolbar.alphaValue == 0)
        #expect(toolbar.ignoresMouseEvents)
        fixture.send(.leftMouseUp, at: CGPoint(x: 450, y: 350))
        #expect(toolbar.ignoresMouseEvents)
        let deadline = ContinuousClock.now + .seconds(4)
        while toolbar.ignoresMouseEvents && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!toolbar.ignoresMouseEvents)
        #expect(fixture.captures.isEmpty)
    }

    @Test func resettingModeCancelsGestureBeforeRelease() {
        let fixture = Fixture()
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        fixture.controller.setRegion(.area)
        fixture.send(.leftMouseUp, at: CGPoint(x: 450, y: 350))
        #expect(fixture.captures.isEmpty)
    }

    @Test(arguments: [CaptureMode.snapshot, .screenRecording])
    func scrollingAndRecordingAreasRemainStaged(mode: CaptureMode) {
        let region: CaptureRegion = mode == .snapshot ? .scrolling : .area
        let fixture = Fixture(mode: region)
        fixture.controller.setMode(mode)
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 400, y: 300))
        fixture.send(.leftMouseUp, at: CGPoint(x: 450, y: 350))
        #expect(fixture.captures.isEmpty)
        var routedMode: CaptureMode?
        var routedRegion: CaptureRegion?
        fixture.controller.onCapture = { mode, region, _, _, _ in
            routedMode = mode
            routedRegion = region
        }
        #expect(fixture.controller.handleShortcut(.confirmCapture))
        #expect(routedMode == mode)
        #expect(routedRegion == region)
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

    @Test func annotationGesturesExportOnceAndUndoRenumbersCounters() throws {
        let fixture = Fixture()
        fixture.controller.instantCapture = false
        fixture.send(.leftMouseDown, at: CGPoint(x: 80, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 380, y: 300))
        let editor = fixture.controller.editor
        editor.select(.counter)
        fixture.send(.leftMouseDown, at: CGPoint(x: 110, y: 130))
        fixture.send(.leftMouseUp, at: CGPoint(x: 110, y: 130))
        fixture.send(.leftMouseDown, at: CGPoint(x: 190, y: 200))
        fixture.send(.leftMouseUp, at: CGPoint(x: 210, y: 225))
        #expect(editor.marks.map(\.label) == ["1", "2"])
        #expect(fixture.controller.handleShortcut(.undoAnnotation))
        #expect(editor.marks.map(\.label) == ["1"])
        #expect(fixture.controller.handleShortcut(.redoAnnotation))
        #expect(editor.marks.map(\.label) == ["1", "2"])
        editor.undo()
        fixture.send(.leftMouseDown, at: CGPoint(x: 200, y: 150))
        fixture.send(.leftMouseUp, at: CGPoint(x: 200, y: 150))
        #expect(editor.marks.map(\.label) == ["1", "2"])
        #expect(!editor.canRedo)
        editor.select(.mosaic)
        fixture.send(.leftMouseDown, at: CGPoint(x: 120, y: 140))
        fixture.send(.leftMouseDragged, at: CGPoint(x: 160, y: 170))
        fixture.send(.leftMouseUp, at: CGPoint(x: 180, y: 180))
        let last = try #require(editor.marks.last)
        #expect(last.rect == CGRect(x: 40, y: 40, width: 60, height: 40))
        var exported: [AreaAnnotation] = []
        fixture.controller.onCapture = { _, region, _, marks, _ in
            #expect(region == .area)
            exported = marks
        }
        fixture.controller.handleShortcut(.confirmCapture)
        #expect(exported.map(\.tool) == [.counter, .counter, .mosaic])
        #expect(editor.marks.isEmpty)
    }

    @Test func lastRegionIsStagedOnDemandEvenWithInstantCapture() {
        let fixture = Fixture(showsToolbar: true)
        defer { fixture.controller.dismiss() }
        let target = CaptureTarget.area(displayID: 41, rect: CGRect(x: -880, y: 330, width: 320, height: 220))
        fixture.controller.previousArea = { (target, .zero) }
        #expect(!fixture.controller.handleShortcut(.selectLastArea))
        fixture.controller.previousArea = { (target, fixture.window.frame) }
        #expect(fixture.controller.handleShortcut(.selectLastArea))
        #expect(fixture.captures.isEmpty)
        #expect(fixture.controller.instantCapture)
        fixture.controller.editor.select(.arrow)
        fixture.send(.leftMouseDown, at: CGPoint(x: 160, y: 160))
        fixture.send(.leftMouseUp, at: CGPoint(x: 200, y: 200))
        #expect(fixture.controller.editor.marks.count == 1)
        #expect(fixture.controller.handleShortcut(.confirmCapture))
        #expect(fixture.captures.first?.1 == target)
        fixture.controller.previousArea = nil
    }

    @Test(arguments: [ShortcutAction.copyScreenshot, .saveScreenshot])
    func stagedScreenshotShortcutsUseTheKeymapAndIncludeAnnotations(_ action: ShortcutAction) throws {
        let fixture = Fixture()
        defer { fixture.controller.dismiss() }
        let suite = "Karuto-Staged-Shortcuts-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keymap = KeymapController(settings: AppSettings(defaults: defaults))
        fixture.controller.keymap = keymap
        let binding = try #require(keymap.configuration.binding(for: action))
        func key(_ binding: ShortcutBinding) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: binding.modifierFlags,
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                characters: binding.menuKeyEquivalent, charactersIgnoringModifiers: binding.menuKeyEquivalent,
                isARepeat: false, keyCode: binding.keyCode))
        }
        let original = try key(binding)
        fixture.controller.instantCapture = false
        #expect(!fixture.controller.handleKeyEvent(original))
        fixture.send(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 320, y: 250))
        fixture.controller.instantCapture = true
        #expect(!fixture.controller.handleKeyEvent(original))
        fixture.controller.instantCapture = false
        fixture.controller.ocrEnabled = true
        #expect(!fixture.controller.handleKeyEvent(original))
        fixture.controller.ocrEnabled = false
        fixture.controller.editor.select(.text)
        fixture.send(.leftMouseDown, at: CGPoint(x: 160, y: 140))
        #expect(!fixture.controller.handleKeyEvent(original))
        fixture.controller.editor.cancelDraft()
        fixture.controller.editor.select(.arrow)
        fixture.send(.leftMouseDown, at: CGPoint(x: 140, y: 140))
        fixture.send(.leftMouseUp, at: CGPoint(x: 190, y: 180))
        let marks = fixture.controller.editor.marks
        try #require(marks.count == 1)
        try keymap.update(action: action, binding: nil)
        #expect(!fixture.controller.handleKeyEvent(original))
        let replacement = ShortcutBinding(keyCode: 7, modifiers: [.command, .option])
        try keymap.update(action: action, binding: replacement)
        #expect(!fixture.controller.handleKeyEvent(original))
        var deliveries: [SnapshotDestination] = []
        fixture.controller.onCapture = { mode, region, target, annotations, destination in
            #expect(mode == .snapshot && region == .area)
            #expect(target == .area(displayID: 41, rect: CGRect(x: -900, y: 300, width: 220, height: 150)))
            #expect(annotations == marks)
            deliveries.append(destination)
        }
        #expect(try fixture.controller.handleKeyEvent(key(replacement)))
        #expect(deliveries == [action == .copyScreenshot ? .clipboard : .saveFolder])
        #expect(try !fixture.controller.handleKeyEvent(key(replacement)))
    }

    @Test func paletteButtonsCommitTypedTextAndReturnToAdjusting() throws {
        let fixture = Fixture(showsToolbar: true)
        defer { fixture.controller.dismiss() }
        fixture.controller.instantCapture = false
        fixture.send(.leftMouseDown, at: CGPoint(x: 80, y: 100))
        fixture.send(.leftMouseUp, at: CGPoint(x: 380, y: 300))
        let panel = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "Area annotation tools" })
        func buttons(_ view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        let tools = buttons(try #require(panel.contentView))
        #expect(AnnotationTool.allCases.allSatisfy { tool in tools.contains { $0.accessibilityLabel() == tool.rawValue && $0.image != nil } })
        try #require(tools.first { $0.accessibilityLabel() == "Text" }).performClick(nil)
        fixture.send(.leftMouseDown, at: CGPoint(x: 120, y: 140))
        fixture.send(.leftMouseUp, at: CGPoint(x: 120, y: 140))
        let responder = try annotationTextView()
        responder.insertText("Release notes", replacementRange: NSRange(location: 0, length: 0))
        responder.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(fixture.controller.editor.marks.first?.label == "Release notes")
        #expect(!fixture.controller.editor.isTyping)
        try #require(tools.first { $0.accessibilityLabel() == "Adjust selection" }).performClick(nil)
        #expect(fixture.controller.editor.tool == .select)
        try #require(tools.first { $0.accessibilityLabel() == "Capture" }).performClick(nil)
        #expect(fixture.captures.count == 1)
    }

    private func annotationTextView() throws -> NSTextView {
        let window = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "Edit annotation text" })
        return try #require((window.contentView as? NSScrollView)?.documentView as? NSTextView)
    }

    @Test(arguments: [false, true])
    func escapeFinishesTextBeforeOverlayCancel(editingSize: Bool) async throws {
        let fixture = Fixture(showsToolbar: true)
        defer { fixture.controller.dismiss() }
        fixture.controller.instantCapture = false
        fixture.controller.keymap = editingSize
            ? try cancelKeymap(binding: ShortcutBinding(keyCode: 7, modifiers: .control))
            : try cancelKeymap()
        let origin = CGPoint(x: 60, y: 80)
        fixture.send(.leftMouseDown, at: origin)
        fixture.send(.leftMouseUp, at: CGPoint(x: 540, y: 450))
        let editor = fixture.controller.editor
        editor.select(.text)
        fixture.send(.leftMouseDown, at: CGPoint(x: 95, y: 365))
        fixture.send(.leftMouseUp, at: CGPoint(x: 95, y: 365))
        let body = try annotationTextView()
        body.insertText("Drag this caption", replacementRange: body.selectedRange())
        let panel = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "Text formatting" })
        let input = try #require(body.window)
        if editingSize {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let controls = descendants(try #require(panel.contentView))
            let field = try #require(controls.compactMap { $0 as? NSTextField }.first { $0.isEditable })
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
            let value = try #require(field.currentEditor() as? NSTextView)
            value.insertText("32", replacementRange: NSRange(location: 0, length: value.string.utf16.count))
        }
        NSApp.postEvent(try cancelEvent(editingSize ? panel : input), atStart: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while editor.isTyping, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!editor.isTyping)
        #expect(!input.isVisible && !panel.isVisible)
        #expect(editor.tool == .text)
        let mark = try #require(editor.marks.first)
        #expect(mark.label == "Drag this caption")
        if editingSize { #expect(mark.textStyle.size == 32) }

        let start = CGPoint(x: origin.x + mark.rect.midX, y: origin.y + mark.rect.midY)
        let end = CGPoint(x: start.x + 35, y: start.y - 20)
        fixture.send(.leftMouseDown, at: start)
        fixture.send(.leftMouseDragged, at: end)
        fixture.send(.leftMouseUp, at: end)
        #expect(editor.marks.map(\.rect) == [mark.rect.offsetBy(dx: 35, dy: -20)])
        #expect(fixture.captures.isEmpty && fixture.cancellations == 0)
        fixture.controller.handleShortcut(.confirmCapture)
        #expect(fixture.captures.first?.1 == .area(displayID: 41, rect: CGRect(x: -940, y: 280, width: 480, height: 370)))
    }

    @Test func committedTextMovesResizesAndReopensWithoutDuplicating() throws {
        let fixture = Fixture()
        defer { fixture.controller.dismiss() }
        fixture.controller.instantCapture = false
        let origin = CGPoint(x: 60, y: 80)
        fixture.send(.leftMouseDown, at: origin)
        fixture.send(.leftMouseUp, at: CGPoint(x: 540, y: 450))
        let editor = fixture.controller.editor
        editor.select(.text)
        fixture.send(.leftMouseDown, at: CGPoint(x: 95, y: 365))
        fixture.send(.leftMouseUp, at: CGPoint(x: 95, y: 365))
        let input = try annotationTextView()
        input.insertText("First caption", replacementRange: input.selectedRange())
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let original = try #require(editor.marks.first)
        func screenPoint(_ box: CGRect) -> CGPoint { CGPoint(x: origin.x + box.midX, y: origin.y + box.midY) }
        let start = screenPoint(original.rect)
        let end = CGPoint(x: start.x + 60, y: start.y - 25)
        fixture.send(.leftMouseDown, at: start)
        #expect(!editor.isTyping)
        fixture.send(.leftMouseDragged, at: end)
        fixture.send(.leftMouseUp, at: end)
        #expect(editor.marks.count == 1)
        let moved = try #require(editor.marks.first)
        #expect(moved.rect == original.rect.offsetBy(dx: 60, dy: -25))
        let corner = CGPoint(x: origin.x + moved.rect.maxX, y: origin.y + moved.rect.minY)
        fixture.send(.leftMouseDown, at: corner)
        fixture.send(.leftMouseUp, at: CGPoint(x: corner.x - 50, y: corner.y - 20))
        let resized = try #require(editor.marks.first)
        #expect(resized.rect.width == moved.rect.width - 50)
        #expect(resized.rect.height == moved.rect.height + 20)
        #expect(resized.textStyle == original.textStyle)

        let another = CGPoint(x: 115, y: 145)
        fixture.send(.leftMouseDown, at: another)
        let nextInput = try annotationTextView()
        nextInput.insertText("Second", replacementRange: nextInput.selectedRange())
        nextInput.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.marks.map(\.label) == ["First caption", "Second"])
        let center = screenPoint(resized.rect)
        fixture.send(.leftMouseDown, at: center)
        fixture.send(.leftMouseUp, at: center)
        fixture.send(.leftMouseDown, at: center, clickCount: 2)
        fixture.send(.leftMouseUp, at: center, clickCount: 2)
        let reopened = try annotationTextView()
        #expect(reopened.string == "First caption")
        reopened.insertText("Edited", replacementRange: NSRange(location: 0, length: reopened.string.utf16.count))
        reopened.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor.marks.map(\.label) == ["Edited", "Second"])
        fixture.send(.leftMouseDown, at: center, clickCount: 2)
        let edited = try annotationTextView()
        edited.insertText("Final", replacementRange: NSRange(location: 0, length: edited.string.utf16.count))
        edited.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.marks.map(\.label) == ["Final", "Second"])
        editor.undo()
        #expect(editor.marks[0].label == "Edited")
        editor.undo()
        #expect(editor.marks[0] == resized)
        editor.undo() // Second caption
        editor.undo() // Resize
        #expect(editor.marks == [moved])
        editor.undo() // Move
        #expect(editor.marks == [original])
        editor.redo()
        #expect(editor.marks == [moved])
    }

    @Test func textFormattingControlsRoundTripThroughCommitAndReopen() throws {
        let fixture = Fixture()
        defer { fixture.controller.dismiss() }
        fixture.controller.instantCapture = false
        fixture.send(.leftMouseDown, at: CGPoint(x: 40, y: 60))
        fixture.send(.leftMouseUp, at: CGPoint(x: 590, y: 500))
        let editor = fixture.controller.editor
        editor.select(.text)
        let point = CGPoint(x: 120, y: 360)
        fixture.send(.leftMouseDown, at: point)
        let body = try annotationTextView()
        body.insertText("Styled", replacementRange: body.selectedRange())
        let panel = try #require(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "Text formatting" })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(try #require(panel.contentView))
        let slider = try #require(controls.compactMap { $0 as? NSSlider }.first)
        let sizeField = try #require(controls.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        slider.doubleValue = 32
        _ = slider.sendAction(slider.action, to: slider.target)
        #expect(sizeField.integerValue == 32)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(sizeField)
        let sizeInput = try #require(sizeField.currentEditor() as? NSTextView)
        let pointSize = 47.5
        sizeInput.insertText(pointSize.formatted(), replacementRange: NSRange(location: 0, length: sizeInput.string.utf16.count))
        sizeInput.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(slider.doubleValue == pointSize)
        let alignment = try #require(controls.compactMap { $0 as? NSSegmentedControl }.first)
        alignment.selectedSegment = 2
        _ = alignment.sendAction(alignment.action, to: alignment.target)
        for label in ["Bold", "Italic", "Underline"] {
            try #require(controls.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }).performClick(nil)
        }
        try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "Done" }).performClick(nil)
        let mark = try #require(editor.marks.first)
        #expect(mark.textStyle == AnnotationTextStyle(size: pointSize, alignment: .right, bold: false, italic: true, underline: true))
        #expect(!panel.isVisible)
        let inside = CGPoint(x: 40 + mark.rect.midX, y: 60 + mark.rect.midY)
        fixture.send(.leftMouseDown, at: inside, clickCount: 2)
        let reopened = try annotationTextView()
        #expect(reopened.string == "Styled")
        let font = try #require(reopened.typingAttributes[.font] as? NSFont)
        #expect(abs(font.pointSize - CGFloat(pointSize)) < 0.001)
        #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect((reopened.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment == .right)
        #expect(reopened.typingAttributes[.underlineStyle] as? Int == 1)
        reopened.insertText("", replacementRange: NSRange(location: 0, length: reopened.string.utf16.count))
        editor.finishGesture()
        #expect(editor.marks.isEmpty)
        #expect(fixture.controller.handleShortcut(.undoAnnotation))
        #expect(editor.marks == [mark])
    }

    @Test func menuTogglesExposeCurrentValuesAndNotifyOnce() {
        let fixture = Fixture()
        var sourceChanges = 0
        fixture.controller.onSelectionSourceChange = { _ in sourceChanges += 1 }
        let menu = fixture.controller.makeOptionsMenu()
        #expect(menu.items.filter { $0.action != nil }.map(\.title) == ["Instant Capture", "Freeze Display During Capture", "Keyboard Shortcuts…", "Settings…"])
        #expect(menu.items.dropFirst().prefix(2).map(\.state) == [.on, .off])
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 2)
        #expect(sourceChanges == 1)
        #expect(!fixture.controller.instantCapture)
        #expect(fixture.controller.freezeDisplay)
        #expect(fixture.controller.makeOptionsMenu().items.dropFirst().prefix(2).map(\.state) == [.off, .on])
    }

    @Test func overlayActionsAndMenuNavigationStayDistinct() {
        let fixture = Fixture()
        var openedKeymap = 0
        var openedPreferences = 0
        var sourceChanges = 0
        fixture.controller.onOpenKeymap = { openedKeymap += 1 }
        fixture.controller.onOpenPreferences = { openedPreferences += 1 }
        fixture.controller.onSelectionSourceChange = { _ in sourceChanges += 1 }
        #expect(!fixture.controller.handleShortcut(.preferences))
        #expect(!fixture.controller.handleShortcut(.keymap))
        #expect(fixture.controller.handleShortcut(.toggleInstantCapture))
        #expect(fixture.controller.handleShortcut(.toggleFreezeDisplay))
        #expect(sourceChanges == 1)
        let menu = fixture.controller.makeOptionsMenu()
        menu.performActionForItem(at: 4)
        menu.performActionForItem(at: 5)
        #expect(openedKeymap == 1)
        #expect(openedPreferences == 1)
        #expect(fixture.controller.handleShortcut(.windowMode))
        #expect(fixture.controller.selectedRegion == .window)
        #expect(fixture.controller.handleShortcut(.areaMode))
        #expect(fixture.controller.selectedRegion == .area)
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
        #expect(fixture.view.accessibilityHelp()?.contains("choose Capture in Capture options") == true)
        let menu = fixture.controller.makeOptionsMenu()
        let item = try #require(menu.item(withTitle: "Capture"))
        menu.performActionForItem(at: menu.index(of: item))
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
        controller.handleShortcut(.toggleFreezeDisplay)
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
        controller.setMode(.screenRecording)
        #expect(layer.contents == nil)
        controller.setMode(.snapshot)
        controller.setRegion(.scrolling)
        #expect(layer.contents == nil)
        controller.setRegion(.area)
        controller.setDelay(3)
        #expect(!controller.usesFrozenSelection)
        controller.setDelay(0)
        for region in [CaptureRegion.area, .fullscreen, .window] {
            controller.setRegion(region)
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
        var captures: [(CaptureRegion, CaptureTarget)] = []
        var cancellations = 0

        init(mode: CaptureRegion = .area, windows: [CaptureWindow] = [], showsToolbar: Bool = false) {
            _ = NSApplication.shared
            controller.instantCapture = true
            let display = CaptureDisplay(id: 41, name: "Offscreen test", frame: CGRect(x: -1000, y: 200, width: 800, height: 600), scale: 2)
            if showsToolbar || !windows.isEmpty {
                controller.present(catalog: CaptureCatalog(displays: [display], windows: windows), initialRegion: mode)
                NSApp.windows.forEach { $0.orderOut(nil) }
            }
            controller.setRegion(mode)
            view = controller.makeSelectionOverlay(for: display)
            window = NSWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            controller.onCapture = { [weak self] _, region, target, _, _ in self?.captures.append((region, target)) }
            controller.onCancel = { [weak self] in self?.cancellations += 1 }
        }

        func send(_ type: NSEvent.EventType, at location: CGPoint, clickCount: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
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

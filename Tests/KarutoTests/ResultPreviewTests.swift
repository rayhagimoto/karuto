import AppKit
import Testing
@testable import Karuto

@MainActor
struct ResultPreviewTests {
    @Test func fileSizeUsesCompactDecimalUnits() {
        #expect(ResultPreviewController.formattedFileSize(0) == "0 B")
        #expect(ResultPreviewController.formattedFileSize(999) == "999 B")
        #expect(ResultPreviewController.formattedFileSize(1_000) == "1 kB")
        #expect(ResultPreviewController.formattedFileSize(1_500) == "1.5 kB")
        #expect(ResultPreviewController.formattedFileSize(999_999) == "1 MB")
        #expect(ResultPreviewController.formattedFileSize(2_500_000) == "2.5 MB")
        #expect(ResultPreviewController.formattedFileSize(1_000_000_000) == "1 GB")
    }

    @Test func everyActionDismissesBeforeCallingItsHandler() async throws {
        _ = NSApplication.shared
        let controller = ResultPreviewController()
        let artifact = makeArtifact()
        var sequence: [String] = []
        controller.onDismiss = { _ in sequence.append("dismiss") }
        controller.onCopy = { _ in sequence.append("copy") }
        controller.onSave = { _ in sequence.append("save") }
        controller.onReveal = { _ in sequence.append("reveal") }
        controller.onTrash = { _ in sequence.append("trash") }
        for (title, action) in [("Copy image", "copy"), ("Save as…", "save"), ("Reveal in Finder", "reveal"), ("Move screenshot to Trash", "trash")] {
            controller.show(artifact)
            let panel = try panel(for: artifact)
            panel.orderOut(nil)
            let button = try #require(descendants(panel.contentView).compactMap { $0 as? PreviewActionButton }.first { $0.title == title })
            #expect(button.acceptsFirstMouse(for: nil))
            sequence.removeAll()
            button.performClick(nil)
            #expect(panel.ignoresMouseEvents)
            #expect(sequence.isEmpty)
            button.performClick(nil) // Repeated action during the fade is ignored.
            try await eventually { sequence.count == 2 }
            #expect(sequence == ["dismiss", action])
            #expect(!panel.isVisible)
            #expect(panel.alphaValue == 0)
        }
    }

    @Test func imageOpensOnSingleReleaseButNotOnMovedOrOutsideRelease() throws {
        let image = DraggableCaptureImageView(artifact: makeArtifact())
        image.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        var opens = 0
        image.onOpen = { opens += 1 }
        #expect(image.acceptsFirstMouse(for: nil))
        image.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20)))
        #expect(opens == 0)
        image.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 20, y: 20)))
        #expect(opens == 1)
        image.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20)))
        image.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 40, y: 20)))
        #expect(opens == 1)
        image.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 199, y: 20)))
        image.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 201, y: 20)))
        #expect(opens == 1)
    }

    @Test func timeoutDismissesOnceAndReplacedPreviewCancelsOldTimeout() async throws {
        _ = NSApplication.shared
        let controller = ResultPreviewController()
        let artifact = makeArtifact()
        var dismissed = 0
        controller.onDismiss = { _ in dismissed += 1 }
        controller.show(artifact, autoDismissAfter: 0.01)
        try panel(for: artifact).orderOut(nil)
        try await eventually { dismissed == 1 }
        controller.dismiss(artifact.id)
        #expect(dismissed == 1)

        controller.show(artifact, autoDismissAfter: 0.01)
        let previous = try panel(for: artifact)
        previous.orderOut(nil)
        let retirement = PreviewCloseProbe(window: previous)
        await Task.yield()
        controller.show(artifact)
        let replacement = try panel(for: artifact)
        replacement.orderOut(nil)
        try await eventually { retirement.didClose }
        #expect(dismissed == 1)
        #expect(!replacement.ignoresMouseEvents)
        #expect(replacement.alphaValue == 1)
        controller.dismiss(artifact.id)
        try await eventually { dismissed == 2 }
    }

    @Test func wholePreviewHoverIgnoresChildBoundariesAndWaitsForDragRelease() throws {
        let hover = PreviewHoverView(frame: CGRect(x: 0, y: 0, width: 288, height: 232))
        let child = NSButton(frame: CGRect(x: 10, y: 10, width: 30, height: 30))
        hover.addSubview(child)
        hover.updateTrackingAreas()
        let tracking = try #require(hover.trackingAreas.first)
        #expect(tracking.options.contains(.activeAlways))
        #expect(tracking.options.contains(.enabledDuringMouseDrag))
        #expect(tracking.options.contains(.inVisibleRect))
        var exits = 0
        hover.onExit = { exits += 1 }
        hover.mouseExited(with: try mouse(.mouseMoved, at: CGPoint(x: 300, y: 100)))
        #expect(exits == 0) // No hover yet.
        hover.mouseEntered(with: try mouse(.mouseMoved, at: CGPoint(x: 20, y: 20)))
        hover.mouseExited(with: try mouse(.mouseMoved, at: CGPoint(x: 45, y: 20)))
        #expect(exits == 0) // Crossed a child boundary, still inside the card.
        hover.requestTimedDismissal()
        #expect(exits == 0) // Timer expiry waits while the card is hovered.
        hover.pointerExited(at: CGPoint(x: 300, y: 100), buttonsPressed: true)
        #expect(exits == 0)
        hover.finishInteraction(at: CGPoint(x: 20, y: 20))
        #expect(exits == 0) // Reentered before release.
        hover.beginDragging()
        hover.pointerExited(at: CGPoint(x: 300, y: 100), buttonsPressed: false)
        #expect(exits == 0)
        hover.endDragging(at: CGPoint(x: 300, y: 100))
        #expect(exits == 1)
        hover.stopTracking()
        hover.pointerExited(at: CGPoint(x: 300, y: 100), buttonsPressed: false)
        #expect(exits == 1)
    }

    @Test func persistentHoverExitAndCloseButtonUseFadeAndOldActionsCannotDismissReplacement() async throws {
        _ = NSApplication.shared
        let controller = ResultPreviewController()
        let artifact = makeArtifact(kind: .video)
        var dismissed = 0
        var opened = 0
        controller.onDismiss = { _ in dismissed += 1 }
        controller.onOpen = { _ in opened += 1 }
        controller.show(artifact)
        let previous = try panel(for: artifact)
        previous.orderOut(nil)
        let hover = try #require(previous.contentView as? PreviewHoverView)
        let oldOpen = try #require(descendants(hover).compactMap { $0 as? PreviewActionButton }.first { $0.title == "Open recording" })
        hover.mouseEntered(with: try mouse(.mouseEntered, at: CGPoint(x: 20, y: 20)))
        hover.mouseExited(with: try mouse(.mouseExited, at: CGPoint(x: 300, y: 100)))
        #expect(!previous.ignoresMouseEvents)
        #expect(dismissed == 0)
        controller.dismiss(artifact.id)
        controller.show(artifact)
        let replacement = try panel(for: artifact)
        replacement.orderOut(nil)
        oldOpen.performClick(nil)
        try await eventually { dismissed == 1 }
        #expect(opened == 0)
        #expect(!replacement.ignoresMouseEvents)
        #expect(replacement.alphaValue == 1)
        let close = try #require(descendants(replacement.contentView).compactMap { $0 as? PreviewActionButton }.first { $0.title == "Dismiss preview" })
        close.performClick(nil)
        #expect(replacement.ignoresMouseEvents)
        #expect(dismissed == 1)
        try await eventually { dismissed == 2 }
        #expect(replacement.alphaValue == 0)
    }

    @Test func hoverExitWaitsAndReentryDuringFadeRestoresPreview() async throws {
        _ = NSApplication.shared
        let controller = ResultPreviewController()
        let artifact = makeArtifact()
        var dismissed = 0
        controller.onDismiss = { _ in dismissed += 1 }
        controller.show(artifact)
        let window = try panel(for: artifact)
        window.orderOut(nil)
        defer { controller.dismiss(artifact.id) }
        let hover = try #require(window.contentView as? PreviewHoverView)
        let enter = try mouse(.mouseEntered, at: CGPoint(x: 20, y: 20))
        hover.mouseEntered(with: enter)
        hover.pointerExited(at: CGPoint(x: 300, y: 100), buttonsPressed: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(window.alphaValue == 1)
        #expect(dismissed == 0)
        hover.mouseEntered(with: enter)
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.alphaValue == 1)
        #expect(dismissed == 0) // Return during the grace period canceled its timer.

        hover.pointerExited(at: CGPoint(x: 300, y: 100), buttonsPressed: false)
        try await eventually("fade started") { window.alphaValue == 0 }
        #expect(!window.ignoresMouseEvents) // Reentry remains possible during the fade.
        hover.mouseEntered(with: enter)
        #expect(window.alphaValue == 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(dismissed == 0) // The old fade cannot close a restored preview.
        #expect(!window.ignoresMouseEvents)
        hover.pointerExited(at: CGPoint(x: 300, y: 100), buttonsPressed: false)
        try await eventually("final hover dismissal") { dismissed == 1 }
        #expect(window.alphaValue == 0)
    }

    @Test func videoPreviewHasNoTrashOrCopyAction() throws {
        _ = NSApplication.shared
        let controller = ResultPreviewController()
        var artifact = makeArtifact(kind: .video)
        artifact.duration = 5
        controller.show(artifact)
        let window = try panel(for: artifact)
        window.orderOut(nil)
        defer { controller.dismiss(artifact.id) }
        let titles = descendants(window.contentView).compactMap { ($0 as? PreviewActionButton)?.title }
        #expect(!titles.contains("Move screenshot to Trash"))
        #expect(!titles.contains("Copy image"))
        #expect(titles.contains("Open recording"))
    }

    @Test func persistentPreviewsAreNotEvictedWhenStackFills() throws {
        _ = NSApplication.shared
        let controller = ResultPreviewController()
        let artifacts = (0..<5).map { _ in makeArtifact(kind: .video) }
        var dismissed = 0
        controller.onDismiss = { _ in dismissed += 1 }
        defer { artifacts.forEach { controller.dismiss($0.id) } }
        for artifact in artifacts {
            controller.show(artifact)
            try panel(for: artifact).orderOut(nil)
        }
        #expect(dismissed == 0)
        for artifact in artifacts { _ = try panel(for: artifact) }

        let screen = CGRect(x: -1280, y: 100, width: 1280, height: 720)
        let sizes = [CGSize(width: 288, height: 238), CGSize(width: 288, height: 134),
                     CGSize(width: 288, height: 200), CGSize(width: 288, height: 238), CGSize(width: 288, height: 180)]
        let frames = ResultPreviewController.previewFrames(sizes: sizes, visibleFrame: screen)
        #expect(frames.count == 5)
        for frame in frames { #expect(screen.insetBy(dx: 16, dy: 16).contains(frame)) }
        for (lower, upper) in zip(frames, frames.dropFirst()) {
            #expect(upper.maxY > lower.maxY)
        }
        #expect(frames.last?.maxY == screen.maxY - 16)
        let uncrowded = ResultPreviewController.previewFrames(sizes: Array(sizes.prefix(2)), visibleFrame: screen)
        #expect(uncrowded[1].minY - uncrowded[0].maxY == 12)
    }

    private func eventually(_ description: String = "eventual condition", _ condition: () -> Bool) async throws {
        // Native UI suites share MainActor. Window creation in another suite can
        // delay timer/animation callbacks beyond three seconds on a live desktop.
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), Comment(rawValue: description))
    }

    private func makeArtifact(kind: ArtifactKind = .image) -> CaptureArtifact {
        CaptureArtifact(id: UUID(), url: URL(fileURLWithPath: "/tmp/Karuto-preview-test-missing.png"), kind: kind, width: 320, height: 200)
    }
    private func panel(for artifact: CaptureArtifact) throws -> NSWindow {
        try #require(NSApp.windows.first { $0.identifier?.rawValue == "capture-preview-\(artifact.id)" && !$0.ignoresMouseEvents })
    }
    private func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil))
        }
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    }
}

@MainActor
private final class PreviewCloseProbe: NSObject {
    private(set) var didClose = false
    init(window: NSWindow) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
    }
    @objc private func closed() { didClose = true }
    deinit { NotificationCenter.default.removeObserver(self) }
}

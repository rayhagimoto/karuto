import AppKit
import ImageIO

@MainActor
final class ResultPreviewController {
    var onSave: (@MainActor (CaptureArtifact) -> Void)?
    var onCopy: (@MainActor (CaptureArtifact) -> Void)?
    var onReveal: (@MainActor (CaptureArtifact) -> Void)?
    var onTrash: (@MainActor (CaptureArtifact) -> Void)?
    var onOpen: (@MainActor (CaptureArtifact) -> Void)?
    var onDismiss: (@MainActor (CaptureArtifact) -> Void)?
    private var previews: [(CaptureArtifact, CapturePanel)] = []
    private var placementFrame: CGRect?
    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]

    private var passiveDismissals: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]

    isolated deinit {
        dismissalTasks.values.forEach { $0.cancel() }
        passiveDismissals.values.forEach { $0.task.cancel() }
    }

    func show(_ artifact: CaptureArtifact, autoDismissAfter: TimeInterval? = nil) {
        dismissalTasks.removeValue(forKey: artifact.id)?.cancel()
        if let previous = previews.first(where: { $0.0.id == artifact.id }) {
            dismiss(previous.0, panel: previous.1, notify: false)
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        placementFrame = screen?.visibleFrame
        let previewWidth: CGFloat = 272
        let aspect = CGFloat(max(1, artifact.height)) / CGFloat(max(1, artifact.width))
        let previewHeight = min(176, max(72, previewWidth * aspect))
        let panel = CapturePanel(contentRect: CGRect(x: 0, y: 0, width: 288, height: previewHeight + 62))
        panel.identifier = NSUserInterfaceItemIdentifier("capture-preview-\(artifact.id)")
        panel.contentMaxSize = panel.contentMinSize
        let surface = CaptureSurface(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
        surface.autoresizingMask = [.width, .height]
        let hover = PreviewHoverView(frame: surface.frame)
        hover.autoresizingMask = [.width, .height]
        hover.addSubview(surface)
        panel.contentView = hover
        hover.onEnter = { [weak self, weak panel] in
            guard let panel else { return }
            self?.cancelPassiveDismissal(panel: panel)
        }
        hover.onExit = { [weak self, weak panel] in
            guard let panel else { return }
            self?.schedulePassiveDismissal(artifact, panel: panel, after: 0.5)
        }
        hover.onTimedDismissal = { [weak self, weak panel] in
            guard let panel else { return }
            self?.schedulePassiveDismissal(artifact, panel: panel, after: 0)
        }

        let image = DraggableCaptureImageView(artifact: artifact)
        image.onOpen = { [weak self, weak panel] in
            guard let panel else { return }
            self?.dismiss(artifact, panel: panel, action: self?.onOpen)
        }
        image.onDragStarted = { [weak hover] in hover?.beginDragging() }
        image.onDragEnded = { [weak self, weak panel, weak hover] succeeded, point in
            guard let panel else { return }
            if succeeded { self?.dismiss(artifact, panel: panel) }
            else { hover?.endDragging(at: panel.convertPoint(fromScreen: point)) }
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        image.layer?.cornerRadius = 9
        image.layer?.borderWidth = 0.5
        image.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        image.layer?.masksToBounds = true
        image.setAccessibilityLabel(artifact.kind == .image ? "Captured image. Click to open; drag to save to another app." : "Recorded video. Click to open; drag to another app.")
        image.image = NSImage(systemSymbolName: artifact.kind == .image ? "photo" : "play.rectangle.fill", accessibilityDescription: nil)
        surface.contentView.addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 8),
            image.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -8),
            image.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: 8),
            image.widthAnchor.constraint(equalToConstant: previewWidth),
            image.heightAnchor.constraint(equalToConstant: previewHeight)
        ])

        let imageLabel = artifact.isPartial ? "Partial PNG" : "PNG"
        let details = artifact.kind == .image
            ? "\(imageLabel) · \(artifact.width) × \(artifact.height)"
            : "MP4 · \(Int(artifact.duration))s · \(artifact.width) × \(artifact.height)"
        let info = captureLabel(details, size: 10, color: .secondaryLabelColor)
        info.lineBreakMode = .byTruncatingTail
        info.toolTip = details
        info.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(info)
        let fileSize = captureLabel("", size: 9, color: .secondaryLabelColor)
        fileSize.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(fileSize)
        Task.detached(priority: .utility) { [weak fileSize] in
            guard let bytes = try? artifact.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            let text = Self.formattedFileSize(Int64(bytes))
            await MainActor.run {
                fileSize?.stringValue = text
                fileSize?.setAccessibilityLabel("File size: \(text)")
            }
        }

        let actions = NSStackView()
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false
        if artifact.kind == .image {
            let copy = PreviewActionButton(title: "Copy image", symbol: "doc.on.doc") { [weak self, weak panel] in
                guard let panel else { return }
                self?.dismiss(artifact, panel: panel, action: self?.onCopy)
            }
            if Int64(artifact.width) * Int64(artifact.height) > CaptureClipboard.maximumPixelCount {
                copy.isEnabled = false
                copy.toolTip = "This image is too large for the clipboard. Save or drag the file instead."
            }
            actions.addArrangedSubview(copy)
        } else {
            actions.addArrangedSubview(PreviewActionButton(title: "Open recording", symbol: "play.fill") { [weak self, weak panel] in
                guard let panel else { return }
                self?.dismiss(artifact, panel: panel, action: self?.onOpen)
            })
        }
        actions.addArrangedSubview(PreviewActionButton(title: "Save as…", symbol: "square.and.arrow.down") { [weak self, weak panel] in
                guard let panel else { return }
                self?.dismiss(artifact, panel: panel, action: self?.onSave)
            })
        actions.addArrangedSubview(PreviewActionButton(title: "Reveal in Finder", symbol: "folder") { [weak self, weak panel] in
                guard let panel else { return }
                self?.dismiss(artifact, panel: panel, action: self?.onReveal)
            })
        if artifact.kind == .image {
            actions.addArrangedSubview(PreviewActionButton(title: "Move screenshot to Trash", symbol: "trash") { [weak self, weak panel] in
                guard let panel else { return }
                self?.dismiss(artifact, panel: panel, action: self?.onTrash)
            })
        }
        surface.contentView.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: image.bottomAnchor, constant: 25),
            actions.heightAnchor.constraint(equalToConstant: 30),
            info.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 12),
            info.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            info.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 10),
            fileSize.leadingAnchor.constraint(equalTo: info.leadingAnchor),
            fileSize.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            fileSize.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 3)
        ])

        let close = PreviewActionButton(title: "Dismiss preview", symbol: "xmark", size: 24, overlay: true) { [weak self, weak panel] in
            guard let panel else { return }
            self?.dismiss(artifact, panel: panel)
        }
        close.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -5),
            close.topAnchor.constraint(equalTo: image.topAnchor, constant: 5)
        ])
        previews.insert((artifact, panel), at: 0)
        arrange()
        panel.orderFrontRegardless()
        if let delay = autoDismissAfter, delay.isFinite, delay > 0 {
            scheduleDismissal(artifact.id, panel: panel, after: delay)
        }
        // Avoid decoding enormous appshots into a full bitmap just to show a thumbnail.
        // Such files still support Save, Reveal and file dragging.
        if artifact.kind == .image, Int64(artifact.width) * Int64(artifact.height) <= 16_777_216 {
            let url = artifact.url
            Task.detached(priority: .utility) { [weak image] in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 544,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return }
                await MainActor.run { image?.image = NSImage(cgImage: thumbnail, size: .zero) }
            }
        }
    }

    private func scheduleDismissal(_ id: UUID, panel: CapturePanel, after delay: TimeInterval) {
        dismissalTasks.removeValue(forKey: id)?.cancel()
        dismissalTasks[id] = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self, let panel,
                  previews.contains(where: { $0.1 === panel }) else { return }
            dismissalTasks.removeValue(forKey: id)
            (panel.contentView as? PreviewHoverView)?.requestTimedDismissal()
        }
    }

    /// Passive dismissal stays interactive until the fade completes. An explicit
    /// action still retires the preview immediately and cannot be undone by hover.
    private func schedulePassiveDismissal(_ artifact: CaptureArtifact, panel: CapturePanel, after delay: TimeInterval) {
        guard previews.contains(where: { $0.1 === panel }) else { return }
        let key = ObjectIdentifier(panel)
        // A timeout must not shorten an existing mouse-exit grace period.
        if delay == 0, passiveDismissals[key] != nil { return }
        cancelPassiveDismissal(panel: panel)
        let token = UUID()
        let task = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let panel, self.passiveDismissals[key]?.token == token else { return }
            if panel.isVisible {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 0
                }, completionHandler: nil)
            } else { panel.alphaValue = 0 }
            // Own completion timing rather than trusting a canceled AppKit
            // animation's completion callback to represent current intent.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard self.passiveDismissals[key]?.token == token else { return }
            self.passiveDismissals.removeValue(forKey: key)
            self.dismiss(artifact, panel: panel, animated: false)
        }
        passiveDismissals[key] = (token, task)
    }

    private func cancelPassiveDismissal(panel: CapturePanel, restore: Bool = true) {
        guard let pending = passiveDismissals.removeValue(forKey: ObjectIdentifier(panel)) else { return }
        pending.task.cancel()
        guard restore else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
    }

    nonisolated static func formattedFileSize(_ bytes: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 999.95 && unit < units.count - 1 { value /= 1000; unit += 1 }
        let number = unit == 0 ? String(Int(value)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        return "\(number.hasSuffix(".0") ? String(number.dropLast(2)) : number) \(units[unit])"
    }

    func dismiss(_ id: UUID) {
        guard let entry = previews.first(where: { $0.0.id == id }) else { return }
        dismiss(entry.0, panel: entry.1)
    }

    private func dismiss(_ artifact: CaptureArtifact, panel: CapturePanel, notify: Bool = true,
                         action: (@MainActor (CaptureArtifact) -> Void)? = nil, animated: Bool = true) {
        // Panel identity matters: an old action or animation must not retire a
        // newly restored preview of the same artifact.
        guard let index = previews.firstIndex(where: { $0.1 === panel }) else { return }
        previews.remove(at: index)
        cancelPassiveDismissal(panel: panel, restore: false)
        dismissalTasks.removeValue(forKey: artifact.id)?.cancel()
        panel.ignoresMouseEvents = true
        (panel.contentView as? PreviewHoverView)?.stopTracking()
        let completion: @MainActor @Sendable () -> Void = { [weak self] in
            panel.close()
            guard let self else { return }
            if notify { self.onDismiss?(artifact) }
            action?(artifact)
            self.arrange()
        }
        // An ordered-out window has nothing to animate, and AppKit may never
        // complete an animator transaction for it. Preserve asynchronous ordering.
        guard panel.isVisible && animated else {
            panel.alphaValue = 0
            Task { @MainActor in completion() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in completion() }
        }
    }

    private func arrange() {
        guard let frame = placementFrame ?? NSScreen.main?.visibleFrame else { return }
        let frames = Self.previewFrames(sizes: previews.map { $0.1.frame.size }, visibleFrame: frame)
        for (entry, placement) in zip(previews, frames) { entry.1.setFrameOrigin(placement.origin) }
    }

    /// Older previews remain available. When space runs out, expose their top edges
    /// above the newest preview rather than dismissing persistent captures.
    nonisolated static func previewFrames(sizes: [CGSize], visibleFrame: CGRect) -> [CGRect] {
        guard let maxHeight = sizes.map(\.height).max() else { return [] }
        let inset = visibleFrame.insetBy(dx: 16, dy: 16)
        let requiredHeight = sizes.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(sizes.count - 1) * 12
        let overlaps = requiredHeight > inset.height
        let step = sizes.count > 1 ? max(0, (inset.height - maxHeight) / CGFloat(sizes.count - 1)) : 0
        var y = inset.minY
        return sizes.enumerated().map { index, size in
            // Align exposed top strips, even when previews have different heights.
            let originY = overlaps ? inset.minY + maxHeight + CGFloat(index) * step - size.height : y
            y += size.height + 12
            return CGRect(x: inset.maxX - size.width, y: originY, width: size.width, height: size.height)
        }
    }
}

/// One tracking region covers the whole card, including image, footer, and controls.
/// Release monitors exist only while an exit is deferred by a held mouse button.
@MainActor
final class PreviewHoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onTimedDismissal: (() -> Void)?
    private(set) var hasEntered = false
    private var pendingExit = false
    private var pointerInside = false
    private var dragging = false
    private var stopped = false
    private var tracking: NSTrackingArea?
    private var localReleaseMonitor: Any?
    private var globalReleaseMonitor: Any?

    isolated deinit { removeReleaseMonitors() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard !stopped else { tracking = nil; return }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !stopped else { return }
        hasEntered = true
        pointerInside = true
        pendingExit = false
        removeReleaseMonitors()
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        pointerExited(at: convert(event.locationInWindow, from: nil), buttonsPressed: NSEvent.pressedMouseButtons != 0)
    }

    func pointerExited(at point: CGPoint, buttonsPressed: Bool) {
        guard !stopped, hasEntered, !bounds.contains(point) else { return }
        pointerInside = false
        if buttonsPressed || dragging {
            pendingExit = true
            installReleaseMonitors()
        } else {
            onExit?()
        }
    }

    func beginDragging() { dragging = true }

    func endDragging(at pointInWindow: CGPoint) {
        dragging = false
        finishInteraction(at: convert(pointInWindow, from: nil))
    }

    func finishInteraction(at point: CGPoint) {
        removeReleaseMonitors()
        guard !stopped, !dragging, pendingExit else { return }
        pendingExit = false
        pointerInside = bounds.contains(point)
        if !pointerInside { onExit?() }
    }

    func requestTimedDismissal() {
        guard !stopped else { return }
        let inside = window.map { $0.isVisible && bounds.contains(convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) } ?? false
        if pointerInside || inside {
            hasEntered = true
            pointerInside = true
        } else if dragging || NSEvent.pressedMouseButtons != 0 {
            pendingExit = true
            installReleaseMonitors()
        } else {
            onTimedDismissal?()
        }
    }

    func stopTracking() {
        stopped = true
        onEnter = nil
        onTimedDismissal = nil
        onExit = nil
        pendingExit = false
        removeReleaseMonitors()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
    }

    private func installReleaseMonitors() {
        guard localReleaseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        localReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseReleased() }
            return event
        }
        globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.mouseReleased() }
        }
    }

    private func mouseReleased() {
        guard let window else { removeReleaseMonitors(); return }
        // A native file drag ends through its source callback, after drop handling.
        guard !dragging, NSEvent.pressedMouseButtons == 0 else { return }
        finishInteraction(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    private func removeReleaseMonitors() {
        if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor) }
        if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor) }
        localReleaseMonitor = nil
        globalReleaseMonitor = nil
    }
}

/// Quiet symbol controls keep the capture itself as the primary visual content.
@MainActor
final class PreviewActionButton: ClosureButton {
    private var hovered = false
    private let overlay: Bool
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String, size: CGFloat = 30, overlay: Bool = false, handler: @escaping () -> Void) {
        self.overlay = overlay
        super.init(title: title, symbol: symbol, handler: handler)
        isBordered = false
        imagePosition = .imageOnly
        toolTip = title
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if overlay || (isEnabled && (hovered || isHighlighted)) {
            let color = overlay
                ? NSColor.black.withAlphaComponent(isHighlighted ? 0.85 : hovered ? 0.75 : 0.6)
                : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.09)
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: overlay ? bounds.width / 2 : 6,
                         yRadius: overlay ? bounds.height / 2 : 6).fill()
        }
        let tint = (overlay ? NSColor.white : NSColor.labelColor).withAlphaComponent(isEnabled ? (hovered ? 1 : 0.86) : 0.3)
        let configuration = NSImage.SymbolConfiguration(pointSize: overlay ? 10 : 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let icon = image?.withSymbolConfiguration(configuration) {
            let size = icon.size
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            // Symbol widths vary. Half-pixel origins blur some symbols but not
            // others, so align the origin without rescaling the symbol.
            let pixels = convertToBacking(origin)
            let aligned = convertFromBacking(NSPoint(x: pixels.x.rounded(), y: pixels.y.rounded()))
            icon.draw(in: CGRect(origin: aligned, size: size))
        }
    }
}

@MainActor
final class DraggableCaptureImageView: NSImageView, NSDraggingSource {
    private let artifact: CaptureArtifact
    private var downPoint: CGPoint?
    var onOpen: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: ((Bool, CGPoint) -> Void)?
    init(artifact: CaptureArtifact) { self.artifact = artifact; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard let downPoint,
              hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y) <= 3,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downPoint, hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y) > 3 else { return }
        self.downPoint = nil
        onDragStarted?()
        let item = NSDraggingItem(pasteboardWriter: artifact.url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        downPoint = nil
        onDragEnded?(operation.contains(.copy), screenPoint)
    }
}

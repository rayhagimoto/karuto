import AppKit
import ImageIO

@MainActor
final class CaptureCoordinator {
    enum Phase { case idle, selecting, preparing, recording, scrolling, finalizing }
    private(set) var phase: Phase = .idle { didSet { onStateChange?() } }
    var onStateChange: (() -> Void)?
    private let engine = CaptureEngine()
    private let captureUI: CaptureUIController
    private let previews = ResultPreviewController()
    private let clipboard: CaptureClipboard
    private var savePanel: NSSavePanel?
    private let controls = SessionControlsController()
    let settings: AppSettings
    let settingsUI: SettingsController
    private let store: CaptureStore
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var directory: URL?
    private var stitcher: StitchingSession?
    private var previousArea: CaptureTarget?
    private var previousDisplayFrame: CGRect?
    private var catalog: CaptureCatalog?
    private var frozenDesktop: FrozenDesktop?
    private var elapsedTask: Task<Void, Never>?
    private var recentArtifact: CaptureArtifact?
    private let automaticScroll = AutomaticScrollDriver()
    private var scrollingAutomatically = false
    private var scrollingNeedsAdjustment = false
    private var scrollInputPoint: CGPoint?
    private let scrollContentGuide = ScrollContentGuide()
    private var scrollingStarted: Date?

    init(settings: AppSettings, store: CaptureStore, clipboard: CaptureClipboard = CaptureClipboard()) {
        self.settings = settings; self.store = store
        self.clipboard = clipboard
        captureUI = CaptureUIController(settings: settings)
        settingsUI = SettingsController(settings: settings)
        engine.capturableOwnWindowIDs = { [weak settingsUI = self.settingsUI] in
            settingsUI?.captureWindowIDs ?? []
        }
        captureUI.onScrollInputPoint = { [weak self] point in self?.scrollInputPoint = point }
        captureUI.previousArea = { [weak self] in
            guard let self, let previousArea, let previousDisplayFrame else { return nil }
            return (previousArea, previousDisplayFrame)
        }
        captureUI.onCapture = { [weak self] mode, region, target, marks, destination in
            self?.perform(mode, region: region, target: target, annotations: marks, destination: destination)
        }
        captureUI.samplePreview = { [weak self] target in
            guard let self else { throw CancellationError() }
            if let frozenDesktop { return try frozenDesktop.image(for: target) }
            // Preview sampling runs independently of the final capture.
            let sampler = CaptureEngine()
            sampler.capturableOwnWindowIDs = engine.capturableOwnWindowIDs
            return try await sampler.capture(target: target, options: ScreenshotOptions(includeShadow: false))
        }
        captureUI.onCancel = { [weak self] in self?.cancel() }
        captureUI.onSelectionSourceChange = { [weak self] previousMode in
            guard let self, phase == .selecting else { return }
            // Acquire the new source with the selection windows out of the way.
            cancel { [weak self] in self?.beginSelection(previousMode: previousMode) }
        }
        captureUI.onOpenPreferences = { [weak self] in self?.showSettings() }
        captureUI.onOpenKeymap = { [weak self] in self?.showKeymap() }
        controls.onStop = { [weak self] in self?.stop() }
        controls.onCancel = { [weak self] in self?.cancel() }
        controls.onReselect = { [weak self] in
            self?.cancel { [weak self] in self?.openToolbar(initialRegion: .scrolling) }
        }
        controls.onManual = { [weak self] in self?.useManualScrolling("Scroll inside the selected content, then choose Finish.") }
        previews.onSave = { [weak self] in self?.saveAs($0) }
        previews.onCopy = { [weak self] in self?.copy($0) }
        previews.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) }
        previews.onOpen = { [weak self] in self?.openArtifact($0) }
        previews.onTrash = { [weak self] in self?.trash($0) }
        engine.onFailure = { [weak self] error in self?.streamFailed(error) }
    }

    func openToolbar(initialRegion: CaptureRegion? = nil) {
        guard phase == .idle else { return }
        captureUI.ocrEnabled = false
        captureUI.loadPreferences()
        if let initialRegion { captureUI.setRegion(initialRegion) }
        beginSelection()
    }

    private func beginSelection(previousMode: CaptureMode? = nil) {
        guard phase == .idle else { return }
        let freeze = captureUI.usesFrozenSelection
        let id = UUID(); operationID = id; phase = .selecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let frozen: FrozenDesktop?
                let catalog: CaptureCatalog
                if freeze {
                    let snapshot = try await engine.freezeDesktop()
                    frozen = snapshot
                    catalog = snapshot.catalog
                } else {
                    frozen = nil
                    catalog = engine.selectionCatalog()
                }
                guard operationID == id, !Task.isCancelled else { return }
                guard !catalog.displays.isEmpty else { throw CaptureError.targetMissing }
                frozenDesktop = frozen
                self.catalog = catalog; phase = .selecting
                captureUI.present(catalog: catalog, frozenFrames: frozen?.frames ?? [:], previousMode: previousMode)
            } catch { fail(error, id: id) }
        }
    }

    func showSettings() {
        if phase == .selecting {
            // Selection windows sit above normal windows. Remove them before
            // showing preferences so the settings window can receive input.
            cancel { [weak self] in self?.settingsUI.show() }
        } else {
            settingsUI.show()
        }
    }

    func showKeymap() {
        if phase == .selecting {
            cancel { [weak self] in self?.settingsUI.showKeymap() }
        } else {
            settingsUI.showKeymap()
        }
    }

    func configureKeymap(_ keymap: KeymapController) {
        captureUI.keymap = keymap
        settingsUI.keymap = keymap
    }

    var isCaptureMenuTracking: Bool { captureUI.isMenuTracking }
    func refreshKeymap() {
        captureUI.refreshKeymap()
        settingsUI.refreshKeymap()
    }

    func capturePrevious() {
        if phase == .selecting { captureUI.handleShortcut(.selectLastArea); return }
        guard phase == .idle else { return }
        captureUI.ocrEnabled = false
        guard let previousArea, case let .area(displayID, _) = previousArea else { openToolbar(); return }
        let id = UUID(); operationID = id; phase = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await engine.catalog()
                guard operationID == id else { return }
                guard current.displays.first(where: { $0.id == displayID })?.frame == previousDisplayFrame else {
                    reset(); openToolbar(); return
                }
                catalog = current; perform(.snapshot, region: .area, target: previousArea)
            } catch { fail(error, id: id) }
        }
    }

    private func startFileSession() throws -> URL {
        let session = try store.newSession()
        directory = session
        return session
    }

    private func perform(_ mode: CaptureMode, region: CaptureRegion, target: CaptureTarget,
                         annotations: [AreaAnnotation] = [], destination: SnapshotDestination = .capturePreferences) {
        guard (phase == .selecting || phase == .preparing), mode.supports(region) else { return }
        let delaySeconds = settings.capturePreferences(for: mode).delaySeconds
        // Keep the same immutable pixels that were shown during selection.
        // Recording, scrolling and delayed captures always use live content.
        let frozen = mode == .snapshot && region != .scrolling && delaySeconds == 0 ? frozenDesktop : nil
        frozenDesktop = nil
        captureUI.dismiss()
        if mode == .snapshot, case let .area(displayID, _) = target {
            previousArea = target; previousDisplayFrame = catalog?.displays.first(where: { $0.id == displayID })?.frame
        }
        let recordingOptions: RecordingOptions?
        if mode == .screenRecording {
            recordingOptions = settingsUI.chooseRecordingOptions(delaySeconds: delaySeconds)
            guard recordingOptions != nil else { reset(); return }
        } else { recordingOptions = nil }
        let id = UUID(); operationID = id; phase = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if delaySeconds > 0 {
                    for remaining in (1...delaySeconds).reversed() {
                        guard operationID == id else { return }
                        controls.show(title: mode == .screenRecording ? "Recording starts soon" : "Snapshot starts soon",
                                      message: "\(remaining)", stopTitle: "")
                        try await Task.sleep(for: .seconds(1))
                    }
                    controls.dismiss()
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                if let options = recordingOptions {
                    let session = try startFileSession()
                    controls.show(title: "Preparing recording", message: "Starting local capture…", stopTitle: "Cancel")
                    try await engine.startRecording(target: target, options: options, to: session.appendingPathComponent("Recording.mp4"))
                    guard operationID == id else { _ = try? await engine.stopRecording(); return }
                    phase = .recording
                    controls.show(title: "Recording", message: "00:00", stopTitle: "Stop", allowsCancel: false)
                    startClock(id: id)
                } else if region == .scrolling {
                    let session = try startFileSession()
                    automaticScroll.prepare()
                    let sessionStitcher = try StitchingSession(directory: session, detectScrollContent: true)
                    stitcher = sessionStitcher; scrollingStarted = Date()
                    controls.show(title: "Preparing scrolling capture", message: "Starting local capture…", stopTitle: "Cancel")
                    try await engine.startFrames(target: target) { [weak self] frame in
                        do {
                            let progress = try sessionStitcher.append(frame)
                            Task { @MainActor [weak self] in
                                guard let self, self.operationID == id, self.phase == .scrolling || self.phase == .preparing else { return }
                                if progress.disposition == 2 && progress.contentRect == nil {
                                    self.requireScrollAdjustment()
                                    return
                                }
                                guard !self.scrollingNeedsAdjustment else { return }
                                self.automaticScroll.observe(progress)
                                if let region = progress.contentRect {
                                    self.scrollContentGuide.show(region: region, sourceSize: progress.sourceSize, target: target, catalog: self.catalog)
                                }
                                if self.phase == .scrolling { self.controls.update(message: progress.message) }
                            }
                        } catch {
                            Task { @MainActor [weak self] in self?.appshotFrameFailed(error, id: id) }
                        }
                    }
                    try Task.checkCancellation()
                    guard operationID == id else { await engine.stopFrames(); return }
                    phase = .scrolling
                    guard !scrollingNeedsAdjustment else { await engine.stopFrames(); return }
                    scrollingAutomatically = settings.automaticScrolling
                    controls.show(title: scrollingAutomatically ? "Automatic scrolling" : "Manual scrolling", message: scrollingAutomatically ? "Keep the target visible. Capturing downward…" : "Scroll inside the selected content, then choose Finish.", stopTitle: "Finish", allowsManual: scrollingAutomatically)
                    if scrollingAutomatically, let catalog {
                        automaticScroll.start(target: target, catalog: catalog, inputPoint: scrollInputPoint, onFinish: { [weak self] in self?.stop() }, onManualFallback: { [weak self] reason in self?.useManualScrolling(reason) })
                    }
                    startClock(id: id)
                } else {
                    let image: CGImage
                    if let frozen {
                        image = try frozen.image(for: target)
                    } else {
                        image = try await engine.capture(target: target, options: ScreenshotOptions(includeShadow: settings.includeShadow))
                    }
                    let output: CGImage
                    if case .area(_, let rect) = target, !annotations.isEmpty {
                        output = try await Task.detached(priority: .userInitiated) {
                            try AreaAnnotation.composite(annotations, over: image, size: rect.size)
                        }.value
                    } else { output = image }
                    try Task.checkCancellation()
                    guard operationID == id else { return }
                    try await finishSnapshot(output, destination: destination)
                }
            } catch is CancellationError {
                if operationID == id { discardAndReset() }
            } catch {
                fail(error, id: id)
            }
        }
    }

    private func requireScrollAdjustment() {
        guard !scrollingNeedsAdjustment else { return }
        scrollingNeedsAdjustment = true
        automaticScroll.stop()
        scrollContentGuide.dismiss()
        elapsedTask?.cancel()
        controls.show(title: "Adjust scrolling area", message: "Could not verify one moving pane. Adjust the area and try again.", stopTitle: "", allowsReselect: true)
        Task { await engine.stopFrames() }
    }

    private func useManualScrolling(_ message: String) {
        guard phase == .scrolling else { return }
        automaticScroll.stop()
        scrollingAutomatically = false
        controls.show(title: "Manual scrolling", message: message, stopTitle: "Finish")
    }

    private func startClock(id: UUID) {
        let began = Date()
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.operationID == id else { return }
                let seconds = Int(Date().timeIntervalSince(began))
                if self.phase == .recording { self.controls.update(message: String(format: "%02d:%02d", seconds / 60, seconds % 60)) }
                if self.phase == .scrolling, seconds >= 120 { self.stop(); return }
            }
        }
    }

    func stop(after completion: (() -> Void)? = nil) {
        guard phase == .recording || phase == .scrolling else {
            if phase == .preparing || phase == .selecting { cancel(after: completion); return }
            completion?(); return
        }
        automaticScroll.stop()
        scrollContentGuide.dismiss()
        let wasRecording = phase == .recording
        let id = operationID
        elapsedTask?.cancel(); phase = .finalizing
        controls.show(title: "Finishing capture", message: "Saving your local file…", stopTitle: "", allowsCancel: false)
        task = Task { [weak self] in
            guard let self else { return }
            defer { completion?() }
            do {
                if wasRecording {
                    let result = try await engine.stopRecording()
                    guard operationID == id else { return }
                    await complete(CaptureArtifact(id: UUID(), url: result.url, kind: .video, width: result.width, height: result.height, duration: result.duration))
                } else {
                    await engine.stopFrames()
                    guard let stitcher, let directory else { discardAndReset(); return }
                    let partial = directory.appendingPathComponent("Scrolling.partial.png")
                    let output = try await Task.detached(priority: .userInitiated) { try stitcher.finish(to: partial) }.value
                    guard operationID == id else { return }
                    let url = directory.appendingPathComponent("Scrolling.png")
                    try FileManager.default.moveItem(at: partial, to: url)
                    await complete(CaptureArtifact(id: UUID(), url: url, kind: .image, width: output.width, height: output.height))
                }
            } catch { if let id { fail(error, id: id) } }
        }
    }

    func cancel(after completion: (() -> Void)? = nil) {
        if phase == .recording { stop(after: completion); return }
        if phase == .idle { completion?(); return }
        guard phase != .finalizing else { return }
        automaticScroll.stop()
        scrollContentGuide.dismiss()
        let pending = task
        pending?.cancel(); elapsedTask?.cancel()
        operationID = nil; frozenDesktop = nil; captureUI.dismiss(); controls.dismiss()
        phase = .finalizing
        Task { [weak self] in
            await pending?.value
            guard let self else { completion?(); return }
            await engine.stopFrames(); _ = try? await engine.stopRecording()
            stitcher?.cancel(); discardAndReset(); completion?()
        }
    }

    private func appshotFrameFailed(_ error: Error, id: UUID) {
        guard operationID == id, phase == .scrolling else { return }
        // Freeze at the last accepted strip. The user can still finish and save valid content.
        automaticScroll.stop()
        scrollContentGuide.dismiss()
        elapsedTask?.cancel()
        controls.update(message: "\(error.localizedDescription) Finish to save accepted content.")
        Task { await engine.stopFrames() }
    }

    private func streamFailed(_ error: Error) {
        guard let id = operationID, phase != .idle, phase != .selecting else { return }
        if phase == .scrolling {
            appshotFrameFailed(error, id: id)
            return
        }
        fail(error, id: id)
    }

    private func fail(_ error: Error, id: UUID) {
        guard operationID == id else { return }
        automaticScroll.stop()
        scrollContentGuide.dismiss()
        task?.cancel(); elapsedTask?.cancel()
        let oldDirectory = directory; let oldStitcher = stitcher
        phase = .finalizing; frozenDesktop = nil; controls.dismiss(); captureUI.dismiss(); operationID = nil
        Task { [weak self] in
            guard let self else { return }
            await engine.stopFrames(); _ = try? await engine.stopRecording()
            oldStitcher?.cancel()
            if let oldDirectory { store.removeSession(oldDirectory) }
            reset(); showError(error)
        }
    }

    func finishSnapshot(_ image: CGImage, destination: SnapshotDestination) async throws {
        let id = operationID
        if destination == .clipboard {
            try await clipboard.copy(image)
            if operationID == id { reset() }
            return
        }

        let session = try startFileSession()
        let url = try await Task.detached(priority: .userInitiated) { [store] in
            try store.writePNG(image, in: session)
        }.value
        guard operationID == id else { store.removeSession(session); return }
        let artifact = CaptureArtifact(id: UUID(), url: url, kind: .image, width: image.width, height: image.height)
        await complete(artifact, saveOnly: destination == .saveFolder)
    }

    private func complete(_ artifact: CaptureArtifact, saveOnly: Bool = false) async {
        phase = .finalizing
        var result = artifact
        var saveError: Error?
        var clipboardError: Error?
        let captureStore = store
        if saveOnly || settings.automaticallySaves(artifact.kind) {
            let folder = settings.saveFolder
            do { result = try await Task.detached(priority: .userInitiated) { try captureStore.save(artifact, folder: folder) }.value }
            catch { saveError = error }
        }
        if !saveOnly && settings.autoCopyScreenshots && result.kind == .image {
            do { try await clipboard.copy(result) }
            catch is CancellationError { } // A newer explicit copy request takes precedence.
            catch { clipboardError = error }
        }
        recentArtifact = result
        previews.show(result, autoDismissAfter: settings.previewDismissInterval)
        reset()
        if let saveError { showError(saveError, title: "Couldn’t save to the selected folder. A temporary copy is available.") }
        if let clipboardError { showError(clipboardError, title: "Capture saved; clipboard copy failed") }
    }

    private func reset() {
        automaticScroll.stop(); scrollingAutomatically = false; scrollingNeedsAdjustment = false
        scrollContentGuide.dismiss(); scrollInputPoint = nil
        controls.dismiss(); elapsedTask?.cancel(); elapsedTask = nil
        stitcher = nil; directory = nil; operationID = nil; scrollingStarted = nil; frozenDesktop = nil; phase = .idle
    }
    private func discardAndReset() {
        if let directory { store.removeSession(directory) }
        reset()
    }
    func restoreRecent() {
        if let recentArtifact, FileManager.default.fileExists(atPath: recentArtifact.url.path) {
            previews.show(recentArtifact, autoDismissAfter: settings.previewDismissInterval)
        }
    }

    private func saveAs(_ artifact: CaptureArtifact) {
        guard savePanel == nil else { savePanel?.makeKeyAndOrderFront(nil); return }
        // Let the preview dismissal commit before creating the system file dialog.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.savePanel == nil else { return }
            let panel = NSSavePanel()
            self.savePanel = panel
            panel.nameFieldStringValue = artifact.url.lastPathComponent
            panel.allowedContentTypes = artifact.kind == .video ? [.mpeg4Movie] : [.png]
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { [weak self, weak panel] response in
                guard let self else { return }
                let destination = panel?.url
                self.savePanel = nil
                guard response == .OK, let destination else { return }
                let captureStore = self.store
                Task { @MainActor [weak self] in
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try captureStore.copyAtomically(from: artifact.url, to: destination)
                        }.value
                        var saved = artifact; saved.url = destination; saved.isSaved = true
                        // Saving an older preview must not replace a newer capture.
                        if self?.recentArtifact?.id == artifact.id { self?.recentArtifact = saved }
                    } catch { self?.showError(error, title: "Couldn't save capture") }
                }
            }
        }
    }

    private func copy(_ artifact: CaptureArtifact) {
        Task { [weak self] in
            guard let self else { return }
            do { try await clipboard.copy(artifact) }
            catch is CancellationError { }
            catch { showError(error, title: "Couldn't copy screenshot") }
        }
    }

    private func openArtifact(_ artifact: CaptureArtifact) {
        if !NSWorkspace.shared.open(artifact.url) {
            showError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSLocalizedDescriptionKey: "The capture couldn't be opened in its default application."]),
                      title: "Couldn't open capture")
        }
    }

    private func trash(_ artifact: CaptureArtifact) {
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.trashItem(at: artifact.url, resultingItemURL: nil)
                }.value
                if self?.recentArtifact?.id == artifact.id { self?.recentArtifact = nil }
            } catch { self?.showError(error, title: "Couldn't move capture to Trash") }
        }
    }
    func showError(_ error: Error, title: String = "Capture couldn't finish") {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}

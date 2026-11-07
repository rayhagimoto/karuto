import AppKit
import ImageIO

@MainActor
final class CaptureCoordinator {
    enum Phase { case idle, selecting, preparing, recording, scrolling, finalizing }
    private(set) var phase: Phase = .idle { didSet { onStateChange?() } }
    var onStateChange: (() -> Void)?
    private let engine = CaptureEngine()
    private let captureUI = CaptureUIController()
    private let previews = ResultPreviewController()
    private let clipboard = CaptureClipboard()
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
    private var sessionPreferences: CaptureSessionPreferences?
    private var elapsedTask: Task<Void, Never>?
    private var recentArtifact: CaptureArtifact?
    private var scrollingStarted: Date?

    init(settings: AppSettings, store: CaptureStore) {
        self.settings = settings; self.store = store
        settingsUI = SettingsController(settings: settings)
        engine.capturableOwnWindowIDs = { [weak settingsUI = self.settingsUI] in
            settingsUI?.captureWindowIDs ?? []
        }
        captureUI.onCapture = { [weak self] mode, target in self?.perform(mode, target: target) }
        captureUI.onCancel = { [weak self] in self?.cancel() }
        captureUI.onInstantCaptureChange = { [weak self] enabled in self?.sessionPreferences?.instantCapture = enabled }
        captureUI.onFreezeDisplayChange = { [weak self] enabled in
            guard let self, var preferences = sessionPreferences else { return }
            preferences.freezeDisplay = enabled
            let mode = captureUI.selectedMode
            // A new snapshot must be taken without selection windows on screen.
            // Carry this session's overrides through the restart, not into defaults.
            cancel { [weak self] in self?.beginSelection(initialMode: mode, preferences: preferences) }
        }
        captureUI.onOpenPreferences = { [weak self] in self?.showSettings() }
        captureUI.onOpenKeymap = { [weak self] in self?.showKeymap() }
        controls.onStop = { [weak self] in self?.stop() }
        controls.onCancel = { [weak self] in self?.cancel() }
        previews.onSave = { [weak self] in self?.saveAs($0) }
        previews.onCopy = { [weak self] in self?.copy($0) }
        previews.onReveal = { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) }
        previews.onOpen = { [weak self] in self?.openArtifact($0) }
        previews.onTrash = { [weak self] in self?.trash($0) }
        engine.onFailure = { [weak self] error in self?.streamFailed(error) }
    }

    func openToolbar(initialMode: CaptureMode = .area) {
        beginSelection(initialMode: initialMode, preferences: CaptureSessionPreferences(defaults: settings))
    }

    private func beginSelection(initialMode: CaptureMode, preferences: CaptureSessionPreferences) {
        guard phase == .idle else { return }
        sessionPreferences = preferences
        let id = UUID(); operationID = id; phase = .selecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let frozen: FrozenDesktop?
                let catalog: CaptureCatalog
                if preferences.freezeDisplay {
                    let snapshot = try await engine.freezeDesktop()
                    frozen = snapshot
                    catalog = snapshot.catalog
                } else {
                    frozen = nil
                    catalog = try await engine.catalog()
                }
                guard operationID == id, !Task.isCancelled else { return }
                frozenDesktop = frozen
                self.catalog = catalog; phase = .selecting
                captureUI.instantCapture = preferences.instantCapture
                captureUI.freezeDisplay = preferences.freezeDisplay
                captureUI.present(catalog: catalog, initialMode: initialMode, frozenFrames: frozen?.frames ?? [:])
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
        guard phase == .idle else { return }
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
                catalog = current; perform(.area, target: previousArea)
            } catch { fail(error, id: id) }
        }
    }

    private func perform(_ mode: CaptureMode, target: CaptureTarget) {
        guard phase == .selecting || phase == .preparing else { return }
        // Keep the same immutable pixels that were shown during selection.
        // Recording, scrolling and delayed captures always use live content.
        let frozen = (mode == .area || mode == .fullscreen || mode == .window) ? frozenDesktop : nil
        frozenDesktop = nil
        captureUI.dismiss()
        if case let .area(displayID, _) = target {
            previousArea = target; previousDisplayFrame = catalog?.displays.first(where: { $0.id == displayID })?.frame
        }
        let recordingOptions: RecordingOptions?
        if mode == .recording {
            recordingOptions = settingsUI.chooseRecordingOptions()
            guard recordingOptions != nil else { reset(); return }
        } else { recordingOptions = nil }
        let id = UUID(); operationID = id; phase = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try store.newSession(); directory = session
                if mode == .timer || mode == .recording {
                    for remaining in (1...3).reversed() {
                        guard operationID == id else { return }
                        controls.show(title: mode == .timer ? "Screenshot timer" : "Recording starts soon", message: "\(remaining)", stopTitle: "Cancel")
                        try await Task.sleep(for: .seconds(1))
                    }
                    controls.dismiss()
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                if mode == .recording, let options = recordingOptions {
                    controls.show(title: "Preparing recording", message: "Starting local capture…", stopTitle: "Cancel")
                    try await engine.startRecording(target: target, options: options, to: session.appendingPathComponent("Recording.mp4"))
                    guard operationID == id else { _ = try? await engine.stopRecording(); return }
                    phase = .recording
                    controls.show(title: "Recording", message: "00:00", stopTitle: "Stop", allowsCancel: false)
                    startClock(id: id)
                } else if mode == .scrolling {
                    let sessionStitcher = try StitchingSession(directory: session)
                    stitcher = sessionStitcher; scrollingStarted = Date()
                    controls.show(title: "Preparing scrolling capture", message: "Starting local capture…", stopTitle: "Cancel")
                    try await engine.startFrames(target: target) { [weak self] frame in
                        do {
                            let progress = try sessionStitcher.append(frame)
                            Task { @MainActor [weak self] in
                                guard let self, self.operationID == id, self.phase == .scrolling else { return }
                                self.controls.update(message: progress.message)
                            }
                        } catch {
                            Task { @MainActor [weak self] in self?.appshotFrameFailed(error, id: id) }
                        }
                    }
                    try Task.checkCancellation()
                    guard operationID == id else { await engine.stopFrames(); return }
                    phase = .scrolling
                    controls.show(title: "Scrolling capture", message: "Scroll down slowly; keep some previous content visible.", stopTitle: "Finish")
                    startClock(id: id)
                } else {
                    let image: CGImage
                    if let frozen {
                        image = try frozen.image(for: target)
                    } else {
                        image = try await engine.capture(target: target, options: ScreenshotOptions(includeShadow: settings.includeShadow))
                    }
                    let captureStore = store
                    let url = try await Task.detached(priority: .userInitiated) { try captureStore.writePNG(image, in: session) }.value
                    guard operationID == id else { store.removeSession(session); return }
                    await complete(CaptureArtifact(id: UUID(), url: url, kind: .image, width: image.width, height: image.height))
                }
            } catch is CancellationError {
                if operationID == id { discardAndReset() }
            } catch { fail(error, id: id) }
        }
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

    private func complete(_ artifact: CaptureArtifact) async {
        phase = .finalizing
        var result = artifact
        var saveError: Error?
        var clipboardError: Error?
        let captureStore = store
        if settings.autoSave {
            let folder = settings.saveFolder
            do { result = try await Task.detached(priority: .userInitiated) { try captureStore.save(artifact, folder: folder) }.value }
            catch { saveError = error }
        }
        if settings.autoCopyScreenshots && result.kind == .image {
            do { try await clipboard.copy(result) }
            catch is CancellationError { } // A newer explicit copy request takes precedence.
            catch { clipboardError = error }
        }
        recentArtifact = result
        previews.show(result, autoDismissAfter: settings.previewDismissInterval)
        reset()
        if let saveError { showError(saveError, title: "Capture saved temporarily; automatic save failed") }
        if let clipboardError { showError(clipboardError, title: "Capture saved; clipboard copy failed") }
    }

    private func reset() {
        controls.dismiss(); elapsedTask?.cancel(); elapsedTask = nil
        stitcher = nil; directory = nil; operationID = nil; scrollingStarted = nil; frozenDesktop = nil; sessionPreferences = nil; phase = .idle
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

import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Owns all Apple capture objects. No stream or sample buffer escapes this module.
@MainActor
final class CaptureEngine {
    var onFailure: ((Error) -> Void)?
    /// The coordinator supplies only the Preferences window's current ID.
    /// Capture panels and result previews remain excluded at application level.
    var capturableOwnWindowIDs: (() -> Set<UInt32>)?
    private var session: CaptureSession?
    private var screenshotBusy = false
    private var cleanupTask: Task<Void, Never>?

    private let headless: Bool
    init(headless: Bool = false) { self.headless = headless }

    func catalog() async throws -> CaptureCatalog {
        // Choosing a mode should not trigger a privacy prompt. Public window metadata
        // supplies IDs/bounds before consent; titles may be withheld by macOS.
        if !CGPreflightScreenCaptureAccess() {
            return CaptureCatalog(displays: localDisplayCatalog(), windows: metadataWindows())
        }
        let content = try await shareableContent()
        return catalog(from: content)
    }

    private var windowPolicy: CaptureWindowPolicy {
        CaptureWindowPolicy(ownProcessID: ProcessInfo.processInfo.processIdentifier,
                            capturableOwnWindowIDs: capturableOwnWindowIDs?() ?? [])
    }

    private func catalog(from content: SCShareableContent) -> CaptureCatalog {
        let policy = windowPolicy
        let screens = displayCatalog(content)
        let primaryHeight = primaryScreenHeight
        let frontToBack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let order = Dictionary(frontToBack.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
                && policy.canSelect(windowID: $0.windowID, ownerProcessID: $0.owningApplication?.processID)
        }.sorted { order[$0.windowID, default: .max] < order[$1.windowID, default: .max] }
            .map {
                CaptureWindow(id: $0.windowID, title: $0.title ?? "",
                              applicationName: $0.owningApplication?.applicationName ?? "Window",
                              frame: CaptureGeometry.appKitRect(fromQuartz: $0.frame, primaryHeight: primaryHeight), processID: $0.owningApplication?.processID)
            }
        return CaptureCatalog(displays: screens, windows: windows)
    }

    /// Called before presenting selection windows. Each display requests one
    /// frame concurrently; no recording stream or process suspension is used.
    func freezeDesktop() async throws -> FrozenDesktop {
        try ensureIdle()
        screenshotBusy = true
        defer { screenshotBusy = false }
        let content = try await shareableContent()
        try Task.checkCancellation()
        let catalog = catalog(from: content)
        guard !catalog.displays.isEmpty else { throw CaptureError.targetMissing }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let policy = windowPolicy
        let exceptions = content.windows.filter { policy.isOwnException(windowID: $0.windowID, ownerProcessID: $0.owningApplication?.processID) }
        var requests: [FrozenDisplayRequest] = []
        var pixelCount = 0
        for display in catalog.displays {
            guard let source = content.displays.first(where: { $0.displayID == display.id }) else { throw CaptureError.targetMissing }
            let filter = SCContentFilter(display: source, excludingApplications: ownApps, exceptingWindows: exceptions)
            filter.includeMenuBar = true
            let scale = CGFloat(filter.pointPixelScale)
            let size = try CaptureGeometry.pixelSize(points: display.frame.size, scale: scale > 0 ? scale : display.scale)
            pixelCount += size.width * size.height
            guard pixelCount <= FrozenDesktop.maximumPixelCount else { throw FrozenDesktopError.tooLarge }
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.captureResolution = .best
            config.scalesToFit = false
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.captureDynamicRange = .SDR
            requests.append(FrozenDisplayRequest(id: display.id, filter: filter, configuration: config))
        }
        let frames = try await withThrowingTaskGroup(of: (UInt32, CGImage).self) { group in
            for request in requests { group.addTask { try await request.capture() } }
            var frames: [UInt32: CGImage] = [:]
            for try await (id, image) in group { frames[id] = image }
            return frames
        }
        try Task.checkCancellation()
        return FrozenDesktop(catalog: catalog, frames: frames)
    }

    func capture(target: CaptureTarget, options: ScreenshotOptions) async throws -> CGImage {
        try ensureIdle()
        screenshotBusy = true
        defer { screenshotBusy = false }
        let resolved = try await resolve(target)
        try Task.checkCancellation()
        let config = resolved.configuration
        config.showsCursor = options.showsCursor
        config.ignoreShadowsSingleWindow = !options.includeShadow
        config.shouldBeOpaque = false
        // The native screenshot API owns the capture lifecycle; no persistent screenshot stream.
        return try await SCScreenshotManager.captureImage(contentFilter: resolved.filter, configuration: config)
    }

    func startRecording(target: CaptureTarget, options: RecordingOptions, to url: URL) async throws {
        try ensureIdle()
        let active = CaptureSession(kind: .recording)
        session = active
        do {
            if options.microphone { try await requestMicrophone() }
            try Task.checkCancellation()
            let resolved = try await resolve(target)
            try Task.checkCancellation()
            guard session?.id == active.id, !active.stopping else { throw CancellationError() }
            guard resolved.excludesCaptureControls else { throw CaptureError.exclusionUnavailable }
            let size = try CaptureGeometry.recordingSize(width: resolved.configuration.width,
                                                        height: resolved.configuration.height,
                                                        resolution: options.resolution)
            let config = resolved.configuration
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = options.showsCursor
            config.ignoreShadowsSingleWindow = true
            config.capturesAudio = options.systemAudio
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = options.microphone
            config.microphoneCaptureDeviceID = options.microphoneID
            config.captureDynamicRange = .SDR
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = url
            outputConfig.videoCodecType = .h264
            outputConfig.outputFileType = .mp4
            if #available(macOS 27.0, *) { outputConfig.mixesAudioWithMicrophone = true }
            let delegate = makeDelegate(for: active)
            let output = SCRecordingOutput(configuration: outputConfig, delegate: delegate)
            let stream = SCStream(filter: resolved.filter, configuration: config, delegate: delegate)
            active.stream = stream
            active.delegate = delegate
            active.output = output
            active.result = RecordingResult(url: url, duration: 0, width: size.width, height: size.height)
            try stream.addRecordingOutput(output)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    active.startContinuation = continuation
                    active.timeout = timeout(for: active.id)
                    active.startupTask = Task { @MainActor [weak self] in
                        guard self?.session?.id == active.id, !Task.isCancelled else { return }
                        do {
                            try await stream.startCapture()
                            // Cancellation may have arrived while ScreenCaptureKit was starting.
                            if self?.session?.id != active.id { try? await stream.stopCapture() }
                        }
                        catch { self?.fail(active.id, error: error) }
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in self?.fail(active.id, error: CancellationError()) }
            }
            try Task.checkCancellation()
        } catch {
            if session?.id == active.id { fail(active.id, error: error, notify: false) }
            throw error
        }
    }

    func stopRecording() async throws -> RecordingResult {
        guard let active = session, active.kind == .recording, let stream = active.stream,
              active.started, !active.stopping else { throw CaptureError.notRecording }
        active.stopping = true
        return try await withCheckedThrowingContinuation { continuation in
            active.finishContinuation = continuation
            active.timeout = timeout(for: active.id)
            Task { @MainActor [weak self] in
                do { try await stream.stopCapture() }
                catch { self?.fail(active.id, error: error) }
            }
        }
    }

    func startFrames(target: CaptureTarget, onFrame: @escaping @Sendable (PixelFrame) -> Void) async throws {
        try ensureIdle()
        let active = CaptureSession(kind: .frames)
        session = active
        do {
            let resolved = try await resolve(target)
            try Task.checkCancellation()
            guard session?.id == active.id, !active.stopping else { throw CancellationError() }
            guard resolved.excludesCaptureControls else { throw CaptureError.exclusionUnavailable }
            let config = resolved.configuration
            guard config.width <= 4096, config.height <= 8192,
                  config.width * config.height * 4 <= 32 * 1024 * 1024 else { throw CaptureError.appshotTooLarge }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let delegate = makeDelegate(for: active)
            let stream = SCStream(filter: resolved.filter, configuration: config, delegate: delegate)
            let frames = FrameReceiver(onFrame: onFrame)
            active.stream = stream
            active.delegate = delegate
            active.frames = frames
            try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
            let startup = Task { @MainActor in try await stream.startCapture() }
            active.frameStartupTask = startup
            try await startup.value
            try Task.checkCancellation()
            guard session?.id == active.id, !active.stopping else { throw CancellationError() }
            active.started = true
        } catch {
            if session?.id == active.id { fail(active.id, error: error, notify: false) }
            else if let stream = active.stream { try? await stream.stopCapture() }
            throw error
        }
    }

    /// Drains the frame callback queue before returning, so a stitcher can finalize safely.
    func stopFrames() async {
        guard let active = session, active.kind == .frames else {
            await cleanupTask?.value
            return
        }
        if let pending = active.frameStopTask { await pending.value; return }
        active.stopping = true
        active.frames?.disable()
        let pending = Task { @MainActor [weak self] in
            // Do not return while a still-starting stream could later become active.
            _ = await active.frameStartupTask?.result
            if let stream = active.stream { try? await stream.stopCapture() }
            await active.frames?.drainAndDisable()
            if self?.session?.id == active.id { self?.session = nil }
        }
        active.frameStopTask = pending
        await pending.value
    }

    private func ensureIdle() throws {
        guard session == nil, cleanupTask == nil, !screenshotBusy else { throw CaptureError.busy }
    }

    private func shareableContent(onScreenWindowsOnly: Bool = true) async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw CaptureError.screenPermission }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenWindowsOnly)
    }

    private func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.microphonePermission }
        default: throw CaptureError.microphonePermission
        }
    }

    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first(where: { screenID($0) == CGMainDisplayID() })?.frame.height
            ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func displayCatalog(_ content: SCShareableContent) -> [CaptureDisplay] {
        let availableIDs = Set(content.displays.map(\.displayID))
        return localDisplayCatalog().filter { availableIDs.contains($0.id) }
    }

    private func localDisplayCatalog() -> [CaptureDisplay] {
        NSScreen.screens.map {
            CaptureDisplay(id: screenID($0), name: $0.localizedName, frame: $0.frame, scale: $0.backingScaleFactor)
        }
    }

    private func metadataWindows() -> [CaptureWindow] {
        let policy = windowPolicy
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  policy.canSelect(windowID: id, ownerProcessID: pid),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            return CaptureWindow(id: id, title: info[kCGWindowName as String] as? String ?? "",
                                 applicationName: info[kCGWindowOwnerName as String] as? String ?? "Window",
                                 frame: CaptureGeometry.appKitRect(fromQuartz: rect, primaryHeight: primaryScreenHeight), processID: pid)
        }
    }

    private func resolve(_ target: CaptureTarget) async throws -> ResolvedCapture {
        let content = try await shareableContent(onScreenWindowsOnly: false)
        let config = SCStreamConfiguration()
        config.queueDepth = 3
        config.captureResolution = .best
        config.scalesToFit = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.captureDynamicRange = .SDR
        let filter: SCContentFilter
        let pointSize: CGSize
        let excludesCaptureControls: Bool
        let policy = windowPolicy
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  policy.canSelect(windowID: window.windowID, ownerProcessID: window.owningApplication?.processID) else {
                throw CaptureError.targetMissing
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pointSize = filter.contentRect.size
            excludesCaptureControls = true // An independent allowed window does not include our capture panels.
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  let screen = NSScreen.screens.first(where: { screenID($0) == id }) else { throw CaptureError.targetMissing }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            excludesCaptureControls = headless || !ownApps.isEmpty
            let exceptions = content.windows.filter { policy.isOwnException(windowID: $0.windowID, ownerProcessID: $0.owningApplication?.processID) }
            // Application exclusion also covers controls created after this
            // catalog. Only the explicitly registered Preferences window escapes it.
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: exceptions)
            filter.includeMenuBar = true
            if case .area(_, let rect) = target {
                config.sourceRect = try CaptureGeometry.sourceRect(selection: rect, displayFrame: screen.frame)
                pointSize = config.sourceRect.size
            } else { pointSize = screen.frame.size }
        }
        let scale = CGFloat(filter.pointPixelScale)
        let size = try CaptureGeometry.pixelSize(points: pointSize, scale: scale > 0 ? scale : 1)
        config.width = size.width
        config.height = size.height
        return ResolvedCapture(filter: filter, configuration: config, excludesCaptureControls: excludesCaptureControls)
    }

    private func makeDelegate(for active: CaptureSession) -> CaptureDelegate {
        let id = active.id
        return CaptureDelegate { [weak self] event in
            Task { @MainActor in self?.handle(event, id: id) }
        }
    }

    private func timeout(for id: UUID) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            self?.fail(id, error: CaptureError.recordingTimedOut)
        }
    }

    private func handle(_ event: CaptureEvent, id: UUID) {
        guard let active = session, active.id == id else { return }
        switch event {
        case .started:
            active.timeout?.cancel()
            active.timeout = nil
            active.started = true
            let continuation = active.startContinuation
            active.startContinuation = nil
            continuation?.resume()
        case .finished:
            guard let result = active.result else { return }
            guard active.stopping, active.finishContinuation != nil else {
                fail(id, error: CaptureError.stoppedUnexpectedly)
                return
            }
            active.timeout?.cancel()
            let duration = active.output?.recordedDuration.seconds ?? 0
            let finalized = RecordingResult(url: result.url, duration: duration.isFinite ? duration : 0,
                                            width: result.width, height: result.height)
            let finishing = active.finishContinuation
            active.finishContinuation = nil
            active.startContinuation?.resume(throwing: CaptureError.stoppedUnexpectedly)
            active.startContinuation = nil
            session = nil
            if let finishing { finishing.resume(returning: finalized) }
            else { onFailure?(CaptureError.stoppedUnexpectedly) }
        case .failed(let error): fail(id, error: error)
        }
    }

    private func fail(_ id: UUID, error: Error, notify: Bool = true) {
        guard let active = session, active.id == id else { return }
        active.timeout?.cancel()
        let wasAwaiting = active.startContinuation != nil || active.finishContinuation != nil
        active.startContinuation?.resume(throwing: error)
        active.startContinuation = nil
        active.finishContinuation?.resume(throwing: error)
        active.finishContinuation = nil
        active.frames?.disable()
        session = nil
        active.startupTask?.cancel()
        cleanupTask = Task { @MainActor [weak self] in
            // A cancelled startCapture call may still complete. Wait for its cleanup before
            // permitting another operation, and before the coordinator removes session files.
            await active.startupTask?.value
            _ = await active.frameStartupTask?.result
            if let stream = active.stream { try? await stream.stopCapture() }
            await active.frames?.drainAndDisable()
            self?.cleanupTask = nil
        }
        if notify, !wasAwaiting { onFailure?(error) }
    }
}

@MainActor
private final class FrozenDisplayRequest {
    let id: UInt32
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration

    init(id: UInt32, filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.id = id
        self.filter = filter
        self.configuration = configuration
    }

    func capture() async throws -> (UInt32, CGImage) {
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return (id, image)
    }
}

@MainActor
private struct ResolvedCapture {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let excludesCaptureControls: Bool
}

@MainActor
private final class CaptureSession {
    enum Kind { case recording, frames }
    let id = UUID()
    let kind: Kind
    var stream: SCStream?
    var delegate: CaptureDelegate?
    var output: SCRecordingOutput?
    var frames: FrameReceiver?
    var result: RecordingResult?
    var started = false
    var stopping = false
    var startContinuation: CheckedContinuation<Void, Error>?
    var finishContinuation: CheckedContinuation<RecordingResult, Error>?
    var timeout: Task<Void, Never>?
    var startupTask: Task<Void, Never>?
    var frameStopTask: Task<Void, Never>?
    var frameStartupTask: Task<Void, Error>?
    init(kind: Kind) { self.kind = kind }
}

private enum CaptureEvent: @unchecked Sendable {
    case started, finished, failed(Error)
}

private final class CaptureDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    let event: @Sendable (CaptureEvent) -> Void
    init(event: @escaping @Sendable (CaptureEvent) -> Void) { self.event = event }
    func stream(_ stream: SCStream, didStopWithError error: Error) { event(.failed(error)) }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { event(.started) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { event(.finished) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { event(.failed(error)) }
}

private final class FrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.karuto.frames", qos: .userInitiated)
    private let onFrame: @Sendable (PixelFrame) -> Void
    private let lock = NSLock()
    private var enabled = true
    private var lastDelivered: CFTimeInterval = 0 // Accessed only on queue.
    init(onFrame: @escaping @Sendable (PixelFrame) -> Void) { self.onFrame = onFrame }

    func disable() { lock.withLock { enabled = false } }

    func drainAndDisable() async {
        disable()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, lock.withLock({ enabled }), sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let now = CACurrentMediaTime()
        guard now - lastDelivered >= 0.2 else { return }
        lastDelivered = now
        autoreleasepool {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard width > 0, width <= 4096, height > 0, height <= 8192,
                  stride >= width * 4, stride <= 131072,
                  let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let data = Data(bytes: base, count: stride * height)
            onFrame(PixelFrame(data: data, width: width, height: height, bytesPerRow: stride))
        }
    }
}

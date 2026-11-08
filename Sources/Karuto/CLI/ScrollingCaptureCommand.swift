import AppKit

@MainActor
enum ScrollingCaptureCommand {
    static func run(arguments: [String]) async throws -> [String: Any] {
        var filtered: [String] = []
        var manual = false
        var duration: Double = 120
        var suppliedDuration = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--manual": manual = true
            case "--duration":
                index += 1
                guard index < arguments.count, let seconds = Double(arguments[index]), seconds.isFinite,
                      (1...120).contains(seconds), !suppliedDuration else { throw KarutoCLI.Failure("Scroll duration must be between 1 and 120 seconds") }
                duration = seconds; suppliedDuration = true
            case "--cursor", "--no-shadow": throw KarutoCLI.Failure("Scrolling capture does not accept screenshot appearance options")
            default: filtered.append(arguments[index])
            }
            index += 1
        }
        if manual && !suppliedDuration { throw KarutoCLI.Failure("Manual scrolling requires --duration (1–120 seconds)") }
        let request = try KarutoCLI.parse(filtered, recording: false)
        guard CGPreflightScreenCaptureAccess() else { throw KarutoCLI.Failure("Screen recording access is required", code: 3) }
        let output = request.output!, target = request.target!
        guard !FileManager.default.fileExists(atPath: output.path) else { throw KarutoCLI.Failure("Output already exists: \(output.path)", code: 1) }
        let engine = CaptureEngine(headless: true)
        let catalog = try await engine.catalog()
        if case let .area(id, rect) = target {
            guard catalog.displays.first(where: { $0.id == id })?.frame.contains(rect) == true else { throw KarutoCLI.Failure("Area must lie within its display") }
        }
        let scratch = output.deletingLastPathComponent().appendingPathComponent(".karuto-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stitcher = try StitchingSession(directory: scratch, detectScrollContent: true)
        defer { stitcher.cancel() }
        let driver = AutomaticScrollDriver()
        driver.prepare()
        defer { driver.stop() }
        let completion = ScrollCompletion()
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            completion.resolve(.failure(KarutoCLI.Failure("Scrolling capture reached its time limit; shorten the page or use manual capture", code: 1)))
        }
        defer { timer.cancel() }
        engine.onFailure = { completion.resolve(.failure($0)) }
        try await engine.startFrames(target: target) { frame in
            do {
                let progress = try stitcher.append(frame)
                Task { @MainActor in driver.observe(progress) }
            } catch { Task { @MainActor in completion.resolve(.failure(error)) } }
        }
        if manual {
            timer.cancel()
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(duration)); completion.resolve(.success(())) }
                catch { completion.resolve(.failure(error)) }
            }
        } else {
            driver.start(target: target, catalog: catalog, onFinish: { completion.resolve(.success(())) }, onManualFallback: { reason in
                if stitcher.needsAreaAdjustment {
                    completion.resolve(.failure(KarutoCLI.Failure("Could not verify one moving pane. Adjust --area and retry.", code: 1)))
                    return
                }
                completion.resolve(.failure(KarutoCLI.Failure("\(reason) Retry with --manual --duration SECONDS for manual scrolling.", code: CGPreflightPostEventAccess() ? 1 : 3)))
            })
        }
        let result = await completion.wait()
        driver.stop()
        await engine.stopFrames()
        try result.get()
        let partial = scratch.appendingPathComponent("capture.png")
        let verified = stitcher.verifiedContentRect
        let size = try await Task.detached { try stitcher.finish(to: partial) }.value
        try FileManager.default.moveItem(at: partial, to: output)
        var response: [String: Any] = ["path": output.path, "type": "image", "width": size.width, "height": size.height, "scrolling": manual ? "manual" : "automatic"]
        if let verified {
            response["content_rect"] = ["x": verified.minX, "y": verified.minY, "width": verified.width, "height": verified.height]
        }
        return response
    }
}

/// A completion can arrive before the caller has installed its await continuation.
@MainActor
private final class ScrollCompletion {
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result); continuation = nil
    }
    func wait() async -> Result<Void, Error> {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}

import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The CLI runs inside the signed app executable, sharing its privacy identity.
@MainActor
enum KarutoCLI {
    static let help = """
    Karuto CLI — noninteractive local screen capture

    Usage: karuto <command> [options]
      help [command]      Show command help
      permissions         Report screen and microphone authorization as JSON
      list displays       List display IDs, bounds and scale as JSON
      list windows        List visible window IDs, titles, applications and bounds as JSON
      screenshot          Capture a display, area, or window to PNG
      record              Record a display, area, or window to MP4
      scroll              Stitch scrolling content to PNG (automatic or manual)
      scroll-region       Suggest an accessible scrolling pane at a point

    Use 'karuto help screenshot', 'karuto help record', or 'karuto help list'
    for options, coordinate conventions, and examples. JSON results go to stdout;
    errors go to stderr. Exit codes: 0 success, 2 invalid usage, 3 permission
    required, 1 capture or filesystem failure. The CLI never opens an overlay.
    """
    static let targetHelp = """
    Targets (choose exactly one):
      --display ID                     Entire display
      --window ID                      Visible window
      --area DISPLAY_ID X Y WIDTH HEIGHT  Rectangle on display

    Area coordinates are global macOS AppKit points: origin at the bottom-left
    of the primary display; X and Y may be negative. Use 'list displays' for
    display bounds. The area must lie within its specified display.
    """
    static func commandHelp(_ command: String?) -> String {
        switch command {
        case "screenshot": return """
        Usage: karuto screenshot TARGET --output PATH [--cursor] [--no-shadow]
        Captures a PNG. PATH must not already exist; parent directory must exist.
        \(targetHelp)
        Examples:
          karuto screenshot --display 1 --output /tmp/screen.png
          karuto screenshot --area 1 0 0 800 600 --output /tmp/area.png
        """
        case "scroll-region": return """
        Usage: karuto scroll-region --window ID --point X Y
        Suggests visible scroll-area bounds from macOS Accessibility at global
        AppKit point X,Y. Returns suggested:false and bounds:null if unavailable.
        A suggestion is structural, not motion-verified; scroll capture verifies
        the moving crop separately. Requires Accessibility authorization.
        """
        case "scroll": return """
        Usage: karuto scroll TARGET --output PATH [--duration SECONDS]
               karuto scroll TARGET --output PATH --manual --duration SECONDS
        Automatically scrolls the visible target downward and stops when image
        growth settles. Target must stay visible. Accessibility access is required
        for automatic input. If automatic input cannot proceed, returns an error
        suggesting --manual; manual mode records while YOU scroll for the given
        duration (1–120 seconds). Auto duration is a safety limit, default 120.
        Initial overlapping frames verify one moving pane and can exclude static
        outer headers and sidebars. content_rect uses input pixels, top-left origin.
        Ambiguous motion reports an error: reduce the selected area and retry.
        \(targetHelp)
        """
        case "record": return """
        Usage: karuto record TARGET --output PATH --duration SECONDS [--native]
                             [--fps 30|60|120] [--system-audio] [--microphone] [--no-cursor]
        Records H.264 MP4 for 0.1–3600 seconds. PATH must not already exist;
        parent directory must exist. Resolution defaults to 1080p; --native uses
        the target's native resolution. Frame rate defaults to 30 fps.
        Audio is disabled unless requested.
        \(targetHelp)
        Example: karuto record --display 1 --duration 5 --output /tmp/demo.mp4
        """
        case "list": return """
        Usage: karuto list displays | windows
        Returns JSON with display or window IDs and global AppKit point bounds.
        Window names can be unavailable until screen recording access is granted.
        """
        case "permissions": return "Usage: karuto permissions\nReports screen recording and microphone authorization without prompting."
        case nil: return help
        default: return ""
        }
    }
    struct Failure: LocalizedError {
        let message: String
        let code: Int32
        var errorDescription: String? { message }
        init(_ message: String, code: Int32 = 2) { self.message = message; self.code = code }
    }
    struct Request {
        var target: CaptureTarget?
        var output: URL?
        var duration: Double?
        var cursor: Bool
        var shadow = true
        var native = false
        var frameRate: RecordingFrameRate?
        var systemAudio = false
        var microphone = false
    }
    static func parse(_ args: [String], recording: Bool) throws -> Request {
        var request = Request(cursor: recording)
        var i = 0
        func value(_ flag: String) throws -> String {
            guard i + 1 < args.count else { throw Failure("Missing value for \(flag)") }
            i += 1; return args[i]
        }
        func target(_ new: CaptureTarget) throws {
            guard request.target == nil else { throw Failure("Specify exactly one target") }
            request.target = new
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--display", "--window":
                let raw = try value(flag)
                guard let id = UInt32(raw), id > 0 else { throw Failure("Invalid ID: \(raw)") }
                try target(flag == "--display" ? .display(id: id) : .window(id: id))
            case "--area":
                let rawID = try value(flag)
                guard let id = UInt32(rawID), id > 0 else { throw Failure("Invalid display ID: \(rawID)") }
                var values: [Double] = []
                for _ in 0..<4 {
                    let raw = try value(flag)
                    guard let n = Double(raw), n.isFinite else { throw Failure("Invalid area coordinate: \(raw)") }
                    values.append(n)
                }
                guard values[2] > 0, values[3] > 0 else { throw Failure("Area width and height must be positive") }
                try target(.area(displayID: id, rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3])))
            case "--output":
                guard request.output == nil else { throw Failure("Output specified twice") }
                let path = try value(flag)
                guard !path.isEmpty else { throw Failure("Output path must not be empty") }
                request.output = URL(fileURLWithPath: path).standardizedFileURL
            case "--duration" where recording:
                let raw = try value(flag)
                guard request.duration == nil, let n = Double(raw), n.isFinite, (0.1...3600).contains(n) else { throw Failure("Duration must be between 0.1 and 3600 seconds") }
                request.duration = n
            case "--fps" where recording:
                guard request.frameRate == nil else { throw Failure("Frame rate specified twice") }
                let raw = try value(flag)
                guard let fps = Int(raw), let rate = RecordingFrameRate(rawValue: fps) else {
                    throw Failure("--fps must be 30, 60, or 120")
                }
                request.frameRate = rate
            case "--cursor" where !recording: request.cursor = true
            case "--no-shadow" where !recording: request.shadow = false
            case "--no-cursor" where recording: request.cursor = false
            case "--native" where recording: request.native = true
            case "--system-audio" where recording: request.systemAudio = true
            case "--microphone" where recording: request.microphone = true
            default: throw Failure("Unknown option: \(flag)")
            }
            i += 1
        }
        guard request.target != nil, request.output != nil else { throw Failure("A target and --output are required") }
        if recording && request.duration == nil { throw Failure("--duration is required for recording") }
        return request
    }
    static func writeJSON(_ value: [String: Any], to handle: FileHandle = .standardOutput) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
            handle.write(data); handle.write(Data("\n".utf8))
        }
    }
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first else { print(help); return 0 }
            if command == "--help" || command == "-h" { print(help); return 0 }
            if command == "help" {
                guard arguments.count <= 2 else { throw Failure("Usage: karuto help [command]") }
                let text = commandHelp(arguments.dropFirst().first)
                guard !text.isEmpty else { throw Failure("Unknown command: \(arguments[1])") }
                print(text); return 0
            }
            if arguments.count == 2 && ["--help", "-h"].contains(arguments[1]) {
                let text = commandHelp(command)
                guard !text.isEmpty else { throw Failure("Unknown command: \(command)") }
                print(text); return 0
            }
            if command == "permissions" {
                guard arguments.count == 1 else { throw Failure("Usage: karuto permissions") }
                let mic: String
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: mic = "authorized"
                case .denied: mic = "denied"
                case .restricted: mic = "restricted"
                case .notDetermined: mic = "not_determined"
                @unknown default: mic = "unknown"
                }
                writeJSON(["screen_recording": CGPreflightScreenCaptureAccess() ? "authorized" : "not_authorized", "microphone": mic, "automatic_scrolling": CGPreflightPostEventAccess() ? "authorized" : "not_authorized"]); return 0
            }
            if command == "list" {
                guard arguments.count == 2, ["displays", "windows"].contains(arguments[1]) else { throw Failure("Usage: karuto list displays | windows") }
                let catalog = try await CaptureEngine().catalog()
                func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
                if arguments[1] == "displays" { writeJSON(["displays": catalog.displays.map { ["id": $0.id, "name": $0.name, "bounds": rect($0.frame), "scale": $0.scale] as [String: Any] }]) }
                else { writeJSON(["windows": catalog.windows.map { ["id": $0.id, "title": $0.title, "application": $0.applicationName, "bounds": rect($0.frame)] as [String: Any] }]) }
                return 0
            }
            if command == "scroll-region" {
                writeJSON(try await ScrollRegionCommand.run(Array(arguments.dropFirst())))
                return 0
            }
            if command == "scroll" {
                writeJSON(try await ScrollingCaptureCommand.run(arguments: Array(arguments.dropFirst())))
                return 0
            }
            guard command == "screenshot" || command == "record" else { throw Failure("Unknown command: \(command)") }
            let recording = command == "record"
            let request = try parse(Array(arguments.dropFirst()), recording: recording)
            guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen recording access required. Grant Karuto access in System Settings and restart; the CLI does not prompt.", code: 3) }
            if request.microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { throw Failure("Microphone access required. Grant Karuto access before using --microphone; the CLI does not prompt.", code: 3) }
            let output = request.output!, target = request.target!
            guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure("Output already exists: \(output.path)", code: 1) }
            let engine = CaptureEngine(headless: true)
            if case let .area(id, rect) = target {
                let catalog = try await engine.catalog()
                guard let display = catalog.displays.first(where: { $0.id == id }), display.frame.contains(rect) else { throw Failure("Area must be entirely within the specified display") }
            }
            let temporary = output.deletingLastPathComponent().appendingPathComponent(".karuto-\(UUID().uuidString).\(recording ? "mp4" : "png")")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if recording {
                let options = RecordingOptions(systemAudio: request.systemAudio, microphone: request.microphone,
                                               showsCursor: request.cursor, resolution: request.native ? .native : .hd1080,
                                               frameRate: request.frameRate ?? .fps30)
                try await engine.startRecording(target: target, options: options, to: temporary)
                var recordingFailure: Error?
                let timer = Task { try await Task.sleep(for: .seconds(request.duration!)) }
                engine.onFailure = { error in
                    recordingFailure = error
                    timer.cancel()
                }
                do {
                    try await timer.value
                } catch {
                    timer.cancel()
                    throw recordingFailure ?? error
                }
                if let recordingFailure { throw recordingFailure }
                let result = try await engine.stopRecording()
                try FileManager.default.moveItem(at: temporary, to: output)
                writeJSON(["path": output.path, "type": "video", "width": result.width, "height": result.height, "duration": result.duration])
            } else {
                let image = try await engine.capture(target: target, options: ScreenshotOptions(includeShadow: request.shadow, showsCursor: request.cursor))
                guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw StorageError.encode }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw StorageError.encode }
                try FileManager.default.moveItem(at: temporary, to: output)
                writeJSON(["path": output.path, "type": "image", "width": image.width, "height": image.height])
            }
            return 0
        } catch {
            let failure = error as? Failure
            writeJSON(["error": error.localizedDescription, "code": failure?.code ?? 1], to: .standardError)
            return failure?.code ?? 1
        }
    }
}

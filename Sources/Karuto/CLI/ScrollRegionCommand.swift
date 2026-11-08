import AppKit
import ApplicationServices

@MainActor
enum ScrollRegionCommand {
    static func run(_ args: [String]) async throws -> [String: Any] {
        guard args.count == 5, args[0] == "--window", args[2] == "--point",
              let id = UInt32(args[1]), let x = Double(args[3]), let y = Double(args[4]), x.isFinite, y.isFinite else {
            throw KarutoCLI.Failure("Usage: karuto scroll-region --window ID --point X Y")
        }
        guard AXIsProcessTrusted() else { throw KarutoCLI.Failure("Accessibility access is required for pane discovery", code: 3) }
        let catalog = try await CaptureEngine().catalog()
        let point = CGPoint(x: x, y: y)
        guard let window = catalog.windows.first(where: { $0.id == id }), window.frame.contains(point),
              let display = catalog.displays.first(where: { $0.frame.contains(point) }) else { throw KarutoCLI.Failure("Point must lie in the specified visible window") }
        let rect = await ScrollRegionResolver().resolve(ScrollRegionRequest(point: point, window: window, display: display, generation: 0))
        return ["window": id, "suggested": rect != nil,
                "bounds": rect.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] } as Any? ?? NSNull(),
                "verified": false]
    }
}

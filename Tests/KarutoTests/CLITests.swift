import Testing
import Foundation
@testable import Karuto

@MainActor
struct CLITests {
    @Test func parsesExplicitTargetsAndOptions() throws {
        let request = try KarutoCLI.parse(["--area", "2", "-200", "50", "100", "80", "--output", "/tmp/out.png", "--cursor"], recording: false)
        #expect(request.target == .area(displayID: 2, rect: CGRect(x: -200, y: 50, width: 100, height: 80)))
        #expect(request.cursor)
        let recording = try KarutoCLI.parse(["--window", "42", "--duration", "1.5", "--output", "/tmp/out.mp4", "--native"], recording: true)
        #expect(recording.target == .window(id: 42))
        #expect(recording.duration == 1.5)
        #expect(recording.native)
    }
    @Test func rejectsInvalidOrAmbiguousRequests() {
        for args in [["--display", "1", "--window", "2", "--output", "/tmp/a"], ["--display", "0", "--output", "/tmp/a"], ["--area", "1", "0", "0", "nan", "5", "--output", "/tmp/a"], ["--display", "1"]] {
            #expect(throws: KarutoCLI.Failure.self) { try KarutoCLI.parse(args, recording: false) }
        }
        #expect(throws: KarutoCLI.Failure.self) { try KarutoCLI.parse(["--display", "1", "--duration", "0", "--output", "/tmp/a"], recording: true) }
    }
}

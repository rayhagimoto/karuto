import Foundation
import Testing
import ImageIO
@testable import Karuto

struct StitchingSessionTests {
    @Test func nativeDecoderReadsStitchedPNG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory)
        #expect(try session.append(frame(start: 0)).accepted)
        #expect(try !session.append(frame(start: 0)).accepted)
        let progress = try session.append(frame(start: 24))
        #expect(progress.accepted)
        #expect(progress.height == 120)
        let output = directory.appendingPathComponent("capture.png")
        let result = try session.finish(to: output)
        #expect(result.width == 64)
        #expect(result.height == 120)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64)
        #expect(image.height == 120)
        #expect(throws: (any Error).self) { try session.append(frame(start: 48)) }
        session.cancel()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["capture.png"])
    }

    @Test func unchangedViewportCannotBeSavedAsSuccessfulScrollingCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory)
        let initial = try session.append(frame(start: 0))
        #expect(initial.accepted)
        #expect(initial.message.contains("Ready"))
        let unchanged = try session.append(frame(start: 0))
        #expect(!unchanged.accepted)
        #expect(unchanged.message.contains("No scrolling captured"))
        let output = directory.appendingPathComponent("capture.png")
        #expect(throws: StitchingError.self) { try session.finish(to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        // A premature Finish attempt must not corrupt the stitching state.
        #expect(try session.append(frame(start: 24)).accepted)
        #expect(try session.finish(to: output).height == 120)
    }

    @Test func unresolvedOverlapRequiresExplicitPartialSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory, detectScrollContent: true,
                                           contentHint: CGRect(x: 0, y: 0, width: 1, height: 1))
        for offset in [0, 12, 24, 36] { _ = try session.append(frame(start: offset)) }
        #expect(session.verifiedContentRect == CGRect(x: 0, y: 0, width: 64, height: 96))
        #expect(session.partialReason == nil)
        #expect(try session.append(frame(start: 1000)).disposition == 2)
        let output = directory.appendingPathComponent("partial.png")
        #expect(throws: StitchingError.self) { try session.finish(to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try session.append(frame(start: 36)).disposition == 5)
        #expect(session.partialReason == nil)
        #expect(try session.append(frame(start: 48)).accepted)
        #expect(session.partialReason == nil)
        #expect(try session.append(frame(start: 1000)).disposition == 2)
        #expect(try session.finish(to: output, allowPartial: true).height == 144)
    }

    @Test func anOccludingBottomBandRequiresPartialReview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory, detectScrollContent: true)
        let fixed = frame(start: 1_000)
        for offset in [0, 12, 24, 36] {
            let source = frame(start: offset)
            var bytes = source.data
            let footer = (source.bytesPerRow * 76)..<bytes.count
            bytes.replaceSubrange(footer, with: fixed.data[footer])
            _ = try session.append(PixelFrame(data: bytes, width: source.width, height: source.height,
                                             bytesPerRow: source.bytesPerRow))
        }
        #expect(session.verifiedContentRect?.height == 76)
        #expect(session.partialReason?.contains("fixed bottom band") == true)
    }

    @Test func automaticBaselineWaitsForLayoutChangesAndKeepsTheSettledViewport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory, detectScrollContent: true, waitForBaseline: true)
        let start = ContinuousClock.now
        _ = try session.append(frame(start: 1_000), at: start)
        let settled = frame(start: 0)
        _ = try session.append(settled, at: start.advanced(by: .milliseconds(250)))
        #expect(try !session.beginMotion(force: false, at: start.advanced(by: .milliseconds(650))))
        _ = try session.append(settled, at: start.advanced(by: .milliseconds(690)))
        #expect(try session.beginMotion(force: false, at: start.advanced(by: .milliseconds(700))))
        for offset in [12, 24] { _ = try session.append(frame(start: offset)) }
        #expect(try session.append(frame(start: 36)).height == 132)
        let output = directory.appendingPathComponent("settled.png")
        #expect(try session.finish(to: output).height == 132)
    }

    @Test func manualFallbackCanStartBeforeTheFirstFrame() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory, waitForBaseline: true)
        #expect(try !session.beginMotion(force: true))
        #expect(try session.append(frame(start: 0)).accepted)
        #expect(try session.append(frame(start: 12)).height == 108)
    }

    @Test func cancellationIsIdempotentAndRemovesOnlyScratch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory)
        let keep = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        _ = try session.append(frame(start: 0))
        session.cancel()
        session.cancel()
        #expect(throws: (any Error).self) { try session.append(frame(start: 24)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["keep.txt"])
    }

    @Test func invalidFrameIsRejectedAtBridge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try StitchingSession(directory: directory)
        #expect(throws: (any Error).self) { try session.append(PixelFrame(data: Data(), width: -1, height: 96, bytesPerRow: 256)) }
        #expect(throws: (any Error).self) { try session.append(PixelFrame(data: Data([0]), width: 64, height: 96, bytesPerRow: 256)) }
        #expect(try session.append(frame(start: 0)).accepted)
        session.cancel()
    }

    private func frame(start: Int) -> PixelFrame {
        let width = 64, height = 96, stride = 272
        var bytes = [UInt8](repeating: 0xCC, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                var hash = UInt32(x) &* 0x45d9f3b ^ (UInt32(y + start) &* 0x119de1f3)
                hash ^= hash >> 16
                hash = hash &* 0x45d9f3b
                let offset = y * stride + x * 4
                bytes[offset] = UInt8(truncatingIfNeeded: hash)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: hash >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: hash >> 16)
                bytes[offset + 3] = 255
            }
        }
        return PixelFrame(data: Data(bytes), width: width, height: height, bytesPerRow: stride)
    }
}

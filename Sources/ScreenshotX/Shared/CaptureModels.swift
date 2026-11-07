import Foundation
import CoreGraphics

enum CaptureMode: String, CaseIterable, Sendable {
    case area, fullscreen, window, scrolling, timer, recording
    var title: String {
        switch self {
        case .area: "Area"
        case .fullscreen: "Fullscreen"
        case .window: "Window"
        case .scrolling: "Scrolling"
        case .timer: "Timer"
        case .recording: "Recording"
        }
    }
}

/// Geometry crossing module interfaces is always global AppKit screen points (bottom-left origin).
enum CaptureTarget: Equatable, Sendable {
    case display(id: UInt32)
    case area(displayID: UInt32, rect: CGRect)
    case window(id: UInt32)
}

struct CaptureDisplay: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let scale: CGFloat
}

struct CaptureWindow: Identifiable, Sendable {
    let id: UInt32
    let title: String
    let applicationName: String
    let frame: CGRect
}

struct CaptureCatalog: Sendable {
    let displays: [CaptureDisplay]
    let windows: [CaptureWindow]
}

struct ScreenshotOptions: Sendable {
    var includeShadow = true
    var showsCursor = false
}

enum RecordingResolution: String, CaseIterable, Sendable {
    case hd1080, native
}

struct RecordingOptions: Sendable {
    var systemAudio = false
    var microphone = false
    var microphoneID: String? = nil
    var showsCursor = true
    var resolution: RecordingResolution = .hd1080
}

struct RecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let width: Int
    let height: Int
}

/// Owned BGRA8 bytes, top-to-bottom, with explicit stride. Never contains borrowed CVPixelBuffer storage.
struct PixelFrame: Sendable {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

enum ArtifactKind: String, Sendable { case image, video }

struct CaptureArtifact: Identifiable, Sendable {
    let id: UUID
    var url: URL
    let kind: ArtifactKind
    let width: Int
    let height: Int
    var duration: TimeInterval = 0
    var isSaved = false
}

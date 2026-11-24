/// Region and options for one capture mode.
struct CaptureSessionPreferences: Equatable, Sendable {
    static let delays = [0, 1, 3, 5, 10]
    var region: CaptureRegion = .area
    var delaySeconds = 0
    var instantCapture: Bool
    var freezeDisplay = false
}

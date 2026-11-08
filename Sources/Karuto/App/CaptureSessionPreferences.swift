/// A value snapshot of saved defaults. Overlay changes mutate only this session.
struct CaptureSessionPreferences: Equatable, Sendable {
    var instantCapture: Bool
    var freezeDisplay: Bool

    @MainActor init(defaults: AppSettings) {
        instantCapture = defaults.instantCapture
        freezeDisplay = defaults.freezeDisplay
    }
}

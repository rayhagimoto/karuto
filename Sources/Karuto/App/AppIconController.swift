import AppKit

@MainActor
final class AppIconController {
    private let settings: AppSettings
    private var systemAppearanceObserver: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let preference = settings.appIcon
        let dark = switch preference {
        case .light: false
        case .dark: true
        case .system: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
        let name = dark ? "KarutoIcon-Dark" : "KarutoIcon-Light"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
        onChange?()
    }
}

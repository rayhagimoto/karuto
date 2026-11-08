import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

enum SetupPermission: CaseIterable, Hashable {
    case screenRecording, accessibility, microphone

    var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }
    var detail: String {
        switch self {
        case .screenRecording: "Required for screenshots and recording."
        case .accessibility: "Automatic scrolling and pane suggestions."
        case .microphone: "Only needed to record your microphone."
        }
    }
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum SetupAuthorization: Equatable {
    case allowed, notEnabled, notRequested, restricted
    var title: String {
        switch self {
        case .allowed: "Allowed"
        case .notEnabled: "Not enabled"
        case .notRequested: "Not requested"
        case .restricted: "Restricted"
        }
    }
}

/// Keeps operating-system changes behind a seam so Settings tests never alter
/// the user's privacy grants or login items.
@MainActor
protocol SetupSupporting: AnyObject {
    func authorization(for permission: SetupPermission) -> SetupAuthorization
    var loginStatus: SMAppService.Status { get }
    func setLaunchAtLogin(_ enabled: Bool) async throws
    func openSettings(for permission: SetupPermission) throws
    func openLoginItems()
}

@MainActor
final class SystemSetupSupport: SetupSupporting {
    private var changingLoginItem = false
    func authorization(for permission: SetupPermission) -> SetupAuthorization {
        switch permission {
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .allowed : .notEnabled
        case .accessibility: AXIsProcessTrusted() && CGPreflightPostEventAccess() ? .allowed : .notEnabled
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .allowed
            case .notDetermined: .notRequested
            case .restricted: .restricted
            default: .notEnabled
            }
        }
    }

    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }

    func setLaunchAtLogin(_ enabled: Bool) async throws {
        // A view can be reopened while asynchronous unregistration is pending.
        guard !changingLoginItem else {
            throw NSError(domain: "Karuto.Setup", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Another login item change is in progress. Try again in a moment."])
        }
        changingLoginItem = true
        defer { changingLoginItem = false }
        if enabled {
            guard loginStatus != .enabled && loginStatus != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else {
            guard loginStatus != .notRegistered else { return }
            try await SMAppService.mainApp.unregister()
        }
    }

    func openSettings(for permission: SetupPermission) throws {
        guard NSWorkspace.shared.open(permission.settingsURL) else {
            throw NSError(domain: "Karuto.Setup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Couldn’t open System Settings. Open Privacy & Security → \(permission.title) manually."])
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

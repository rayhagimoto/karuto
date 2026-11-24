import AppKit
import Testing
@testable import Karuto

@MainActor
struct OverlayAppearanceTests {
    @Test func glassAndControlsFollowWindowAppearance() throws {
        _ = NSApplication.shared
        let window = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100))
        let surface = SettingsGlassSurface()
        surface.frame = window.contentView!.bounds
        window.contentView = surface
        let button = CaptureToolbarButton("Area", symbol: "viewfinder")
        surface.content.addSubview(button)
        defer { window.close() }
        for (appearance, expected) in [(NSAppearance.Name.aqua, NSAppearance.Name.aqua), (.darkAqua, .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            #expect(surface.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        }
    }
    @Test func checkedSymbolExposesItsStateInBothAppearances() {
        _ = NSApplication.shared
        let button = CaptureToolbarButton("Recognize text", symbol: "text.viewfinder", checked: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            button.appearance = NSAppearance(named: appearance)
            for state in [NSControl.StateValue.on, .off] {
                button.state = state
                #expect(button.showsCheckmark)
                #expect(button.accessibilityValue() as? Int == (state == .on ? 1 : 0))
                #expect(button.accessibilityRole() == .checkBox)
            }
        }
    }
}

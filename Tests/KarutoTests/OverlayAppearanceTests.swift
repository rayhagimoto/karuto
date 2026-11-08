import AppKit
import Testing
@testable import Karuto

@MainActor
struct OverlayAppearanceTests {
    @Test func glassAndControlsFollowWindowAppearance() throws {
        _ = NSApplication.shared
        let window = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100))
        let surface = CaptureSurface(frame: window.contentView!.bounds)
        window.contentView = surface
        let button = CaptureModeButton(title: "Area", symbol: "viewfinder")
        surface.contentView.addSubview(button)
        defer { window.close() }
        for (appearance, expected) in [(NSAppearance.Name.aqua, NSAppearance.Name.aqua), (.darkAqua, .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            #expect(surface.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        }
    }
    @Test func modePaletteUsesViewAppearanceWhenCallerAppearanceDiffers() throws {
        _ = NSApplication.shared
        let button = CaptureModeButton(title: "Area", symbol: "viewfinder")
        button.appearance = NSAppearance(named: .darkAqua)
        // State changes happen in event handlers, outside AppKit's drawing scope.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            button.state = .on
        }
        let background = try #require(button.layer?.backgroundColor)
        let rgb = try #require(NSColor(cgColor: background)?.usingColorSpace(.deviceRGB))
        #expect(rgb.redComponent > 0.9)
        #expect(rgb.alphaComponent > 0)
        button.appearance = NSAppearance(named: .aqua)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            button.state = .on
        }
        let lightBackground = try #require(button.layer?.backgroundColor)
        let lightRGB = try #require(NSColor(cgColor: lightBackground)?.usingColorSpace(.deviceRGB))
        #expect(lightRGB.redComponent < 0.2)
    }

}

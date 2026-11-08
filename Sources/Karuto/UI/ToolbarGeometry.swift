import CoreGraphics

/// Toolbar and menu placement use global AppKit points (bottom-left origin).
enum ToolbarGeometry {
    struct MenuPlacement: Equatable {
        let topLeft: CGPoint
        let opensUpward: Bool
    }

    static func menuPlacement(anchor: CGRect, menuSize: CGSize, visibleFrame: CGRect,
                              gap: CGFloat = 8, margin: CGFloat = 8) -> MenuPlacement {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        let above = max(0, bounds.maxY - anchor.maxY - gap)
        let below = max(0, anchor.minY - bounds.minY - gap)
        let upward = below < menuSize.height && above > below
        let desiredTop = upward ? anchor.maxY + gap + menuSize.height : anchor.minY - gap
        // NSMenu's nil positioning item anchors the menu's TOP-left corner.
        // Clamp the complete menu, not merely the button point. On a genuinely
        // undersized screen AppKit can still provide native menu scrolling.
        let top = min(max(desiredTop, bounds.minY + min(menuSize.height, bounds.height)), bounds.maxY)
        let x = min(max(anchor.maxX - menuSize.width, bounds.minX),
                    max(bounds.minX, bounds.maxX - menuSize.width))
        return MenuPlacement(topLeft: CGPoint(x: x, y: top), opensUpward: upward)
    }

    static func clamped(_ frame: CGRect, to visibleFrame: CGRect, margin: CGFloat = 8) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        return CGRect(x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width)),
                      y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height)),
                      width: frame.width, height: frame.height)
    }

    static func moved(_ initialFrame: CGRect, from start: CGPoint, to point: CGPoint,
                      visibleFrames: [CGRect]) -> CGRect {
        let proposed = initialFrame.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        guard let screen = visibleFrames.first(where: { $0.contains(point) })
                ?? visibleFrames.max(by: { overlap($0, proposed) < overlap($1, proposed) }) else { return proposed }
        return clamped(proposed, to: screen)
    }

    private static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

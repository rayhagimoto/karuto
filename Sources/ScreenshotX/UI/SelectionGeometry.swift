import CoreGraphics

/// Pure selection geometry. Every rectangle is in global AppKit screen points.
enum SelectionGeometry {
    static func rectangle(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
    }

    static func moved(_ rect: CGRect, delta: CGSize, within bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        return CGRect(x: min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - width),
                      y: min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    static func resized(_ rect: CGRect, size: CGSize, within bounds: CGRect) -> CGRect {
        moved(CGRect(origin: rect.origin, size: CGSize(width: max(2, min(size.width, bounds.width)),
                                                     height: max(2, min(size.height, bounds.height)))),
              delta: .zero, within: bounds)
    }
}

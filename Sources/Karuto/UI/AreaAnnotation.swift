// SPDX-License-Identifier: GPL-3.0-or-later
// Circle counter geometry adapted from Flameshot's circlecounttool.cpp.
// SPDX-FileCopyrightText: 2017-2019 Alejandro Sirgo Rica & Contributors
// Karuto adaptation (2026) uses Core Graphics and Core Text in AppKit points.
import CoreGraphics
import CoreText
import Foundation

enum AnnotationTool: String, CaseIterable {
    case select = "Adjust selection", pen = "Pen", arrow = "Arrow", rectangle = "Rectangle"
    case ellipse = "Ellipse", highlight = "Highlighter", text = "Text", counter = "Numbered circle", mosaic = "Mosaic"

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

enum AnnotationColor: String, CaseIterable {
    case red, blue, yellow, white, black

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 0.92, green: 0.16, blue: 0.20, alpha: 1)
        case .blue: CGColor(srgbRed: 0.12, green: 0.46, blue: 0.98, alpha: 1)
        case .yellow: CGColor(srgbRed: 1, green: 0.82, blue: 0.10, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        case .black: CGColor(gray: 0, alpha: 1)
        }
    }
}

/// All points are relative to the bottom left of the capture, independent of Retina scale.
struct AreaAnnotation: Sendable, Equatable {
    var tool: AnnotationTool
    var color: AnnotationColor
    var start: CGPoint
    var end: CGPoint
    var stroke: [CGPoint] = []
    var label = ""
    var textStyle = AnnotationTextStyle()

    mutating func setTextFrame(_ frame: CGRect) {
        start = frame.origin
        end = CGPoint(x: frame.maxX, y: frame.maxY)
    }

    mutating func offset(by delta: CGPoint) {
        func moved(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.x, y: p.y + delta.y) }
        start = moved(start)
        end = moved(end)
        stroke = stroke.map(moved)
    }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var outline: CGPath? {
        switch tool {
        case .rectangle: return CGPath(rect: rect, transform: nil)
        case .ellipse: return CGPath(ellipseIn: rect, transform: nil)
        case .arrow:
            let path = CGMutablePath()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = min(15, hypot(end.x - start.x, end.y - start.y) * 0.5)
            path.move(to: start)
            path.addLine(to: end)
            for offset in [-0.5, 0.5] {
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x - cos(angle + offset) * head, y: end.y - sin(angle + offset) * head))
            }
            return path
        default: return nil
        }
    }

    private func textLine(size: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
    }

    var drawingBounds: CGRect {
        switch tool {
        case .pen, .highlight:
            var bounds = CGRect(origin: start, size: .zero)
            for point in stroke { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
            return bounds.insetBy(dx: -10, dy: -10)
        case .counter, .arrow: return rect.insetBy(dx: -19, dy: -19)
        case .text: return rect
        default: return rect.insetBy(dx: -3, dy: -3)
        }
    }

    func draw(in ctx: CGContext, canvas: CGSize, mosaic: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch tool {
        case .select: break
        case .pen, .highlight:
            let width: CGFloat = tool == .pen ? 3 : 16
            ctx.setLineWidth(width)
            if tool == .highlight { ctx.setAlpha(0.4) }
            if stroke.isEmpty {
                ctx.fillEllipse(in: CGRect(x: start.x - width/2, y: start.y - width/2, width: width, height: width))
            } else {
                ctx.addLines(between: [start] + stroke)
                ctx.strokePath()
            }
        case .rectangle, .ellipse, .arrow:
            if let outline { ctx.addPath(outline); ctx.strokePath() }
        case .mosaic:
            ctx.clip(to: rect)
            // Cover the area while the live preview sample is being acquired.
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
            ctx.fill(rect)
            if let mosaic {
                ctx.interpolationQuality = .none
                ctx.draw(mosaic, in: CGRect(origin: .zero, size: canvas))
            }
        case .text:
            textStyle.draw(label, color: color, in: rect, context: ctx)
        case .counter:
            let radius: CGFloat = 15
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            if length > radius {
                let nx = -dy * radius / length, ny = dx * radius / length
                ctx.move(to: CGPoint(x: start.x + nx, y: start.y + ny))
                ctx.addLine(to: end)
                ctx.addLine(to: CGPoint(x: start.x - nx, y: start.y - ny))
                ctx.fillPath()
            }
            ctx.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius, width: 2 * radius, height: 2 * radius))
            let line = textLine(size: label.count < 3 ? 16 : 12)
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            ctx.setFillColor(CGColor(gray: color == .yellow || color == .white ? 0 : 1, alpha: 1))
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: start.x - bounds.midX, y: start.y - bounds.midY)
            CTLineDraw(line, ctx)
        }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Keep only one color sample per ten-point tile for preview. The export
    /// samples the actual captured frame, including timer and live-mode changes.
    static func mosaicGrid(_ image: CGImage, size: CGSize) throws -> CGImage {
        let w = max(1, Int(ceil(size.width / 10))), h = max(1, Int(ceil(size.height / 10)))
        guard let ctx = context(width: w, height: h) else { throw StorageError.encode }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let grid = ctx.makeImage() else { throw StorageError.encode }
        return grid
    }

    static func composite(_ marks: [Self], over image: CGImage, size: CGSize) throws -> CGImage {
        guard !marks.isEmpty else { return image }
        guard size.width > 0, size.height > 0, let ctx = context(width: image.width, height: image.height) else { throw StorageError.encode }
        let grid = marks.contains { $0.tool == .mosaic } ? try mosaicGrid(image, size: size) : nil
        ctx.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        for mark in marks { mark.draw(in: ctx, canvas: size, mosaic: grid) }
        guard let result = ctx.makeImage() else { throw StorageError.encode }
        return result
    }
}

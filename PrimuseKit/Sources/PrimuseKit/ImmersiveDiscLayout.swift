import Foundation

public struct ImmersiveDiscLayout: Sendable {
    public let artworkBounds: CGRect
    public let textBounds: CGRect
    public let diameter: CGFloat
    public let canvasSize: CGSize

    public init(content: CGRect, portrait: Bool, hasTonearm: Bool, spacing: CGFloat) {
        if portrait {
            let artHeight = max(0, content.height * 0.57 - spacing / 2)
            artworkBounds = CGRect(x: content.minX, y: content.minY, width: content.width, height: artHeight)
            textBounds = CGRect(x: content.minX, y: artworkBounds.maxY + spacing,
                                width: content.width, height: max(0, content.maxY - artworkBounds.maxY - spacing))
        } else {
            let artWidth = max(0, (content.width - spacing) * 0.55)
            artworkBounds = CGRect(x: content.minX, y: content.minY, width: artWidth, height: content.height)
            textBounds = CGRect(x: artworkBounds.maxX + spacing, y: content.minY,
                                width: max(0, content.width - artWidth - spacing), height: content.height)
        }
        let widthRatio: CGFloat = hasTonearm ? 1.14 : 1
        diameter = max(0, min(artworkBounds.width / widthRatio, artworkBounds.height) * 0.88)
        canvasSize = CGSize(width: diameter * widthRatio, height: diameter)
    }

    public var travel: CGSize {
        CGSize(width: max(0, artworkBounds.width - canvasSize.width),
               height: max(0, artworkBounds.height - canvasSize.height))
    }

    public func frame(at position: CGPoint) -> CGRect {
        let position = Self.clamped(position)
        return CGRect(x: artworkBounds.minX + travel.width * position.x,
                      y: artworkBounds.minY + travel.height * position.y,
                      width: canvasSize.width, height: canvasSize.height)
    }

    public func containsDisc(_ point: CGPoint, at position: CGPoint) -> Bool {
        let frame = frame(at: position)
        let dx = point.x - (frame.minX + diameter / 2)
        let dy = point.y - (frame.minY + diameter / 2)
        return diameter > 0 && dx * dx + dy * dy <= diameter * diameter / 4
    }

    public func translated(_ position: CGPoint, by translation: CGSize) -> CGPoint {
        Self.clamped(CGPoint(x: position.x + (travel.width > 0 ? translation.width / travel.width : 0),
                             y: position.y + (travel.height > 0 ? translation.height / travel.height : 0)))
    }

    public static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? min(max(point.x, 0), 1) : 0.5,
                y: point.y.isFinite ? min(max(point.y, 0), 1) : 0.5)
    }
}

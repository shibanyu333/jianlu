import Foundation

public enum ScreenshotMarkup: Codable, Equatable, Identifiable, Sendable {
    case stroke(AnnotationEvent)
    case text(ScreenshotTextMarkup)
    case mosaic(ScreenshotMosaicMarkup)

    public var id: UUID {
        switch self {
        case .stroke(let annotation):
            annotation.id
        case .text(let text):
            text.id
        case .mosaic(let mosaic):
            mosaic.id
        }
    }
}

public struct ScreenshotTextMarkup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var anchor: NormalizedPoint
    public var colorHex: String
    public var fontSize: Double

    public init(
        id: UUID = UUID(),
        text: String,
        anchor: NormalizedPoint,
        colorHex: String = "#FF3B30",
        fontSize: Double = 24
    ) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.colorHex = colorHex
        self.fontSize = max(8, fontSize)
    }
}

public struct ScreenshotMosaicMarkup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var rect: NormalizedRect
    public var blockSize: Double

    public init(
        id: UUID = UUID(),
        rect: NormalizedRect,
        blockSize: Double = 10
    ) {
        self.id = id
        self.rect = rect
        self.blockSize = max(2, blockSize)
    }
}

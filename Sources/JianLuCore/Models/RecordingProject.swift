import Foundation

public enum CameraFrameShape: String, Codable, CaseIterable, Sendable {
    case circle
    case square
    case roundedSquare

    public var displayName: String {
        switch self {
        case .circle:
            "圆形"
        case .square:
            "方形"
        case .roundedSquare:
            "圆角方形"
        }
    }
}

public struct CameraLayoutEvent: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var frame: NormalizedRect
    public var shape: CameraFrameShape
    public var isVisible: Bool

    public init(time: TimeInterval, frame: NormalizedRect, shape: CameraFrameShape, isVisible: Bool) {
        self.time = time
        self.frame = frame
        self.shape = shape
        self.isVisible = isVisible
    }
}

public struct ZoomEvent: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var magnification: Double
    public var focus: NormalizedPoint

    public init(time: TimeInterval, magnification: Double, focus: NormalizedPoint) {
        self.time = time
        self.magnification = magnification
        self.focus = focus
    }
}

public struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct StrokePoint: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var point: NormalizedPoint

    public init(time: TimeInterval, point: NormalizedPoint) {
        self.time = time
        self.point = point
    }
}

public enum AnnotationTool: String, Codable, CaseIterable, Sendable {
    case pen
    case highlight
    case line
    case arrow

    public var displayName: String {
        switch self {
        case .pen:
            "画笔"
        case .highlight:
            "高亮"
        case .line:
            "直线"
        case .arrow:
            "箭头"
        }
    }
}

public struct AnnotationEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var time: TimeInterval
    public var tool: AnnotationTool
    public var points: [StrokePoint]
    public var colorHex: String
    public var lineWidth: Double

    public init(
        id: UUID = UUID(),
        time: TimeInterval,
        tool: AnnotationTool,
        points: [StrokePoint],
        colorHex: String,
        lineWidth: Double
    ) {
        self.id = id
        self.time = time
        self.tool = tool
        self.points = points
        self.colorHex = colorHex
        self.lineWidth = lineWidth
    }
}

public enum EffectEvent: Codable, Equatable, Sendable {
    case cameraLayout(CameraLayoutEvent)
    case zoom(ZoomEvent)
    case annotation(AnnotationEvent)

    public var time: TimeInterval {
        switch self {
        case .cameraLayout(let event):
            event.time
        case .zoom(let event):
            event.time
        case .annotation(let event):
            event.time
        }
    }
}

public struct RecordingProject: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var screenRecordingURL: URL
    public var cameraRecordingURL: URL?
    public var events: [EffectEvent]
    public var timeline: EditTimeline

    public var duration: TimeInterval {
        timeline.totalExportDuration
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        screenRecordingURL: URL,
        cameraRecordingURL: URL?,
        events: [EffectEvent],
        timeline: EditTimeline
    ) {
        self.id = id
        self.createdAt = createdAt
        self.screenRecordingURL = screenRecordingURL
        self.cameraRecordingURL = cameraRecordingURL
        self.events = events.sorted { $0.time < $1.time }
        self.timeline = timeline
    }

    public mutating func appendEvent(_ event: EffectEvent) {
        events.append(event)
        events.sort { $0.time < $1.time }
    }
}

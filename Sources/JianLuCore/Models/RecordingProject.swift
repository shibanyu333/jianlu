import CoreGraphics
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

public enum CameraBackgroundStyle: String, Codable, CaseIterable, Sendable {
    case original
    case studioBlue
    case softGray
    case warmSunset
    case mint
    case graphite
    case office
    case bookshelf
    case meetingRoom
    case cityWindow
    case lightStudio

    public var displayName: String {
        switch self {
        case .original:
            "原始背景"
        case .studioBlue:
            "商务蓝"
        case .softGray:
            "浅灰"
        case .warmSunset:
            "暖橙"
        case .mint:
            "薄荷绿"
        case .graphite:
            "深灰"
        case .office:
            "真实办公室"
        case .bookshelf:
            "书架"
        case .meetingRoom:
            "会议室"
        case .cityWindow:
            "城市窗景"
        case .lightStudio:
            "明亮影棚"
        }
    }
}

public enum CameraBackgroundBlur: String, Codable, CaseIterable, Sendable {
    case off
    case light
    case medium
    case strong

    public var displayName: String {
        switch self {
        case .off:
            "关闭"
        case .light:
            "轻度"
        case .medium:
            "中度"
        case .strong:
            "强度"
        }
    }

    public var radius: Double {
        switch self {
        case .off:
            0
        case .light:
            8
        case .medium:
            16
        case .strong:
            26
        }
    }
}

public enum ZoomShortcut: String, Codable, CaseIterable, Sendable {
    case controlOptionCommandZ
    case controlOptionZ
    case controlOptionCommandSpace
    case controlOptionSpace

    public var displayName: String {
        switch self {
        case .controlOptionCommandZ:
            "⌃⌥⌘Z"
        case .controlOptionZ:
            "⌃⌥Z"
        case .controlOptionCommandSpace:
            "⌃⌥⌘Space"
        case .controlOptionSpace:
            "⌃⌥Space"
        }
    }
}

public struct RecordingPreferences: Codable, Equatable, Sendable {
    public var includeAppInterface: Bool
    public var cameraEnabled: Bool
    public var microphoneEnabled: Bool
    public var microphoneNoiseReductionEnabled: Bool
    public var cameraBackgroundStyle: CameraBackgroundStyle
    public var cameraBackgroundBlur: CameraBackgroundBlur
    public var cameraBeautyLevel: Double
    public var zoomShortcut: ZoomShortcut
    public var recordingDirectoryPath: String?
    public var lastSelectedRegion: RecordingRegion?

    private enum CodingKeys: String, CodingKey {
        case includeAppInterface
        case cameraEnabled
        case microphoneEnabled
        case microphoneNoiseReductionEnabled
        case cameraBackgroundStyle
        case cameraBackgroundBlur
        case cameraBeautyLevel
        case zoomShortcut
        case recordingDirectoryPath
        case lastSelectedRegion
    }

    public init(
        includeAppInterface: Bool,
        cameraEnabled: Bool = true,
        microphoneEnabled: Bool = true,
        microphoneNoiseReductionEnabled: Bool = false,
        cameraBackgroundStyle: CameraBackgroundStyle,
        cameraBackgroundBlur: CameraBackgroundBlur,
        cameraBeautyLevel: Double,
        zoomShortcut: ZoomShortcut = .controlOptionCommandZ,
        recordingDirectoryPath: String? = nil,
        lastSelectedRegion: RecordingRegion? = nil
    ) {
        self.includeAppInterface = includeAppInterface
        self.cameraEnabled = cameraEnabled
        self.microphoneEnabled = microphoneEnabled
        self.microphoneNoiseReductionEnabled = microphoneNoiseReductionEnabled
        self.cameraBackgroundStyle = cameraBackgroundStyle
        self.cameraBackgroundBlur = cameraBackgroundBlur
        self.cameraBeautyLevel = min(max(cameraBeautyLevel, 0), 1)
        self.zoomShortcut = zoomShortcut
        self.recordingDirectoryPath = recordingDirectoryPath
        self.lastSelectedRegion = lastSelectedRegion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeAppInterface = try container.decodeIfPresent(Bool.self, forKey: .includeAppInterface) ?? false
        cameraEnabled = try container.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? true
        microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? true
        microphoneNoiseReductionEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneNoiseReductionEnabled) ?? false
        cameraBackgroundStyle = (try? container.decodeIfPresent(CameraBackgroundStyle.self, forKey: .cameraBackgroundStyle)) ?? .original
        cameraBackgroundBlur = (try? container.decodeIfPresent(CameraBackgroundBlur.self, forKey: .cameraBackgroundBlur)) ?? .light
        cameraBeautyLevel = min(max(try container.decodeIfPresent(Double.self, forKey: .cameraBeautyLevel) ?? 0.25, 0), 1)
        zoomShortcut = (try? container.decodeIfPresent(ZoomShortcut.self, forKey: .zoomShortcut)) ?? .controlOptionCommandZ
        recordingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .recordingDirectoryPath)
        lastSelectedRegion = try container.decodeIfPresent(RecordingRegion.self, forKey: .lastSelectedRegion)
    }

    public static let defaults = RecordingPreferences(
        includeAppInterface: false,
        cameraEnabled: true,
        microphoneEnabled: true,
        microphoneNoiseReductionEnabled: false,
        cameraBackgroundStyle: .original,
        cameraBackgroundBlur: .light,
        cameraBeautyLevel: 0.25,
        zoomShortcut: .controlOptionCommandZ
    )
}

public struct RecordingRegion: Codable, Equatable, Sendable {
    public var displayID: UInt32
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var isUsable: Bool {
        width >= 80 && height >= 80
    }

    public init(displayID: UInt32, x: Double, y: Double, width: Double, height: Double) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public func sourceRect(
        displayPixelWidth: Double,
        displayPixelHeight: Double,
        displayPointWidth: Double,
        displayPointHeight: Double
    ) -> CGRect {
        let scaleX = displayPixelWidth / max(1, displayPointWidth)
        let scaleY = displayPixelHeight / max(1, displayPointHeight)
        let pixelWidth = min(max(80, width * scaleX), max(80, displayPixelWidth))
        let pixelHeight = min(max(80, height * scaleY), max(80, displayPixelHeight))
        let pixelX = min(max(0, x * scaleX), max(0, displayPixelWidth - pixelWidth))
        let pixelY = min(max(0, y * scaleY), max(0, displayPixelHeight - pixelHeight))
        return CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)
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
    case rectangle
    case ellipse

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
        case .rectangle:
            "方框"
        case .ellipse:
            "圆框"
        }
    }

    public var isShapeTool: Bool {
        self == .line || self == .arrow || self == .rectangle || self == .ellipse
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

public struct AnnotationClearEvent: Codable, Equatable, Sendable {
    public var time: TimeInterval

    public init(time: TimeInterval) {
        self.time = time
    }
}

public enum EffectEvent: Codable, Equatable, Sendable {
    case cameraLayout(CameraLayoutEvent)
    case zoom(ZoomEvent)
    case annotation(AnnotationEvent)
    case annotationClear(AnnotationClearEvent)

    public var time: TimeInterval {
        switch self {
        case .cameraLayout(let event):
            event.time
        case .zoom(let event):
            event.time
        case .annotation(let event):
            event.time
        case .annotationClear(let event):
            event.time
        }
    }
}

public struct RecordingProject: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var screenRecordingURL: URL
    public var cameraRecordingURL: URL?
    public var microphoneRecordingURL: URL?
    public var sourceDuration: TimeInterval
    public var preferences: RecordingPreferences
    public var events: [EffectEvent]
    public var timeline: EditTimeline

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case screenRecordingURL
        case cameraRecordingURL
        case microphoneRecordingURL
        case sourceDuration
        case preferences
        case events
        case timeline
    }

    public var duration: TimeInterval {
        timeline.totalExportDuration
    }

    public var needsRenderedPreview: Bool {
        if cameraRecordingURL != nil || microphoneRecordingURL != nil {
            return true
        }

        for event in events {
            switch event {
            case .annotation:
                return true
            case .annotationClear:
                break
            case .zoom(let zoom) where zoom.magnification > 1.001:
                return true
            case .cameraLayout(let layout) where layout.isVisible:
                return true
            default:
                break
            }
        }

        guard timeline.segments.count == 1, let onlySegment = timeline.segments.first else {
            return true
        }
        return onlySegment.sourceStart > 0.001 || abs(onlySegment.sourceEnd - sourceDuration) > 0.001
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        screenRecordingURL: URL,
        cameraRecordingURL: URL?,
        microphoneRecordingURL: URL? = nil,
        sourceDuration: TimeInterval? = nil,
        preferences: RecordingPreferences = .defaults,
        events: [EffectEvent],
        timeline: EditTimeline
    ) {
        self.id = id
        self.createdAt = createdAt
        self.screenRecordingURL = screenRecordingURL
        self.cameraRecordingURL = cameraRecordingURL
        self.microphoneRecordingURL = microphoneRecordingURL
        self.sourceDuration = max(0, sourceDuration ?? timeline.sourceDurationEstimate)
        self.preferences = preferences
        self.events = events.sorted { $0.time < $1.time }
        self.timeline = timeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        screenRecordingURL = try container.decode(URL.self, forKey: .screenRecordingURL)
        cameraRecordingURL = try container.decodeIfPresent(URL.self, forKey: .cameraRecordingURL)
        microphoneRecordingURL = try container.decodeIfPresent(URL.self, forKey: .microphoneRecordingURL)
        preferences = (try? container.decodeIfPresent(RecordingPreferences.self, forKey: .preferences)) ?? .defaults
        events = (try container.decodeIfPresent([EffectEvent].self, forKey: .events) ?? []).sorted { $0.time < $1.time }
        timeline = try container.decodeIfPresent(EditTimeline.self, forKey: .timeline) ?? .fullLength(duration: 0)
        sourceDuration = max(0, try container.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration) ?? timeline.sourceDurationEstimate)
    }

    public mutating func appendEvent(_ event: EffectEvent) {
        events.append(event)
        events.sort { $0.time < $1.time }
    }
}

public extension RecordingProject {
    func exportedCameraLayoutStates() -> [CameraLayoutEvent] {
        let sourceLayoutEvents = events.compactMap { event -> CameraLayoutEvent? in
            if case .cameraLayout(let layout) = event {
                return layout
            }
            return nil
        }.sorted { $0.time < $1.time }

        var exported: [CameraLayoutEvent] = []
        var exportCursor: TimeInterval = 0

        for segment in timeline.segments {
            let stateAtStart = latestCameraLayoutState(at: segment.sourceStart, in: sourceLayoutEvents)
            exported.append(
                CameraLayoutEvent(
                    time: exportCursor,
                    frame: stateAtStart.frame,
                    shape: stateAtStart.shape,
                    isVisible: stateAtStart.isVisible
                )
            )

            for event in sourceLayoutEvents where event.time > segment.sourceStart && event.time < segment.sourceEnd {
                exported.append(
                    CameraLayoutEvent(
                        time: exportCursor + event.time - segment.sourceStart,
                        frame: event.frame,
                        shape: event.shape,
                        isVisible: event.isVisible
                    )
                )
            }

            exportCursor += segment.duration
        }

        return coalescedCameraLayoutStates(exported)
    }

    func exportedZoomStates() -> [ZoomEvent] {
        let sourceZoomEvents = events.compactMap { event -> ZoomEvent? in
            if case .zoom(let zoom) = event {
                return zoom
            }
            return nil
        }.sorted { $0.time < $1.time }

        var exported: [ZoomEvent] = []
        var exportCursor: TimeInterval = 0

        for segment in timeline.segments {
            let stateAtStart = latestZoomState(at: segment.sourceStart, in: sourceZoomEvents)
            exported.append(
                ZoomEvent(
                    time: exportCursor,
                    magnification: stateAtStart.magnification,
                    focus: stateAtStart.focus
                )
            )

            for event in sourceZoomEvents where event.time > segment.sourceStart && event.time < segment.sourceEnd {
                exported.append(
                    ZoomEvent(
                        time: exportCursor + event.time - segment.sourceStart,
                        magnification: event.magnification,
                        focus: event.focus
                    )
                )
            }

            exportCursor += segment.duration
        }

        return coalescedZoomStates(exported)
    }

    func exportedAnnotationEvents() -> [EffectEvent] {
        let sourceAnnotationEvents = annotationTimelineEvents()
        var exported: [EffectEvent] = []
        var exportCursor: TimeInterval = 0

        for segment in timeline.segments {
            let activeAtStart = activeAnnotations(at: segment.sourceStart, in: sourceAnnotationEvents)
            for annotation in activeAtStart {
                exported.append(
                    .annotation(
                        remappedAnnotation(
                            annotation,
                            time: exportCursor,
                            sourceStart: segment.sourceStart,
                            exportCursor: exportCursor,
                            forcePointTimeToEventTime: true
                        )
                    )
                )
            }

            for event in sourceAnnotationEvents where event.time > segment.sourceStart && event.time < segment.sourceEnd {
                switch event {
                case .annotation(let annotation):
                    let exportTime = exportCursor + annotation.time - segment.sourceStart
                    exported.append(
                        .annotation(
                            remappedAnnotation(
                                annotation,
                                time: exportTime,
                                sourceStart: segment.sourceStart,
                                exportCursor: exportCursor,
                                forcePointTimeToEventTime: false
                            )
                        )
                    )
                case .annotationClear:
                    exported.append(
                        .annotationClear(
                            AnnotationClearEvent(time: exportCursor + event.time - segment.sourceStart)
                        )
                    )
                default:
                    break
                }
            }

            exportCursor += segment.duration
        }

        return exported.sorted { $0.time < $1.time }
    }

    private func latestCameraLayoutState(at sourceTime: TimeInterval, in events: [CameraLayoutEvent]) -> CameraLayoutEvent {
        events.last { $0.time <= sourceTime } ?? CameraLayoutEvent(
            time: sourceTime,
            frame: .defaultCameraFrame,
            shape: .circle,
            isVisible: cameraRecordingURL != nil
        )
    }

    private func coalescedCameraLayoutStates(_ states: [CameraLayoutEvent]) -> [CameraLayoutEvent] {
        var result: [CameraLayoutEvent] = []
        for state in states.sorted(by: { $0.time < $1.time }) {
            if let last = result.last, abs(last.time - state.time) < 0.001 {
                result[result.count - 1] = state
            } else if let last = result.last,
                      last.frame == state.frame,
                      last.shape == state.shape,
                      last.isVisible == state.isVisible {
                continue
            } else {
                result.append(state)
            }
        }
        return result
    }

    private func latestZoomState(at sourceTime: TimeInterval, in events: [ZoomEvent]) -> ZoomEvent {
        events.last { $0.time <= sourceTime } ?? ZoomEvent(
            time: sourceTime,
            magnification: 1,
            focus: NormalizedPoint(x: 0.5, y: 0.5)
        )
    }

    private func annotationTimelineEvents() -> [EffectEvent] {
        events.compactMap { event -> EffectEvent? in
            switch event {
            case .annotation, .annotationClear:
                event
            default:
                nil
            }
        }
        .sorted { $0.time < $1.time }
    }

    private func activeAnnotations(at sourceTime: TimeInterval, in events: [EffectEvent]) -> [AnnotationEvent] {
        var active: [AnnotationEvent] = []
        for event in events where event.time <= sourceTime {
            switch event {
            case .annotation(let annotation):
                active.removeAll { $0.id == annotation.id }
                active.append(annotation)
            case .annotationClear:
                active.removeAll()
            default:
                break
            }
        }
        return active.sorted { $0.time < $1.time }
    }

    private func remappedAnnotation(
        _ annotation: AnnotationEvent,
        time: TimeInterval,
        sourceStart: TimeInterval,
        exportCursor: TimeInterval,
        forcePointTimeToEventTime: Bool
    ) -> AnnotationEvent {
        let delta = exportCursor - sourceStart
        let points = annotation.points.map { point in
            StrokePoint(
                time: forcePointTimeToEventTime ? time : max(time, point.time + delta),
                point: point.point
            )
        }
        return AnnotationEvent(
            id: annotation.id,
            time: time,
            tool: annotation.tool,
            points: points,
            colorHex: annotation.colorHex,
            lineWidth: annotation.lineWidth
        )
    }

    private func coalescedZoomStates(_ states: [ZoomEvent]) -> [ZoomEvent] {
        var result: [ZoomEvent] = []
        for state in states.sorted(by: { $0.time < $1.time }) {
            if let last = result.last, abs(last.time - state.time) < 0.001 {
                result[result.count - 1] = state
            } else if let last = result.last,
                      abs(last.magnification - state.magnification) < 0.001,
                      last.focus == state.focus {
                continue
            } else {
                result.append(state)
            }
        }
        return result
    }
}

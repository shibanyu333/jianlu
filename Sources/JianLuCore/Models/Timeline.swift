import CoreGraphics
import Foundation

public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let defaultCameraFrame = NormalizedRect(x: 0.74, y: 0.64, width: 0.22, height: 0.22)
    public static let minCameraFrameSize = 0.08
    public static let maxCameraFrameSize = 0.45

    public var clampedCameraFrame: NormalizedRect {
        let minSize = Self.minCameraFrameSize
        let maxSize = Self.maxCameraFrameSize
        let clampedWidth = min(maxSize, max(minSize, width))
        let clampedHeight = min(maxSize, max(minSize, height))
        return NormalizedRect(
            x: min(max(0, x), 1 - clampedWidth),
            y: min(max(0, y), 1 - clampedHeight),
            width: clampedWidth,
            height: clampedHeight
        )
    }

    public func resizedCameraFrame(size: Double) -> NormalizedRect {
        let clampedSize = min(Self.maxCameraFrameSize, max(Self.minCameraFrameSize, size))
        let centerX = x + width / 2
        let centerY = y + height / 2
        return NormalizedRect(
            x: centerX - clampedSize / 2,
            y: centerY - clampedSize / 2,
            width: clampedSize,
            height: clampedSize
        ).clampedCameraFrame
    }

    /// The camera bubble's pixel/point rect inside `containerSize`.
    ///
    /// For every shape except `.ellipse` the box is a **square** so the "圆形" shape
    /// renders as a true circle regardless of the recording's aspect ratio (a
    /// normalized 0.22×0.22 frame would otherwise become an oval on a 16:9 canvas).
    /// The side is driven by the width fraction and capped to the shorter container
    /// edge. `.ellipse` intentionally keeps the normalized frame's own aspect ratio,
    /// which is what makes it an oval. The origin is clamped either way so the bubble
    /// stays fully on screen.
    ///
    /// Both the live overlay and the export compositor call this so the preview, the
    /// overlay's mouse hit-testing and the exported video always agree. Returns a
    /// top-left-origin (y-down) rect.
    public func cameraBubbleRect(in containerSize: CGSize, shape: CameraFrameShape) -> CGRect {
        let containerWidth = max(1, containerSize.width)
        let containerHeight = max(1, containerSize.height)
        let size: CGSize
        if shape.usesSquareBubble {
            let maxSide = max(1, min(containerWidth, containerHeight))
            let side = min(max(1, CGFloat(width) * containerWidth), maxSide)
            size = CGSize(width: side, height: side)
        } else {
            size = CGSize(
                width: min(max(1, CGFloat(width) * containerWidth), containerWidth),
                height: min(max(1, CGFloat(height) * containerHeight), containerHeight)
            )
        }
        let originX = min(max(0, CGFloat(x) * containerWidth), max(0, containerWidth - size.width))
        let originY = min(max(0, CGFloat(y) * containerHeight), max(0, containerHeight - size.height))
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }
}

public struct EditSegment: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var sourceStart: TimeInterval
    public var sourceEnd: TimeInterval

    public var duration: TimeInterval {
        max(0, sourceEnd - sourceStart)
    }

    public init(id: UUID = UUID(), sourceStart: TimeInterval, sourceEnd: TimeInterval) {
        self.id = id
        self.sourceStart = min(sourceStart, sourceEnd)
        self.sourceEnd = max(sourceStart, sourceEnd)
    }

    public func contains(_ sourceTime: TimeInterval) -> Bool {
        sourceTime >= sourceStart && sourceTime < sourceEnd
    }

    public func canSplit(at sourceTime: TimeInterval) -> Bool {
        sourceTime > sourceStart && sourceTime < sourceEnd
    }

    public func split(at sourceTime: TimeInterval) -> (EditSegment, EditSegment)? {
        guard canSplit(at: sourceTime) else { return nil }
        return (
            EditSegment(sourceStart: sourceStart, sourceEnd: sourceTime),
            EditSegment(sourceStart: sourceTime, sourceEnd: sourceEnd)
        )
    }
}

public struct EditTimeline: Codable, Equatable, Sendable {
    public private(set) var segments: [EditSegment]

    public var totalExportDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    public var sourceDurationEstimate: TimeInterval {
        segments.map(\.sourceEnd).max() ?? totalExportDuration
    }

    public init(segments: [EditSegment]) {
        self.segments = segments.filter { $0.duration > 0 }
    }

    public static func fullLength(duration: TimeInterval) -> EditTimeline {
        EditTimeline(segments: [EditSegment(sourceStart: 0, sourceEnd: max(0, duration))])
    }

    public static func excluding(sourceDuration: TimeInterval, ranges: [EditSegment]) -> EditTimeline {
        let sourceDuration = max(0, sourceDuration)
        guard sourceDuration > 0 else {
            return EditTimeline(segments: [])
        }

        var keptSegments = [EditSegment(sourceStart: 0, sourceEnd: sourceDuration)]
        let exclusionRanges = ranges
            .map { range in
                EditSegment(
                    sourceStart: min(max(0, range.sourceStart), sourceDuration),
                    sourceEnd: min(max(0, range.sourceEnd), sourceDuration)
                )
            }
            .filter { $0.duration > 0 }
            .sorted { $0.sourceStart < $1.sourceStart }

        for range in exclusionRanges {
            var nextSegments: [EditSegment] = []
            for segment in keptSegments {
                if range.sourceEnd <= segment.sourceStart || range.sourceStart >= segment.sourceEnd {
                    nextSegments.append(segment)
                    continue
                }

                if range.sourceStart > segment.sourceStart {
                    nextSegments.append(EditSegment(sourceStart: segment.sourceStart, sourceEnd: range.sourceStart))
                }
                if range.sourceEnd < segment.sourceEnd {
                    nextSegments.append(EditSegment(sourceStart: range.sourceEnd, sourceEnd: segment.sourceEnd))
                }
            }
            keptSegments = nextSegments
        }

        return EditTimeline(segments: keptSegments)
    }

    @discardableResult
    public mutating func split(at sourceTime: TimeInterval) -> Bool {
        guard let index = segments.firstIndex(where: { $0.canSplit(at: sourceTime) }),
              let splitSegments = segments[index].split(at: sourceTime) else {
            return false
        }

        segments.replaceSubrange(index...index, with: [splitSegments.0, splitSegments.1])
        return true
    }

    @discardableResult
    public mutating func deleteSegment(id: UUID) -> Bool {
        guard segments.count > 1,
              let index = segments.firstIndex(where: { $0.id == id }) else {
            return false
        }
        segments.remove(at: index)
        return true
    }

    public func exportTime(forSourceTime sourceTime: TimeInterval) -> TimeInterval? {
        var accumulated: TimeInterval = 0
        for segment in segments {
            if segment.contains(sourceTime) {
                return accumulated + (sourceTime - segment.sourceStart)
            }
            accumulated += segment.duration
        }
        return nil
    }

    public func sourceTime(forExportTime exportTime: TimeInterval) -> TimeInterval? {
        guard exportTime >= 0 else { return nil }

        var remaining = exportTime
        for segment in segments {
            if remaining < segment.duration {
                return segment.sourceStart + remaining
            }
            remaining -= segment.duration
        }

        if exportTime == totalExportDuration, let last = segments.last {
            return last.sourceEnd
        }

        return nil
    }

    public func canSplit(atExportTime exportTime: TimeInterval) -> Bool {
        guard let sourceTime = sourceTime(forExportTime: exportTime) else {
            return false
        }
        return segments.contains { $0.canSplit(at: sourceTime) }
    }

    public func canSplit(atExportRatio ratio: Double) -> Bool {
        let clampedRatio = min(max(0, ratio), 1)
        return canSplit(atExportTime: totalExportDuration * clampedRatio)
    }
}

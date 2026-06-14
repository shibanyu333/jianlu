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
}

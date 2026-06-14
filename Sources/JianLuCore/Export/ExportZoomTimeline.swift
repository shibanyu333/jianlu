import CoreGraphics
import Foundation

public struct ExportZoomEffect: Equatable, Sendable {
    public var depth: Double
    public var focusX: Double
    public var focusY: Double

    public init(depth: Double, focusX: Double, focusY: Double) {
        self.depth = depth
        self.focusX = focusX
        self.focusY = focusY
    }
}

public struct ExportZoomRegion: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var depth: Double
    public var focus: NormalizedPoint

    public init(start: TimeInterval, end: TimeInterval, depth: Double, focus: NormalizedPoint) {
        self.start = start
        self.end = end
        self.depth = depth
        self.focus = focus
    }

    public var duration: TimeInterval {
        max(0, end - start)
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

public enum ExportZoomTimeline {
    public static let defaultDepth = 1.75
    public static let rampInSeconds = 0.45
    public static let rampOutSeconds = 0.35
    public static let safeZoneRatio = 0.25
    public static let focusClampRange = 0.08...0.92

    public static func regions(from states: [ZoomEvent], duration: TimeInterval) -> [ExportZoomRegion] {
        guard duration > 0 else { return [] }
        let sortedStates = states.sorted { $0.time < $1.time }
        var regions: [ExportZoomRegion] = []
        var activeStart: TimeInterval?
        var activeDepth = defaultDepth
        var activeFocus = NormalizedPoint(x: 0.5, y: 0.5)

        for state in sortedStates {
            let eventTime = min(max(state.time, 0), duration)
            if state.magnification > 1.001 {
                if activeStart == nil {
                    activeStart = eventTime
                    activeDepth = state.magnification
                    activeFocus = clamped(state.focus)
                } else if state.magnification > activeDepth {
                    activeDepth = state.magnification
                }
            } else if let start = activeStart {
                appendRegion(
                    start: start,
                    end: eventTime,
                    depth: activeDepth,
                    focus: activeFocus,
                    to: &regions
                )
                activeStart = nil
                activeDepth = defaultDepth
            }
        }

        if let start = activeStart {
            appendRegion(
                start: start,
                end: duration,
                depth: activeDepth,
                focus: activeFocus,
                to: &regions
            )
        }

        return regions
    }

    public static func activeEffect(
        states: [ZoomEvent],
        duration: TimeInterval,
        at time: TimeInterval
    ) -> ExportZoomEffect? {
        activeEffect(regions: regions(from: states, duration: duration), states: states, at: time)
    }

    public static func activeEffect(
        regions: [ExportZoomRegion],
        states: [ZoomEvent],
        at time: TimeInterval
    ) -> ExportZoomEffect? {
        guard time.isFinite, !regions.isEmpty else { return nil }
        guard let active = regions
            .last(where: { $0.contains(time) || abs($0.end - time) < 0.001 }) else {
            return nil
        }

        let progress = animationProgress(for: active, at: time)
        let depth = 1 + (max(1, active.depth) - 1) * progress
        guard depth > 1.001 else { return nil }
        let focus = resolvedFocus(for: active, states: states, at: time, depth: depth)
        return ExportZoomEffect(
            depth: depth,
            focusX: focus.x,
            focusY: focus.y
        )
    }

    public static func animationProgress(for region: ExportZoomRegion, at time: TimeInterval) -> Double {
        guard region.duration > 0, region.contains(time) || abs(region.end - time) < 0.001 else {
            return 0
        }

        let rampIn = min(rampInSeconds, region.duration * 0.4)
        let rampOut = min(rampOutSeconds, region.duration * 0.4)
        if rampIn > 0, time < region.start + rampIn {
            return smoothstep((time - region.start) / rampIn)
        }
        if rampOut > 0, time > region.end - rampOut {
            return smoothstep((region.end - time) / rampOut)
        }
        return 1
    }

    public static func transform(for effect: ExportZoomEffect?, in rect: CGRect, flipsY: Bool = false) -> CGAffineTransform {
        guard let effect else { return .identity }
        let depth = CGFloat(max(1, effect.depth))
        guard depth > 1,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return .identity
        }

        let focus = CGPoint(
            x: rect.minX + rect.width * CGFloat(effect.focusX),
            y: rect.minY + rect.height * CGFloat(flipsY ? 1 - effect.focusY : effect.focusY)
        )
        return CGAffineTransform(translationX: -focus.x, y: -focus.y)
            .concatenating(CGAffineTransform(scaleX: depth, y: depth))
            .concatenating(CGAffineTransform(translationX: focus.x, y: focus.y))
    }

    private static func appendRegion(
        start: TimeInterval,
        end: TimeInterval,
        depth: Double,
        focus: NormalizedPoint,
        to regions: inout [ExportZoomRegion]
    ) {
        guard end - start > 0.001 else { return }
        regions.append(
            ExportZoomRegion(
                start: start,
                end: end,
                depth: max(1, depth),
                focus: clamped(focus)
            )
        )
    }

    private static func clamped(_ focus: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(focus.x, focusClampRange.lowerBound), focusClampRange.upperBound),
            y: min(max(focus.y, focusClampRange.lowerBound), focusClampRange.upperBound)
        )
    }

    private static func resolvedFocus(
        for region: ExportZoomRegion,
        states: [ZoomEvent],
        at time: TimeInterval,
        depth: Double
    ) -> NormalizedPoint {
        let rampOut = min(rampOutSeconds, region.duration * 0.4)
        let effectiveTime = min(max(time, region.start), max(region.start, region.end - rampOut))
        var focus = region.focus

        for state in states where state.time >= region.start && state.time <= effectiveTime && state.magnification > 1.001 {
            let cursorFocus = clamped(state.focus)
            let visibleHalfSpan = 1 / (2 * max(depth, 1))
            let safeInset = visibleHalfSpan * 2 * min(max(safeZoneRatio, 0), 0.49)
            let safeLeft = focus.x - visibleHalfSpan + safeInset
            let safeRight = focus.x + visibleHalfSpan - safeInset
            let safeTop = focus.y - visibleHalfSpan + safeInset
            let safeBottom = focus.y + visibleHalfSpan - safeInset

            if cursorFocus.x < safeLeft || cursorFocus.x > safeRight {
                focus.x = cursorFocus.x
            }
            if cursorFocus.y < safeTop || cursorFocus.y > safeBottom {
                focus.y = cursorFocus.y
            }
        }

        return clamped(focus)
    }

    private static func smoothstep(_ rawValue: Double) -> Double {
        let x = min(max(rawValue, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

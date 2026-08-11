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
    public static let focusClampRange = 0.0...1.0

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
                    // Store the depth the zoom opened at. The exact depth at any later
                    // instant is resolved per-frame from the recorded events (see
                    // resolvedDepth) so mid-zoom ⌃⌥⌘=/- changes — including zoom-outs —
                    // are honored instead of being flattened to the region maximum.
                    activeDepth = state.magnification
                    activeFocus = clamped(state.focus)
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
        let sortedStates = states.sorted { $0.time < $1.time }
        return activeEffect(regions: regions(from: sortedStates, duration: duration), states: sortedStates, at: time)
    }

    /// `states` must be sorted by time (the compositor instruction sorts once up
    /// front; the convenience overload above sorts before delegating), so the
    /// per-frame lookup can binary-search instead of walking every recorded event.
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
        let resolved = resolvedFocusAndDepth(for: active, states: states, at: time)
        let depth = 1 + (max(1, resolved.depth) - 1) * progress
        guard depth > 1.001 else { return nil }
        return ExportZoomEffect(
            depth: depth,
            focusX: resolved.focus.x,
            focusY: resolved.focus.y
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

    /// The depth a zoom has reached `elapsed` seconds after it opened, using the same
    /// ramp-in curve the export replays. The live overlay drives its magnification
    /// through this so the presenter watches the zoom grow exactly the way the
    /// finished video will. (The export's ramp-*out* starts before the presenter
    /// releases the zoom, so only the ramp-in can be mirrored live.)
    public static func rampedDepth(target: Double, elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite else { return max(1, target) }
        let progress = rampInSeconds > 0 ? smoothstep(elapsed / rampInSeconds) : 1
        return 1 + (max(1, target) - 1) * progress
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

    /// The focus and depth at `time`, following the latest recorded zoom event within
    /// the region (so mid-zoom focus moves and ⌃⌥⌘=/- adjustments are reflected).
    /// Falls back to the region's opening state before any later event applies.
    ///
    /// `states` is sorted by time, so instead of scanning every recorded event on
    /// every exported frame this binary-searches the newest event at or before the
    /// effective time and walks back at most past same-instant events.
    private static func resolvedFocusAndDepth(
        for region: ExportZoomRegion,
        states: [ZoomEvent],
        at time: TimeInterval
    ) -> (focus: NormalizedPoint, depth: Double) {
        let rampOut = min(rampOutSeconds, region.duration * 0.4)
        let effectiveTime = min(max(time, region.start), max(region.start, region.end - rampOut))
        var focus = region.focus
        var depth = region.depth

        var low = 0
        var high = states.count
        while low < high {
            let mid = (low + high) / 2
            if states[mid].time <= effectiveTime {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var index = low - 1
        while index >= 0, states[index].time >= region.start {
            let state = states[index]
            if state.magnification > 1.001 {
                focus = clamped(state.focus)
                depth = state.magnification
                break
            }
            index -= 1
        }

        return (clamped(focus), max(1, depth))
    }

    private static func smoothstep(_ rawValue: Double) -> Double {
        let x = min(max(rawValue, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

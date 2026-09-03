import CoreGraphics

enum ScrollAxis {
    case vertical
    case horizontal
}

struct AxisDeltas: Equatable {
    var line: Int64
    var point: Int64
    var fixedPt: Double
}

struct ScrollAxisConfig: Equatable {
    var invert: Bool
    var flatten: Bool
    var linesPerNotch: Int
    var mulThousandths: Int
}

struct AxisResidue: Equatable {
    var positive: Int
    var negative: Int

    // Explicit empty init on purpose: it suppresses the memberwise init, so a
    // caller cannot fabricate residue with arbitrary values.
    init() {
        positive = 0
        negative = 0
    }
}

private struct AxisFilterState {
    var residue = AxisResidue()
    var lastMotionTime: Double?
}

struct ScrollFilterState {
    fileprivate var vertical = AxisFilterState()
    fileprivate var horizontal = AxisFilterState()
    fileprivate var verticalConfig: ScrollAxisConfig?
    fileprivate var horizontalConfig: ScrollAxisConfig?

    init() {}
}

enum ScrollDecision: Equatable {
    case passUnchanged
    case swallow
    case rewrite(vertical: AxisDeltas?, horizontal: AxisDeltas?)
}

private let accumulatorFraction = 65_536
private let accumulatorUnit = accumulatorFraction * 1_000
private let maximumLineDelta = 1_000
private let maximumSourceMagnitude = maximumLineDelta * accumulatorFraction
// CoreGraphics derives 8 pixels per line, not the 10 folklore reports.
private let pointsPerLine = 8
private let maximumPointDelta = maximumLineDelta * pointsPerLine
private let burstGap = 0.25
private let defaultMulThousandths = 1_000

private struct EffectiveSource {
    let magnitude: Int
    let sign: Int
    // The raw field exceeded the clamp, so the magnitude no longer
    // corresponds to the original deltas and scaling them would break
    // cross-channel coherence.
    let clamped: Bool
}

func clampedLinesPerNotch(_ raw: Int) -> Int {
    min(max(raw, 1), 1_000)
}

func clampedMulThousandths(_ raw: Int) -> Int {
    min(max(raw, 1), 100_000)
}

func clampedMulThousandths(fromMultiplier raw: Double) -> Int {
    guard raw.isFinite else {
        return defaultMulThousandths
    }
    // The 0.001...100 clamp guarantees the scaled value converts exactly; the
    // Int overload restates the same bounds in thousandths.
    return clampedMulThousandths(Int((min(max(raw, 0.001), 100) * 1_000).rounded()))
}

// The fixed-point field carries nothing when it is non-finite or too small to
// round to one 16.16 unit (no genuine field is finer than 1/65536). Source
// resolution and the output-channel selection must agree on this judgment,
// so it has one home.
private func fixedPointAbsent(_ value: Double) -> Bool {
    !value.isFinite || (abs(value) * Double(accumulatorFraction)).rounded() == 0
}

private func effectiveSource(for input: AxisDeltas) -> EffectiveSource? {
    if input.line != 0 {
        let lineMagnitude = min(input.line.magnitude, UInt64(maximumLineDelta))
        return EffectiveSource(
            magnitude: Int(lineMagnitude) * accumulatorFraction,
            sign: input.line > 0 ? 1 : -1,
            clamped: input.line.magnitude > UInt64(maximumLineDelta)
        )
    }

    // An absent fixed-point value keeps resolving, so a point-only event with
    // a stray tiny fixed-point delta is still rewritten rather than passed
    // through with its original direction.
    if !fixedPointAbsent(input.fixedPt) {
        let scaled = (abs(input.fixedPt) * Double(accumulatorFraction)).rounded()
        let sign = input.fixedPt > 0 ? 1 : -1
        if let exact = Int64(exactly: scaled), exact <= Int64(maximumSourceMagnitude) {
            return EffectiveSource(magnitude: Int(exact), sign: sign, clamped: false)
        }
        return EffectiveSource(magnitude: maximumSourceMagnitude, sign: sign, clamped: true)
    }

    if input.point != 0 {
        let pointMagnitude = min(input.point.magnitude, UInt64(maximumPointDelta))
        return EffectiveSource(
            magnitude: Int(pointMagnitude) * accumulatorFraction / pointsPerLine,
            sign: input.point > 0 ? 1 : -1,
            clamped: input.point.magnitude > UInt64(maximumPointDelta)
        )
    }

    return nil
}

func rewriteAxis(
    _ input: AxisDeltas,
    config: ScrollAxisConfig,
    residue: inout AxisResidue
) -> AxisDeltas? {
    guard let source = effectiveSource(for: input) else {
        return nil
    }

    // Re-clamp here rather than trusting the caller: the overflow ceiling and
    // the sign of the residue arithmetic both depend on these bounds, and a
    // negative linesPerNotch would poison a residue slot permanently.
    let linesPerNotch = clampedLinesPerNotch(config.linesPerNotch)
    let mulThousandths = clampedMulThousandths(config.mulThousandths)
    let magnitude = config.flatten
        ? linesPerNotch * accumulatorFraction
        : source.magnitude
    let direction = source.sign * (config.invert ? -1 : 1)
    let product = direction * (magnitude * mulThousandths)
    let previousResidue = direction > 0 ? residue.positive : residue.negative
    let wanted = product + previousResidue
    let emittedLines = wanted / accumulatorUnit
    let remaining = wanted - emittedLines * accumulatorUnit

    if direction > 0 {
        residue.positive = remaining
    } else {
        residue.negative = remaining
    }

    // The synthesized channels match what the CGEvent line-delta setter
    // derives on its own, which is what the flatten path relies on.
    let emitted = Int64(emittedLines)
    let fallbackPoint = emitted * Int64(pointsPerLine)
    let fallbackFixedPt = Double(emitted)
    if config.flatten {
        return AxisDeltas(line: emitted, point: fallbackPoint, fixedPt: fallbackFixedPt)
    }
    // A clamped source no longer corresponds to the original fields, so
    // scaling them would emit channels disagreeing with the line count by the
    // clamp ratio; synthesize instead, as the flatten path does.
    if source.clamped {
        return AxisDeltas(line: emitted, point: fallbackPoint, fixedPt: fallbackFixedPt)
    }

    let sourceLines = Double(source.sign * source.magnitude) / Double(accumulatorFraction)
    let scale = Double(emitted) / sourceLines
    var point: Int64
    if input.point == 0 {
        point = fallbackPoint
    } else {
        let scaledPoint = (Double(input.point) * scale).rounded()
        point = Int64(exactly: scaledPoint) ?? fallbackPoint
    }

    var fixedPt = fixedPointAbsent(input.fixedPt) ? fallbackFixedPt : input.fixedPt * scale

    // Coherence guard: a derived channel that overflowed or points the other
    // way from the emitted lines would scroll that field's readers backwards
    // (NSEvent's scrollingDeltaY follows the fixed-point field), so it falls
    // back to the synthesized value.
    if emitted != 0 {
        if point != 0, (point > 0) != (emitted > 0) { point = fallbackPoint }
        if !fixedPt.isFinite || (fixedPt != 0 && (fixedPt > 0) != (emitted > 0)) {
            fixedPt = fallbackFixedPt
        }
    }
    return AxisDeltas(line: emitted, point: point, fixedPt: fixedPt)
}

/// `time` is the event time in SECONDS. The allocation-free, time-correct
/// source in a tap callback is `CGEvent.timestamp` (mach ticks) scaled by a
/// `mach_timebase_info` read once at startup; `NSEvent(cgEvent:)?.timestamp`
/// is correct but allocates per event. Passing mach ticks raw makes the burst
/// gap elapse on every event, so residue resets each time and any multiplier
/// below 1.0 silently emits nothing.
/// A nil axis in `.rewrite` means that axis carried nothing: leave its fields
/// untouched, never write zeros over them. `state` must be one long-lived
/// value; a fresh instance per event discards residue and the burst timer.
func decideScrollEvent(
    vertical: AxisDeltas,
    horizontal: AxisDeltas,
    isContinuous: Bool,
    scrollPhase: Int64,
    momentumPhase: Int64,
    verticalConfig: ScrollAxisConfig,
    horizontalConfig: ScrollAxisConfig,
    altTrackpadDetection: Bool,
    time: Double,
    state: inout ScrollFilterState
) -> ScrollDecision {
    // Config bookkeeping runs even for events that pass through below, so a
    // later wheel event never compares against a stale record. On the first
    // event the stored nil registers as a change and resets residues that are
    // already zero, which is harmless.
    if state.verticalConfig != verticalConfig || state.horizontalConfig != horizontalConfig {
        state.vertical.residue = AxisResidue()
        state.horizontal.residue = AxisResidue()
    }
    state.verticalConfig = verticalConfig
    state.horizontalConfig = horizontalConfig

    if isContinuous || momentumPhase != 0 {
        return .passUnchanged
    }
    if altTrackpadDetection && scrollPhase != 0 {
        return .passUnchanged
    }

    let verticalSource = effectiveSource(for: vertical)
    let horizontalSource = effectiveSource(for: horizontal)

    // An idle gap on an axis resets both of that axis's direction slots; the
    // clock only advances on events that carry motion on that axis.
    func resetStaleResidue(_ axis: inout AxisFilterState, isActive: Bool) {
        guard isActive else { return }
        if let lastMotion = axis.lastMotionTime, time - lastMotion > burstGap {
            axis.residue = AxisResidue()
        }
        axis.lastMotionTime = time
    }
    resetStaleResidue(&state.vertical, isActive: verticalSource != nil)
    resetStaleResidue(&state.horizontal, isActive: horizontalSource != nil)

    let verticalResult = rewriteAxis(vertical, config: verticalConfig, residue: &state.vertical.residue)
    let horizontalResult = rewriteAxis(horizontal, config: horizontalConfig, residue: &state.horizontal.residue)

    guard verticalResult != nil || horizontalResult != nil else {
        return .passUnchanged
    }

    let allEmittedZero = (verticalResult?.line ?? 0) == 0
        && (horizontalResult?.line ?? 0) == 0
    if allEmittedZero && scrollPhase == 0 {
        return .swallow
    }

    return .rewrite(vertical: verticalResult, horizontal: horizontalResult)
}

private extension ScrollAxis {
    var fields: (line: CGEventField, point: CGEventField, fixedPt: CGEventField) {
        switch self {
        case .vertical:
            return (.scrollWheelEventDeltaAxis1,
                    .scrollWheelEventPointDeltaAxis1,
                    .scrollWheelEventFixedPtDeltaAxis1)
        case .horizontal:
            return (.scrollWheelEventDeltaAxis2,
                    .scrollWheelEventPointDeltaAxis2,
                    .scrollWheelEventFixedPtDeltaAxis2)
        }
    }
}

/// `flatten` must come from the same per-axis config that produced `deltas`:
/// under flatten only the line write happens and CoreGraphics' own derivation
/// supplies the other two channels; a mismatched flag silently drops the
/// scaled point and fixed-point values.
func applyAxisDeltas(
    _ deltas: AxisDeltas,
    to event: CGEvent,
    axis: ScrollAxis,
    flatten: Bool
) {
    let fields = axis.fields
    // The line setter synthesizes the other two fields, so the explicit
    // values must follow it.
    event.setIntegerValueField(fields.line, value: deltas.line)
    if !flatten {
        event.setIntegerValueField(fields.point, value: deltas.point)
        event.setDoubleValueField(fields.fixedPt, value: deltas.fixedPt)
    }
}

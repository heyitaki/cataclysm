// Table-driven harness for the scroll rewrite pipeline (ScrollFilter.swift).
// Covers every case in the deleted design spec's "Testing" table (see
// specs/progress.md). Pure-function cases assert exact output triples; the
// CGEvent cases assert field-write order, which nothing visible
// distinguishes by eye.
//
// Build and run: make test

import CoreGraphics
import Foundation

var passed = 0
var failed = 0

func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passed += 1 } else {
        failed += 1
        let text = detail()
        print("FAIL: \(name)\(text.isEmpty ? "" : ": " + text)")
    }
}

func checkEq<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got), want \(want)")
}

func cfg(invert: Bool = false, flatten: Bool = true, lines: Int = 1, mul: Int = 1000) -> ScrollAxisConfig {
    ScrollAxisConfig(invert: invert, flatten: flatten, linesPerNotch: lines, mulThousandths: mul)
}

// Run a sequence of inputs through one axis, collecting non-idle outputs.
func run(_ inputs: [AxisDeltas], _ config: ScrollAxisConfig) -> [AxisDeltas] {
    var residue = AxisResidue()
    return inputs.compactMap { rewriteAxis($0, config: config, residue: &residue) }
}

// decideScrollEvent with the harness's baseline defaults; each case names
// only the parameters it is about.
func decide(vertical: AxisDeltas, horizontal: AxisDeltas = idleAxis,
            continuous: Bool = false, phase: Int64 = 0, momentum: Int64 = 0,
            vConfig: ScrollAxisConfig = cfg(), hConfig: ScrollAxisConfig = cfg(),
            alt: Bool = false, time: Double = 0,
            state: inout ScrollFilterState) -> ScrollDecision {
    decideScrollEvent(vertical: vertical, horizontal: horizontal,
                      isContinuous: continuous, scrollPhase: phase, momentumPhase: momentum,
                      verticalConfig: vConfig, horizontalConfig: hConfig,
                      altTrackpadDetection: alt, time: time, state: &state)
}

func makeScrollEvent() -> CGEvent? {
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0)
}

let notch = AxisDeltas(line: 1, point: 10, fixedPt: 1.0)
let backNotch = AxisDeltas(line: -1, point: -10, fixedPt: -1.0)
let idleAxis = AxisDeltas(line: 0, point: 0, fixedPt: 0.0)
// The spec's upper-bound input: 50000 lines at multiplier 100.
let boundInput = AxisDeltas(line: 50000, point: 400000, fixedPt: 50000.0)

@main
struct ScrollFilterTests {
    static func main() {
        pipeline()
        events()
        fieldWrites()
        settingsClamps()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func pipeline() {
        check(run([idleAxis], cfg()).isEmpty, "idle axis emits nothing")

        // Flatten identity: a slow notch and a fast flick emit the same
        // triple, not just the same line count.
        let slow = run([notch], cfg(invert: true))
        let fast = run([AxisDeltas(line: 3, point: 30, fixedPt: 3.0)], cfg(invert: true))
        checkEq(slow, [AxisDeltas(line: -1, point: -8, fixedPt: -1.0)], "flatten: slow notch")
        checkEq(fast, [AxisDeltas(line: -1, point: -8, fixedPt: -1.0)], "flatten: fast flick identical")

        // Cumulative totals over 20 notches at fractional multipliers: exact,
        // no floating-point under-emission.
        for (mul, want) in [(300, 6), (600, 12), (1500, 30)] {
            let out = run(Array(repeating: notch, count: 20), cfg(mul: mul))
            checkEq(out.reduce(0) { $0 + Int($1.line) }, want, "cumulative total at mul \(mul)")
        }

        // The spec's exact 5-notch emission pattern at 0.6, inverted.
        let five = run(Array(repeating: notch, count: 5), cfg(invert: true, mul: 600))
        checkEq(five.map(\.line), [0, -1, 0, -1, -1], "emission pattern at 0.6 inverted")

        // Alternating direction at 0.6: per-direction residue slots keep
        // scrolling alive; a single shared slot emits nothing forever.
        var alternating: [AxisDeltas] = []
        for i in 0..<20 { alternating.append(i % 2 == 0 ? notch : backNotch) }
        let alt = run(alternating, cfg(mul: 600))
        checkEq(alt.filter { $0.line != 0 }.count, 12, "alternating at 0.6 emits 12 non-zero")

        // Line 0 with non-zero point and fixed-point: sub-line movement is
        // rewritten (inverted), never passed through on the line test alone.
        let subLine = run([AxisDeltas(line: 0, point: 10, fixedPt: 1.0)],
                          cfg(invert: true, flatten: false))
        checkEq(subLine, [AxisDeltas(line: -1, point: -10, fixedPt: -1.0)], "line-0 event inverted")

        // A fixed-point delta of 1/65536: non-zero source magnitude, finite
        // scale factor, never NaN, and not idle.
        let tiny = run([AxisDeltas(line: 0, point: 0, fixedPt: 1.0 / 65536)],
                       cfg(flatten: false))
        checkEq(tiny, [AxisDeltas(line: 0, point: 0, fixedPt: 0.0)], "1/65536 fixed-point")

        // Point-only event, inverted: the spec's exact full triple.
        let pointOnly = run([AxisDeltas(line: 0, point: 16, fixedPt: 0.0)],
                            cfg(invert: true, flatten: false))
        checkEq(pointOnly, [AxisDeltas(line: -2, point: -16, fixedPt: -2.0)], "point-only 16px inverted")

        // 2000 half-line inputs at the lowest multiplier emit exactly one
        // line; residue lives in product units, so divide-first loses it all.
        let halves = run(Array(repeating: AxisDeltas(line: 0, point: 0, fixedPt: 0.5), count: 2000),
                         cfg(flatten: false, mul: 1))
        checkEq(halves.reduce(0) { $0 + Int($1.line) }, 1, "2000 half-lines at 0.001 emit 1 line")
        checkEq(halves.filter { $0.line != 0 }.count, 1, "exactly one non-zero emission")

        // Upper bounds under flatten: exercises the conversion path without
        // trapping (the magnitude itself comes from linesPerNotch there).
        let big = run([boundInput], cfg(lines: 1000, mul: 100000))
        checkEq(big.map(\.line), [100000], "bound case emits 100000, no trap")

        // The same bound without flatten, where the clamp actually decides the
        // magnitude. The clamped source also forces synthesized point and
        // fixed-point channels, so the triple stays coherent instead of
        // disagreeing by the clamp ratio.
        let bigScaled = run([boundInput], cfg(flatten: false, lines: 1000, mul: 100000))
        checkEq(bigScaled, [AxisDeltas(line: 100000, point: 800000, fixedPt: 100000.0)],
                "unflattened line delta clamps to maxLineDelta, channels coherent")
        let astronomical = run([AxisDeltas(line: 4_000_000_000_000, point: 0, fixedPt: 0.0)],
                               cfg(flatten: false, lines: 1000, mul: 100000))
        checkEq(astronomical.map(\.line), [100000], "astronomical line delta clamps, no trap")

        // The clamp reached through the point branch alone.
        let pointClamped = run([AxisDeltas(line: 0, point: 400000, fixedPt: 0.0)],
                               cfg(flatten: false))
        checkEq(pointClamped, [AxisDeltas(line: 1000, point: 8000, fixedPt: 1000.0)],
                "point-only delta clamps and synthesizes coherent channels")

        // Config values are re-clamped at use: a negative linesPerNotch would
        // otherwise flip the magnitude sign and poison a residue slot, and a
        // negative multiplier would reverse the product while the residue slot
        // selection still followed the un-reversed direction.
        let negLines = run([notch], cfg(lines: -5))
        checkEq(negLines, [AxisDeltas(line: 1, point: 8, fixedPt: 1.0)],
                "negative linesPerNotch clamps to 1 at use")
        let negMul = run([notch], cfg(mul: -1))
        checkEq(negMul, [AxisDeltas(line: 0, point: 0, fixedPt: 0.0)],
                "negative multiplier clamps to minimum at use")

        // Hostile doubles from the event fields must not trap conversions, and
        // a clamped source synthesizes coherent channels rather than scaling
        // the absurd original back out.
        let huge = run([AxisDeltas(line: 0, point: 0, fixedPt: 1e300)], cfg(flatten: false))
        checkEq(huge, [AxisDeltas(line: 1000, point: 8000, fixedPt: 1000.0)],
                "1e300 fixed-point clamps, coherent triple, no trap")
        check(run([AxisDeltas(line: 0, point: 0, fixedPt: Double.nan)], cfg()).isEmpty,
              "NaN fixed-point treated as idle")

        // A NaN fixed-point beside a real line delta is treated as absent, so
        // the output fixed-point is synthesized, not NaN.
        let nanBesideLine = run([AxisDeltas(line: 1, point: 10, fixedPt: Double.nan)],
                                cfg(flatten: false))
        checkEq(nanBesideLine, [AxisDeltas(line: 1, point: 10, fixedPt: 1.0)],
                "NaN beside a line delta synthesizes the fixed-point channel")

        // A fixed-point original whose scaled result would overflow to
        // infinity falls back to the synthesized value.
        let overflow = run([AxisDeltas(line: 1, point: 10, fixedPt: 1e308)],
                           cfg(flatten: false, mul: 100000))
        checkEq(overflow, [AxisDeltas(line: 100, point: 1000, fixedPt: 100.0)],
                "infinite scaled fixed-point falls back to synthesized")

        // Channels disagreeing on direction with the resolved source: neither
        // derived channel may oppose the emitted lines (the fixed-point field
        // drives NSEvent's scrollingDeltaY).
        let opposedFixed = run([AxisDeltas(line: 1, point: 10, fixedPt: -1.0)],
                               cfg(flatten: false))
        checkEq(opposedFixed, [AxisDeltas(line: 1, point: 10, fixedPt: 1.0)],
                "opposing fixed-point sign is overridden by the emitted direction")
        let opposedPoint = run([AxisDeltas(line: 1, point: -10, fixedPt: 1.0)],
                               cfg(flatten: false))
        checkEq(opposedPoint, [AxisDeltas(line: 1, point: 8, fixedPt: 1.0)],
                "opposing point sign is overridden by the emitted direction")

        // A fixed-point value too small to round to one 16.16 unit must not
        // shadow real point movement into an idle verdict.
        let tinyBesidePoint = run([AxisDeltas(line: 0, point: 16, fixedPt: 1e-9)],
                                  cfg(invert: true, flatten: false))
        checkEq(tinyBesidePoint, [AxisDeltas(line: -2, point: -16, fixedPt: -2.0)],
                "sub-resolution fixed-point falls through to the point branch")
    }

    static func events() {
        let v3 = cfg(mul: 300)
        let v6 = cfg(mul: 600)

        // Both axes non-idle, one emitting zero: the other axis's movement
        // survives, so the event is rewritten, not swallowed.
        var state = ScrollFilterState()
        checkEq(decide(vertical: notch, horizontal: notch, vConfig: v3, state: &state),
                ScrollDecision.rewrite(vertical: AxisDeltas(line: 0, point: 0, fixedPt: 0.0),
                                       horizontal: AxisDeltas(line: 1, point: 8, fixedPt: 1.0)),
                "zero-emit axis does not swallow the other")

        // All non-idle axes emitting zero with no phase metadata: swallow.
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, vConfig: v3, state: &state),
                ScrollDecision.swallow, "zero-emit with no phase swallows")

        state = ScrollFilterState()
        checkEq(decide(vertical: idleAxis, state: &state),
                ScrollDecision.passUnchanged, "fully idle event passes unchanged")

        // A non-continuous event carrying a scroll phase is never swallowed:
        // coherent zero deltas instead, or a phase-tracking view sticks.
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, phase: 2, vConfig: v3, state: &state),
                ScrollDecision.rewrite(vertical: AxisDeltas(line: 0, point: 0, fixedPt: 0.0),
                                       horizontal: nil),
                "phase-bearing zero-emit passes with zero deltas")

        // Trackpad pass-through, and the rule that momentum is never modified
        // regardless of the alternate-detection flag.
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, continuous: true, vConfig: v3, state: &state),
                ScrollDecision.passUnchanged, "continuous event passes unchanged")
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, momentum: 1, vConfig: v3, alt: true, state: &state),
                ScrollDecision.passUnchanged, "alt detection: momentum passes unchanged")
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, momentum: 1, vConfig: v3, state: &state),
                ScrollDecision.passUnchanged, "momentum never modified")

        // The alternate detection widens what counts as a trackpad: a
        // phase-bearing non-continuous event passes untouched with the flag
        // and is rewritten without it.
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, phase: 2, alt: true, state: &state),
                ScrollDecision.passUnchanged, "alt detection: scroll phase passes unchanged")
        state = ScrollFilterState()
        checkEq(decide(vertical: notch, phase: 2, state: &state),
                ScrollDecision.rewrite(vertical: AxisDeltas(line: 1, point: 8, fixedPt: 1.0),
                                       horizontal: nil),
                "without alt detection the same event is rewritten")

        // Residue carries within a burst and resets across a >250ms idle gap,
        // in both direction slots; an implementation resetting only the
        // positive slot must fail the negative rows.
        for (input, sign, name) in [(notch, Int64(1), "positive"), (backNotch, Int64(-1), "negative")] {
            state = ScrollFilterState()
            _ = decide(vertical: input, vConfig: v6, state: &state)
            checkEq(decide(vertical: input, vConfig: v6, time: 0.1, state: &state),
                    ScrollDecision.rewrite(
                        vertical: AxisDeltas(line: sign, point: sign * 8, fixedPt: Double(sign)),
                        horizontal: nil),
                    "\(name)-direction residue carries within a burst")
            state = ScrollFilterState()
            _ = decide(vertical: input, vConfig: v6, state: &state)
            checkEq(decide(vertical: input, vConfig: v6, time: 0.5, state: &state),
                    ScrollDecision.swallow, "\(name)-direction residue resets across a gap")
        }

        // A gap of exactly 250ms is within the burst; only strictly more
        // resets.
        state = ScrollFilterState()
        _ = decide(vertical: notch, vConfig: v6, state: &state)
        checkEq(decide(vertical: notch, vConfig: v6, time: 0.25, state: &state),
                ScrollDecision.rewrite(vertical: AxisDeltas(line: 1, point: 8, fixedPt: 1.0),
                                       horizontal: nil),
                "a gap of exactly 250ms keeps the residue")

        state = ScrollFilterState()
        _ = decide(vertical: notch, vConfig: v6, state: &state)
        checkEq(decide(vertical: notch, vConfig: cfg(mul: 601), time: 0.1, state: &state),
                ScrollDecision.swallow, "residue resets on config change")
    }

    static func fieldWrites() {
        // The line-delta setter synthesizes the point and fixed-point fields,
        // so the write order is load-bearing: line first, then the others.
        // Values chosen so a wrong order is visible: a last-place line write
        // of -2 would synthesize point -16 and fixed -2.0, not -30 and -2.5.
        // Both axes run the same cases; the other axis's fields must stay
        // untouched.
        let axes: [(ScrollAxis, CGEventField, CGEventField, CGEventField, CGEventField, String)] = [
            (.vertical, .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1,
             .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis2, "vertical"),
            (.horizontal, .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2,
             .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis1, "horizontal"),
        ]
        for (axis, lineField, pointField, fixedField, otherLineField, name) in axes {
            if let event = makeScrollEvent() {
                event.setIntegerValueField(pointField, value: 99)
                event.setDoubleValueField(fixedField, value: 3.5)
                applyAxisDeltas(AxisDeltas(line: -2, point: -30, fixedPt: -2.5),
                                to: event, axis: axis, flatten: false)
                checkEq(event.getIntegerValueField(lineField), -2, "\(name): line written")
                checkEq(event.getIntegerValueField(pointField), -30,
                        "\(name): point survives the line write")
                checkEq(event.getDoubleValueField(fixedField), -2.5,
                        "\(name): fixed-point survives the line write")
                checkEq(event.getIntegerValueField(otherLineField), 0,
                        "\(name): other axis untouched")
            } else {
                check(false, "CGEvent creation failed; \(name) order case not run")
            }

            // Under flatten the single line write is the whole job, and the
            // OS's own derivation supplies the other two channels.
            if let flat = makeScrollEvent() {
                applyAxisDeltas(AxisDeltas(line: -1, point: -8, fixedPt: -1.0),
                                to: flat, axis: axis, flatten: true)
                checkEq(flat.getIntegerValueField(lineField), -1, "\(name) flatten: line")
                checkEq(flat.getIntegerValueField(pointField), -8, "\(name) flatten: synthesized point")
                checkEq(flat.getDoubleValueField(fixedField), -1.0, "\(name) flatten: synthesized fixed")
            } else {
                check(false, "CGEvent creation failed; \(name) flatten case not run")
            }
        }
    }

    static func settingsClamps() {
        // Loaded values are clamped at both ends; zero for either setting
        // would swallow every scroll event with no error shown.
        checkEq(clampedLinesPerNotch(0), 1, "lines 0 clamps to 1")
        checkEq(clampedLinesPerNotch(-5), 1, "negative lines clamps to 1")
        checkEq(clampedLinesPerNotch(2000), 1000, "lines above bound clamps to 1000")
        checkEq(clampedLinesPerNotch(3), 3, "in-range lines untouched")
        checkEq(clampedMulThousandths(0), 1, "mul 0 clamps to 1")
        checkEq(clampedMulThousandths(200000), 100000, "mul above bound clamps to 100000")
        // A non-finite multiplier reaches an Int64 conversion that terminates
        // the process; it must fall back to the default instead.
        checkEq(clampedMulThousandths(fromMultiplier: Double.nan), 1000, "NaN multiplier -> default")
        checkEq(clampedMulThousandths(fromMultiplier: .infinity), 1000, "infinite multiplier -> default")
        checkEq(clampedMulThousandths(fromMultiplier: 0), 1, "multiplier 0 clamps to minimum")
        checkEq(clampedMulThousandths(fromMultiplier: 0.6), 600, "0.6 stored exactly as 600")
        checkEq(clampedMulThousandths(fromMultiplier: 100.0), 100000, "100 stored as 100000")
    }
}

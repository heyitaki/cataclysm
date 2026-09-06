// Harness for the speed slider math (PanelMath.swift): the log-scale
// position mapping, the park-at-nearer-end rule for out-of-slider-range
// stored values, the per-scale snap grid, and the readout formatting. Two
// scales share the code: scroll speed (0.5x-10x in 0.25x steps) and pointer
// speed (0.25x-4x in 0.05x steps).
//
// Build and run: make test

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

func checkClose(_ got: Double, _ want: Double, _ name: String) {
    check(abs(got - want) < 1e-12, name, "got \(got), want \(want)")
}

@main
struct PanelMathTests {
    static func main() {
        positionTests()
        snapTests()
        pointerScaleTests()
        labelTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func positionTests() {
        let scale = scrollSpeedScale
        checkClose(scale.position(forMultiplier: 1.0), 0.0, "position: 1.00x is the log origin")
        checkClose(scale.position(forMultiplier: 0.5), scale.positionRange.lowerBound,
                   "position: 0.50x is the lower end")
        checkClose(scale.position(forMultiplier: 10.0), scale.positionRange.upperBound,
                   "position: 10.00x is the upper end")
        // Log scale: 0.5x and 2.0x sit the same distance either side of 1.0x.
        checkClose(scale.position(forMultiplier: 2.0), -scale.position(forMultiplier: 0.5),
                   "position: 2x mirrors 0.5x")
        // Legal stored values beyond the slider park at the nearer end.
        checkClose(scale.position(forMultiplier: 50.0), scale.positionRange.upperBound,
                   "position: 50x parks at the upper end")
        checkClose(scale.position(forMultiplier: 0.001), scale.positionRange.lowerBound,
                   "position: 0.001x parks at the lower end")
    }

    static func snapTests() {
        let scale = scrollSpeedScale
        // On-grid multipliers survive the position round trip exactly.
        for value in [0.5, 1.0, 1.25, 2.0, 4.0, 10.0] {
            checkEq(scale.multiplier(forPosition: scale.position(forMultiplier: value)), value,
                    "snap: \(value) round-trips")
        }
        // An arbitrary track position snaps to the nearest 0.25x.
        checkEq(scale.multiplier(forPosition: 0.1), 1.0,
                "snap: exp(0.1), about 1.1052, snaps to 1.00")
        checkEq(scale.multiplier(forPosition: scale.position(forMultiplier: 1.37)), 1.25,
                "snap: 1.37 snaps to 1.25")
        checkEq(scale.multiplier(forPosition: scale.position(forMultiplier: 1.38)), 1.5,
                "snap: 1.38 snaps to 1.50")
        // Every grid point round-trips exactly and stores as a whole number
        // of thousandths.
        for i in 2...40 {
            let value = Double(i) / 4
            let snapped = scale.multiplier(forPosition: scale.position(forMultiplier: value))
            checkEq(snapped, value, "snap: grid point \(i) is exactly \(value)")
            checkEq(mulThousandths(forMultiplier: snapped), i * 250,
                    "store: grid point \(i) stores as \(i * 250) thousandths")
        }
        checkEq(scale.multiplier(forPosition: scale.positionRange.lowerBound), 0.5,
                "snap: lower end reads 0.50")
        checkEq(scale.multiplier(forPosition: scale.positionRange.upperBound), 10.0,
                "snap: upper end reads 10.00")
        // Storage conversion of already-snapped values.
        checkEq(mulThousandths(forMultiplier: 0.5), 500, "store: 0.5 is 500 thousandths")
        checkEq(mulThousandths(forMultiplier: 1.25), 1_250, "store: 1.25 is 1250 thousandths")
        checkEq(mulThousandths(forMultiplier: 10.0), 10_000, "store: 10.00 is 10000 thousandths")
    }

    // The pointer speed scale: 0.25x to 4x, so 0.5x and 2x mirror around 1x
    // and the ends do too, snapped to 0.05x because pointer speed wants finer
    // steps than the wheel.
    static func pointerScaleTests() {
        let scale = pointerSpeedScale
        checkClose(scale.position(forMultiplier: 1.0), 0.0, "pointer: 1.00x is the log origin")
        checkClose(scale.position(forMultiplier: 0.25), scale.positionRange.lowerBound,
                   "pointer: 0.25x is the lower end")
        checkClose(scale.position(forMultiplier: 4.0), scale.positionRange.upperBound,
                   "pointer: 4.00x is the upper end")
        checkClose(scale.position(forMultiplier: 4.0), -scale.position(forMultiplier: 0.25),
                   "pointer: 4x mirrors 0.25x")
        checkClose(scale.position(forMultiplier: 10.0), scale.positionRange.upperBound,
                   "pointer: 10x parks at the upper end")
        checkClose(scale.position(forMultiplier: 0.1), scale.positionRange.lowerBound,
                   "pointer: 0.1x parks at the lower end")
        // Every 0.05x grid point round-trips and stores as a multiple of 50.
        for i in 5...80 {
            let value = Double(i) / 20
            let snapped = scale.multiplier(forPosition: scale.position(forMultiplier: value))
            checkEq(snapped, value, "pointer: grid point \(i) is exactly \(value)")
            checkEq(mulThousandths(forMultiplier: snapped), i * 50,
                    "pointer: grid point \(i) stores as \(i * 50) thousandths")
        }
        checkEq(scale.multiplier(forPosition: scale.position(forMultiplier: 1.37)), 1.35,
                "pointer: 1.37 snaps to 1.35")
        checkEq(scale.multiplier(forPosition: scale.position(forMultiplier: 1.38)), 1.4,
                "pointer: 1.38 snaps to 1.40")
        checkEq(scale.multiplier(forPosition: scale.positionRange.lowerBound), 0.25,
                "pointer: lower end reads 0.25")
        checkEq(scale.multiplier(forPosition: scale.positionRange.upperBound), 4.0,
                "pointer: upper end reads 4.00")
    }

    static func labelTests() {
        checkEq(multiplierLabel(forThousandths: 1_000), "1.00x", "label: default")
        checkEq(multiplierLabel(forThousandths: 500), "0.50x", "label: slider minimum")
        checkEq(multiplierLabel(forThousandths: 10_000), "10.00x", "label: slider maximum")
        checkEq(multiplierLabel(forThousandths: 50_000), "50.00x", "label: beyond the slider")
        // Below 0.01x the readout keeps three decimals so a tiny legal
        // stored value never reads as "off".
        checkEq(multiplierLabel(forThousandths: 1), "0.001x", "label: stored 0.001 keeps three decimals")
        checkEq(multiplierLabel(forThousandths: 10), "0.01x", "label: 0.01 stays two decimals")
    }
}

// Harness for the scroll speed slider math (PanelMath.swift): the log-scale
// position mapping, the park-at-nearer-end rule for out-of-slider-range
// stored values, the 0.25x snap, and the readout formatting.
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
        labelTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func positionTests() {
        checkClose(sliderPosition(forMultiplier: 1.0), 0.0, "position: 1.00x is the log origin")
        checkClose(sliderPosition(forMultiplier: 0.5), sliderPositionRange.lowerBound,
                   "position: 0.50x is the lower end")
        checkClose(sliderPosition(forMultiplier: 10.0), sliderPositionRange.upperBound,
                   "position: 10.00x is the upper end")
        // Log scale: 0.5x and 2.0x sit the same distance either side of 1.0x.
        checkClose(sliderPosition(forMultiplier: 2.0), -sliderPosition(forMultiplier: 0.5),
                   "position: 2x mirrors 0.5x")
        // Legal stored values beyond the slider park at the nearer end.
        checkClose(sliderPosition(forMultiplier: 50.0), sliderPositionRange.upperBound,
                   "position: 50x parks at the upper end")
        checkClose(sliderPosition(forMultiplier: 0.001), sliderPositionRange.lowerBound,
                   "position: 0.001x parks at the lower end")
    }

    static func snapTests() {
        // On-grid multipliers survive the position round trip exactly.
        for value in [0.5, 1.0, 1.25, 2.0, 4.0, 10.0] {
            checkEq(multiplier(forSliderPosition: sliderPosition(forMultiplier: value)), value,
                    "snap: \(value) round-trips")
        }
        // An arbitrary track position snaps to the nearest 0.25x.
        checkEq(multiplier(forSliderPosition: 0.1), 1.0,
                "snap: exp(0.1), about 1.1052, snaps to 1.00")
        checkEq(multiplier(forSliderPosition: sliderPosition(forMultiplier: 1.37)), 1.25,
                "snap: 1.37 snaps to 1.25")
        checkEq(multiplier(forSliderPosition: sliderPosition(forMultiplier: 1.38)), 1.5,
                "snap: 1.38 snaps to 1.50")
        // Every grid point round-trips exactly and stores as a whole number
        // of thousandths.
        for i in 2...40 {
            let value = Double(i) / 4
            let snapped = multiplier(forSliderPosition: sliderPosition(forMultiplier: value))
            checkEq(snapped, value, "snap: grid point \(i) is exactly \(value)")
            checkEq(mulThousandths(forMultiplier: snapped), i * 250,
                    "store: grid point \(i) stores as \(i * 250) thousandths")
        }
        checkEq(multiplier(forSliderPosition: sliderPositionRange.lowerBound), 0.5,
                "snap: lower end reads 0.50")
        checkEq(multiplier(forSliderPosition: sliderPositionRange.upperBound), 10.0,
                "snap: upper end reads 10.00")
        // Storage conversion of already-snapped values.
        checkEq(mulThousandths(forMultiplier: 0.5), 500, "store: 0.5 is 500 thousandths")
        checkEq(mulThousandths(forMultiplier: 1.25), 1_250, "store: 1.25 is 1250 thousandths")
        checkEq(mulThousandths(forMultiplier: 10.0), 10_000, "store: 10.00 is 10000 thousandths")
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

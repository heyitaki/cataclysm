// Harness for the scroll speed slider math (PanelMath.swift): the log-scale
// position mapping, the park-at-nearer-end rule for out-of-slider-range
// stored values, the 0.05x snap, and the readout formatting.
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
        checkClose(sliderPosition(forMultiplier: 1.0), 0.0, "position: 1.00x is the track centre")
        checkClose(sliderPosition(forMultiplier: 0.25), sliderPositionRange.lowerBound,
                   "position: 0.25x is the lower end")
        checkClose(sliderPosition(forMultiplier: 4.0), sliderPositionRange.upperBound,
                   "position: 4.00x is the upper end")
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
        for value in [0.25, 0.5, 1.0, 1.35, 2.0, 4.0] {
            checkEq(multiplier(forSliderPosition: sliderPosition(forMultiplier: value)), value,
                    "snap: \(value) round-trips")
        }
        // An arbitrary track position snaps to the nearest 0.05x.
        checkEq(multiplier(forSliderPosition: 0.1), 1.10,
                "snap: exp(0.1), about 1.1052, snaps to 1.10")
        checkEq(multiplier(forSliderPosition: sliderPosition(forMultiplier: 1.37)), 1.35,
                "snap: 1.37 snaps to 1.35")
        checkEq(multiplier(forSliderPosition: sliderPosition(forMultiplier: 1.38)), 1.40,
                "snap: 1.38 snaps to 1.40")
        // Every grid point snaps to the exact shortest double for its
        // decimal (the thousandths conversion would hide a 1-ulp miss, and
        // n * 0.05 misses at 29 of these 76 points) and stores as a whole
        // number of thousandths.
        for i in 5...80 {
            let value = Double(i) / 20
            let snapped = multiplier(forSliderPosition: sliderPosition(forMultiplier: value))
            checkEq(snapped, value, "snap: grid point \(i) is exactly \(value)")
            checkEq(mulThousandths(forMultiplier: snapped), i * 50,
                    "store: grid point \(i) stores as \(i * 50) thousandths")
        }
        checkEq(multiplier(forSliderPosition: sliderPositionRange.lowerBound), 0.25,
                "snap: lower end reads 0.25")
        checkEq(multiplier(forSliderPosition: sliderPositionRange.upperBound), 4.0,
                "snap: upper end reads 4.00")
        // Storage conversion of already-snapped values.
        checkEq(mulThousandths(forMultiplier: 0.25), 250, "store: 0.25 is 250 thousandths")
        checkEq(mulThousandths(forMultiplier: 1.15), 1_150, "store: 1.15 is 1150 thousandths")
        checkEq(mulThousandths(forMultiplier: 4.0), 4_000, "store: 4.00 is 4000 thousandths")
    }

    static func labelTests() {
        checkEq(multiplierLabel(forThousandths: 1_000), "1.00x", "label: default")
        checkEq(multiplierLabel(forThousandths: 250), "0.25x", "label: slider minimum")
        checkEq(multiplierLabel(forThousandths: 50_000), "50.00x", "label: beyond the slider")
        // Below 0.01x the readout keeps three decimals so a tiny legal
        // stored value never reads as "off".
        checkEq(multiplierLabel(forThousandths: 1), "0.001x", "label: stored 0.001 keeps three decimals")
        checkEq(multiplierLabel(forThousandths: 10), "0.01x", "label: 0.01 stays two decimals")
    }
}

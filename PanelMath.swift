// Pure math and formatting behind the panel's scroll speed slider (spec "The
// dropdown"): a log-scaled 0.25x-4.0x track so 0.5x and 2.0x sit the same
// distance either side of 1.0x, snapped to 0.05x steps. The slider's range
// is deliberately not the persisted bound: a stored multiplier outside it is
// legal, is never rewritten, and displays with the slider parked at the
// nearer end. Foundation-only so the test harness links it without AppKit.

import Foundation

let sliderMultiplierMin = 0.25
let sliderMultiplierMax = 4.0

// Track positions are natural-log multiplier values, so equal track distance
// is equal ratio.
let sliderPositionRange = log(sliderMultiplierMin)...log(sliderMultiplierMax)

// Where the slider sits for a stored multiplier; out-of-slider-range values
// park at the nearer end without being rewritten.
func sliderPosition(forMultiplier multiplier: Double) -> Double {
    log(min(max(multiplier, sliderMultiplierMin), sliderMultiplierMax))
}

// Snap grid for the slider: 20 steps per 1.0x, so the readout only ever
// shows a multiple of 0.05x (1.00x, 1.05x, 1.10x) and the stored value agrees
// with it exactly. Held as a divisor rather than a 0.05 step because n / 20
// lands on the shortest double for the decimal (28 / 20 is exactly the
// literal 1.4) where n * 0.05 rounds to a neighbouring double
// (1.4000000000000001).
let sliderStepsPerUnit = 20.0

// The multiplier a track position means, snapped to the step grid.
func multiplier(forSliderPosition position: Double) -> Double {
    (exp(position) * sliderStepsPerUnit).rounded() / sliderStepsPerUnit
}

// Storage form. The slider can only produce in-slider-range values, so the
// Settings setter's clamp is the only bound this needs.
func mulThousandths(forMultiplier multiplier: Double) -> Int {
    Int((multiplier * 1_000).rounded())
}

// Two-decimal readout; rendered with .monospacedDigit() so the panel never
// shifts as the number changes. Below 0.01x (reachable only by hand-edited
// plists) two decimals would read as "off", so those keep three.
func multiplierLabel(forThousandths thousandths: Int) -> String {
    let value = Double(thousandths) / 1_000
    return String(format: value < 0.01 ? "%.3fx" : "%.2fx", value)
}

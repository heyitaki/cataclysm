// Pure math and formatting behind the panel's two speed sliders: scroll
// spans 0.5x-10x in 0.25x steps, pointer 0.25x-4x in 0.05x steps. Log-scaled
// tracks put equal ratios at equal distances. Their ranges are narrower
// than the persisted bounds: a stored multiplier outside the track is never
// rewritten and parks at the nearer end. Foundation-only so the test
// harness links it without AppKit.

import Foundation

struct SliderScale {
    let minimum: Double
    let maximum: Double
    let stepsPerUnit: Double

    var positionRange: ClosedRange<Double> { log(minimum)...log(maximum) }

    func position(forMultiplier multiplier: Double) -> Double {
        log(min(max(multiplier, minimum), maximum))
    }

    func multiplier(forPosition position: Double) -> Double {
        (exp(position) * stepsPerUnit).rounded() / stepsPerUnit
    }
}

let scrollSpeedScale = SliderScale(minimum: 0.5, maximum: 10, stepsPerUnit: 4)
let pointerSpeedScale = SliderScale(minimum: 0.25, maximum: 4, stepsPerUnit: 20)

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

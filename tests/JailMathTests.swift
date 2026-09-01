// Harness for the pure jail geometry (JailMath.swift): the rounded-rect
// clamp's corner projection, radius capping, title-bar shrink, and the
// title-bar inference rules. Pure functions; no AX, no windows.
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

@main
struct JailMathTests {
    static func main() {
        rectClampTests()
        cornerTests()
        radiusTests()
        titleBarTests()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func rectClampTests() {
        let c = Clamp(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                      titleBar: 0, cornerRadius: 10)
        checkEq(c.clamped(CGPoint(x: 50, y: 50)), CGPoint(x: 50, y: 50),
                "point inside the rect is unchanged")
        // Beyond one edge but not past an arc centre: plain rect clamp, no
        // corner projection.
        checkEq(c.clamped(CGPoint(x: 150, y: 50)), CGPoint(x: 100, y: 50),
                "edge overshoot clamps to the edge")
        checkEq(c.clamped(CGPoint(x: 50, y: -20)), CGPoint(x: 50, y: 0),
                "top overshoot clamps to the top")
        // On the rect corner but inside the arc's quadrant guard on one axis.
        checkEq(c.clamped(CGPoint(x: 95, y: 50)), CGPoint(x: 95, y: 50),
                "point between the arc centres stays put")
    }

    static func cornerTests() {
        let c = Clamp(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                      titleBar: 0, cornerRadius: 10)
        // (200,200) rect-clamps to (100,100); bottom-right arc centre is
        // (90,90), d = 10*sqrt(2), projection lands at 90 + 10/sqrt(2) each
        // axis = 97.07, rounded to nearest.
        checkEq(c.clamped(CGPoint(x: 200, y: 200)), CGPoint(x: 97, y: 97),
                "bottom-right corner projects onto the arc")
        checkEq(c.clamped(CGPoint(x: -200, y: 200)), CGPoint(x: 3, y: 97),
                "bottom-left corner projects onto the arc")
        checkEq(c.clamped(CGPoint(x: 200, y: -200)), CGPoint(x: 97, y: 3),
                "top-right corner projects onto the arc")
        checkEq(c.clamped(CGPoint(x: -200, y: -200)), CGPoint(x: 3, y: 3),
                "top-left corner projects onto the arc")
        // Just inside the arc: distance to the centre under the radius.
        checkEq(c.clamped(CGPoint(x: 93, y: 93)), CGPoint(x: 93, y: 93),
                "point inside the arc is unchanged")
    }

    static func radiusTests() {
        // Radius 0 disables corner clamping entirely (the stepper's 0 case).
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let flat = Clamp(rect: square, titleBar: 0, cornerRadius: 0)
        checkEq(flat.clamped(CGPoint(x: -5, y: -5)), CGPoint(x: 0, y: 0),
                "radius 0 keeps the sharp rect corner")

        // A radius beyond half the shorter side caps there: the two arc
        // centres must fit inside the rect.
        let wide = Clamp(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                         titleBar: 0, cornerRadius: 200)
        checkEq(wide.topRadius, 20, "radius caps at half the shorter side (top)")
        checkEq(wide.bottomRadius, 20, "radius caps at half the shorter side (bottom)")

        // The top arcs shrink by the title bar the rect already excludes.
        let shrunk = Clamp(rect: square, titleBar: 6, cornerRadius: 20)
        checkEq(shrunk.topRadius, 14, "top radius shrinks by the title bar")
        checkEq(shrunk.bottomRadius, 20, "bottom radius keeps the full radius")

        // A title bar taller than the radius zeroes the top arcs, never
        // negative.
        let zeroed = Clamp(rect: square, titleBar: 30, cornerRadius: 10)
        checkEq(zeroed.topRadius, 0, "title bar beyond the radius zeroes the top")
        checkEq(zeroed.clamped(CGPoint(x: -5, y: -5)), CGPoint(x: 0, y: 0),
                "zeroed top radius keeps the sharp top corner")
        checkEq(zeroed.clamped(CGPoint(x: 200, y: 200)), CGPoint(x: 97, y: 97),
                "bottom corner still projects with a zeroed top")
    }

    static func titleBarTests() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 480)
        // Close button height plus twice its top inset: 12 + 2*6 = 24.
        checkEq(inferredTitleBarHeight(
                    closeButton: CGRect(x: 8, y: 6, width: 12, height: 12),
                    frame: frame),
                24, "close button measures the title bar")
        // No close button: 480 - 800*(9/16) = 30, inside the 16...45 band.
        checkEq(inferredTitleBarHeight(closeButton: nil, frame: frame),
                30, "16:9 ratio table infers the leftover height")
        // A bad AX read (bar taller than plausible) falls through to ratios.
        checkEq(inferredTitleBarHeight(
                    closeButton: CGRect(x: 8, y: 10, width: 12, height: 100),
                    frame: frame),
                30, "implausible close button falls back to ratios")
        // A non-positive measurement falls through too.
        checkEq(inferredTitleBarHeight(
                    closeButton: CGRect(x: 8, y: -3, width: 12, height: 4),
                    frame: frame),
                30, "non-positive close-button measurement falls back")
        // No ratio matches a square window: no title bar inferred.
        checkEq(inferredTitleBarHeight(
                    closeButton: nil,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 800)),
                0, "no matching ratio infers no title bar")
    }
}

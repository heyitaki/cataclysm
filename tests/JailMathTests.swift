// Harness for the pure jail geometry (JailMath.swift): the rounded-rect
// clamp's corner projection, radius capping, title-bar shrink, the
// title-bar inference rules, the display-mode classification, the
// engagement deferral for a held title-bar press, and the window-server
// fallback's window selection. Pure functions; no AX, no windows.
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
        windowModeTests()
        jailClampTests()
        shouldDeferEngageTests()
        fallbackWindowTests()
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

    static func windowModeTests() {
        func mode(standard: Bool = false, closeButton: Bool = false,
                  fullScreen: Bool = false) -> WindowMode {
            windowMode(standardWindow: standard, hasCloseButton: closeButton,
                       fullScreen: fullScreen)
        }
        // Borderless as League draws it: no chrome of any kind. Size plays no
        // part, so a bare window at the display's size is jailed too.
        checkEq(mode(), .borderless, "no chrome is borderless")
        checkEq(mode(standard: true, closeButton: true), .windowed,
                "standard subrole with a close button is windowed")
        checkEq(mode(standard: true), .windowed, "standard subrole alone is windowed")
        checkEq(mode(closeButton: true), .windowed, "close button alone is windowed")
        checkEq(mode(standard: true, closeButton: true, fullScreen: true), .fullscreen,
                "AX fullscreen flag outranks chrome")
        checkEq(mode(fullScreen: true), .fullscreen, "AX fullscreen flag alone is fullscreen")
    }

    static func jailClampTests() {
        let frame = CGRect(x: 640, y: 360, width: 1920, height: 1080)
        let closeButton = CGRect(x: 648, y: 366, width: 12, height: 12)
        // Borderless: the plain frame less the inset, no title bar, no arcs,
        // whatever the close button read said.
        let bare = jailClamp(mode: .borderless, frame: frame, closeButton: closeButton,
                             cornerRadius: 18)
        checkEq(bare?.rect, CGRect(x: 641, y: 361, width: 1918, height: 1078),
                "borderless keeps the whole frame less the inset")
        checkEq(bare?.topRadius, 0, "borderless has no top arcs")
        checkEq(bare?.bottomRadius, 0, "borderless has no bottom arcs")
        // Windowed: the close button measures a 24 point bar (12 + 2*6), which
        // comes off the top; the radius applies, shrunk at the top by the bar.
        let chrome = jailClamp(mode: .windowed, frame: frame, closeButton: closeButton,
                               cornerRadius: 18)
        checkEq(chrome?.rect, CGRect(x: 641, y: 385, width: 1918, height: 1054),
                "windowed carves out the title bar")
        checkEq(chrome?.bottomRadius, 18, "windowed keeps the corner radius")
        checkEq(chrome?.topRadius, 0, "windowed zeroes top arcs under the bar")
        // A radius past the bar keeps the difference at the top: a 30 point
        // bar (14 + 2*8) off a 60 point radius.
        let deep = jailClamp(mode: .windowed, frame: frame,
                             closeButton: CGRect(x: 648, y: 368, width: 14, height: 14),
                             cornerRadius: 60)
        checkEq(deep?.topRadius, 30, "windowed shrinks the top arcs by the bar")
        checkEq(deep?.bottomRadius, 60, "windowed keeps the bottom radius")
        // A frame too thin to inset yields nothing rather than CGRect.null.
        check(jailClamp(mode: .borderless, frame: CGRect(x: 0, y: 0, width: 1, height: 100),
                        closeButton: nil, cornerRadius: 18) == nil,
              "a frame too thin to inset yields no clamp")
    }

    static func shouldDeferEngageTests() {
        let area = Clamp(rect: CGRect(x: 0, y: 30, width: 200, height: 200),
                         titleBar: 30, cornerRadius: 0)
        let onTitleBar = CGPoint(x: 100, y: 15)
        let content = CGPoint(x: 100, y: 100)
        func shouldDefer(deferred: Bool, held: Bool, at cursor: CGPoint,
                         in clamp: Clamp = area) -> Bool {
            shouldDeferEngage(deferred: deferred, leftButtonHeld: held, cursor: cursor, area: clamp)
        }
        check(shouldDefer(deferred: false, held: true, at: onTitleBar), "a held press outside the clamp defers")
        check(!shouldDefer(deferred: false, held: false, at: onTitleBar),
              "a released button outside the clamp engages")
        check(!shouldDefer(deferred: false, held: true, at: content), "a held press inside the clamp engages")
        check(!shouldDefer(deferred: false, held: false, at: content), "released inside the clamp engages")
        // Mid-drag the cursor can sit over the content area (lagging window,
        // stale clamp); only the release ends a deferral.
        check(shouldDefer(deferred: true, held: true, at: content), "a deferred press stays deferred inside the clamp")
        check(!shouldDefer(deferred: true, held: false, at: onTitleBar), "the release ends the deferral")
        // The corner gap is inside the rect but outside the window, so a
        // press there is a press on the app behind: the rule follows the
        // rounded clamp, not the rect.
        let rounded = Clamp(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                            titleBar: 0, cornerRadius: 10)
        check(shouldDefer(deferred: false, held: true, at: CGPoint(x: 98, y: 98), in: rounded),
              "a held press in the corner gap defers")
    }

    // The window-server fallback (fallbackWindow): the jail's measurement
    // when the Accessibility read fails, pure over what
    // CGWindowListCopyWindowInfo reports and the display frames.
    static func fallbackWindowTests() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let second = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let displays = [display, second]
        func entry(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                   layer: Int = 0) -> WindowListEntry {
            WindowListEntry(bounds: CGRect(x: x, y: y, width: w, height: h), layer: layer)
        }

        checkEq(fallbackWindow(entries: [], displays: displays), .none,
                "no windows yields nothing")
        // Anything under 200 points on a side is chrome, a tooltip, or a
        // splash, never the game's surface.
        checkEq(fallbackWindow(entries: [entry(100, 100, 199, 600), entry(0, 0, 600, 199)],
                               displays: displays),
                .none, "windows under the size floor are ignored")
        // The largest window wins, whatever its order in the list.
        checkEq(fallbackWindow(entries: [entry(10, 10, 300, 250), entry(640, 360, 1280, 720)],
                               displays: displays),
                .window(mode: .windowed, frame: CGRect(x: 640, y: 360, width: 1280, height: 720)),
                "the largest window is the game's")
        // A window past the floor on one side but not the other never beats a
        // qualifying one, however wide it is.
        checkEq(fallbackWindow(entries: [entry(0, 0, 2000, 150), entry(0, 200, 400, 300)],
                               displays: displays),
                .window(mode: .windowed, frame: CGRect(x: 0, y: 200, width: 400, height: 300)),
                "a wide strip does not outrank a real window")
        // Equal areas: the list is front to back, so the earlier entry is the
        // one in front.
        checkEq(fallbackWindow(entries: [entry(0, 0, 800, 600), entry(100, 100, 800, 600)],
                               displays: displays),
                .window(mode: .windowed, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                "an area tie keeps the frontmost window")
        // Layer 0 is a normal window with macOS chrome; anything else (League's
        // borderless window sits at level 1000) is bare.
        checkEq(fallbackWindow(entries: [entry(320, 180, 1920, 1080, layer: 1000)],
                               displays: displays),
                .window(mode: .borderless, frame: CGRect(x: 320, y: 180, width: 1920, height: 1080)),
                "a window off layer 0 is borderless")
        // A window covering a display exactly cannot be told from native
        // fullscreen without Accessibility, so the jail releases.
        checkEq(fallbackWindow(entries: [entry(0, 0, 2560, 1440, layer: 1000)], displays: displays),
                .fullscreen, "a display-sized window on the main display releases")
        checkEq(fallbackWindow(entries: [entry(2560, 0, 1920, 1080)], displays: displays),
                .fullscreen, "a display-sized window on a second display releases")
        // Display-sized on one side only is a big window, not fullscreen.
        checkEq(fallbackWindow(entries: [entry(0, 0, 2560, 1400)], displays: displays),
                .window(mode: .windowed, frame: CGRect(x: 0, y: 0, width: 2560, height: 1400)),
                "a window one side short of the display is still a window")
    }
}

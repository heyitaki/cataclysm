// Pure jail geometry: the rounded-rect clamp, the title-bar inference, and
// the display-mode classification. CoreGraphics-only (no AppKit, no AX) so
// the test harness can pin the corner projection, ratio-table math, and mode
// rules; the AX measurement and engagement state live in Jail.swift.

import CoreGraphics
import Foundation

// Fallback title-bar inference: common windowed aspect ratios. The title bar
// is the window height left over above the content. Ratio gaps exceed the
// accepted band at any playable width, so at most one matches.
let contentRatios: [CGFloat] = [9.0 / 16.0, 10.0 / 16.0, 3.0 / 4.0, 4.0 / 5.0]

func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    return min(max(v, lo), hi)
}

// Built once per frame refresh, so a radius can never describe a rect that has
// moved on. The top arc is shrunk by the title bar the rect already excludes: a
// circle that much smaller is internally tangent to the real one, so it can only
// hold the cursor further inside the window.
struct Clamp {
    let rect: CGRect
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    init(rect: CGRect, titleBar: CGFloat, cornerRadius: CGFloat) {
        // half the shorter side is the largest radius the two arc centres fit in
        let cap = min(rect.width, rect.height) / 2
        self.rect = rect
        self.topRadius = min(max(0, cornerRadius - titleBar), cap)
        self.bottomRadius = min(cornerRadius, cap)
    }

    // A rect clamp holds the cursor in the frame but not in the window, and the
    // difference is the four rounded corners: out there a click lands on the app
    // behind, which drops the game out of focus and releases the jail.
    func clamped(_ p: CGPoint) -> CGPoint {
        let q = CGPoint(x: clamp(p.x, rect.minX, rect.maxX),
                        y: clamp(p.y, rect.minY, rect.maxY))
        let top = q.y < rect.midY
        let radius = top ? topRadius : bottomRadius
        guard radius > 0 else { return q }
        let left = q.x < rect.midX
        let cx = left ? rect.minX + radius : rect.maxX - radius
        let cy = top ? rect.minY + radius : rect.maxY - radius
        let dx = q.x - cx, dy = q.y - cy
        // only the quadrant beyond both arc centres is corner, anywhere else the
        // rect clamp already holds
        guard left == (dx < 0), top == (dy < 0) else { return q }
        let d = hypot(dx, dy)
        guard d > radius else { return q }
        // Whole points, because the delta fields the callback writes are
        // integers. To nearest rather than inward: inward leaves nearly a point
        // of step between a position just inside the arc and its projection just
        // outside, so a hand crossing there twitches.
        let s = radius / d
        return CGPoint(x: (cx + dx * s).rounded(), y: (cy + dy * s).rounded())
    }
}

// The game's three display modes, which decide what the jail does:
// - windowed: macOS draws the chrome, so the clamp excludes the title bar and
//   follows the rounded corners.
// - borderless: a bare window at the game resolution (League centres it on the
//   display). No title bar and sharp corners, so the clamp is the plain rect;
//   a radius here would wall the cursor off the minimap corner.
// - fullscreen: the game confines the cursor itself, and a second capture on
//   top would fight its warps. The jail releases.
enum WindowMode {
    case windowed, borderless, fullscreen
}

// The AX flag is native fullscreen, which can keep the standard subrole, so
// it goes first. Chrome outranks size because a zoomed window covers the
// display once the menu bar auto-hides. The size rule cannot tell exclusive
// fullscreen from borderless at the display's own resolution: that case
// releases, which on a single display loses nothing. A fullscreen window that
// keeps clear of a camera housing is smaller than its display and would read
// as borderless (unverified).
func windowMode(standardWindow: Bool, hasCloseButton: Bool, fullScreen: Bool,
                frame: CGRect, displays: [CGRect]) -> WindowMode {
    if fullScreen { return .fullscreen }
    if standardWindow || hasCloseButton { return .windowed }
    return displays.contains(where: { coversDisplay(frame, $0) }) ? .fullscreen : .borderless
}

// The AX frame and CGDisplayBounds come from different sources, so a half
// point of drift must not turn a fullscreen window into a borderless one,
// which is the direction where the jail engages over a game already
// confining the cursor.
func coversDisplay(_ frame: CGRect, _ display: CGRect) -> Bool {
    let tolerance: CGFloat = 1
    return abs(frame.minX - display.minX) <= tolerance
        && abs(frame.minY - display.minY) <= tolerance
        && abs(frame.maxX - display.maxX) <= tolerance
        && abs(frame.maxY - display.maxY) <= tolerance
}

let inset: CGFloat = 1

// The clamp for a measured windowed or borderless frame (fullscreen never
// reaches here). Windowed carves out the title bar and rounds the corners;
// borderless has neither. nil once the inset leaves nothing: insetBy returns
// CGRect.null when a side is too thin, and null's infinite origin turns
// virtualPos into NaN permanently (NaN never compares equal, so every later
// re-clamp warps again).
func jailClamp(mode: WindowMode, frame: CGRect, closeButton: CGRect?,
               cornerRadius: CGFloat) -> Clamp? {
    let windowed = mode == .windowed
    let titleBar = windowed ? inferredTitleBarHeight(closeButton: closeButton, frame: frame) : 0
    var rect = frame
    rect.origin.y += titleBar
    rect.size.height -= titleBar
    let inner = rect.insetBy(dx: inset, dy: inset)
    guard !inner.isEmpty else { return nil }
    return Clamp(rect: inner, titleBar: titleBar, cornerRadius: windowed ? cornerRadius : 0)
}

// The title bar must be excluded from the clamp or click-flicks drag the
// window and ratchet the cursor out the top. Preferred measurement is the
// close button, which sits vertically centered in the title bar; no close
// button (nil) means hidden controls, where the ratio table takes over.
// jailClamp measures windowed mode only: borderless has no bar to find, and
// its game-size frame can land in the ratio band by accident.
func inferredTitleBarHeight(closeButton: CGRect?, frame: CGRect) -> CGFloat {
    if let btnRect = closeButton {
        let tb = btnRect.height + (btnRect.minY - frame.minY) * 2
        // a bar taller than its own window means a bad AX read, fall through
        if tb > 0 && tb < 80 && tb < frame.height { return tb }
    }
    for ratio in contentRatios {
        // 16..45 points spans the standard macOS title-bar heights
        let tb = frame.height - frame.width * ratio
        if tb >= 16 && tb <= 45 { return tb }
    }
    return 0
}

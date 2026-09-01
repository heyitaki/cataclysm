// Pure jail geometry: the rounded-rect clamp and the title-bar inference.
// CoreGraphics-only (no AppKit, no AX) so the test harness can pin the
// corner projection and ratio-table math; the AX measurement and engagement
// state live in Jail.swift. The math is settled behavior moved verbatim from
// there; only the cornerRadius global became an init parameter.

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

// The title bar must be excluded from the clamp or click-flicks drag the
// window and ratchet the cursor out the top. Preferred measurement is the
// close button, which sits vertically centered in the title bar; no close
// button (nil) means borderless, fullscreen, or hidden controls, where the
// ratio table takes over.
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

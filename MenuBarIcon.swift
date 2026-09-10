// The menu bar glyph: a filled cursor arrow standing inside the Cataclysm
// ring, drawn at menu bar scale. Two things read from it: the master switch
// fades the whole glyph to 40% when off, and the ring is dotted until the
// cursor lock is holding the cursor, then solid. Drawing in code keeps the
// bundle a single binary plus plist. A template image lets macOS tint it
// for the light and dark menu bars and for the pressed state.

import AppKit

enum MenuBarIconState {
    case off, on, engaged
}

func makeMenuBarIcon(_ state: MenuBarIconState) -> NSImage {
    let side: CGFloat = 18
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
        // Template images mask by alpha, so the off fade survives the menu
        // bar tint.
        let ink = NSColor.black.withAlphaComponent(state == .off ? 0.4 : 1)
        ink.setFill()
        ink.setStroke()

        // The arena wall: eight short dashes while the lock is idle, a
        // closed line once it is holding the cursor.
        let center = NSPoint(x: side / 2, y: side / 2)
        let radius: CGFloat = 7.5
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: radius,
                       startAngle: 0, endAngle: 360)
        ring.lineWidth = 1.8
        if state != .engaged {
            ring.lineCapStyle = .round
            let period = 2 * .pi * radius / 8
            // Round caps add lineWidth to each dash, so the drawn dash is
            // about 4 points on a 5.9 point period.
            let dash = period * 0.35
            ring.setLineDash([dash, period - dash], count: 2, phase: -dash / 2)
        }
        ring.stroke()

        // The cursor: the classic macOS arrow in its 12x19 grid, scaled to sit
        // inside the ring with a clear margin from the pillars. The arrow's
        // mass sits up and left of its bounding box, so it is placed by its
        // centroid rather than its box, or it reads off-center in the ring.
        let outline: [NSPoint] = [
            NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 16), NSPoint(x: 4, y: 12.5),
            NSPoint(x: 6.5, y: 18.5), NSPoint(x: 9.5, y: 17.2),
            NSPoint(x: 7, y: 11.5), NSPoint(x: 12, y: 11.5),
        ]
        let scale: CGFloat = 9.5 / 19
        // Area centroid of the outline (shoelace formula), precomputed.
        let centroid = NSPoint(x: 4.3035, y: 9.7691)
        let origin = NSPoint(x: center.x - centroid.x * scale,
                             y: center.y - centroid.y * scale)
        let arrow = NSBezierPath()
        for (i, p) in outline.enumerated() {
            let point = NSPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
            if i == 0 { arrow.move(to: point) } else { arrow.line(to: point) }
        }
        arrow.close()
        arrow.fill()
        return true
    }
    image.isTemplate = true
    // An image-only menu bar label carries no name of its own, so the image
    // supplies one for VoiceOver.
    image.accessibilityDescription = "Cataclysm"
    return image
}

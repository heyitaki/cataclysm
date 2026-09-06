// The menu bar glyph: a cursor arrow standing inside the Cataclysm ring,
// drawn at menu bar scale. Off is a faint dotted ring and outlined arrow.
// On is a solid ring and outlined arrow. Engaged fills the arrow so the
// cursor lock reads from the menu bar alone. Drawing in code keeps the
// bundle a single binary plus plist. A template image lets macOS tint it
// for the light and dark menu bars and for the pressed state.

import AppKit

enum MenuBarIconState {
    case off, on, engaged
}

func makeMenuBarIcon(_ state: MenuBarIconState) -> NSImage {
    let side: CGFloat = 18
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
        NSColor.black.setFill()

        // The arena wall. Off: twelve round dots at 40% so the ring is
        // there but plainly not up. Template images mask by alpha, so the
        // fade survives the menu bar tint.
        let center = NSPoint(x: side / 2, y: side / 2)
        let radius: CGFloat = 7.5
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: radius,
                       startAngle: 0, endAngle: 360)
        ring.lineWidth = 1.8
        if state != .off {
            NSColor.black.setStroke()
        } else {
            ring.lineCapStyle = .round
            let period = 2 * .pi * radius / 12
            // Zero-length dashes with round caps draw as dots of lineWidth.
            ring.setLineDash([0, period], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.4).setStroke()
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
        let centroid = polygonCentroid(outline)
        let origin = NSPoint(x: center.x - centroid.x * scale,
                             y: center.y - centroid.y * scale)
        let arrow = NSBezierPath()
        for (i, p) in outline.enumerated() {
            let point = NSPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
            if i == 0 { arrow.move(to: point) } else { arrow.line(to: point) }
        }
        arrow.close()
        if state == .engaged {
            arrow.fill()
        } else {
            arrow.lineWidth = 1
            NSColor.black.withAlphaComponent(state == .off ? 0.4 : 1).setStroke()
            arrow.stroke()
        }
        return true
    }
    image.isTemplate = true
    // An image-only menu bar label carries no name of its own, so the image
    // supplies one for VoiceOver.
    image.accessibilityDescription = "Cataclysm"
    return image
}

// Area centroid of a simple polygon (shoelace formula).
private func polygonCentroid(_ points: [NSPoint]) -> NSPoint {
    var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
    for i in points.indices {
        let p = points[i], q = points[(i + 1) % points.count]
        let cross = p.x * q.y - q.x * p.y
        area += cross
        cx += (p.x + q.x) * cross
        cy += (p.y + q.y) * cross
    }
    area /= 2
    return NSPoint(x: cx / (6 * area), y: cy / (6 * area))
}

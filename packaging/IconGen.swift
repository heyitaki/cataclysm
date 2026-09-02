// Placeholder app icon generator: writes a 1024x1024 PNG (dark rounded square,
// gold arena ring, cursor arrow standing in it — the Cataclysm ult as an icon,
// matching the menu bar glyph). Pure drawing to a file, no system access; real
// artwork replaces it post-completion.

import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: icon-gen <out.png>\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

let size = 1024
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("icon-gen: no bitmap context\n".utf8))
    exit(1)
}

let s = CGFloat(size)
// macOS icon grid: artwork inside ~100pt margins of the 1024 canvas; a rounded
// rect stands in for the squircle, close enough for a placeholder.
let plate = CGRect(x: 100, y: 100, width: s - 200, height: s - 200)
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 180, cornerHeight: 180,
                   transform: nil))
ctx.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1))
ctx.fillPath()

ctx.setStrokeColor(CGColor(red: 0.87, green: 0.72, blue: 0.34, alpha: 1))
ctx.setLineWidth(56)
ctx.strokeEllipse(in: plate.insetBy(dx: 170, dy: 170))

// The cursor: the same classic arrow the menu bar icon draws, in its 12x19
// grid, sized to the ring the way the menu glyph is (arrow height 9.5 of a
// 15 ring diameter). The arrow's mass sits up and left of its bounding box,
// so it is placed by its centroid, or it reads off-center in the ring. The
// outline is authored y-down like the menu icon; CoreGraphics is y-up, so y
// is negated when plotting.
let outline: [CGPoint] = [
    CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16), CGPoint(x: 4, y: 12.5),
    CGPoint(x: 6.5, y: 18.5), CGPoint(x: 9.5, y: 17.2),
    CGPoint(x: 7, y: 11.5), CGPoint(x: 12, y: 11.5),
]
let ringDiameter = plate.insetBy(dx: 170, dy: 170).width
let scale = ringDiameter * (9.5 / 15) / 19
let centroid = polygonCentroid(outline)
let arrow = CGMutablePath()
for (i, p) in outline.enumerated() {
    let point = CGPoint(x: s / 2 + (p.x - centroid.x) * scale,
                        y: s / 2 - (p.y - centroid.y) * scale)
    if i == 0 { arrow.move(to: point) } else { arrow.addLine(to: point) }
}
arrow.closeSubpath()
ctx.addPath(arrow)
ctx.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1))
ctx.fillPath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL,
                                                 "public.png" as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("icon-gen: no image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("icon-gen: png write failed\n".utf8))
    exit(1)
}

// Area centroid of a simple polygon (shoelace formula); mirrors MenuBarIcon.
func polygonCentroid(_ points: [CGPoint]) -> CGPoint {
    var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
    for i in points.indices {
        let p = points[i], q = points[(i + 1) % points.count]
        let cross = p.x * q.y - q.x * p.y
        area += cross
        cx += (p.x + q.x) * cross
        cy += (p.y + q.y) * cross
    }
    area /= 2
    return CGPoint(x: cx / (6 * area), y: cy / (6 * area))
}

// Placeholder app icon generator: writes a 1024x1024 PNG (dark rounded square,
// gold arena ring, cursor dot — the Cataclysm ult as an icon). Pure drawing to
// a file, no system access; real artwork replaces it post-completion.

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

ctx.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1))
ctx.fillEllipse(in: CGRect(x: s / 2 - 56, y: s / 2 - 56, width: 112, height: 112))

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

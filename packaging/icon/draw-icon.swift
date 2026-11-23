// Draws the app icon of Display 16X: a display with its menu bar line, standing on a
// foot, in aqua on the family's navy. 1024 pixels square.
//
//   swift packaging/icon/draw-icon.swift packaging/AppIcon.png
//   scripts/make-icon.sh packaging/AppIcon.png
//
// The mark is the one the app draws in its panel and in the menu bar. To change the icon,
// change the numbers here and run the two commands again. Chosen by the owner on
// 23 November 2026.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}

func gradient(_ context: CGContext, _ first: CGColor, _ second: CGColor, from: CGPoint, to: CGPoint) {
    let blend = CGGradient(colorsSpace: space, colors: [first, second] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(blend, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The plate: the macOS icon shape in navy, with a soft shadow under it and a faint glow
/// where the screen sits.
func plate(_ context: CGContext) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(rounded(rect, 186))
    context.setFillColor(color(0x102238))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(rounded(rect, 186))
    context.clip()
    gradient(context, color(0x1E3A5C), color(0x0A1728), from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    let glow = CGGradient(colorsSpace: space, colors: [color(0x4DF2CF, 0.16), color(0x4DF2CF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
    context.restoreGState()

    context.addPath(rounded(rect.insetBy(dx: 2, dy: 2), 184))
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(4)
    context.strokePath()
}

/// Fills a shape with the aqua of the mark, lighter at the top.
func aqua(_ context: CGContext, _ path: CGPath, top: CGFloat, bottom: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    gradient(context, color(0x8FFFE6), color(0x2FD3B2), from: CGPoint(x: 512, y: top), to: CGPoint(x: 512, y: bottom))
    context.restoreGState()
}

/// The display, its menu bar line, and the foot it stands on.
func mark(_ context: CGContext) {
    let screen = CGRect(x: 232, y: 400, width: 560, height: 350)
    let outline = rounded(screen, 52).copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10)
    aqua(context, outline, top: screen.maxY, bottom: screen.minY)
    aqua(context, rounded(CGRect(x: screen.minX + 76, y: screen.maxY - 96, width: screen.width - 152, height: 26), 13), top: screen.maxY, bottom: screen.minY)
    aqua(context, rounded(CGRect(x: 494, y: 318, width: 36, height: 70), 6), top: 400, bottom: 290)
    aqua(context, rounded(CGRect(x: 392, y: 290, width: 240, height: 36), 18), top: 400, bottom: 290)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift packaging/icon/draw-icon.swift OUT.png\n".utf8))
    exit(1)
}
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
plate(context)
mark(context)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("The picture could not be written to \(url.path).\n".utf8))
    exit(1)
}
print("Wrote \(url.path)")

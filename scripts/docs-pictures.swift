// The picture helper for scripts/docs-pictures.sh. It crops a render, or lays renders side
// by side, and writes a PNG. It never draws anything of its own: every pixel comes from a
// render of the app.
//
//   docs-pictures crop X Y WIDTH HEIGHT IN.png OUT.png
//   docs-pictures strip HEIGHT GAP OUT.png IN.png [IN.png ...]
//
// "strip" scales each picture to HEIGHT pixels and puts them in a row, GAP pixels apart, on
// a transparent background.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("docs-pictures: " + message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
    return image
}

func save(_ image: CGImage, _ path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(path)") }
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "crop" where arguments.count == 8:
    guard let x = Double(arguments[2]), let y = Double(arguments[3]), let width = Double(arguments[4]), let height = Double(arguments[5]) else {
        fail("crop takes X Y WIDTH HEIGHT in pixels")
    }
    guard let cropped = load(arguments[6]).cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { fail("the crop lies outside \(arguments[6])") }
    save(cropped, arguments[7])

case "strip" where arguments.count >= 6:
    guard let height = Int(arguments[2]), let gap = Int(arguments[3]) else { fail("strip takes HEIGHT GAP in pixels") }
    let images = arguments.dropFirst(5).map(load)
    let widths = images.map { Int((Double($0.width) * Double(height) / Double($0.height)).rounded()) }
    let total = widths.reduce(0, +) + gap * (images.count - 1)
    guard let context = CGContext(data: nil, width: total, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("cannot make a picture \(total) × \(height)")
    }
    context.interpolationQuality = .high
    var x = 0
    for (image, width) in zip(images, widths) {
        context.draw(image, in: CGRect(x: x, y: 0, width: width, height: height))
        x += width + gap
    }
    save(context.makeImage()!, arguments[4])

default:
    fail("usage: docs-pictures crop X Y WIDTH HEIGHT IN.png OUT.png | strip HEIGHT GAP OUT.png IN.png…")
}

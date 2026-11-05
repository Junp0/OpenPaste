import AppKit
import Foundation

// One vector mark supplies the app icon and the monochrome menu-bar template.
// Coordinates use a 1024-point canvas, with the origin at the bottom left.
func pasteMark() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 318, y: 246))
    path.curve(to: NSPoint(x: 286, y: 278), controlPoint1: NSPoint(x: 300, y: 246), controlPoint2: NSPoint(x: 286, y: 260))
    path.line(to: NSPoint(x: 286, y: 696))
    path.curve(to: NSPoint(x: 338, y: 748), controlPoint1: NSPoint(x: 286, y: 725), controlPoint2: NSPoint(x: 309, y: 748))
    path.line(to: NSPoint(x: 550, y: 748))
    path.curve(to: NSPoint(x: 738, y: 562), controlPoint1: NSPoint(x: 672, y: 748), controlPoint2: NSPoint(x: 738, y: 680))
    path.curve(to: NSPoint(x: 550, y: 376), controlPoint1: NSPoint(x: 738, y: 444), controlPoint2: NSPoint(x: 672, y: 376))
    path.line(to: NSPoint(x: 414, y: 376))
    path.line(to: NSPoint(x: 414, y: 278))
    path.curve(to: NSPoint(x: 382, y: 246), controlPoint1: NSPoint(x: 414, y: 260), controlPoint2: NSPoint(x: 400, y: 246))
    path.close()
    // The counter has the proportions of a copied card, rather than a font glyph.
    path.append(NSBezierPath(roundedRect: NSRect(x: 414, y: 496, width: 196, height: 132), xRadius: 36, yRadius: 36))
    path.windingRule = .evenOdd
    return path
}

let buildDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
let directory = buildDirectory.appendingPathComponent("iPaste.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let cream = NSColor(calibratedRed: 1, green: 0.975, blue: 0.935, alpha: 1)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                          color: NSColor.black.withAlphaComponent(0.16).cgColor)
        NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.54, blue: 0.36, alpha: 1),
                            NSColor(calibratedRed: 0.91, green: 0.24, blue: 0.24, alpha: 1)])!.draw(in: tile, angle: -80)
        context.restoreGState()
        NSColor.white.withAlphaComponent(0.26).setStroke()
        tile.lineWidth = 2; tile.stroke()

        // An offset sheet gives the P a copy/paste silhouette.
        context.saveGState()
        context.translateBy(x: 552, y: 496)
        context.rotate(by: -0.12)
        context.translateBy(x: -552, y: -496)
        let sheet = NSBezierPath(roundedRect: NSRect(x: 430, y: 246, width: 294, height: 442), xRadius: 56, yRadius: 56)
        cream.withAlphaComponent(0.34).setFill(); sheet.fill()
        context.restoreGState()

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22,
                          color: NSColor(calibratedRed: 0.52, green: 0.12, blue: 0.10, alpha: 0.24).cgColor)
        cream.setFill(); pasteMark().fill()
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// Vector PDF stays sharp on every display and is tinted by AppKit for light/dark menus.
let statusURL = buildDirectory.appendingPathComponent("iPasteStatus.pdf")
var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
guard let consumer = CGDataConsumer(url: statusURL as CFURL),
      let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    fatalError("无法创建菜单栏图标")
}
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
pdf.translateBy(x: 1.8, y: 1)
pdf.scaleBy(x: 14.4 / 452, y: 16.0 / 502)
pdf.translateBy(x: -286, y: -246)
NSColor.black.setFill(); pasteMark().fill()
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", buildDirectory.appendingPathComponent("iPaste.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

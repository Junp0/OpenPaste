import AppKit
import Foundation

// Finder draws the real app and Applications icons above this Retina background.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let version = CommandLine.arguments[2]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let size = NSSize(width: 680, height: 440)
let ink = NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.24, alpha: 1)
let muted = NSColor(calibratedRed: 0.45, green: 0.46, blue: 0.50, alpha: 1)
let coral = NSColor(calibratedRed: 0.89, green: 0.34, blue: 0.27, alpha: 1)

func text(_ value: String, _ rect: NSRect, _ font: NSFont, _ color: NSColor,
          centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    (value as NSString).draw(in: rect, withAttributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
    ])
}

var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 680 * scale,
        pixelsHigh: 440 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.965, blue: 0.94, alpha: 1),
                        NSColor(calibratedRed: 0.955, green: 0.97, blue: 0.99, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -30)

    text("OpenPaste", NSRect(x: 42, y: 356, width: 360, height: 47),
         .systemFont(ofSize: 36, weight: .bold), ink)
    text("复制之后，随手可得。", NSRect(x: 44, y: 324, width: 400, height: 25),
         .systemFont(ofSize: 15, weight: .regular), muted)
    let badge = NSRect(x: 550, y: 365, width: 88, height: 28)
    NSColor.white.withAlphaComponent(0.7).setFill()
    NSBezierPath(roundedRect: badge, xRadius: 14, yRadius: 14).fill()
    text("v\(version)", NSRect(x: 550, y: 370, width: 88, height: 18),
         .monospacedSystemFont(ofSize: 12, weight: .medium), muted, centered: true)

    for x in [184.0, 496.0] {
        let well = NSBezierPath(roundedRect: NSRect(x: x - 83, y: 128, width: 166, height: 170),
                                xRadius: 25, yRadius: 25)
        NSColor.white.withAlphaComponent(0.55).setFill(); well.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke(); well.lineWidth = 1; well.stroke()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 294, y: 216)); arrow.line(to: NSPoint(x: 386, y: 216))
    arrow.move(to: NSPoint(x: 373, y: 229)); arrow.line(to: NSPoint(x: 386, y: 216))
    arrow.line(to: NSPoint(x: 373, y: 203))
    coral.withAlphaComponent(0.8).setStroke()
    arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    text("拖动安装", NSRect(x: 290, y: 177, width: 100, height: 22),
         .systemFont(ofSize: 12, weight: .medium), muted, centered: true)

    text("将 OpenPaste 拖入右侧的“应用程序”文件夹", NSRect(x: 40, y: 65, width: 600, height: 27),
         .systemFont(ofSize: 17, weight: .medium), ink, centered: true)
    text("安装后，打开“应用程序”中的 OpenPaste 即可开始使用。", NSRect(x: 40, y: 36, width: 600, height: 23),
         .systemFont(ofSize: 12, weight: .regular), muted, centered: true)
    NSGraphicsContext.restoreGraphicsState()
    representations.append(bitmap)
    if scale == 2 {
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("background@2x.png"))
    }
}
try NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff,
    properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])!
    .write(to: output.appendingPathComponent("background.tiff"))

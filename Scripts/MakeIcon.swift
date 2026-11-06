import AppKit

let destination = CommandLine.arguments[1]
let fm = FileManager.default
try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let bounds = CGRect(x: 64, y: 64, width: 896, height: 896)
    let path = NSBezierPath(roundedRect: bounds, xRadius: 200, yRadius: 200)
    NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.70, alpha: 1).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.45).setStroke()
    let back = NSBezierPath(roundedRect: CGRect(x: 238, y: 376, width: 530, height: 340), xRadius: 44, yRadius: 44)
    back.lineWidth = 24; back.stroke()
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: CGRect(x: 176, y: 276, width: 570, height: 370), xRadius: 48, yRadius: 48).fill()
    NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.70, alpha: 0.25).setFill()
    NSBezierPath(roundedRect: CGRect(x: 208, y: 308, width: 506, height: 268), xRadius: 23, yRadius: 23).fill()
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: CGRect(x: 604, y: 210, width: 212, height: 212)).fill()
    NSColor.white.setStroke()
    let cross = NSBezierPath()
    cross.lineWidth = 23; cross.lineCapStyle = .round
    cross.move(to: CGPoint(x: 675, y: 281)); cross.line(to: CGPoint(x: 745, y: 351))
    cross.move(to: CGPoint(x: 675, y: 351)); cross.line(to: CGPoint(x: 745, y: 281)); cross.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let url = URL(fileURLWithPath: destination).appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

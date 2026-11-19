// Renders the MacPulse Pro app icon into an .iconset directory: swift make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1), NSColor(red: 0.13, green: 0.17, blue: 0.30, alpha: 1)])!
        .draw(in: shape, angle: 90)
    // Pulse line
    let path = NSBezierPath()
    let y = rect.midY, w = rect.width, x0 = rect.minX + w * 0.12
    path.move(to: NSPoint(x: x0, y: y))
    path.line(to: NSPoint(x: x0 + w * 0.20, y: y))
    path.line(to: NSPoint(x: x0 + w * 0.30, y: y + w * 0.24))
    path.line(to: NSPoint(x: x0 + w * 0.42, y: y - w * 0.26))
    path.line(to: NSPoint(x: x0 + w * 0.52, y: y + w * 0.10))
    path.line(to: NSPoint(x: x0 + w * 0.58, y: y))
    path.line(to: NSPoint(x: rect.maxX - w * 0.12, y: y))
    path.lineWidth = max(1.5, w * 0.055)
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: w * 0.05, color: NSColor(red: 0.25, green: 0.9, blue: 0.75, alpha: 0.8).cgColor)
    NSColor(red: 0.35, green: 0.95, blue: 0.80, alpha: 1).setStroke()
    path.stroke()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}

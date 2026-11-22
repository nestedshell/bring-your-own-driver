// Draws the app icon from scratch: a small printer with a strip of paper. No vendor artwork is used.
// Run mac/tools/make_icon.sh to produce Resources/AppIcon.icns.
import AppKit

func icon(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Background: the rounded square of a macOS icon.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let colors = [CGColor(red: 0.16, green: 0.53, blue: 0.56, alpha: 1), CGColor(red: 0.07, green: 0.31, blue: 0.38, alpha: 1)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // Paper, coming out of the top of the printer.
    let paper = CGRect(x: 342, y: 400, width: 340, height: 440)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(paper)
    ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
    for (y, w) in [(770, 250), (715, 190), (660, 250), (605, 130)] as [(CGFloat, CGFloat)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 387, y: y, width: w, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
    }

    // Body.
    let body = CGPath(roundedRect: CGRect(x: 232, y: 214, width: 560, height: 340), cornerWidth: 74, cornerHeight: 74, transform: nil)
    ctx.addPath(body)
    ctx.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1))
    ctx.fillPath()
    // Slot.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 312, y: 482, width: 400, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
    ctx.fillPath()
    // Status light.
    ctx.setFillColor(CGColor(red: 0.16, green: 0.62, blue: 0.56, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 650, y: 300, width: 62, height: 62))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! icon(size).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}

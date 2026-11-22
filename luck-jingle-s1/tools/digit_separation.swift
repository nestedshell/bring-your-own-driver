// Digit separation behind the small-type warning (article, Section 4.4; run with: swiftc digit_separation.swift -o /tmp/digit_separation && /tmp/digit_separation).
import AppKit
import CoreText

func render(_ text: String, em: CGFloat, font: String, dx: CGFloat, dy: CGFloat, o: CGFloat = 3) -> (w: Int, h: Int, bits: [Bool]) {
    let W = 240, H = Int(em * 2) + 4
    let big = CGContext(data: nil, width: W * Int(o), height: H * Int(o), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    big.setFillColor(gray: 1, alpha: 1); big.fill(CGRect(x: 0, y: 0, width: W * Int(o), height: H * Int(o)))
    let f = NSFont(name: font, size: em * o)!
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor.black]))
    big.textPosition = CGPoint(x: (2 + dx) * o, y: (em * 0.6 + dy) * o)
    CTLineDraw(line, big)
    let small = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    small.interpolationQuality = .high
    small.draw(big.makeImage()!, in: CGRect(x: 0, y: 0, width: W, height: H))
    let px = small.data!.assumingMemoryBound(to: UInt8.self), stride = small.bytesPerRow
    var g = [Float](repeating: 255, count: W * H)
    for y in 0..<H { for x in 0..<W { g[y * W + x] = Float(px[y * stride + x]) } }
    // The app's "Documents" rule, for the dots that matter here: edges cut at 150, flat grey dithered around 60-200.
    var out = [Bool](repeating: false, count: W * H)
    for i in 0..<W * H { out[i] = g[i] < 150 }
    return (W, H, out)
}

/// Is there ink in the gap where the point sits, close to the baseline, between "1" and "1"?
func pointSurvives(em: CGFloat, font: String, dx: CGFloat, dy: CGFloat) -> Bool {
    let digits = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: "1", attributes: [.font: NSFont(name: font, size: em)!])), nil, nil, nil)
    let dot = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: ".", attributes: [.font: NSFont(name: font, size: em)!])), nil, nil, nil)
    let withPoint = render("1.1", em: em, font: font, dx: dx, dy: dy)
    let x0 = Int(2 + dx + CGFloat(digits)), x1 = Int(2 + dx + CGFloat(digits + dot)) + 1
    var ink = 0
    for y in 0..<withPoint.h { for x in x0...x1 where withPoint.bits[y * withPoint.w + x] { ink += 1 } }
    return ink > 0
}


let offsets: [CGFloat] = [0, 0.25, 0.5, 0.75]
let digits = (0...9).map(String.init)
print("em dots | fewest dots that differ between any two digits, worst position | worst pair | height of a digit in dots")
for font in ["Helvetica", "Times-Roman", "Georgia"] {
    print(font)
    for em in stride(from: CGFloat(6), through: 24, by: 2) {
        var worst = Int.max, pair = ""
        for dx in offsets { for dy in offsets {
            let maps = digits.map { render($0, em: em, font: font, dx: dx, dy: dy).bits }
            for a in 0..<10 { for b in (a + 1)..<10 {
                let d = zip(maps[a], maps[b]).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                if d < worst { worst = d; pair = "\(a)/\(b)" }
            } }
        } }
        let cap = NSFont(name: font, size: em)!.capHeight
        print("  \(Int(em)): \(worst) \(pair) ~\(Int(cap.rounded()))")
    }
}

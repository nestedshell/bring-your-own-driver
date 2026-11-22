import AppKit
import CoreText
import ImageIO
import PDFKit

enum Dither: String, CaseIterable, Identifiable {
    case auto, atkinson, threshold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Documents"
        case .atkinson: "Photos"
        case .threshold: "Line art"
        }
    }
}

enum TextFont: String, CaseIterable, Identifiable {
    case sans, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sans: "Sans serif"
        case .serif: "Serif"
        case .mono: "Monospace"
        }
    }
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .sans: NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        case .serif: NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .mono: NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

struct RenderOptions: Equatable {
    var dither = Dither.auto
    var tone: Double = 0  // right is darker
    var trim = true
    var rotate = true
    var marginMM = 0
    var font = TextFont.sans
    var fontSize: Double = 11
}

struct Stroke: Equatable {
    var width: CGFloat
    var points: [CGPoint]  // in dots, from the top left

    /// Smoothed through the midpoints, so the screen and the paper draw the same line.
    var path: CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        if points.count == 1 { p.addLine(to: first) }
        for i in 1..<max(1, points.count) {
            let a = points[i - 1], b = points[i]
            p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        if points.count > 1 { p.addLine(to: points[points.count - 1]) }
        return p
    }
}

/// Greyscale page. 0 = black, 255 = white.
struct GrayPage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let label: String
    var number = 0
    var raw = false  // already laid out on the whole head: no margin
    var blank = false
    var dotsPerSourcePixel: CGFloat = 1
    var smallText = false
    var hasText = false
    var asText = false
}

/// A page ready for the head: packed 1-bit rows plus a preview image.
struct HeadPage: Identifiable {
    let id: String  // stable across renders
    let sourceID: UUID
    let number: Int
    let bits: [UInt8]
    let height: Int
    let preview: CGImage
    let label: String
    let blank: Bool
    let smallText: Bool  // digits and decimal points may print wrong
    let hasText: Bool  // the page has real text, so it can print as text
    let asText: Bool  // printing as plain text instead of the page's picture
}

enum LoadError: LocalizedError {
    case unsupported(String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let n): "This file type is not supported: \(n)"
        case .unreadable(let n): "Could not read \(n)"
        }
    }
}

enum Loader {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"]
    static let textTypes: Set<String> = ["txt", "md", "csv", "log", "text"]
    static let richTypes: Set<String> = ["rtf"]
    static let oversample: CGFloat = 3
    static let textPad = 2 * Head.dotsPerMM
    /// Below this size in dots per em, printed numbers cannot be trusted. Measured on Helvetica, Times and Georgia:
    /// under it a decimal point can leave no ink at some positions, and two digits can differ by 3 dots or fewer.
    static let smallTextEm: CGFloat = 14
    /// The size assumed for a page with no text layer, such as a scan.
    static let assumedTextPoints: CGFloat = 10

    private static func width(_ o: RenderOptions) -> Int { Head.dots - 2 * o.marginMM * Head.dotsPerMM }

    // MARK: PDF and images

    static func pdf(_ data: Data, name: String, removed: Set<Int>, asText: Set<Int> = [], options o: RenderOptions) throws -> [GrayPage] {
        guard let doc = PDFDocument(data: data) else { throw LoadError.unreadable(name) }
        return (0..<doc.pageCount).compactMap { i in
            guard !removed.contains(i), let page = doc.page(at: i) else { return nil }
            let label = doc.pageCount > 1 ? "\(name) · p. \(i + 1)" : name
            let reading = readingText(of: page)
            if asText.contains(i), var out = textPage(reading, label: label, options: o) {
                out.number = i
                out.asText = true
                out.hasText = true
                return out
            }
            let box = page.bounds(for: .cropBox)
            var rotation = ((page.rotation % 360) + 360) % 360
            var size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            if o.rotate, size.width > size.height {
                rotation = (rotation + 90) % 360
                size = CGSize(width: size.height, height: size.width)
                page.rotation = rotation
            }
            let scale = CGFloat(width(o)) * oversample / size.width
            let ctx = grayContext(Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
            ctx.scaleBy(x: scale, y: scale)
            page.transform(ctx, for: .cropBox)
            page.draw(with: .cropBox, to: ctx)
            var out = fit(ctx.makeImage()!, label: label, options: o)
            out.number = i
            out.hasText = !reading.isEmpty
            let points = smallestTextPoints(of: page) ?? assumedTextPoints
            out.smallText = out.dotsPerSourcePixel > 0 && points * scale * out.dotsPerSourcePixel < smallTextEm
            return out
        }
    }

    /// The smallest type on the page that holds a letter or a digit.
    static func smallestTextPoints(of page: PDFPage) -> CGFloat? {
        guard let text = page.attributedString else { return nil }
        var smallest: CGFloat?
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont, font.pointSize >= 1,
                  (text.string as NSString).substring(with: range).rangeOfCharacter(from: .alphanumerics) != nil else { return }
            smallest = min(smallest ?? font.pointSize, font.pointSize)
        }
        return smallest
    }

    /// The page's words, line by line, with a blank line where the page leaves a wider gap.
    static func readingText(of page: PDFPage) -> String {
        guard let whole = page.selection(for: page.bounds(for: .cropBox)) else { return "" }
        var lines: [String] = []
        var lastY: CGFloat?
        for selection in whole.selectionsByLine() {
            let line = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let b = selection.bounds(for: page)
            if let last = lastY, abs(last - b.midY) > 1.9 * b.height { lines.append("") }
            lines.append(line)
            lastY = b.midY
        }
        return lines.joined(separator: "\n")
    }

    /// Fixed size and font, whatever the text card is set to. 8 pt is 22.6 dots per em, well above the warning.
    /// On paper its digits and decimal points read correctly, and a typical table row still fits on one line.
    private static func textPage(_ string: String, label: String, options o: RenderOptions) -> GrayPage? {
        var plain = o
        plain.font = .sans
        plain.fontSize = 8
        return text(string, name: label, options: plain)
    }

    static func image(_ data: Data, name: String, options o: RenderOptions) throws -> GrayPage {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honour EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { throw LoadError.unreadable(name) }
        let rotate = o.rotate && CGFloat(img.width) > CGFloat(img.height) * 1.15
        let ctx = grayContext(rotate ? img.height : img.width, rotate ? img.width : img.height)
        ctx.interpolationQuality = .high
        if rotate {
            ctx.translateBy(x: CGFloat(img.height), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return fit(ctx.makeImage()!, label: name, options: o)
    }

    /// Fits a high-resolution picture to the head width, cropping the blank edges when asked.
    private static func fit(_ big: CGImage, label: String, options o: RenderOptions) -> GrayPage {
        let w = width(o)
        var box: CGRect? = CGRect(x: 0, y: 0, width: big.width, height: big.height)
        if o.trim { box = contentBox(of: big) }
        guard let box, let part = big.cropping(to: box) else {
            return GrayPage(width: w, height: 8, pixels: [UInt8](repeating: 255, count: w * 8), label: label, dotsPerSourcePixel: 0)
        }
        let h = max(1, Int((box.height * CGFloat(w) / box.width).rounded()))
        let ctx = grayContext(w, h)
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GrayPage(width: w, height: h, pixels: pixels(ctx), label: label, dotsPerSourcePixel: CGFloat(w) / box.width)
    }

    /// Bounding box of everything that is not nearly white, in image coordinates from the top left.
    static func contentBox(of image: CGImage) -> CGRect? {
        let ctx = grayContext(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = pixels(ctx), w = image.width, h = image.height
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for y in 0..<h {
            for x in 0..<w where px[y * w + x] < 245 {
                if x < x0 { x0 = x }
                if x > x1 { x1 = x }
                if y < y0 { y0 = y }
                if y > y1 { y1 = y }
            }
        }
        return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    // MARK: Text

    static func text(_ string: String, name: String, options o: RenderOptions) -> GrayPage? {
        let trimmed = string.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }
        let font = o.font.font(size: CGFloat(o.fontSize))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        return layout(NSAttributedString(string: trimmed, attributes: attrs), name: name, options: o)
    }

    static func rich(_ data: Data, name: String, options o: RenderOptions) throws -> GrayPage {
        // RTF only, named explicitly: importing HTML could fetch remote content.
        guard let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
              let page = layout(attr, name: name, options: o)
        else { throw LoadError.unreadable(name) }
        return page
    }

    /// One long strip with blank space around the text: a roll has no page height.
    private static func layout(_ attr: NSAttributedString, name: String, options o: RenderOptions) -> GrayPage? {
        let s = Head.dotsPerPoint
        let w = width(o), pad = CGFloat(textPad) / s
        let inner = CGFloat(w) / s - 2 * pad
        guard attr.length > 0, inner > 10 else { return nil }
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: inner, height: .greatestFiniteMagnitude), nil)
        let textHeight = ceil(size.height) + 2
        let h = Int(((textHeight + 2 * pad) * s).rounded(.up))
        let ctx = grayContext(w, h)
        ctx.scaleBy(x: s, y: s)
        let rect = CGRect(x: pad, y: pad, width: inner, height: textHeight)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
        return GrayPage(width: w, height: h, pixels: pixels(ctx), label: name)
    }

    // MARK: Handwritten note and calibration page

    static let noteRows = 320

    static func drawStrokes(_ strokes: [Stroke], in ctx: CGContext) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes where !s.points.isEmpty {
            ctx.setLineWidth(s.width)
            ctx.addPath(s.path)
            ctx.strokePath()
        }
    }

    /// What prints: the written part with a little space around it. An empty note does not print.
    static func note(_ strokes: [Stroke], name: String) -> GrayPage {
        let lowest = strokes.flatMap(\.points).map(\.y).max() ?? 0
        let rows = max(noteRows, Int(lowest) + 40)
        let ctx = grayContext(Head.dots, rows)
        ctx.translateBy(x: 0, y: CGFloat(rows))
        ctx.scaleBy(x: 1, y: -1)
        drawStrokes(strokes, in: ctx)
        let px = pixels(ctx)
        var first = rows, last = -1
        for y in 0..<rows where px[(y * Head.dots)..<((y + 1) * Head.dots)].contains(where: { $0 < 245 }) {
            if y < first { first = y }
            last = y
        }
        guard last >= 0 else {
            return GrayPage(width: Head.dots, height: 1, pixels: [UInt8](repeating: 255, count: Head.dots), label: name, raw: true, blank: true)
        }
        let top = max(0, first - textPad), end = min(rows, last + 1 + textPad)
        return GrayPage(width: Head.dots, height: end - top, pixels: Array(px[(top * Head.dots)..<(end * Head.dots)]), label: name, raw: true)
    }

    /// Ruler across the whole head, a 10 mm height mark and grey steps.
    static func calibration() -> GrayPage {
        let w = Head.dots, h = 240
        let ctx = grayContext(w, h)
        let rect = { (x: Int, y: Int, width: Int, height: Int) in
            CGRect(x: x, y: h - y - height, width: width, height: height)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        for x in stride(from: 0, to: w, by: 8) { ctx.fill(rect(x, 0, 2, x % 48 == 0 ? 30 : 12)) }
        ctx.fill(rect(w - 2, 0, 2, 30))
        let label = { (string: String, x: CGFloat, top: Int, size: CGFloat) in
            let font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: x, y: CGFloat(h - top) - size)
            CTLineDraw(line, ctx)
        }
        for mm in [12, 24, 36] { label("\(mm)", CGFloat(mm * Head.dotsPerMM - 12), 34, 20) }
        ctx.fill(rect(0, 70, 4, 80))
        label("10 mm tall · 384 dots wide", 14, 100, 20)
        let step = w / 8
        for i in 0..<8 {
            ctx.setFillColor(gray: CGFloat(i) / 7, alpha: 1)
            ctx.fill(rect(i * step, 165, step, 70))
        }
        return GrayPage(width: w, height: h, pixels: pixels(ctx), label: "Calibration", raw: true)
    }

    private static func grayContext(_ w: Int, _ h: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// Bitmap rows top-down, without row padding.
    private static func pixels(_ ctx: CGContext) -> [UInt8] {
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
        let base = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 255, count: w * h)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h { (dst.baseAddress! + y * w).update(from: base + y * stride, count: w) }
        }
        return out
    }
}

enum Rasterizer {
    static let edgeRange: Float = 96  // 3x3 grey range above which a dot is part of an edge
    static let edgeCut: Float = 150  // threshold on edges; above 128 so thin strokes come out bolder

    static func headPage(_ page: GrayPage, sourceID: UUID, options o: RenderOptions) -> HeadPage {
        let w = Head.dots, h = page.height
        let x0 = page.raw ? 0 : o.marginMM * Head.dotsPerMM
        let shift = Float(-o.tone * 2.55)
        var g = [Float](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<page.width { g[y * w + x0 + x] = Float(page.pixels[y * page.width + x]) + shift }
        }
        switch o.dither {
        case .threshold:
            for i in g.indices { g[i] = g[i] < 128 ? 0 : 255 }
        case .atkinson:
            diffuse(&g, w, h, atkinson, fixed: nil)
        case .auto:
            // Hard threshold on edges (text, lines), dithering only on flat grey areas:
            // dithered antialiased glyph edges look fuzzy on a 203 dpi head.
            let edge = edgeMask(g, w, h)
            for i in g.indices {
                let v = g[i]
                g[i] = edge[i] ? (v < edgeCut ? 0 : 255) : v < 60 ? 0 : v > 200 ? 255 : (v - 60) * 255 / 140
            }
            diffuse(&g, w, h, floyd, fixed: edge)
        }
        var bits = [UInt8](repeating: 0, count: Head.bytesPerLine * h)
        var shown = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w where g[y * w + x] < 128 {
                bits[y * Head.bytesPerLine + x >> 3] |= 0x80 >> UInt8(x & 7)
                shown[y * w + x] = 20
            }
        }
        let provider = CGDataProvider(data: Data(shown) as CFData)!
        let preview = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return HeadPage(id: "\(sourceID)-\(page.number)", sourceID: sourceID, number: page.number, bits: bits, height: h,
                        preview: preview, label: page.label, blank: page.blank,
                        smallText: page.smallText, hasText: page.hasText, asText: page.asText)
    }

    private static let floyd: [(Int, Int, Float)] = [(1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)]
    private static let atkinson: [(Int, Int, Float)] = [(1, 0, 0.125), (2, 0, 0.125), (-1, 1, 0.125), (0, 1, 0.125), (1, 1, 0.125), (0, 2, 0.125)]

    private static func edgeMask(_ g: [Float], _ w: Int, _ h: Int) -> [Bool] {
        var m = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
            for x in 0..<w {
                var lo: Float = .infinity, hi: Float = -.infinity
                for yy in y0...y1 {
                    for xx in max(0, x - 1)...min(w - 1, x + 1) {
                        let v = g[yy * w + xx]
                        lo = min(lo, v); hi = max(hi, v)
                    }
                }
                m[y * w + x] = hi - lo > edgeRange
            }
        }
        return m
    }

    /// Error diffusion; dots set in `fixed` keep their value and absorb no error.
    private static func diffuse(_ g: inout [Float], _ w: Int, _ h: Int, _ kernel: [(Int, Int, Float)], fixed: [Bool]?) {
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if fixed?[i] == true { continue }
                let old = g[i], new: Float = old < 128 ? 0 : 255, err = old - new
                g[i] = new
                if err == 0 { continue }
                for (dx, dy, f) in kernel {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny < h, fixed?[ny * w + nx] != true { g[ny * w + nx] += err * f }
                }
            }
        }
    }
}

/// Everything that can sit on the desk.
enum Source {
    case pdf(Data, removed: Set<Int>, asText: Set<Int>)
    case image(Data)
    case rich(Data)
    case text(String)
    case note([Stroke], rows: Int)
    case calibration

    static func pages(_ source: Source, name: String, id: UUID, options o: RenderOptions) throws -> [HeadPage] {
        let grays: [GrayPage]
        switch source {
        case .pdf(let data, let removed, let asText): grays = try Loader.pdf(data, name: name, removed: removed, asText: asText, options: o)
        case .image(let data): grays = [try Loader.image(data, name: name, options: o)]
        case .rich(let data): grays = [try Loader.rich(data, name: name, options: o)]
        case .text(let text): grays = Loader.text(text, name: name, options: o).map { [$0] } ?? []
        case .note(let strokes, _): grays = [Loader.note(strokes, name: name)]
        case .calibration: grays = [Loader.calibration()]
        }
        return grays.map { Rasterizer.headPage($0, sourceID: id, options: o) }
    }
}

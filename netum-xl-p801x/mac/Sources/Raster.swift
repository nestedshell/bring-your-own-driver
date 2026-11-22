import AppKit
import CoreText
import ImageIO
import PDFKit

/// Print head geometry and job encoding. See docs/PROTOCOL.md.
enum Head {
    static let dots = 1728
    static let bytesPerLine = dots / 8
    static let dotsPerMM: CGFloat = 8
    static let dotsPerPoint: CGFloat = 203.0 / 72.0
    static let bandRows = 256
}

/// Paper sits centred on the 216 mm head: an A4 sheet covers dots 24...1704.
enum Paper: String, CaseIterable, Identifiable {
    case a4, letter, a5, a6, roll80, roll57
    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4 · 210 × 297 mm"
        case .letter: "US Letter · 216 × 279 mm"
        case .a5: "A5 · 148 × 210 mm"
        case .a6: "A6 · 105 × 148 mm"
        case .roll80: "Roll · 80 mm"
        case .roll57: "Roll · 57 mm"
        }
    }

    private var mm: (width: CGFloat, height: CGFloat?) {
        switch self {
        case .a4: (210, 297)
        case .letter: (215.9, 279.4)
        case .a5: (148, 210)
        case .a6: (105, 148)
        case .roll80: (80, nil)
        case .roll57: (57, nil)
        }
    }

    var width: Int { min(Head.dots, Int((mm.width * Head.dotsPerMM).rounded())) }
    /// nil for a continuous roll: text is not split into pages.
    var height: Int? { mm.height.map { Int(($0 * Head.dotsPerMM).rounded()) } }
    var offset: Int { (Head.dots - width) / 2 }
}

enum Dither: String, CaseIterable, Identifiable {
    case auto, floyd, atkinson, threshold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto (crisp text)"
        case .floyd: "Floyd–Steinberg"
        case .atkinson: "Atkinson (photos)"
        case .threshold: "Black & white"
        }
    }
}

/// Greyscale page, exactly as wide as the paper. 0 = black, 255 = white.
struct GrayPage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let label: String
}

/// A page ready for the head: packed 1-bit rows plus a preview image.
struct HeadPage: Identifiable {
    let id = UUID()
    let bits: [UInt8]
    let height: Int
    let preview: CGImage
    let label: String
}

enum LoadError: LocalizedError {
    case unsupported(String), unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let n): "Unsupported file: \(n)"
        case .unreadable(let n): "Could not read \(n)"
        }
    }
}

// MARK: - Loading

enum Loader {
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif"]
    static let textTypes: Set<String> = ["txt", "md", "csv", "log", "text"]
    /// Each rich format is named explicitly. HTML is not accepted: importing it could fetch remote content.
    static let richTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument,
    ]

    /// `data` is read up front by the caller: files handed over by the print dialog are temporary.
    static func load(_ data: Data, name: String, paper: Paper) throws -> [GrayPage] {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(data: data) else { throw LoadError.unreadable(name) }
            return pdf(doc, name: name, paper: paper)
        }
        if imageTypes.contains(ext) { return [try image(data, name: name, paper: paper)] }
        if textTypes.contains(ext) {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let font = NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11)
            return self.text(NSAttributedString(string: text, attributes: [.font: font]), name: name, paper: paper)
        }
        if let type = richTypes[ext],
           let attr = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil) {
            return text(attr, name: name, paper: paper)
        }
        throw LoadError.unsupported(name)
    }

    static func pdf(_ doc: PDFDocument, name: String, paper: Paper) -> [GrayPage] {
        (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let box = page.bounds(for: .cropBox)
            var rotation = ((page.rotation % 360) + 360) % 360
            var size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            if size.width > size.height {  // landscape pages print rotated, larger
                rotation = (rotation + 90) % 360
                size = CGSize(width: size.height, height: size.width)
                page.rotation = rotation
            }
            let scale = CGFloat(paper.width) / size.width
            let height = Int((size.height * scale).rounded())
            let ctx = grayContext(paper.width, height)
            ctx.scaleBy(x: scale, y: scale)
            page.transform(ctx, for: .cropBox)
            page.draw(with: .cropBox, to: ctx)
            return GrayPage(width: paper.width, height: height, pixels: pixels(ctx),
                            label: doc.pageCount > 1 ? "\(name) · p. \(i + 1)" : name)
        }
    }

    static func image(_ data: Data, name: String, paper: Paper) throws -> GrayPage {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honour EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: 8000,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { throw LoadError.unreadable(name) }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let rotate = iw > ih * 1.15
        let scale = CGFloat(paper.width) / (rotate ? ih : iw)
        let height = Int(((rotate ? iw : ih) * scale).rounded())
        let ctx = grayContext(paper.width, height)
        ctx.interpolationQuality = .high
        if rotate {
            ctx.translateBy(x: CGFloat(paper.width), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: iw * scale, height: ih * scale))
        return GrayPage(width: paper.width, height: height, pixels: pixels(ctx), label: name)
    }

    /// Lays text out on pages of the paper size; the last page is cut just below the text to save paper.
    static func text(_ attr: NSAttributedString, name: String, paper: Paper) -> [GrayPage] {
        let s = Head.dotsPerPoint
        let pageHeight = paper.height ?? 40_000  // a roll is one long page
        let margin: CGFloat = paper.width < 1000 ? 8 : 36  // points
        let frameRect = CGRect(x: margin, y: margin,
                               width: CGFloat(paper.width) / s - 2 * margin,
                               height: CGFloat(pageHeight) / s - 2 * margin)
        let setter = CTFramesetterCreateWithAttributedString(attr)
        var pages: [GrayPage] = []
        var start = 0
        repeat {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0),
                                                 CGPath(rect: frameRect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            let ctx = grayContext(paper.width, pageHeight)
            ctx.scaleBy(x: s, y: s)
            CTFrameDraw(frame, ctx)
            start += visible.length
            var height = pageHeight
            if start >= attr.length {
                let lines = CTFrameGetLines(frame) as! [CTLine]
                if !lines.isEmpty {
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                    var descent: CGFloat = 0
                    CTLineGetTypographicBounds(lines.last!, nil, &descent, nil)
                    let bottom = frameRect.minY + origins.last!.y - descent  // points from page bottom
                    height = min(pageHeight, Int(((CGFloat(pageHeight) / s - bottom + 18) * s).rounded()))
                }
            }
            let all = pixels(ctx)
            pages.append(GrayPage(width: paper.width, height: height,
                                  pixels: Array(all[0..<(height * paper.width)]),
                                  label: "\(name) · \(pages.count + 1)"))
            if visible.length == 0 { break }
        } while start < attr.length
        return pages
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

// MARK: - Dithering

enum Rasterizer {
    static let edgeRange: Float = 96  // 3x3 grey range above which a dot is part of an edge
    static let edgeCut: Float = 150  // threshold on edges; above 128 so thin strokes come out bolder

    static func headPage(_ page: GrayPage, dither: Dither) -> HeadPage {
        let w = Head.dots, h = page.height, x0 = (Head.dots - page.width) / 2  // paper is centred
        var g = [Float](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<page.width { g[y * w + x0 + x] = Float(page.pixels[y * page.width + x]) }
        }
        switch dither {
        case .threshold:
            for i in g.indices { g[i] = g[i] < 128 ? 0 : 255 }
        case .floyd:
            diffuse(&g, w, h, floyd, fixed: nil)
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
                shown[y * w + x] = 0
            }
            // grey out the dots that fall beside the sheet
            for x in 0..<x0 where shown[y * w + x] == 255 { shown[y * w + x] = 225 }
            for x in (x0 + page.width)..<w where shown[y * w + x] == 255 { shown[y * w + x] = 225 }
        }
        let provider = CGDataProvider(data: Data(shown) as CFData)!
        let preview = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return HeadPage(bits: bits, height: h, preview: preview, label: page.label)
    }

    private static let floyd: [(Int, Int, Float)] = [(1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)]
    private static let atkinson: [(Int, Int, Float)] = [(1, 0, 0.125), (2, 0, 0.125), (-1, 1, 0.125), (0, 1, 0.125), (1, 1, 0.125), (0, 2, 0.125)]

    private static func edgeMask(_ g: [Float], _ w: Int, _ h: Int) -> [Bool] {
        var m = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
            for x in 0..<w {
                var lo: Float = 255, hi: Float = 0
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

// MARK: - Job

struct PrintJob {
    var data: Data
    var rasterRanges: [Range<Int>]  // GS v 0 blocks, finished with blank rows on cancel
    var tailStart: Int  // final feed, always sent

    init(pages: [HeadPage], density: Int, feedLines: UInt8 = 4) {
        var d = Data([0x1B, 0x40, 0x12, 0x23, UInt8(max(0, min(31, density)))])
        var ranges: [Range<Int>] = []
        let bpl = Head.bytesPerLine
        for page in pages {
            var y = 0
            while y < page.height {
                let rows = min(Head.bandRows, page.height - y)
                let start = d.count
                d.append(contentsOf: [0x1D, 0x76, 0x30, 0x00, UInt8(bpl & 255), UInt8(bpl >> 8), UInt8(rows & 255), UInt8(rows >> 8)])
                d.append(contentsOf: page.bits[(y * bpl)..<((y + rows) * bpl)])
                ranges.append(start..<d.count)
                y += rows
            }
        }
        tailStart = d.count
        d.append(contentsOf: [0x1B, 0x64, feedLines])
        data = d
        rasterRanges = ranges
    }
}

import CoreGraphics
import Foundation

/// Print head geometry. 384 dots across is confirmed on paper; 8 dots per mm is assumed from 203 dpi.
enum Head {
    static let dots = 384
    static let bytesPerLine = dots / 8
    static let dotsPerMM = 8
    static let dotsPerPoint: CGFloat = 203.0 / 72.0
    static let maxRows = 65535
    /// The printer drops an unfinished raster after a pause: it was still open after 1 s and gone after 3 s.
    static let stopWait: TimeInterval = 3.5
}

/// Standard ESC/POS only: GS v 0 raster and ESC J paper feed. Each page is one raster command, because the
/// printer moved the paper about 6 mm whenever one raster ended and the next one started in a new packet.
struct PrintJob {
    struct Piece {
        let bytes: Data
        var raster = false
        var always = false  // still sent after a stop: the final feed
    }

    let pieces: [Piece]
    let total: Int

    init(pages: [(bits: [UInt8], height: Int)], tailMM: Int) {
        let bpl = Head.bytesPerLine
        var out: [Piece] = []
        for (n, page) in pages.enumerated() {
            var y = 0
            while y < page.height {
                let rows = min(Head.maxRows, page.height - y)
                var d = Data([0x1D, 0x76, 0x30, 0x00, UInt8(bpl & 255), UInt8(bpl >> 8), UInt8(rows & 255), UInt8(rows >> 8)])
                d.append(contentsOf: page.bits[(y * bpl)..<((y + rows) * bpl)])
                out.append(Piece(bytes: d, raster: true))
                y += rows
            }
            if n < pages.count - 1 { out.append(Piece(bytes: Self.feed(3 * Head.dotsPerMM))) }
        }
        // The final feed is blank rows sent as a raster, not ESC J: on paper, ESC J right after a raster left the
        // paper where it was, while a blank raster of 30 mm gave the space (note 50).
        if tailMM > 0 {
            let rows = tailMM * Head.dotsPerMM
            var d = Data([0x1D, 0x76, 0x30, 0x00, UInt8(bpl & 255), UInt8(bpl >> 8), UInt8(rows & 255), UInt8(rows >> 8)])
            d.append(Data(count: bpl * rows))
            out.append(Piece(bytes: d, raster: true, always: true))
        }
        pieces = out
        total = out.reduce(0) { $0 + $1.bytes.count }
    }

    static func feed(_ dots: Int) -> Data {
        var d = Data()
        var left = dots
        while left > 0 {
            d.append(contentsOf: [0x1B, 0x4A, UInt8(min(left, 255))])
            left -= 255
        }
        return d
    }
}

/// Walks a job packet by packet. It knows nothing about Bluetooth, so it can be tested alone.
struct JobSender {
    private let pieces: [PrintJob.Piece]
    private var index = 0
    private var offset = 0
    private var end: Int
    private var rasterOpen = false
    private(set) var stopped = false
    private(set) var sent = 0
    private(set) var lastChunkWasRaster = false
    let total: Int

    init(_ job: PrintJob) {
        pieces = job.pieces
        total = job.total
        end = job.pieces.first?.bytes.count ?? 0
    }

    var isDone: Bool { index >= pieces.count }
    /// A stop left a raster unfinished: nothing may be sent until the printer has dropped it.
    var mustWait: Bool { rasterOpen && offset >= end }

    /// On stop nothing more is sent, apart from the rest of the current line of text and the final feed.
    /// A job that has already gone out entirely is left to finish.
    /// With `finishPage` (the paired serial link) the current page is sent whole instead: there a write ends when the
    /// system has the bytes, so the printer may still be receiving the page long after the stop, and a raster cut
    /// short would swallow the final feed and confuse the next print (seen on paper from a browser, note 47).
    mutating func stop(finishPage: Bool = false) {
        guard !stopped, !isDone else { return }
        stopped = true
        let piece = pieces[index]
        if piece.raster && offset > 0 && offset < end {
            if !finishPage {
                end = Self.stopOffset(piece.bytes, from: offset)
                rasterOpen = end < piece.bytes.count
            }
        } else if !piece.always || offset >= end {
            advance()
        }
    }

    /// Where a stopped raster ends: after the next blank row, so a line of text is not cut in half. A picture may
    /// have no blank row, so the search covers 8 mm, under a second of printing, and then the current row ends it.
    private static let stopSearchRows = 64
    private static func stopOffset(_ bytes: Data, from offset: Int) -> Int {
        if offset < 8 { return 8 }  // a header cut in two would swallow whatever comes next
        let bpl = Head.bytesPerLine
        let next = offset + (bpl - (offset - 8) % bpl) % bpl
        var row = next
        for _ in 0..<stopSearchRows {
            if row >= bytes.count { return bytes.count }  // the page ends first
            if bytes[row..<(row + bpl)].allSatisfy({ $0 == 0 }) { return row + bpl }
            row += bpl
        }
        return next
    }

    mutating func resumeAfterWait() {
        rasterOpen = false
        advance()
    }

    mutating func next(packet: Int) -> Data? {
        while !isDone, offset >= end {
            if rasterOpen { return nil }
            advance()
        }
        guard !isDone else { return nil }
        let n = min(packet, end - offset)
        let chunk = pieces[index].bytes.subdata(in: offset..<(offset + n))
        lastChunkWasRaster = pieces[index].raster
        offset += n
        sent += n
        return chunk
    }

    private mutating func advance() {
        index += 1
        offset = 0
        while stopped, index < pieces.count, !pieces[index].always { index += 1 }
        end = index < pieces.count ? pieces[index].bytes.count : 0
    }
}

// Tests what can run without the printer: the job bytes, stopping, layout. Run mac/test.sh
import AppKit

var failed = 0
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    print("\(ok ? "ok  " : "FAIL") \(name) \(extra)")
    if !ok { failed += 1 }
}
func page(_ rows: Int) -> (bits: [UInt8], height: Int) { ([UInt8](repeating: 0xAA, count: rows * Head.bytesPerLine), rows) }
func drain(_ s: inout JobSender, packet: Int = 200) -> [UInt8] {
    var out: [UInt8] = []
    while let c = s.next(packet: packet) { out += c }
    return out
}
func parse(_ b: [UInt8]) -> [String] {
    var out: [String] = [], i = 0
    while i < b.count {
        if b[i] == 0x1D, b[i + 1] == 0x76 {
            let w = Int(b[i + 4]) | Int(b[i + 5]) << 8, h = Int(b[i + 6]) | Int(b[i + 7]) << 8
            out.append("r\(h)x\(w)"); i += 8 + w * h
        } else if b[i] == 0x1B, b[i + 1] == 0x4A { out.append("f\(b[i + 2])"); i += 3 }
        else { out.append("bad\(b[i])"); break }
    }
    return out
}

do {
    var s = JobSender(PrintJob(pages: [page(640)], tailMM: 15))
    check("one raster command per page", parse(drain(&s)) == ["r640x48", "r120x48"])
    check("job ends", s.isDone && !s.stopped && s.sent == s.total)
}
do {
    var s = JobSender(PrintJob(pages: [page(10), page(20)], tailMM: 0))
    check("two pages with a 3 mm gap", parse(drain(&s)) == ["r10x48", "f24", "r20x48"])
}
do {
    var s = JobSender(PrintJob(pages: [page(10)], tailMM: 40))
    check("long feed is one blank raster", parse(drain(&s)) == ["r10x48", "r320x48"])
}
do {
    let tiny = PrintJob(pages: [page(100)], tailMM: 2)
    var s = JobSender(tiny)
    check("small packets keep the data", parse(drain(&s, packet: 20)) == ["r100x48", "r16x48"])
}
do {  // Stop in the middle of a page, then again in a later page
    var s = JobSender(PrintJob(pages: [page(640), page(300)], tailMM: 15))
    var out: [UInt8] = []
    for _ in 0..<16 { out += s.next(packet: 200)! }
    s.stop()
    out += drain(&s)
    let body = out.count - 8
    check("stop: ends on a whole row", body % Head.bytesPerLine == 0 && body < 3300, "\(body / Head.bytesPerLine) rows")
    check("stop: must wait before anything else", s.mustWait && !s.isDone)
    s.resumeAfterWait()
    out = drain(&s)
    check("stop: only the final feed follows", parse(out) == ["r120x48"] && s.isDone && s.stopped)
}
do {  // Over the paired serial link a stop finishes the current page, drops later pages, then feeds
    var s = JobSender(PrintJob(pages: [page(640), page(300)], tailMM: 15))
    var out: [UInt8] = []
    for _ in 0..<16 { out += s.next(packet: 200)! }
    s.stop(finishPage: true)
    out += drain(&s)
    check("serial stop: page finished, later page dropped, feed sent", parse(out) == ["r640x48", "r120x48"] && !s.mustWait && s.isDone && s.stopped)
}
// A page like text: 20 rows of ink, then 6 blank, over and over.
func textPage(_ rows: Int) -> (bits: [UInt8], height: Int) {
    var bits = [UInt8](repeating: 0, count: rows * Head.bytesPerLine)
    for y in 0..<rows where y % 26 < 20 { for x in 0..<Head.bytesPerLine { bits[y * Head.bytesPerLine + x] = 0xAA } }
    return (bits, rows)
}
do {  // Stop inside a line of text finishes that line
    var s = JobSender(PrintJob(pages: [textPage(640)], tailMM: 0))
    let stopAt = 8 + 26 * 5 * Head.bytesPerLine + 5 * Head.bytesPerLine  // the sixth line, 5 rows in
    var out = [UInt8](s.next(packet: stopAt)!)
    s.stop()
    out += drain(&s)
    let rows = (out.count - 8) / Head.bytesPerLine
    check("stop: a line of text is not cut", out.suffix(Head.bytesPerLine).allSatisfy { $0 == 0 } && (out.count - 8) % Head.bytesPerLine == 0, "\(rows) rows")
    check("stop: and ends on the first blank row after it", rows % 26 == 21 && rows < 26 * 8, "\(rows) rows")
    check("stop: the printer still needs its wait", s.mustWait)
}
do {  // A picture with no blank row stops where it is
    var s = JobSender(PrintJob(pages: [page(640)], tailMM: 0))
    let stopAt = 8 + 100 * Head.bytesPerLine
    var out = [UInt8](s.next(packet: stopAt)!)
    s.stop()
    out += drain(&s)
    check("stop in a picture: ends on the current row", out.count == stopAt, "\(out.count) bytes")
}
do {  // Stop near the end of a picture lets the page end, with no wait for the printer to drop it
    let job = PrintJob(pages: [page(100)], tailMM: 5)
    var s = JobSender(job)
    var out = [UInt8](s.next(packet: 8 + 70 * Head.bytesPerLine)!)
    s.stop()
    out += drain(&s)
    check("stop near the end of a page: the page is whole, then the feed", out.count == job.total && s.isDone && !s.mustWait, "\(out.count) of \(job.total)")
}
do {  // Stop before anything was sent
    var s = JobSender(PrintJob(pages: [page(50)], tailMM: 5))
    s.stop()
    check("stop before sending: only the feed, no wait", parse(drain(&s)) == ["r40x48"] && !s.mustWait && s.isDone)
}
do {  // Stop on a page boundary leaves no raster open
    var s = JobSender(PrintJob(pages: [page(4), page(4)], tailMM: 5))
    _ = s.next(packet: 500)!
    s.stop()
    let out = drain(&s)
    check("stop right after a page: no wait, only the feed", !s.mustWait && parse(out) == ["r40x48"] && s.isDone)
}

do {  // Stop with the raster header only half sent
    var s = JobSender(PrintJob(pages: [page(4)], tailMM: 5))
    _ = s.next(packet: 3)!
    s.stop()
    let out = drain(&s, packet: 3)
    check("stop never leaves half a header", out.count == 5 && s.mustWait, "\(out.count) more bytes")
}
do {  // Stop after everything went out: the job finishes normally
    var s = JobSender(PrintJob(pages: [page(4)], tailMM: 5))
    _ = drain(&s)
    s.stop()
    check("stop after the last byte changes nothing", s.isDone && !s.stopped)
}

var o = RenderOptions()
let demo = """
DEMO RECEIPT
-----------------------
Printed from a Mac
over Bluetooth, with no
app and no account.

Coffee             3.50
Sandwich           8.00
-----------------------
TOTAL             11.50
"""
o.font = .mono
o.fontSize = 9
let text = Loader.text(demo, name: "t", options: o)!
let lineH = text.height - 2 * Loader.textPad
check("text is as wide as the head", text.width == 384)
check("demo does not wrap: 10 lines", (280...340).contains(lineH), "\(lineH) rows of text")
do {
    let head = Rasterizer.headPage(text, sourceID: UUID(), options: o)
    var left = 384, right = -1, top = head.height, bottom = -1
    for y in 0..<head.height { for x in 0..<384 where head.bits[y * 48 + x >> 3] & (0x80 >> UInt8(x & 7)) != 0 {
        left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y) } }
    check("text keeps clear of the edges", left >= 14 && 383 - right >= 8 && top >= 14 && head.height - 1 - bottom >= 10,
          "left \(left) right \(383 - right) top \(top) bottom \(head.height - 1 - bottom)")
}
check("empty text gives no page", Loader.text("  \n ", name: "t", options: o) == nil)

let empty = Loader.note([], name: "n")
check("empty note does not print", empty.blank)
let written = Loader.note([Stroke(width: 5, points: [CGPoint(x: 40, y: 100), CGPoint(x: 120, y: 120), CGPoint(x: 200, y: 110)])], name: "n")
check("note is cut to the writing", !written.blank && written.height < 80 && written.width == 384, "\(written.height) rows")
let dot = Loader.note([Stroke(width: 8, points: [CGPoint(x: 40, y: 100)])], name: "n")
check("a single tap leaves a dot", !dot.blank)
let far = Loader.note([Stroke(width: 5, points: [CGPoint(x: 40, y: 900), CGPoint(x: 80, y: 910)])], name: "n")
check("writing low on a longer note still prints", !far.blank)

let cal = Loader.calibration()
let calHead = Rasterizer.headPage(cal, sourceID: UUID(), options: RenderOptions())
check("calibration first and last dots burn", calHead.bits[0] & 0x80 != 0 && calHead.bits[47] & 0x01 != 0)

var margin = RenderOptions(); margin.marginMM = 5
let narrow = Loader.text("Hello", name: "t", options: margin)!
check("margin narrows the page", narrow.width == 384 - 80)
let shifted = Rasterizer.headPage(narrow, sourceID: UUID(), options: margin)
check("margin stays blank", (0..<shifted.height).allSatisfy { y in (0..<5).allSatisfy { shifted.bits[y * 48 + $0] == 0 } })

let pdfData: Data = {
    let d = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(consumer: CGDataConsumer(data: d)!, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil); ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 200, y: 400, width: 100, height: 50)); ctx.endPDFPage()
    ctx.beginPDFPage(nil); ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 100, y: 100, width: 300, height: 600)); ctx.endPDFPage()
    ctx.closePDF()
    return d as Data
}()
do {
    let trimmed = try Loader.pdf(pdfData, name: "a.pdf", removed: [], options: RenderOptions())
    check("PDF gives two pages", trimmed.count == 2)
    check("trim enlarges the content", abs(trimmed[0].height - 192) <= 3 && trimmed[0].width == 384, "first page \(trimmed[0].width)x\(trimmed[0].height)")
    var keep = RenderOptions(); keep.trim = false
    let full = try Loader.pdf(pdfData, name: "a.pdf", removed: [], options: keep)
    check("keeping the page keeps its shape", abs(full[0].height - 543) <= 1, "\(full[0].height) rows")
    check("a removed page stays out", try Loader.pdf(pdfData, name: "a.pdf", removed: [0], options: RenderOptions()).map(\.number) == [1])
} catch { check("PDF renders", false, "\(error)") }

do {  // A page with no text layer gives a warning based on an assumed size, and has nothing to print as text.
    let pages = try Loader.pdf(pdfData, name: "a.pdf", removed: [], options: RenderOptions())
    check("a small graphic that fills the paper gets no warning", !pages[0].smallText && !pages[0].hasText)
    check("a page shrunk a lot gets one, with no text to offer", pages[1].smallText && !pages[1].hasText, "\(pages[1].height) rows")
} catch { check("PDF renders", false, "\(error)") }

print(failed == 0 ? "all passed" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)

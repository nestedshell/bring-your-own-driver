// Model checks and offscreen renders of the window. Needs no printer. Run: mac/test.sh [folder for the pictures]
import AppKit
import PDFKit
import SwiftUI

@main
struct AppTests {
    @MainActor static var failed = 0

    @MainActor static func check(_ name: String, _ ok: Bool, _ extra: String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name) \(extra)")
        if !ok { failed += 1 }
    }

    /// Lets the background rendering finish. A fixed wait here once passed a check on stale pages.
    @MainActor static func settle(_ model: AppModel, seconds: Double = 0.1) {
        let limit = Date().addingTimeInterval(30)
        repeat { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) } while model.renderPending && Date() < limit
        check("rendering finished in time", !model.renderPending)
    }

    @MainActor static func picture(_ model: AppModel, dark: Bool, to url: URL, size: CGSize = CGSize(width: 1120, height: 760)) throws {
        // Drawn as the active window, so the buttons show the colours they have in use.
        let root = ContentView().environmentObject(model).environmentObject(model.printer)
            .environment(\.controlActiveState, .key)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }

    /// A few written words, as points in dots.
    static func scribble() -> [Stroke] {
        var out: [Stroke] = []
        for (line, y0) in [(0, 70.0), (1, 170.0)] {
            var pts: [CGPoint] = []
            let count = line == 0 ? 90 : 60
            for i in 0..<count {
                let x = 34 + Double(i) * 3.4
                pts.append(CGPoint(x: x, y: y0 + 20 * sin(Double(i) * 0.62) + 7 * sin(Double(i) * 0.17)))
            }
            out.append(Stroke(width: 5, points: pts))
        }
        out.append(Stroke(width: 5, points: [CGPoint(x: 40, y: 245), CGPoint(x: 150, y: 250), CGPoint(x: 345, y: 240)]))
        return out
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let report = tests.appendingPathComponent("../../tests/fake-report.pdf").standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let defaults = UserDefaults.standard
        for key in ["dither", "tone", "trim", "rotate", "margin", "font", "fontSize", "feedAfterMM", "printDialogAtOnce", "printerLink", "printerID", "printerName"] { defaults.removeObject(forKey: key) }

        defaults.set(true, forKey: "printOnOpen")  // written by older versions whenever any setting changed
        let m = AppModel()
        m.printer.disconnect()  // nothing here may reach a printer
        check("files from the print dialog wait for Print by default", !m.printOnOpen)
        check("the old auto-print value is not restored", defaults.object(forKey: "printOnOpen") == nil)
        check("the feed after the last line is 20 mm by default", m.tailMM == 20)
        check("no printer is chosen by itself", m.printer.chosen == nil)
        m.printOnOpen = false

        check("an empty desk prints nothing", m.printable.isEmpty && m.printableCount == 0)
        settle(m)
        check("a link told to stay off does not search", m.printer.status == .offline || m.printer.status == .bluetoothOff, "\(m.printer.status)")

        m.add([report], autoPrint: false)
        settle(m)
        check("a two-page PDF gives two pages", m.items.count == 1 && m.items[0].pages.count == 2)
        let pdf = m.items[0].id
        let first = m.items[0].pages[0].number
        m.remove(page: first, of: pdf)
        settle(m)
        check("the bin removes one page of a longer PDF", m.items.count == 1 && m.items[0].pages.count == 1)
        m.remove(page: m.items[0].pages[0].number, of: pdf)
        check("the bin on the last page removes the document", m.items.isEmpty)

        m.addNote()
        settle(m)
        let note = m.items[0].id
        check("an empty note is on the desk but does not print", m.items[0].pages.count == 1 && m.printable.isEmpty)
        m.setNote(scribble(), rows: Loader.noteRows, of: note)
        settle(m)
        check("a written note prints", m.printable.count == 1)
        m.setNote([], rows: Loader.noteRows, of: note)
        settle(m)
        check("a cleared note no longer prints", m.printable.isEmpty)
        m.remove(note)

        m.addText()
        settle(m)
        let text = m.editingText?.id
        check("Type text opens an empty text card", text != nil && m.printable.isEmpty)
        m.addText()
        check("Type text does not open a second one", m.items.count == 1)
        m.setText("Hello", of: text!)
        settle(m)
        check("typed text prints", m.printable.count == 1)
        m.remove(text!)

        m.add([report], autoPrint: false)
        settle(m)
        let doc = m.items[0].id
        let picture1 = m.items[0].pages[0], picture2 = m.items[0].pages[1]
        check("a shrunk A4 page warns about small text", picture1.smallText && picture1.hasText && !picture1.asText)
        check("a label that fills the paper does not", !picture2.smallText)
        m.setAsText(true, page: picture1.number, of: doc)
        settle(m)
        let asText = m.items[0].pages[0]
        check("Print as text replaces the page", asText.asText && !asText.smallText && asText.height > picture1.height,
              "asText \(asText.asText), small \(asText.smallText), \(picture1.height) -> \(asText.height) rows, label \(asText.label), pages \(m.items[0].pages.count)")
        check("the other page keeps its picture", !m.items[0].pages[1].asText)
        m.setAsText(false, page: picture1.number, of: doc)
        settle(m)
        check("Show original brings the picture back", !m.items[0].pages[0].asText && m.items[0].pages[0].height == picture1.height)
        m.remove(doc)

        let reportDoc = PDFDocument(url: report)!
        let reading = Loader.readingText(of: reportDoc.page(at: 0)!)
        check("each table row stays on one line", reading.contains("Sample B 13.8 g/dL 12.0 to 16.0\n") && reading.contains("Sample C 0.82 mg/dL 0.60 to 1.10"))
        check("the text keeps the page's order", (reading.range(of: "Reason for visit")?.lowerBound ?? reading.endIndex) < (reading.range(of: "Results")?.lowerBound ?? reading.startIndex))
        check("a size is read from the page", abs((Loader.smallestTextPoints(of: reportDoc.page(at: 0)!) ?? 0) - 10) < 0.1)

        let bad = temp.appendingPathComponent("file.xyz")
        try Data([1, 2, 3]).write(to: bad)
        m.add([bad], autoPrint: false)
        check("an unknown file type is refused", m.items.isEmpty && (m.error ?? "").contains("file.xyz"))
        m.error = nil

        let plain = temp.appendingPathComponent("notes.txt")
        try "Plain text file".data(using: .utf8)!.write(to: plain)
        m.add([plain], autoPrint: false)
        settle(m)
        check("a text file opens as text", m.items.count == 1 && m.editingText?.name == "notes.txt" && m.printable.count == 1)
        m.remove(m.items[0].id)

        // Files from the print dialog: they wait for Print unless asked, and small text waits even then.
        m.add([plain], autoPrint: true)
        settle(m)
        check("a print-dialog file waits for Print", m.items.count == 1 && !m.waitingForPrinter)
        m.remove(m.items[0].id)
        m.printOnOpen = true
        m.add([report], autoPrint: true)
        settle(m)
        check("small text is not printed by itself, even when asked", m.items.count == 1 && !m.waitingForPrinter && (m.notice ?? "").contains("small text"))
        m.remove(m.items[0].id)
        m.add([plain], autoPrint: true)
        settle(m)
        check("a file without small text is sent at once when asked", m.waitingForPrinter)
        m.stop()
        m.remove(m.items[0].id)
        m.printOnOpen = false

        // RTF that hides HTML must not be read as HTML, because HTML import can fetch remote content.
        let hidden = "<html><body><p>Hi</p><img src=\"http://127.0.0.1:9/x.png\"></body></html>".data(using: .utf8)!
        check("HTML in an .rtf file is refused", (try? Loader.rich(hidden, name: "fake.rtf", options: RenderOptions())) == nil)
        let rtf = "{\\rtf1\\ansi Real RTF}".data(using: .utf8)!
        check("real RTF is read", (try? Loader.rich(rtf, name: "real.rtf", options: RenderOptions())) != nil)

        m.copies = 3
        m.addCalibration()
        settle(m)
        check("copies multiply the pages", m.printableCount == 3)
        check("calibration is 30 mm per copy", abs(m.paperCM - 9) < 0.01, "\(m.paperCM) cm")
        m.copies = 1
        m.remove(m.items[0].id)

        check("settings survive a restart", {
            m.options.tone = 20
            m.tailMM = 7
            let again = AppModel()
            again.printer.disconnect()
            return again.options.tone == 20 && again.tailMM == 7
        }())
        m.options.tone = 0
        m.tailMM = 10

        if CommandLine.arguments.count > 1 {
            let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try picture(m, dark: false, to: out.appendingPathComponent("mac_empty.png"))
            m.add([report], autoPrint: false)
            m.addDemo()
            let n = m.addNote()
            settle(m)
            m.setNote(scribble(), rows: Loader.noteRows, of: n)
            settle(m)
            try picture(m, dark: false, to: out.appendingPathComponent("mac_light.png"))
            try picture(m, dark: true, to: out.appendingPathComponent("mac_dark.png"))
        }

        for key in ["dither", "tone", "trim", "rotate", "margin", "font", "fontSize", "feedAfterMM", "printDialogAtOnce", "printerLink", "printerID", "printerName"] { defaults.removeObject(forKey: key) }
        print(failed == 0 ? "all passed" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}

// Prints on the real printer through the same model the window uses, and logs what happens.
// Run: mac/tools/real_print.sh model. The paper shows, in order: the fake report as text, a written note,
// then a job of several copies stopped part way, and a last line that must print clean.
// With the argument "stop", only the last two. With "text", the report as text and its table at 8 pt.
import AppKit
import PDFKit

/// These runs print, so they need a printer. They use the one chosen before if it is on the link asked for;
/// otherwise the first paired serial port of an S1, or the first S1 seen over Bluetooth LE when "ble" is passed.
/// The app itself never picks one.
func pickPrinter(_ link: PrinterLink) {
    let wanted: LinkKind = CommandLine.arguments.contains("ble") ? .ble : .serial
    if let c = link.chosen, c.kind != wanted {
        print("forgetting \(c.name): this run asks for \(wanted.label)")
        link.forget()
    }
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
        guard link.status == .choose else { if link.chosen != nil { t.invalidate() }; return }
        if let c = link.found.first(where: { $0.kind == wanted }) {
            print("choosing \(c.name) (\(c.kind.label))")
            link.choose(c)
            t.invalidate()
        }
    }
}

@main
struct RealModel {
    @MainActor static var model: AppModel!

    static func log(_ s: String) { print("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(s)"); fflush(stdout) }

    @MainActor static func wait(_ what: String, limit: Double = 60, until: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(limit)
        while !until(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let ok = until()
        log("\(what): \(ok ? "ok" : "TIMED OUT")")
        return ok
    }

    @MainActor static func printAndWait(_ what: String) -> Bool {
        guard wait("\(what) rendered", until: { !model.renderPending }) else { return false }
        log("\(what): \(model.printableCount) page(s), \(String(format: "%.1f", model.paperCM)) cm")
        model.printAll()
        guard wait("\(what) started", limit: 5, until: { model.isPrinting }) else { return false }
        let done = wait("\(what) finished", until: { !model.isPrinting })
        log("\(what): notice \"\(model.notice ?? "")\", error \"\(model.error ?? "")\"")
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        return done
    }

    @MainActor static func clear() { for item in model.items { model.remove(item.id) } }

    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let report = tests.appendingPathComponent("../../tests/fake-report.pdf").standardizedFileURL

        model = AppModel()
        model.printOnOpen = false
        pickPrinter(model.printer)
        guard wait("connected", limit: 20, until: { model.printer.status == .ready }) else { exit(1) }

        // The report as text at 11 pt, then its table at 8 pt, to compare the two sizes on one strip.
        if CommandLine.arguments.contains("text") {
            model.add([report], autoPrint: false)
            guard wait("report rendered", until: { !model.renderPending && !model.items.isEmpty }) else { exit(1) }
            let doc = model.items[0].id
            model.setAsText(true, page: model.items[0].pages[0].number, of: doc)
            model.remove(page: model.items[0].pages[1].number, of: doc)
            guard printAndWait("report as text, 11 pt") else { exit(1) }
            clear()
            let whole = Loader.readingText(of: PDFDocument(url: report)!.page(at: 0)!)
            let table = whole[whole.range(of: "Results")!.lowerBound..<whole.range(of: "0.60 to 1.10")!.upperBound]
            model.options.font = .sans
            model.options.fontSize = 8
            model.addText()
            model.setText("THE SAME TABLE AT 8 PT\n\n" + table, of: model.editingText!.id)
            guard printAndWait("table, 8 pt") else { exit(1) }
            log("battery \(model.printer.battery.map(String.init) ?? "unknown")")
            model.printer.disconnect()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            exit(0)
        }

        let onlyStop = CommandLine.arguments.contains("stop")
        // A shrunk page printed as text.
        if !onlyStop {
        model.add([report], autoPrint: false)
        guard wait("report rendered", until: { !model.renderPending && !model.items.isEmpty }) else { exit(1) }
        let id = model.items[0].id
        log("page 1 warns: \(model.items[0].pages[0].smallText); page 2 warns: \(model.items[0].pages[1].smallText)")
        model.setAsText(true, page: model.items[0].pages[0].number, of: id)
        model.remove(page: model.items[0].pages[1].number, of: id)  // the label already printed well
        guard printAndWait("report as text") else { exit(1) }
        clear()

        // A note, written with the same stroke type the drawing area produces.
        let note = model.addNote()
        var pts: [CGPoint] = []
        for i in 0..<90 { pts.append(CGPoint(x: 30 + Double(i) * 3.6, y: 70 + 26 * sin(Double(i) * 0.45))) }
        model.setNote([Stroke(width: 5, points: pts), Stroke(width: 3, points: [CGPoint(x: 40, y: 140), CGPoint(x: 340, y: 150)])], rows: Loader.noteRows, of: note)
        guard printAndWait("note") else { exit(1) }
        clear()
        }

        // Stop during several copies: nothing more may come out, the queue included.
        model.addDemo()
        model.copies = 5
        guard wait("demo rendered", until: { !model.renderPending }) else { exit(1) }
        model.printAll()
        guard wait("copies started", limit: 5, until: { model.isPrinting }) else { exit(1) }
        guard wait("reached 30%", until: { model.printer.progress >= 0.3 }) else { exit(1) }
        log("stop at \(Int(model.printer.progress * 100))%")
        model.stop()
        guard wait("copies ended", limit: 20, until: { !model.isPrinting }) else { exit(1) }
        log("after stop: notice \"\(model.notice ?? "")\", error \"\(model.error ?? "")\"")
        clear()
        model.copies = 1
        RunLoop.main.run(until: Date().addingTimeInterval(4))

        model.addText()
        model.setText("AFTER WINDOW STOP", of: model.editingText!.id)
        guard printAndWait("after stop") else { exit(1) }
        log("battery \(model.printer.battery.map(String.init) ?? "unknown")")
        model.printer.disconnect()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        exit(0)
    }
}

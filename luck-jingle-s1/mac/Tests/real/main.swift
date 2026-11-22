// Prints on the real printer through the app's own link and job code, and logs what happens.
// Run: mac/tools/real_print.sh. The paper shows, in order: MAC RUN, MAC STOP TEST, MAC AFTER STOP, a written note.
import AppKit

func log(_ s: String) { print(String(format: "[%7.2f] ", Date().timeIntervalSince(t0)) + s); fflush(stdout) }
let t0 = Date()
let link = PrinterLink()

/// These runs print, so they need a printer. They use the one chosen before if it is on the link asked for;
/// otherwise the first paired serial port of an S1, or the first S1 seen over Bluetooth LE when "ble" is passed.
/// The app itself never picks one.
func pickPrinterFor(_ link: PrinterLink) {
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
pickPrinterFor(link)
var mono = RenderOptions()
mono.font = .mono
mono.fontSize = 9

func page(_ text: String, _ o: RenderOptions = mono) -> (bits: [UInt8], height: Int) {
    let p = Rasterizer.headPage(Loader.text(text, name: "t", options: o)!, sourceID: UUID(), options: o)
    return (p.bits, p.height)
}

let receipt = """
MAC RUN
-----------------------
Coffee             3.50
Sandwich           8.00
-----------------------
TOTAL             11.50
"""
let long = (1...120).map { "MAC STOP TEST line \($0)" }.joined(separator: "\n")

func run(_ label: String, _ job: PrintJob, stopAt: Double? = nil, then: @escaping () -> Void) {
    let start = Date()
    log("\(label): \(job.total) bytes")
    link.send(job) { result in
        log("\(label): \(result) after \(String(format: "%.2f", Date().timeIntervalSince(start))) s, progress \(Int(link.progress * 100))%")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: then)
    }
    if let stopAt {
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
            if link.progress >= stopAt {
                t.invalidate()
                log("\(label): stop pressed at \(Int(link.progress * 100))%")
                link.stop()
            }
        }
    }
}

let strokes = [
    Stroke(width: 5, points: (0..<80).map { CGPoint(x: 34 + Double($0) * 4, y: 60 + 22 * sin(Double($0) * 0.6)) }),
    Stroke(width: 3, points: (0..<80).map { CGPoint(x: 34 + Double($0) * 4, y: 130 + 22 * sin(Double($0) * 0.6)) }),
    Stroke(width: 8, points: (0..<80).map { CGPoint(x: 34 + Double($0) * 4, y: 200 + 22 * sin(Double($0) * 0.6)) }),
]

func all() {
    run("receipt", PrintJob(pages: [page(receipt)], tailMM: 10)) {
        run("stop test", PrintJob(pages: [page(long)], tailMM: 10), stopAt: 0.2) {
            run("after stop", PrintJob(pages: [page("MAC AFTER STOP")], tailMM: 10)) {
                let n = Rasterizer.headPage(Loader.note(strokes, name: "n"), sourceID: UUID(), options: RenderOptions())
                run("note", PrintJob(pages: [(n.bits, n.height)], tailMM: 15)) {
                    log("done, battery \(link.battery.map(String.init) ?? "unknown")")
                    link.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
        }
    }
}

var began = false
link.onReady = {
    guard !began else { return }
    began = true
    log("connected to \(link.deviceName)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: all)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    if !began { log("no printer within 20 s, status \(link.status)"); exit(1) }
}
RunLoop.main.run()

import AppKit
import Foundation
import UniformTypeIdentifiers

struct DeskItem: Identifiable {
    let id = UUID()
    var name: String
    var source: Source
    var pages: [HeadPage] = []
    var version = 0
    var rendered: (version: Int, options: RenderOptions)?

    var isText: Bool { if case .text = source { return true } else { return false } }
    var isNote: Bool { if case .note = source { return true } else { return false } }
    var text: String { if case .text(let t) = source { return t } else { return "" } }
    var strokes: [Stroke] { if case .note(let s, _) = source { return s } else { return [] } }
    var rows: Int { if case .note(_, let r) = source { return r } else { return 0 } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var items: [DeskItem] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var dropTargeted = false
    @Published private(set) var waitingForPrinter = false

    @Published var options: RenderOptions { didSet { saveSettings(); if options != oldValue { scheduleRender() } } }
    @Published var tailMM: Int { didSet { saveSettings() } }
    @Published var printOnOpen: Bool { didSet { saveSettings() } }
    @Published var copies = 1

    let printer = PrinterLink()
    private let defaults = UserDefaults.standard
    private var queue: [PrintJob] = []
    private var printAfterRender: Set<UUID> = []
    private var renderToken = 0
    private var started = Date()
    private var noticeToken = 0
    private var jobHasSmallText: [Bool] = []

    static let demo = """
    DEMO LAB RESULT
    -----------------------
    Invented data, printed
    over Bluetooth with no
    phone and no account.

    Sample        DEMO 0001
    -----------------------
    Glucose      5.4 mmol/L
    Hb           13.8 g/dL
    Creatinine  0.82 mg/dL
    -----------------------
    Nothing leaves this
    computer.

    """

    init() {
        let d = UserDefaults.standard
        var o = RenderOptions()
        o.dither = Dither(rawValue: d.string(forKey: "dither") ?? "") ?? .auto
        o.tone = d.object(forKey: "tone") as? Double ?? 0
        o.trim = d.object(forKey: "trim") as? Bool ?? true
        o.rotate = d.object(forKey: "rotate") as? Bool ?? true
        o.marginMM = d.object(forKey: "margin") as? Int ?? 0
        o.font = TextFont(rawValue: d.string(forKey: "font") ?? "") ?? .sans
        o.fontSize = d.object(forKey: "fontSize") as? Double ?? 11
        options = o
        // Saved under a new key: the old "tail" was the 10 mm default, too short to clear the tear bar.
        tailMM = d.object(forKey: "feedAfterMM") as? Int ?? 20
        // Off by default: a file from the print dialog opens with its preview and waits for Print. Saved under a new
        // key: older versions wrote "printOnOpen" (then on by default) whenever any setting changed.
        printOnOpen = d.object(forKey: "printDialogAtOnce") as? Bool ?? false
        d.removeObject(forKey: "printOnOpen")
        printer.onReady = { [weak self] in Task { @MainActor in self?.next() } }
    }

    private func saveSettings() {
        defaults.set(options.dither.rawValue, forKey: "dither")
        defaults.set(options.tone, forKey: "tone")
        defaults.set(options.trim, forKey: "trim")
        defaults.set(options.rotate, forKey: "rotate")
        defaults.set(options.marginMM, forKey: "margin")
        defaults.set(options.font.rawValue, forKey: "font")
        defaults.set(options.fontSize, forKey: "fontSize")
        defaults.set(tailMM, forKey: "feedAfterMM")
        defaults.set(printOnOpen, forKey: "printDialogAtOnce")
    }

    // MARK: Pages

    /// What Print sends: an empty note is left out.
    var printable: [HeadPage] { items.flatMap(\.pages).filter { !$0.blank } }
    var printableCount: Int { printable.count * copies }
    var paperCM: Double { Double(printable.reduce(0) { $0 + $1.height } * copies) / Double(Head.dotsPerMM) / 10 }
    var etaSeconds: Int { max(1, Int((Double(printable.reduce(0) { $0 + $1.bits.count } * copies) / 4100).rounded())) }
    /// The text card edits the most recently added text.
    var editingText: DeskItem? { items.last(where: \.isText) }

    // MARK: Adding

    /// `autoPrint`: files sent by the print dialog, the Dock icon or "Open With". They print without Print only
    /// when `printOnOpen` is on, and even then not if a page has small text (see `apply`).
    func add(_ urls: [URL], autoPrint: Bool) {
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let source = try Self.source(for: data, url: url)
                let item = DeskItem(name: url.lastPathComponent, source: source)
                items.append(item)
                if autoPrint && printOnOpen { printAfterRender.insert(item.id) }
            } catch {
                self.error = error.localizedDescription
            }
        }
        scheduleRender(after: 0)
    }

    private static func source(for data: Data, url: URL) throws -> Source {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if data.starts(with: Array("%PDF".utf8)) || ext == "pdf" { return .pdf(data, removed: [], asText: []) }
        if Loader.richTypes.contains(ext) { return .rich(data) }
        if Loader.textTypes.contains(ext) { return .text(plainText(data)) }
        if Loader.imageTypes.contains(ext) { return .image(data) }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image(data) }
            if type.conforms(to: .plainText) { return .text(plainText(data)) }
        }
        throw LoadError.unsupported(name)
    }

    private static func plainText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func addFromPasteboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls, autoPrint: false)
        } else if let pdf = pb.data(forType: .pdf) {
            items.append(DeskItem(name: "Pasted PDF", source: .pdf(pdf, removed: [], asText: [])))
        } else if let image = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            items.append(DeskItem(name: "Pasted image", source: .image(image)))
        } else if let text = pb.string(forType: .string) {
            items.append(DeskItem(name: "Pasted text", source: .text(text)))
        } else {
            error = "The clipboard holds nothing that can be printed."
        }
        scheduleRender(after: 0)
    }

    func addText() {
        if editingText == nil { items.append(DeskItem(name: "Text", source: .text(""))) }
        scheduleRender(after: 0)
    }

    func addDemo() {
        options.font = .mono
        options.fontSize = 9
        items.append(DeskItem(name: "Demo lab result", source: .text(Self.demo)))
        scheduleRender(after: 0)
    }

    func addCalibration() {
        items.append(DeskItem(name: "Calibration page", source: .calibration))
        scheduleRender(after: 0)
    }

    @discardableResult
    func addNote() -> UUID {
        let note = DeskItem(name: "Handwritten note", source: .note([], rows: Loader.noteRows))
        items.append(note)
        scheduleRender(after: 0)
        return note.id
    }

    // MARK: Editing

    func setText(_ text: String, of id: UUID) {
        update(id) { $0.source = .text(text) }
        scheduleRender(after: 0.25)
    }

    func setNote(_ strokes: [Stroke], rows: Int, of id: UUID) {
        update(id) { $0.source = .note(strokes, rows: rows) }
        scheduleRender(after: 0.25)
    }

    /// A page of a longer PDF goes alone; the last page takes the document with it.
    func remove(page number: Int, of id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if case .pdf(let data, let removed, let asText) = item.source, item.pages.count > 1 {
            update(id) { $0.source = .pdf(data, removed: removed.union([number]), asText: asText) }
            scheduleRender(after: 0)
        } else {
            remove(id)
        }
    }

    /// Prints a page of a PDF as plain text, or goes back to its picture.
    func setAsText(_ on: Bool, page number: Int, of id: UUID) {
        guard let item = items.first(where: { $0.id == id }), case .pdf(let data, let removed, var asText) = item.source else { return }
        if on { asText.insert(number) } else { asText.remove(number) }
        update(id) { $0.source = .pdf(data, removed: removed, asText: asText) }
        scheduleRender(after: 0)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        printAfterRender.remove(id)
    }

    private func update(_ id: UUID, _ change: (inout DeskItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        items[i].version += 1
    }

    // MARK: Rendering

    /// True while a page on the desk does not yet show its latest content and settings.
    var renderPending: Bool {
        items.contains { i in i.rendered.map { $0.version != i.version || $0.options != options } ?? true }
    }

    /// Only what changed is drawn again. A newer request discards an older one still running.
    func scheduleRender(after delay: TimeInterval = 0.15) {
        renderToken += 1
        let token = renderToken, o = options
        let work = items.filter { i in i.rendered.map { $0.version != i.version || $0.options != o } ?? true }
            .map { (id: $0.id, name: $0.name, source: $0.source, version: $0.version) }
        guard !work.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard await self.renderToken == token else { return }
            for w in work {
                let result = Result { try Source.pages(w.source, name: w.name, id: w.id, options: o) }
                let current = await self.apply(result, to: w.id, version: w.version, options: o, token: token)
                if !current { return }
            }
        }
    }

    private func apply(_ result: Result<[HeadPage], Error>, to id: UUID, version: Int, options o: RenderOptions, token: Int) -> Bool {
        guard token == renderToken else { return false }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return true }
        switch result {
        case .failure(let e):
            error = e.localizedDescription
            remove(id)
        case .success(let pages):
            items[i].pages = pages
            items[i].rendered = (version, o)
            if printAfterRender.remove(id) != nil {
                if pages.contains(where: \.smallText) {
                    // Not printed by itself: the warning on the page has to be seen before the paper.
                    show("\(items[i].name) has small text, so it was not printed. Check the warning on the page, then press Print.", seconds: 20)
                } else {
                    enqueue(pages)
                }
            }
        }
        return true
    }

    // MARK: Printing

    func printAll() {
        guard !isPrinting, !waitingForPrinter else { return }
        enqueue(printable)
    }

    var isPrinting: Bool { printer.status == .printing || printer.status == .stopping }

    func stop() {
        queue.removeAll()
        jobHasSmallText = Array(jobHasSmallText.prefix(isPrinting ? 1 : 0))
        waitingForPrinter = false
        printer.stop()
    }

    private func enqueue(_ pages: [HeadPage]) {
        let printed = pages.filter { !$0.blank }
        guard !printed.isEmpty else { return }
        let all = (0..<max(1, copies)).flatMap { _ in printed }
        queue.append(PrintJob(pages: all.map { (bits: $0.bits, height: $0.height) }, tailMM: tailMM))
        jobHasSmallText.append(printed.contains(where: \.smallText))
        next()
    }

    private func next() {
        guard !queue.isEmpty else { waitingForPrinter = false; return }
        guard printer.status == .ready else {
            waitingForPrinter = !isPrinting
            return
        }
        waitingForPrinter = false
        started = Date()
        printer.send(queue.removeFirst()) { [weak self] result in
            Task { @MainActor in self?.finished(result) }
        }
    }

    private func finished(_ result: PrintResult) {
        let small = jobHasSmallText.isEmpty ? false : jobHasSmallText.removeFirst()
        switch result {
        case .printed(confirmed: true):
            show("Printed in \(max(1, Int(Date().timeIntervalSince(started).rounded()))) s" + (small ? ". Small text: check numbers against the original." : ""))
        case .printed(confirmed: false):
            show(printer.link == .serial ? "Sent over the paired link, which gives no confirmation. Check the paper."
                : "Sent, but the printer did not confirm. Check the paper.")
        case .stopped:
            queue.removeAll()
            jobHasSmallText.removeAll()
            show("Stopped")
        case .failed(let message):
            queue.removeAll()
            jobHasSmallText.removeAll()
            error = "Print failed: \(message)"
        }
        next()
    }

    private func show(_ text: String, seconds: UInt64 = 4) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if token == noticeToken { notice = nil }
        }
    }
}

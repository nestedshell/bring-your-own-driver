import AppKit
import Foundation

struct SourceFile: Identifiable {
    let id = UUID()
    let url: URL
    let data: Data  // kept in memory: re-rendered when the paper size changes
    var grays: [GrayPage]
    var pages: [HeadPage] = []
    var printed = false
    var name: String { url.lastPathComponent }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var files: [SourceFile] = []
    @Published var skipped: Set<UUID> = []
    @Published var error: String?
    @Published var loading = 0
    @Published var queued = 0
    @Published var dropTargeted = false

    @Published var density: Double { didSet { defaults.set(density, forKey: "density") } }
    @Published var dither: Dither { didSet { defaults.set(dither.rawValue, forKey: "dither"); rerender(reload: false) } }
    @Published var paper: Paper { didSet { defaults.set(paper.rawValue, forKey: "paper"); rerender(reload: true) } }
    @Published var copies = 1
    @Published var printOnDrop: Bool { didSet { defaults.set(printOnDrop, forKey: "printOnDrop") } }

    let printer = PrinterLink()
    private let defaults = UserDefaults.standard
    private var queue: [(pages: [HeadPage], files: [UUID])] = []
    private var userCancelled = false

    init() {
        density = defaults.object(forKey: "density") as? Double ?? 24
        dither = Dither(rawValue: defaults.string(forKey: "dither") ?? "") ?? .auto
        paper = Paper(rawValue: defaults.string(forKey: "paper") ?? "") ?? .a4
        // Off by default: dropped files and files from the print dialog open with their preview and wait for Print.
        printOnDrop = defaults.object(forKey: "printOnDrop") as? Bool ?? false
        printer.onReady = { [weak self] in Task { @MainActor in self?.next() } }
    }

    var selectedPages: [HeadPage] {
        files.flatMap(\.pages).filter { !skipped.contains($0.id) }
    }

    // MARK: Files

    /// `autoPrint`: files dropped on the window or the Dock icon, or sent by the print dialog. They print without
    /// pressing Print only when `printOnDrop` is on.
    func add(_ urls: [URL], autoPrint: Bool) {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                error = LoadError.unreadable(url.lastPathComponent).localizedDescription
                continue
            }
            loading += 1
            let mode = dither, paper = paper
            Task.detached(priority: .userInitiated) {
                let result = Result { try Loader.load(data, name: url.lastPathComponent, paper: paper) }
                    .map { grays in (grays, grays.map { Rasterizer.headPage($0, dither: mode) }) }
                await MainActor.run {
                    self.loading -= 1
                    switch result {
                    case .failure(let e): self.error = e.localizedDescription
                    case .success(let (grays, pages)):
                        let file = SourceFile(url: url, data: data, grays: grays, pages: pages)
                        self.files.append(file)
                        if autoPrint && self.printOnDrop { self.enqueue(pages, files: [file.id]) }
                    }
                }
            }
        }
    }

    func remove(_ file: SourceFile) {
        files.removeAll { $0.id == file.id }
    }

    func clear() {
        files.removeAll()
        skipped.removeAll()
    }

    /// `reload`: lay the source out again (paper changed); otherwise only re-dither.
    private func rerender(reload: Bool) {
        let mode = dither, paper = paper
        for file in files {
            let (data, name, grays) = (file.data, file.name, file.grays)
            Task.detached(priority: .userInitiated) {
                let newGrays = reload ? ((try? Loader.load(data, name: name, paper: paper)) ?? grays) : grays
                let pages = newGrays.map { Rasterizer.headPage($0, dither: mode) }
                await MainActor.run {
                    guard mode == self.dither, paper == self.paper,
                          let i = self.files.firstIndex(where: { $0.id == file.id }) else { return }
                    self.files[i].grays = newGrays
                    self.files[i].pages = pages
                }
            }
        }
    }

    // MARK: Printing

    func printSelected() {
        let pages = selectedPages
        guard !pages.isEmpty else { return }
        let ids = files.filter { f in f.pages.contains { !skipped.contains($0.id) } }.map(\.id)
        enqueue(pages, files: ids)
    }

    func cancel() {
        queue.removeAll()
        queued = 0
        userCancelled = true
        printer.cancel()
    }

    private func enqueue(_ pages: [HeadPage], files ids: [UUID]) {
        queue.append((Array(repeating: pages, count: max(1, copies)).flatMap { $0 }, ids))
        queued = queue.count
        next()
    }

    private func next() {
        guard printer.status == .ready, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        queued = queue.count + 1
        printer.send(PrintJob(pages: item.pages, density: Int(density))) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    for i in self.files.indices where item.files.contains(self.files[i].id) { self.files[i].printed = true }
                } else if !self.userCancelled {
                    self.error = "Printing stopped: the printer disconnected."
                }
                self.userCancelled = false
                self.queued = self.queue.count
                self.next()
            }
        }
    }
}

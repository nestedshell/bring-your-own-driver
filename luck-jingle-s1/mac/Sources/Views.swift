import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// View state kept in small objects: the @State macro needs a plugin that the Command Line Tools do not ship,
/// and this app builds without Xcode.
final class Flag: ObservableObject { @Published var on = false }
final class NotePad: ObservableObject {
    @Published var penWidth: CGFloat = 5
    @Published var current: Stroke?
}

extension AppModel {
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image, .plainText, .rtf]
        if panel.runModal() == .OK { add(panel.urls, autoPrint: false) }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 310)
            Divider()
            Desk()
        }
        .frame(minWidth: 840, minHeight: 600)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls, autoPrint: false)
            return true
        } isTargeted: { model.dropTargeted = $0 }
        .alert("S1 Driver", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var printer: PrinterLink
    @StateObject private var more = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusRow().padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    quick
                    if let text = model.editingText { TextCard(item: text) }
                    settings
                    DisclosureGroup("More settings", isExpanded: $more.on) { moreSettings.padding(.top, 10) }
                }
                .padding(16)
            }
            Divider()
            Footer().padding(16)
        }
        .background(.background)
    }

    private var quick: some View {
        HStack(spacing: 10) {
            QuickButton(title: "Write by hand", symbol: "scribble") { model.addNote() }
            QuickButton(title: "Type text", symbol: "textformat") { model.addText() }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Best for")
                Picker("Best for", selection: $model.options.dither) {
                    ForEach(Dither.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Tone")
                HStack(spacing: 8) {
                    Text("Lighter").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $model.options.tone, in: -60...60)
                    Text("Darker").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Trim blank edges", isOn: $model.options.trim)
            Toggle("Rotate wide pages", isOn: $model.options.rotate)
            Stepper("Copies: \(model.copies)", value: $model.copies, in: 1...50)
        }
    }

    private var moreSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            ValueSlider(title: "Margin", unit: "mm", range: 0...10, value: Binding(
                get: { Double(model.options.marginMM) }, set: { model.options.marginMM = Int($0) }))
            ValueSlider(title: "Feed after", unit: "mm", range: 0...40, value: Binding(
                get: { Double(model.tailMM) }, set: { model.tailMM = Int($0) }))
            Toggle("Print files from the print dialog at once", isOn: $model.printOnOpen)
                .help("Off: files sent from a print dialog or dropped on the Dock icon open here with their preview and wait for Print. On: they print without pressing Print, except pages with small text, which wait with their warning.")
            HStack {
                Button("Add calibration page") { model.addCalibration() }
                Button("Add demo lab result") { model.addDemo() }
            }
            .controlSize(.small)
        }
    }
}

struct QuickButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18)).frame(height: 24)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.1)))
    }
}

struct ValueSlider: View {
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 66, alignment: .leading)
            // Rounded by hand: a stepped slider draws a tick for every value.
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
            Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
    }
}

struct TextCard: View {
    @EnvironmentObject private var model: AppModel
    let item: DeskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text").font(.headline)
                Spacer()
                Button { model.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Remove this text")
            }
            TextEditor(text: Binding(get: { item.text }, set: { model.setText($0, of: item.id) }))
                .font(Font(model.options.font.font(size: 12) as CTFont))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .accessibilityLabel("Text to print")
            Picker("Font", selection: $model.options.font) {
                ForEach(TextFont.allCases) { Text($0.title).tag($0) }
            }
            ValueSlider(title: "Size", unit: "pt", range: 7...48, value: $model.options.fontSize)
        }
    }
}

struct Footer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var printer: PrinterLink

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                Text(eta).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            if model.isPrinting {
                ProgressView(value: printer.progress)
                Button(role: .destructive) { model.stop() } label: {
                    Label(printer.status == .stopping ? printer.stoppingText : "Stop printing", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(printer.status == .stopping)
            } else if model.waitingForPrinter {
                Text("Will print when the printer connects.").font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { model.stop() }.controlSize(.large)
            } else {
                Button { model.printAll() } label: {
                    Label("Print", systemImage: "printer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.printable.isEmpty)
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var summary: String {
        let n = model.printableCount
        return n == 0 ? "Nothing to print yet" : "\(n) page\(n == 1 ? "" : "s") · \(String(format: "%.1f", model.paperCM)) cm of paper"
    }

    private var eta: String {
        if model.isPrinting {
            let left = printer.secondsLeft.map { " · \($0) s left" } ?? ""
            return "\(Int(printer.progress * 100))%\(left)"
        }
        return model.printableCount == 0 ? "" : "~\(model.etaSeconds) s"
    }
}

struct StatusRow: View {
    @EnvironmentObject private var printer: PrinterLink

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch printer.status {
                case .searching, .connecting, .choose:
                    ProgressView().controlSize(.small)
                case .ready:
                    Button("Disconnect") { printer.disconnect() }.buttonStyle(.borderless).font(.callout)
                        .help("Frees the printer for another app or browser")
                case .offline:
                    Button("Connect") { printer.connectAgain() }.buttonStyle(.borderless).font(.callout)
                default:
                    EmptyView()
                }
            }
            if printer.status == .choose {
                PrinterChooser()
            } else if let kind = printer.link {
                LinkLine(kind: kind)
            }
        }
    }

    private var color: Color {
        switch printer.status {
        case .ready: .green
        case .printing, .stopping: .orange
        case .searching, .connecting, .choose: .yellow
        case .offline: .gray
        case .bluetoothOff, .unauthorized, .noAnswer: .red
        }
    }

    private var title: String {
        switch printer.status {
        case .ready, .printing, .stopping: printer.deviceName
        case .choose: "Choose your printer"
        case .searching: "Looking for the printer…"
        case .connecting: "Connecting…"
        case .offline: "Not connected"
        case .noAnswer: "The printer does not answer"
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth not allowed"
        }
    }

    private var subtitle: String {
        let paired = printer.link == .serial
        switch printer.status {
        case .ready: return printer.battery.map { "Connected · battery \($0)%" } ?? "Connected"
        case .printing: return "Printing…"
        case .stopping: return printer.stoppingText
        case .choose: return "It connects only to the printer you choose"
        case .searching:
            return paired ? "Switch \(printer.deviceName) on and close any other app or page using it. If it is not in System Settings › Bluetooth any more, pair it again"
                : "Switch \(printer.deviceName) on and close any other app or page using it"
        case .connecting: return printer.deviceName
        case .offline: return "The printer is free for other apps"
        case .noAnswer: return "Switch it on. If the USB cable is plugged in, unplug it"
        case .bluetoothOff: return "Turn Bluetooth on in Control Centre"
        case .unauthorized: return "System Settings › Privacy & Security › Bluetooth"
        }
    }
}

/// Which link is in use, and the way to change printer.
struct LinkLine: View {
    @EnvironmentObject private var printer: PrinterLink
    let kind: LinkKind

    private var busy: Bool { printer.status == .printing || printer.status == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: kind == .serial ? "lock.fill" : "lock.open")
                    .foregroundStyle(kind == .serial ? Color.green : Color.orange)
                Text(kind.label)
                Spacer()
                Button("Change printer") { printer.forget() }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Forget this printer and choose again")
            }
            // Only the paired port of the same printer: PPS1_4367_BLE is PPS1_4367 over the paired link.
            if kind == .ble, let stem = printer.chosen?.shortName.uppercased(),
               let path = printer.serialPorts.first(where: { SerialPort.displayName($0).uppercased().hasPrefix(stem) }) {
                Button("Use the paired link of \(SerialPort.displayName(path)) instead (encrypted)") {
                    printer.choose(PrinterChoice(kind: .serial, id: path, name: SerialPort.displayName(path)))
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
        }
        .font(.caption)
    }
}

/// Printers found nearby. Nothing connects until the user picks one; the paired, encrypted link comes first.
struct PrinterChooser: View {
    @EnvironmentObject private var printer: PrinterLink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if printer.found.isEmpty {
                Text("Looking for printers… Switch the S1 on.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(printer.found) { c in
                HStack(spacing: 8) {
                    Image(systemName: c.kind == .serial ? "lock.fill" : "lock.open")
                        .foregroundStyle(c.kind == .serial ? Color.green : Color.orange)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text(c.kind == .serial ? "Paired link, encrypted · recommended" : "Bluetooth LE, not encrypted")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if c.kind == .serial {
                        Button("Connect") { printer.choose(c) }.buttonStyle(.borderedProminent).controlSize(.small)
                    } else {
                        Button("Connect") { printer.choose(c) }.controlSize(.small)
                    }
                }
            }
            Text("For the encrypted link, pair the printer once in System Settings › Bluetooth. It is listed there as PPS1_…, without _BLE.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Desk

struct Desk: View {
    @EnvironmentObject private var model: AppModel

    private var sheets: [(item: DeskItem, page: HeadPage)] {
        model.items.flatMap { item in item.pages.map { (item, $0) } }
    }

    var body: some View {
        let sheets = sheets
        Group {
            if sheets.isEmpty {
                AddTile(large: true).padding(32)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 26, alignment: .top)], spacing: 30) {
                        ForEach(Array(sheets.enumerated()), id: \.element.page.id) { i, sheet in
                            if sheet.item.isNote {
                                NoteSheet(item: sheet.item, index: i + 1)
                            } else {
                                PageSheet(item: sheet.item, page: sheet.page, index: i + 1)
                            }
                        }
                        AddTile(large: false)
                    }
                    .padding(28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct AddTile: View {
    @EnvironmentObject private var model: AppModel
    let large: Bool

    var body: some View {
        Button { model.showOpenPanel() } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .medium))
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                Text("Add document").font(.title3.weight(.semibold))
                Text("Drop a PDF, an image or a text file here, or click to choose")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: large ? .infinity : nil)
            .frame(minHeight: 240)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 14).fill(model.dropTargeted ? Color.accentColor.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
            model.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.55),
            style: StrokeStyle(lineWidth: model.dropTargeted ? 2.5 : 1.5, dash: [8, 6])))
    }
}

/// Round bin at the top right of a sheet.
struct TrashButton: View {
    let help: String
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover.on ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hover.on ? Color.red : Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(.quaternary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SheetFrame<Content: View>: View {
    let title: String
    let trashHelp: String
    let onTrash: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).padding(.trailing, 40).frame(height: 30)
                .help(title)
            content
        }
        .overlay(alignment: .topTrailing) { TrashButton(help: trashHelp, action: onTrash) }
    }
}

struct PageSheet: View {
    @EnvironmentObject private var model: AppModel
    let item: DeskItem
    let page: HeadPage
    let index: Int

    var body: some View {
        let onePage: Bool = { if case .pdf = item.source { return item.pages.count > 1 } else { return false } }()
        SheetFrame(title: "\(index). \(page.label)", trashHelp: onePage ? "Delete this page" : "Delete this document") {
            model.remove(page: page.number, of: item.id)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Image(decorative: page.preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .background(.white)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                if page.asText || page.smallText { TextNotice(item: item, page: page) }
            }
        }
    }
}

/// Says when a page's text cannot be trusted on paper, and offers the way out.
struct TextNotice: View {
    @EnvironmentObject private var model: AppModel
    let item: DeskItem
    let page: HeadPage

    private var message: String {
        if page.asText { return "Text only. The layout is gone and tables may not line up. Check it against the original." }
        if page.hasText { return "Small text. Digits and decimal points may print wrong. Check numbers against the original." }
        return "If this page has small text, digits and decimal points may print wrong. Check numbers against the original."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if page.asText {
                Button("Show original page") { model.setAsText(false, page: page.number, of: item.id) }.controlSize(.small)
            } else if page.hasText {
                Button("Print as text") { model.setAsText(true, page: page.number, of: item.id) }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.45)))
    }
}

// MARK: - Handwritten note

struct NoteSheet: View {
    @EnvironmentObject private var model: AppModel
    let item: DeskItem
    let index: Int
    @StateObject private var pad = NotePad()
    private static let pens: [(name: String, width: CGFloat)] = [("Fine pen", 3), ("Medium pen", 5), ("Bold pen", 8)]
    private static let grow = 160

    var body: some View {
        SheetFrame(title: "\(index). \(item.name)", trashHelp: "Delete this note") {
            model.remove(item.id)
        } content: {
            VStack(spacing: 8) {
                ink
                bar
            }
        }
    }

    private var ink: some View {
        GeometryReader { geo in
            let scale = geo.size.width / CGFloat(Head.dots)
            Canvas { ctx, _ in
                ctx.scaleBy(x: scale, y: scale)
                for s in item.strokes + (pad.current.map { [$0] } ?? []) {
                    ctx.stroke(Path(s.path), with: .color(.black), style: StrokeStyle(lineWidth: s.width, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let p = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                if pad.current == nil { pad.current = Stroke(width: pad.penWidth, points: []) }
                pad.current?.points.append(p)
            }.onEnded { _ in
                guard let s = pad.current else { return }
                pad.current = nil
                // Paper is cheap to add while writing; the blank end is cut before printing.
                let lowest = s.points.map(\.y).max() ?? 0
                let rows = lowest > CGFloat(item.rows - 48) ? item.rows + Self.grow : item.rows
                model.setNote(item.strokes + [s], rows: rows, of: item.id)
            })
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .overlay {
                if item.strokes.isEmpty && pad.current == nil {
                    Text("Write here").foregroundStyle(Color.black.opacity(0.35)).allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(CGFloat(Head.dots) / CGFloat(max(item.rows, 1)), contentMode: .fit)
        .background(.white)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityLabel("Writing area")
    }

    private var bar: some View {
        HStack(spacing: 6) {
            ForEach(Self.pens, id: \.width) { pen in
                Button { pad.penWidth = pen.width } label: {
                    Circle().fill(Color.primary).frame(width: pen.width + 2, height: pen.width + 2)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(pad.penWidth == pen.width ? Color.accentColor.opacity(0.25) : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(pen.name)
                .accessibilityLabel(pen.name)
            }
            Spacer()
            Button("Undo") { model.setNote(Array(item.strokes.dropLast()), rows: item.rows, of: item.id) }
                .disabled(item.strokes.isEmpty)
            Button("Clear") { model.setNote([], rows: Loader.noteRows, of: item.id) }
                .disabled(item.strokes.isEmpty)
        }
        .controlSize(.small)
    }
}

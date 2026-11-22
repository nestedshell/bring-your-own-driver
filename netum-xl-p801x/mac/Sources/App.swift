import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct XLP801App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("XL-P801X Print", id: "main") {
            ContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.printer)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { delegate.model.showOpenPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print") { delegate.model.printSelected() }.keyboardShortcut("p")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    /// Files dropped on the Dock icon, "Open With", or the print dialog's PDF menu.
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls, autoPrint: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension AppModel {
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image, .plainText, .rtf]
        if panel.runModal() == .OK { add(panel.urls, autoPrint: false) }
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 300)
            Divider()
            PreviewGrid()
        }
        .frame(minWidth: 820, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls, autoPrint: true)
            return true
        } isTargeted: { model.dropTargeted = $0 }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Text(model.printOnDrop ? "Drop to print" : "Drop to add").font(.title2.weight(.semibold)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert("XL-P801X", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var printer: PrinterLink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusRow().padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DropBox()
                    if !model.files.isEmpty { FileList() }
                    settings
                }
                .padding(16)
            }
            Divider()
            footer.padding(16)
        }
        .background(.background)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRINT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Darkness")
                    Spacer()
                    Text("\(Int(model.density))").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $model.density, in: 0...31, step: 1)
            }
            Picker("Paper", selection: $model.paper) {
                ForEach(Paper.allCases) { Text($0.title).tag($0) }
            }
            Picker("Dithering", selection: $model.dither) {
                ForEach(Dither.allCases) { Text($0.title).tag($0) }
            }
            Stepper("Copies: \(model.copies)", value: $model.copies, in: 1...50)
            Toggle("Print files at once when dropped or sent from the print dialog", isOn: $model.printOnDrop)
                .toggleStyle(.checkbox)
                .help("Off: the files open here with their preview and wait for Print.")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if printer.status == .printing {
                ProgressView(value: printer.progress)
                HStack {
                    Text("\(Int(printer.progress * 100))%" + (model.queued > 1 ? " · \(model.queued - 1) more queued" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }
            } else if model.loading > 0 {
                ProgressView().controlSize(.small)
            }
            let count = model.selectedPages.count * model.copies
            Button {
                model.printSelected()
            } label: {
                Text(count == 0 ? "Print" : "Print \(count) page\(count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(count == 0)
            .keyboardShortcut(.defaultAction)
            if count > 0 && printer.status != .ready && printer.status != .printing {
                Text("Will print when the printer connects.").font(.caption).foregroundStyle(.secondary)
            }
        }
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
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if printer.status == .searching || printer.status == .connecting || printer.status == .choose {
                    ProgressView().controlSize(.small)
                } else if printer.status == .ready {
                    Button { printer.reconnect() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Reconnect")
                }
            }
            if printer.status == .choose {
                chooser
            } else if printer.chosen != nil {
                HStack {
                    Text("Bluetooth LE (not encrypted)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Change printer") { printer.forget() }
                        .buttonStyle(.borderless)
                        .disabled(printer.status == .printing)
                        .help("Forget this printer and choose again")
                }
                .font(.caption)
            }
        }
    }

    /// Printers found nearby. Nothing connects until the user picks one.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            if printer.found.isEmpty {
                Text("Looking for printers… Switch the XL-P801X on.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(printer.found) { c in
                HStack {
                    Text(c.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Connect") { printer.choose(c) }.controlSize(.small)
                }
            }
        }
    }

    private var color: Color {
        switch printer.status {
        case .ready: .green
        case .printing: .orange
        case .searching, .connecting, .choose: .yellow
        case .bluetoothOff, .unauthorized: .red
        }
    }

    private var title: String {
        switch printer.status {
        case .ready, .printing: printer.deviceName
        case .choose: "Choose your printer"
        case .searching: "Looking for the printer…"
        case .connecting: "Connecting…"
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth not allowed"
        }
    }

    private var subtitle: String {
        switch printer.status {
        case .ready: "Connected"
        case .printing: "Printing…"
        case .choose: "It connects only to the printer you choose"
        case .searching: "Switch the XL-P801X on and close the phone app"
        case .connecting: printer.deviceName
        case .bluetoothOff: "Turn Bluetooth on in Control Centre"
        case .unauthorized: "System Settings › Privacy & Security › Bluetooth"
        }
    }
}

struct DropBox: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.showOpenPanel() } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.system(size: 26, weight: .light))
                Text("Drop PDFs, images or text").font(.callout.weight(.semibold))
                Text("or click to choose").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
}

struct FileList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FILES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clear() }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(model.files) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.printed ? "checkmark.circle.fill" : "doc")
                        .foregroundStyle(file.printed ? Color.green : Color.secondary)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(file.pages.count) p.").font(.caption).foregroundStyle(.secondary)
                    Button { model.remove(file) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

struct PreviewGrid: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let pages = model.files.flatMap(\.pages)
        Group {
            if pages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "printer").font(.system(size: 54, weight: .thin)).foregroundStyle(.tertiary)
                    Text("Drop files anywhere in this window\nor on the app icon in the Dock.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 28)], spacing: 32) {
                        ForEach(pages) { page in PageCard(page: page) }
                    }
                    .padding(28)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct PageCard: View {
    @EnvironmentObject private var model: AppModel
    let page: HeadPage

    var body: some View {
        let included = !model.skipped.contains(page.id)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { included },
                set: { on in if on { model.skipped.remove(page.id) } else { model.skipped.insert(page.id) } }
            )) {
                Text(page.label).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            Image(decorative: page.preview, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .background(.white)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .opacity(included ? 1 : 0.3)
        }
    }
}

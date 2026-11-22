import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct S1DriverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("S1 Driver", id: "main") {
            ContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.printer)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Document…") { delegate.model.showOpenPanel() }.keyboardShortcut("o")
                Button("Write by Hand") { delegate.model.addNote() }.keyboardShortcut("n")
            }
            CommandGroup(after: .pasteboard) {
                Button("Add from Clipboard") { delegate.model.addFromPasteboard() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Print") { delegate.model.printAll() }.keyboardShortcut("p")
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

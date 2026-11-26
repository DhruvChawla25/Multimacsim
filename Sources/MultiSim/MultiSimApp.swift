import SwiftUI

@main
struct MultiSimApp: App {
    @StateObject private var viewModel = CircuitEditorViewModel(preset: .seriesRLC50Hz)

    init() {
        // `MultiSim --export-png <folder>` renders every lab circuit to a PNG and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-png"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
            let code = MainActor.assumeIsolated { CircuitPrintExporter.exportAll(to: folder) }
            exit(code)
        }
    }

    var body: some Scene {
        WindowGroup("MULTIMACSIM") {
            ContentView(viewModel: viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Circuit") { viewModel.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { viewModel.openDocument() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save") { viewModel.saveDocument() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { viewModel.saveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

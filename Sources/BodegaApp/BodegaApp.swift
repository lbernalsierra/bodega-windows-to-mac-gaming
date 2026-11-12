import AppKit
import SwiftUI

@main
struct BodegaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Bodega", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nueva botella…") { model.showNewBottle = true }
                    .keyboardShortcut("n")
                Button("Ejecutar programa de Windows…") {
                    if let bottle = model.selectedBottle { model.chooseAndRun(in: bottle) }
                }
                .keyboardShortcut("o")
                .disabled(model.selectedBottle == nil)
                Divider()
                Button("Importar botella…") { model.importWithPanel() }
            }
        }

        Settings {
            EnginesSettingsView()
                .environment(model)
                .frame(width: 600, height: 440)
        }
    }
}

/// Recibe los .exe/.msi que se abren desde el Finder («Abrir con › Bodega»).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var queued: [URL] = []

    var model: AppModel? {
        didSet { flush() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // bodega://run?... llega de los accesos del Dock; el resto son ficheros .exe/.msi.
        queued.append(contentsOf: urls)
        flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func flush() {
        guard let model, !queued.isEmpty else { return }
        for url in queued where url.scheme == "bodega" { model.handleRunURL(url) }
        model.pendingFiles.append(contentsOf: queued.filter(\.isFileURL))
        queued.removeAll()
    }
}

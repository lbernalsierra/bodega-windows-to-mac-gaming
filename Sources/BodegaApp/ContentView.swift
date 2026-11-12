import BodegaCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            if let bottle = model.selectedBottle {
                BottleDetailView(bottle: bottle)
                    .id(bottle.id)
            } else {
                EmptyBottlesView()
            }
        }
        .task { await model.start() }
        .sheet(isPresented: $model.showNewBottle) {
            NewBottleSheet()
        }
        .sheet(isPresented: Binding(
            get: { !model.pendingFiles.isEmpty },
            set: { if !$0 { model.pendingFiles.removeAll() } }
        )) {
            OpenFilesSheet()
        }
        .alert(
            "Algo no ha ido bien",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("Aceptar", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

struct EmptyBottlesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Sin botellas", systemImage: "wineglass")
        } description: {
            if model.engines.isEmpty && !model.isLoadingEngines {
                Text("Antes necesitas un motor Wine. Bodega puede instalar el suyo, libre y gratuito.")
            } else {
                Text("Una botella es un Windows aislado donde instalar y ejecutar programas.")
            }
        } actions: {
            if model.engines.isEmpty && !model.isLoadingEngines {
                Button(model.engineInstallStatus ?? "Instalar el motor de Bodega (\(EngineInstaller.totalMegabytes) MB)") {
                    Task { await model.installBodegaEngine() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.engineInstallStatus != nil)
            } else {
                Button("Nueva botella…") { model.showNewBottle = true }
                    .buttonStyle(.borderedProminent)
            }
            SettingsLink { Text("Motores…") }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var bottlePendingTrash: Bottle?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Botellas") {
                ForEach(model.bottles) { bottle in
                    BottleRow(bottle: bottle)
                        .tag(bottle.id)
                        .contextMenu {
                            Button("Ejecutar programa…") { model.chooseAndRun(in: bottle) }
                            Button("Abrir unidad C:") { model.openDriveC(bottle) }
                            Divider()
                            Button("Exportar…") { model.exportWithPanel(bottle) }
                            Button("Mover a la Papelera…", role: .destructive) { bottlePendingTrash = bottle }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.showNewBottle = true
                } label: {
                    Label("Nueva botella", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Crear una botella nueva")
                Spacer()
                Button {
                    model.importWithPanel()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Importar una botella exportada")
            }
            .padding(10)
        }
        .confirmationDialog(
            "¿Mover «\(bottlePendingTrash?.name ?? "")» a la Papelera?",
            isPresented: Binding(get: { bottlePendingTrash != nil }, set: { if !$0 { bottlePendingTrash = nil } }),
            presenting: bottlePendingTrash
        ) { bottle in
            Button("Mover a la Papelera", role: .destructive) {
                Task { await model.moveToTrash(bottle) }
            }
        } message: { _ in
            Text("Se cerrarán sus programas. Podrás recuperarla desde la Papelera mientras no la vacíes.")
        }
    }
}

private struct BottleRow: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        let runningCount = model.running.filter { $0.bottleID == bottle.id }.count
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(bottle.name)
                Text(model.busy[bottle.id] ?? bottle.config.windowsVersion.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            if model.busy[bottle.id] != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "wineglass")
            }
        }
        .badge(runningCount)
    }
}

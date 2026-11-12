import BodegaCore
import SwiftUI

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var config = BottleConfig()

    private var nameError: String? {
        guard !name.isEmpty else { return nil }
        if model.bottles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "Ya hay una botella con ese nombre."
        }
        do { try BottleName.validate(name) } catch { return "Usa letras, números, espacios, guiones o puntos." }
        return nil
    }

    private var engine: WineEngine? {
        model.engines.first { $0.id == config.engineID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nueva botella")
                .font(.title2.bold())
                .padding([.top, .horizontal], 20)
            Form {
                TextField("Nombre", text: $name, prompt: Text("p. ej. Juegos u Office"))
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.red)
                }
                Picker("Motor Wine", selection: $config.engineID) {
                    ForEach(model.engines) { engine in
                        Text(engine.displayName).tag(Optional(engine.id))
                    }
                }
                Picker("Versión de Windows", selection: $config.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                }
                GraphicsPicker(selection: $config.graphics, engine: engine)
                Toggle("MSync (recomendado para juegos)", isOn: $config.msync)
                Toggle("Modo alta resolución (Retina)", isOn: $config.retinaMode)
            }
            .formStyle(.grouped)
            HStack {
                if model.engines.isEmpty {
                    Text("No hay motores Wine. Añade uno en Ajustes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crear") {
                    let chosen = config
                    let chosenName = name
                    dismiss()
                    Task { await model.createBottle(name: chosenName, config: chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || nameError != nil || config.engineID == nil)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            if config.engineID == nil { config.engineID = model.engines.first?.id }
        }
        .onChange(of: config.engineID) {
            if let engine, !engine.availableBackends.contains(config.graphics) { config.graphics = .automatic }
        }
    }
}

/// Aparece al abrir .exe/.msi desde el Finder: elige en qué botella ejecutarlos.
struct OpenFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bottleID: Bottle.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ejecutar con Bodega").font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.pendingFiles, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: "doc")
                }
            }
            if model.bottles.isEmpty {
                Text("Primero crea una botella.").foregroundStyle(.secondary)
            } else {
                Picker("Botella", selection: $bottleID) {
                    ForEach(model.bottles) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) {
                    model.pendingFiles.removeAll()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if model.bottles.isEmpty {
                    Button("Nueva botella…") {
                        dismiss()
                        model.showNewBottle = true
                    }
                } else {
                    Button("Ejecutar") {
                        if let bottle = model.bottles.first(where: { $0.id == bottleID }) {
                            model.run(model.pendingFiles, in: bottle)
                            model.selection = bottle.id
                        }
                        model.pendingFiles.removeAll()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bottleID == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { bottleID = model.selection ?? model.bottles.first?.id }
    }
}

struct EnginesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Motores Wine").font(.title2.bold())
                Spacer()
                if model.isLoadingEngines { ProgressView().controlSize(.small) }
                Button("Volver a buscar") { Task { await model.reloadEngines() } }
                Button("Añadir motor…") { model.addEngineWithPanel() }
                Button("Añadir D3DMetal…") { model.importD3DMetalWithPanel() }
                    .help("DirectX 11/12 → Metal, del Game Porting Toolkit que descargas gratis de Apple")
                    .disabled(model.d3dMetalStatus != nil)
            }
            BodegaEngineBanner()
            if let status = model.d3dMetalStatus ?? model.motorBuildStatus {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(status) }
            } else if !model.hasMotorBodega && EngineInstaller.isInstalled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Motor Bodega").bold()
                        Text("El Wine de CodeWeavers con MSync, compilado en tu Mac desde su código LGPL. Más FPS en juegos.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Compilar…") { Task { await model.buildMotorBodega() } }
                }
                .padding(12)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            List {
                ForEach(model.engines) { engine in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(engine.name).bold()
                            if EngineLocator.isBodegaEngine(engine) {
                                Text("Propio").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.blue.opacity(0.25), in: Capsule())
                            }
                            ForEach(engine.gamingBadges, id: \.self) { badge in
                                Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.green.opacity(0.2), in: Capsule())
                            }
                            Spacer()
                            if model.isCustom(engine) {
                                Button("Quitar") { model.removeCustomEngine(engine) }
                                    .buttonStyle(.link)
                            }
                        }
                        Text(engine.version ?? "versión desconocida").font(.caption).foregroundStyle(.secondary)
                        Text(engine.root.path).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 3)
                }
            }
            .overlay {
                if model.engines.isEmpty && !model.isLoadingEngines {
                    ContentUnavailableView("Sin motores", systemImage: "shippingbox", description: Text("Instala un Wine para macOS y pulsa «Volver a buscar»."))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Bodega funciona con cualquier Wine para macOS: los paquetes libres «Wine Stable/Devel» o una carpeta con `bin/wine` en \(Paths.engines.path).")
                Text("Motor Bodega es el Wine de CodeWeavers (con MSync) compilado aquí desde su código LGPL con engine/build-motor.sh; DXMT y DXVK van incluidos. D3DMetal (DirectX 12) es software de Apple: solo si la licencia de su Game Porting Toolkit te permite usarlo, descárgalo de developer.apple.com y pulsa «Añadir D3DMetal…».")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(20)
    }
}

/// Perfil de lanzamiento de un programa anclado: nombre, argumentos y variables propias.
struct ProgramProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    let program: PinnedProgram
    @State private var name: String
    @State private var arguments: String
    @State private var environment: String
    @State private var forceWineD3D: Bool

    init(bottle: Bottle, program: PinnedProgram) {
        self.bottle = bottle
        self.program = program
        _name = State(initialValue: program.name)
        _arguments = State(initialValue: program.arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        _environment = State(initialValue: BottleSettingsView.format(program.environment))
        _forceWineD3D = State(initialValue: program.forceWineD3D)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Perfil de «\(program.name)»")
                .font(.title2.bold())
                .padding([.top, .horizontal], 20)
            Form {
                TextField("Nombre", text: $name)
                LabeledContent("Programa") {
                    Text(program.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                TextField("Argumentos", text: $arguments, prompt: Text("p. ej. -dx11 -windowed"))
                Toggle(isOn: $forceWineD3D) {
                    Text("Forzar el Direct3D de Wine (WineD3D)")
                    Text("Para juegos que se ven en negro o se cierran con DXMT/DXVK. Se aplica a \(program.executableName) aunque lo abra Steam.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variables solo para este programa (CLAVE=valor)")
                    TextEditor(text: $environment)
                        .font(.body.monospaced())
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    Text("Ejemplos: DXVK_HUD=fps · MTL_HUD_ENABLED=1 · WINEDLLOVERRIDES=xinput1_3=n,b")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    var updated = program
                    updated.name = name.isEmpty ? program.name : name
                    updated.arguments = Self.splitArguments(arguments)
                    updated.environment = BottleSettingsView.parse(environment)
                    updated.forceWineD3D = forceWineD3D
                    model.updatePinned(updated, in: bottle)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    /// Separa por espacios respetando comillas dobles.
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Ofrece instalar el motor propio cuando falta, y muestra el progreso.
struct BodegaEngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let status = model.engineInstallStatus {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(status)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else if !EngineInstaller.isInstalled {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Motor de Bodega").bold()
                    Text("Wine 11.21 con DXMT y DXVK, de compilaciones libres verificadas.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Instalar (\(EngineInstaller.totalMegabytes) MB)") {
                    Task { await model.installBodegaEngine() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

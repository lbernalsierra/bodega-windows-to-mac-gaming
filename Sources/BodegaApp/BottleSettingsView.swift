import BodegaCore
import SwiftUI

/// Edita una copia de la configuración y la guarda al pulsar «Aplicar».
struct BottleSettingsView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @State private var draft: BottleConfig
    @State private var environmentText: String

    init(bottle: Bottle) {
        self.bottle = bottle
        _draft = State(initialValue: bottle.config)
        _environmentText = State(initialValue: Self.format(bottle.config.environment))
    }

    private var edited: BottleConfig {
        var config = draft
        config.environment = Self.parse(environmentText)
        // Los programas anclados se gestionan aparte; no se pisan desde aquí.
        config.pinnedPrograms = bottle.config.pinnedPrograms
        return config
    }

    private var isDirty: Bool { edited != bottle.config }

    private var selectedEngine: WineEngine? {
        model.engines.first { $0.id == draft.engineID } ?? model.engine(for: bottle)
    }

    var body: some View {
        Form {
            Section {
                Picker("Motor Wine", selection: $draft.engineID) {
                    ForEach(model.engines) { engine in
                        Text(engine.displayName).tag(Optional(engine.id))
                    }
                    if let id = draft.engineID, !model.engines.contains(where: { $0.id == id }) {
                        Text("No disponible (\(id))").tag(Optional(id))
                    }
                }
                Picker("Versión de Windows", selection: $draft.windowsVersion) {
                    ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                }
                GraphicsPicker(selection: $draft.graphics, engine: selectedEngine)
            }
            Section("Juegos") {
                Toggle(isOn: $draft.msync) {
                    Text("MSync")
                    Text("Sincronización rápida con puertos Mach de macOS. Mejora mucho los FPS en juegos con muchos hilos.")
                }
                Toggle(isOn: $draft.advertiseAVX) {
                    Text("Anunciar AVX en Rosetta")
                    Text("Muchos juegos recientes no arrancan sin AVX/AVX2.")
                }
                Toggle(isOn: $draft.metalHUD) {
                    Text("HUD de rendimiento de Metal")
                    Text("Muestra FPS, tiempo de fotograma y memoria de la GPU sobre el juego.")
                }
                Toggle(isOn: $draft.retinaMode) {
                    Text("Modo alta resolución (Retina)")
                    Text("Resolución nativa de la pantalla: más nitidez y más carga para la GPU.")
                }
            }
            Section {
                Toggle(isOn: $draft.startupPrograms) {
                    Text("Programas de inicio de Windows")
                    Text("Steam y Epic se apuntan para abrirse solos y quedarse en segundo plano. Desactivado, solo se abre lo que tú lances.")
                }
                Toggle("ESync (alternativa a MSync)", isOn: $draft.esync)
                TextField("Canales de depuración (WINEDEBUG)", text: $draft.debugChannels, prompt: Text("-all"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variables de entorno (una por línea, CLAVE=valor)")
                    TextEditor(text: $environmentText)
                        .font(.body.monospaced())
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
            } header: {
                Text("Avanzado")
            } footer: {
                HStack {
                    Spacer()
                    Button("Descartar") {
                        draft = bottle.config
                        environmentText = Self.format(bottle.config.environment)
                    }
                    .disabled(!isDirty)
                    Button("Aplicar cambios") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty || model.busy[bottle.id] != nil)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .padding(.horizontal, -20)
    }

    private func apply() {
        var updated = bottle
        updated.config = edited
        let old = bottle.config
        // Solo estos ajustes necesitan ejecutar órdenes dentro de Wine; el resto es entorno.
        let needsWine = old.windowsVersion != updated.config.windowsVersion
            || old.retinaMode != updated.config.retinaMode
            || old.graphics != updated.config.graphics
            || old.engineID != updated.config.engineID
        Task { await model.update(updated, applyInWine: needsWine && bottle.isInitialized) }
    }

    static func format(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !key.isEmpty, !key.hasPrefix("#") else { continue }
            result[key] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        return result
    }
}

/// Selector de traductor Direct3D: solo ofrece lo que trae el motor y explica qué se usará.
struct GraphicsPicker: View {
    @Binding var selection: GraphicsBackend
    let engine: WineEngine?

    private var available: [GraphicsBackend] { engine?.availableBackends ?? [.automatic, .wined3d] }

    var body: some View {
        Picker("Gráficos Direct3D", selection: $selection) {
            ForEach(available) { Text($0.displayName).tag($0) }
            if !available.contains(selection) {
                Text("\(selection.displayName) (no disponible)").tag(selection)
            }
        }
        if let engine {
            let plan = GraphicsResolver.plan(for: selection, engine: engine)
            LabeledContent("Se usará") {
                Text(plan.summary).foregroundStyle(.secondary)
            }
            if engine.d3dMetalDirectory == nil {
                Text("D3DMetal (necesario para muchos juegos DirectX 12) requiere un motor con el Game Porting Toolkit de Apple. Consulta Ajustes › Motores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

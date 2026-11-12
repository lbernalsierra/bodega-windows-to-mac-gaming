import BodegaCore
import SwiftUI

struct BottleDetailView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @State private var isDropTargeted = false
    @State private var editingProfile: PinnedProgram?

    private var programs: BottlePrograms { model.programs[bottle.id] ?? BottlePrograms() }
    private var running: [RunningProgram] { model.running.filter { $0.bottleID == bottle.id } }
    private var isBusy: Bool { model.busy[bottle.id] != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !bottle.isInitialized && !isBusy {
                    Label("Esta botella aún no tiene Windows instalado. Revisa el motor en Ajustes y vuelve a crearla.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !programs.steamGames.isEmpty { steamGamesSection }
                programsSection
                if !running.isEmpty { runningSection }
                storesSection
                dependenciesSection
                toolsSection
                SectionHeader("Ajustes")
                BottleSettingsView(bottle: bottle)
                    .id(bottle.config)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(bottle.name)
        .navigationSubtitle(model.busy[bottle.id] ?? model.engine(for: bottle)?.displayName ?? "Sin motor")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.chooseAndRun(in: bottle)
                } label: {
                    Label("Ejecutar…", systemImage: "play.fill")
                }
                .help("Ejecutar un instalador o programa de Windows en esta botella")
                .disabled(isBusy)

                Button {
                    model.openDriveC(bottle)
                } label: {
                    Label("Unidad C:", systemImage: "internaldrive")
                }
                .help("Abrir la unidad C: de la botella en el Finder")

                Button {
                    Task { await model.killAll(bottle) }
                } label: {
                    Label("Cerrar todo", systemImage: "stop.circle")
                }
                .help("Forzar el cierre de todos los programas de esta botella")

                Menu {
                    Button("Ver registros") { model.openLogs(bottle) }
                    Button("Volver a buscar programas") { Task { await model.scanPrograms(bottle) } }
                    Divider()
                    Button("Exportar botella…") { model.exportWithPanel(bottle) }
                } label: {
                    Label("Más", systemImage: "ellipsis.circle")
                }
            }
        }
        .task {
            // Steam instala juegos por su cuenta: se vuelve a mirar cada pocos segundos.
            while !Task.isCancelled {
                await model.scanPrograms(bottle)
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(item: $editingProfile) { program in
            ProgramProfileSheet(bottle: bottle, program: program)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { LaunchTarget.supportedExtensions.contains($0.pathExtension.lowercased()) }
            model.run(supported, in: bottle)
            return !supported.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .overlay(Text("Suelta para ejecutar en «\(bottle.name)»").font(.title3.bold()))
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: [Color(red: 0.55, green: 0.1, blue: 0.25), Color(red: 0.3, green: 0.05, blue: 0.15)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(bottle.name).font(.title.bold())
                Text("\(bottle.config.windowsVersion.displayName) · \(model.graphicsSummary(for: bottle))")
                    .foregroundStyle(.secondary)
                if let status = model.busy[bottle.id] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status)
                    }
                    .font(.callout)
                }
            }
            Spacer()
        }
    }

    private var programsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Programas") {
                Button("Anclar programa…") { model.pinWithPanel(in: bottle) }
                    .buttonStyle(.link)
            }
            let pinned = bottle.config.pinnedPrograms
            let shortcuts = programs.shortcuts.filter { program in
                !pinned.contains { $0.relativePath == bottle.relativePath(of: program.url) }
            }
            if pinned.isEmpty && shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Todavía no hay programas. Arrastra un instalador (.exe o .msi) aquí o pulsa «Ejecutar…».")
                        .foregroundStyle(.secondary)
                    Button("Instalar un programa…") { model.chooseAndRun(in: bottle) }
                        .disabled(isBusy)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(pinned) { item in
                        ProgramTile(title: item.name, systemImage: item.arguments.isEmpty && item.environment.isEmpty ? "pin.fill" : "slider.horizontal.below.square.filled.and.square",
                                    icon: model.icon(for: item.url(in: bottle), in: bottle)) {
                            model.launch(item, in: bottle)
                        }
                        .contextMenu {
                            Button("Perfil de lanzamiento…") { editingProfile = item }
                            Button("Crear acceso en el Mac") {
                                model.createMacShortcut(name: item.name, program: item.url(in: bottle), arguments: item.arguments,
                                                        icon: model.icon(for: item.url(in: bottle), in: bottle), in: bottle)
                            }
                            Button("Desanclar") { model.unpin(item, in: bottle) }
                            Button("Mostrar en el Finder") { model.reveal(item.url(in: bottle)) }
                        }
                    }
                    ForEach(shortcuts) { program in
                        ProgramTile(title: program.name, systemImage: "macwindow", icon: model.icon(for: program.url, in: bottle)) {
                            model.launch(.shortcut(program.url), in: bottle)
                        }
                        .contextMenu {
                            Button("Anclar") { model.pin(program, in: bottle) }
                            Button("Crear acceso en el Mac") {
                                model.createMacShortcut(name: program.name, program: program.url, icon: model.icon(for: program.url, in: bottle), in: bottle)
                            }
                            Button("Mostrar en el Finder") { model.reveal(program.url) }
                        }
                    }
                }
            }
            if !programs.executables.isEmpty {
                DisclosureGroup("Ejecutables encontrados en Program Files (\(programs.executables.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(programs.executables) { program in
                            HStack {
                                Image(systemName: "gearshape.2").foregroundStyle(.secondary)
                                Text(program.name)
                                Text(bottle.relativePath(of: program.url) ?? program.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("Anclar") { model.pin(program, in: bottle) }
                                Button("Ejecutar") { model.launch(.executable(program.url), in: bottle) }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("En ejecución")
            ForEach(running) { program in
                HStack {
                    ProgressView().controlSize(.small)
                    Text(program.name).bold()
                    Text("pid \(program.pid) · desde \(program.started.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Registro") { NSWorkspace.shared.open(program.logURL) }
                    Button("Terminar") { program.terminate() }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var steamGamesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Juegos de Steam")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16)], alignment: .leading, spacing: 18) {
                ForEach(programs.steamGames) { game in
                    let wineD3D = model.usesWineD3D(game, in: bottle)
                    SteamGameCard(game: game, usesWineD3D: wineD3D) {
                        model.play(game, in: bottle)
                    }
                    .contextMenu {
                        Button("Jugar") { model.play(game, in: bottle) }
                        Toggle("Usar el Direct3D de Wine (si se ve en negro o se cierra)", isOn: Binding(
                            get: { wineD3D },
                            set: { model.setWineD3D($0, for: game, in: bottle) }
                        ))
                        .disabled(game.executables.isEmpty)
                        Button("Crear acceso en el Mac") { model.createMacShortcut(for: game, in: bottle) }
                        Divider()
                        Button("Mostrar en el Finder") { model.reveal(game.installDirectory) }
                    }
                    .disabled(!game.isInstalled)
                }
            }
        }
    }

    private var storesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Tiendas de juegos")
            Text("Descarga el instalador oficial y lo ejecuta en esta botella.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(GameStore.allCases) { store in
                    Button {
                        Task { await model.install(store, in: bottle) }
                    } label: {
                        Label(store.displayName, systemImage: store.symbolName)
                    }
                    .controlSize(.large)
                    .disabled(isBusy || !bottle.isInitialized)
                }
            }
        }
    }

    private var dependenciesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Componentes de Windows")
            Text("Para juegos y programas de fuera de Steam que los pidan (Steam ya instala los suyos). .NET va incluido con Wine Mono.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(WindowsDependency.allCases) { dependency in
                    Button {
                        Task { await model.install(dependency, in: bottle) }
                    } label: {
                        Label(dependency.displayName, systemImage: dependency.symbolName)
                    }
                    .help(dependency.detail)
                    .controlSize(.large)
                    .disabled(isBusy || !bottle.isInitialized)
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Herramientas de Windows")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(WineTool.allCases) { tool in
                    Button {
                        model.launch(.tool(tool), in: bottle)
                    } label: {
                        Label(tool.displayName, systemImage: tool.symbolName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.large)
                    .disabled(isBusy || !bottle.isInitialized)
                }
            }
        }
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

struct ProgramTile: View {
    let title: String
    let systemImage: String
    var icon: NSImage? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(6)
                    } else {
                        Image(systemName: systemImage).font(.system(size: 26))
                    }
                }
                .frame(width: 54, height: 54)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text(title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 112, height: 108)
            .background(isHovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Abrir \(title)")
    }
}

struct SteamGameCard: View {
    let game: SteamGame
    let usesWineD3D: Bool
    let play: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    cover
                        .frame(width: 132, height: 198)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 10 : 4, y: 3)
                    if isHovered && game.isInstalled {
                        Label("Jugar", systemImage: "play.fill")
                            .font(.callout.bold())
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 10)
                    }
                }
                Text(game.name).font(.callout).lineLimit(1)
                Group {
                    if !game.isInstalled {
                        Text("Instalando…")
                    } else if usesWineD3D {
                        Text("Direct3D de Wine")
                    } else if let lastPlayed = game.lastPlayed {
                        Text("Jugado \(lastPlayed.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Sin jugar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(width: 132)
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(.snappy(duration: 0.18), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(game.isInstalled ? "Jugar a \(game.name)" : "\(game.name) se está instalando en Steam")
    }

    @ViewBuilder private var cover: some View {
        if let url = game.coverArt ?? game.headerArt, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.24), Color(red: 0.06, green: 0.08, blue: 0.12)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 30))
                    Text(game.name).font(.caption.bold()).multilineTextAlignment(.center).padding(.horizontal, 8)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

import AppKit
import BodegaCore
import Observation
import UniformTypeIdentifiers

struct BottlePrograms: Sendable {
    var shortcuts: [DiscoveredProgram] = []
    var executables: [DiscoveredProgram] = []
    var steam: SteamInstallation?
    var steamGames: [SteamGame] = []
}

/// Estado de la app. Toda la UI lee y escribe a través de aquí.
@MainActor
@Observable
final class AppModel {
    var engines: [WineEngine] = []
    var bottles: [Bottle] = []
    var selection: Bottle.ID?
    var programs: [Bottle.ID: BottlePrograms] = [:]
    var running: [RunningProgram] = []
    var busy: [Bottle.ID: String] = [:]
    var errorMessage: String?
    var pendingFiles: [URL] = []
    var isLoadingEngines = false
    var showNewBottle = false
    /// Mensaje del instalador del motor mientras trabaja.
    var engineInstallStatus: String?
    /// Mensaje mientras se añade D3DMetal.
    var d3dMetalStatus: String?
    /// Mensaje mientras se compila Motor Bodega.
    var motorBuildStatus: String?
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()

    private let store = BottleStore()
    private let defaults = UserDefaults.standard

    static let windowsFileTypes: [UTType] = LaunchTarget.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    var selectedBottle: Bottle? { bottles.first { $0.id == selection } }

    var customEngineRoots: [URL] {
        get { (defaults.stringArray(forKey: "customEngineRoots") ?? []).map { URL(filePath: $0) } }
        set { defaults.set(newValue.map(\.path), forKey: "customEngineRoots") }
    }

    // MARK: - Carga

    func start() async {
        reloadBottles()
        if selection == nil { selection = bottles.first?.id }
        await reloadEngines()
    }

    func reloadBottles() {
        do {
            bottles = try store.list()
        } catch {
            report(error)
        }
        if let selection, !bottles.contains(where: { $0.id == selection }) {
            self.selection = bottles.first?.id
        }
    }

    func reloadEngines() async {
        isLoadingEngines = true
        let roots = customEngineRoots
        engines = await Task.detached { EngineLocator.discover(customRoots: roots) }.value
        isLoadingEngines = false
    }

    func scanPrograms(_ bottle: Bottle) async {
        let found = await Task.detached {
            (ProgramScanner.scan(bottle), SteamLibrary.installation(in: bottle), SteamLibrary.games(in: bottle))
        }.value
        programs[bottle.id] = BottlePrograms(shortcuts: found.0.shortcuts, executables: found.0.executables, steam: found.1, steamGames: found.2)
    }

    // MARK: - Motores

    func engine(for bottle: Bottle) -> WineEngine? {
        if let id = bottle.config.engineID {
            if let match = engines.first(where: { $0.id == id }) { return match }
            if let engine = EngineLocator.engine(at: URL(filePath: id)) { return engine }
        }
        return engines.first
    }

    func addEngineWithPanel() {
        let panel = NSOpenPanel()
        panel.message = "Elige una carpeta de Wine (con bin/wine) o una app como «Wine Stable.app»."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard EngineLocator.engine(at: url) != nil else {
            errorMessage = "No hay un motor Wine reconocible en \(url.path)."
            return
        }
        var roots = customEngineRoots
        if !roots.contains(url) { roots.append(url) }
        customEngineRoots = roots
        Task { await reloadEngines() }
    }

    /// Descarga e instala el motor propio de Bodega (Wine + DXMT + DXVK, componentes libres).
    func installBodegaEngine() async {
        guard engineInstallStatus == nil else { return }
        engineInstallStatus = "Preparando…"
        do {
            try await EngineInstaller.install { message in
                Task { @MainActor [weak self] in
                    if self?.engineInstallStatus != nil { self?.engineInstallStatus = message }
                }
            }
            engineInstallStatus = nil
            await reloadEngines()
        } catch {
            engineInstallStatus = nil
            report(error)
        }
    }

    var hasMotorBodega: Bool { engines.contains { $0.root.path.contains("/Motor Bodega") } }

    /// Compila Motor Bodega (Wine de CodeWeavers con MSync) con el script incluido en la app.
    func buildMotorBodega() async {
        guard motorBuildStatus == nil, let script = Bundle.main.url(forResource: "build-motor", withExtension: "sh") else { return }
        motorBuildStatus = "Compilando Motor Bodega (unos 15 minutos)…"
        defer { motorBuildStatus = nil }
        let log = Paths.defaultHome.appending(path: "build-motor.log")
        do {
            let output = try await ProcessRunner.run(executable: URL(filePath: "/bin/zsh"), arguments: [script.path], environment: ProcessInfo.processInfo.environment)
            try? output.output.write(to: log, atomically: true, encoding: .utf8)
            guard output.status == 0 else {
                throw BodegaError.commandFailed(command: "build-motor.sh (registro: \(log.path))", status: output.status, output: output.output)
            }
            await reloadEngines()
        } catch {
            report(error)
        }
    }

    /// Importa D3DMetal del Game Porting Toolkit que el usuario ha descargado de Apple.
    func importD3DMetalWithPanel() {
        guard let base = engines.first(where: { EngineLocator.isBodegaEngine($0) && $0.d3dMetalDirectory == nil }) ?? engines.first else {
            report(BodegaError.noEngine)
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Elige el Game Porting Toolkit de Apple (.dmg o su carpeta). Se descarga gratis con tu cuenta de Apple."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.diskImage, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            d3dMetalStatus = "Preparando…"
            defer { d3dMetalStatus = nil }
            do {
                try await D3DMetalInstaller.install(from: url, basedOn: base) { message in
                    Task { @MainActor [weak self] in if self?.d3dMetalStatus != nil { self?.d3dMetalStatus = message } }
                }
                await reloadEngines()
            } catch {
                report(error)
            }
        }
    }

    func removeCustomEngine(_ engine: WineEngine) {
        customEngineRoots = customEngineRoots.filter { EngineLocator.engine(at: $0)?.id != engine.id }
        Task { await reloadEngines() }
    }

    func isCustom(_ engine: WineEngine) -> Bool {
        customEngineRoots.contains { EngineLocator.engine(at: $0)?.id == engine.id }
    }

    // MARK: - Botellas

    func createBottle(name: String, config: BottleConfig) async {
        do {
            var config = config
            if config.engineID == nil { config.engineID = engines.first?.id }
            guard config.engineID != nil else { throw BodegaError.noEngine }
            let bottle = try store.prepareNewBottle(named: name, config: config)
            reloadBottles()
            selection = bottle.id
            await perform("Creando la botella…", on: bottle) { try await $0.initializePrefix() }
            await scanPrograms(bottle)
        } catch {
            report(error)
        }
    }

    /// Guarda la configuración y, si hace falta, la aplica dentro de Wine.
    func update(_ bottle: Bottle, applyInWine: Bool) async {
        do {
            try store.save(bottle)
        } catch {
            report(error)
            return
        }
        reloadBottles()
        if applyInWine {
            await perform("Aplicando ajustes…", on: bottle) { try await $0.applySettings() }
        }
    }

    func killAll(_ bottle: Bottle) async {
        await perform("Cerrando procesos…", on: bottle) { try await $0.killAll() }
        running.removeAll { !$0.isRunning }
    }

    func moveToTrash(_ bottle: Bottle) async {
        if let runner = try? runner(for: bottle) { _ = try? await runner.killAll() }
        do {
            try store.moveToTrash(bottle)
            programs[bottle.id] = nil
            reloadBottles()
        } catch {
            report(error)
        }
    }

    func exportWithPanel(_ bottle: Bottle) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(bottle.name).tar.gz"
        panel.message = "Exporta la botella completa para copiarla o guardarla."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busy[bottle.id] = "Exportando…"
            defer { busy[bottle.id] = nil }
            do { try await store.export(bottle, to: url) } catch { report(error) }
        }
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gzip]
        panel.message = "Elige una botella exportada por Bodega (.tar.gz)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bottle = try await store.importArchive(url)
                reloadBottles()
                selection = bottle.id
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Programas

    func chooseAndRun(in bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.windowsFileTypes
        panel.allowsMultipleSelection = true
        panel.message = "Elige un instalador o programa de Windows (.exe, .msi, .bat, .lnk)."
        guard panel.runModal() == .OK else { return }
        run(panel.urls, in: bottle)
    }

    func run(_ files: [URL], in bottle: Bottle) {
        for file in files where LaunchTarget.supportedExtensions.contains(file.pathExtension.lowercased()) {
            launch(LaunchTarget(file: file), in: bottle)
        }
    }

    func launch(_ target: LaunchTarget, in bottle: Bottle, arguments: [String] = [], environment: [String: String] = [:]) {
        Task { await launchNow(target, in: bottle, arguments: arguments, environment: environment) }
    }

    private func launchNow(_ target: LaunchTarget, in bottle: Bottle, arguments: [String], environment: [String: String]) async {
        do {
            let runner = try runner(for: bottle)
            let bottleID = bottle.id
            let started = Date()
            let program = try await runner.launch(target, arguments: arguments, environment: environment) { [weak self] _ in
                Task { @MainActor in self?.programExited(in: bottleID) }
            }
            running.append(program)
            await handOverFocus(to: program, engineRoot: runner.engine.root, since: started)
        } catch {
            report(error)
        }
    }

    /// Desde macOS 14 una app solo pasa al frente si la activa le cede el turno. Sin esto,
    /// el juego se ve pero no recibe clics ni teclado (le pasó a Bulb Boy al lanzarlo en segundo plano).
    private func handOverFocus(to program: RunningProgram, engineRoot: URL, since started: Date) async {
        let enginePath = engineRoot.resolvingSymlinksInPath().path
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            let candidates = NSWorkspace.shared.runningApplications.filter { app in
                if app.processIdentifier == program.pid { return true }
                // Los accesos directos (.lnk) arrancan el programa como proceso hijo de Wine.
                guard app.bundleIdentifier == nil, let launched = app.launchDate, launched >= started.addingTimeInterval(-1) else { return false }
                return app.executableURL?.resolvingSymlinksInPath().path.hasPrefix(enginePath) == true
            }
            if let app = candidates.first(where: { $0.activationPolicy == .regular }) {
                NSApp.yieldActivation(to: app)
                app.activate()
                return
            }
            if !program.isRunning { return }
        }
    }

    func launch(_ pinned: PinnedProgram, in bottle: Bottle) {
        launch(LaunchTarget(file: pinned.url(in: bottle)), in: bottle, arguments: pinned.arguments, environment: pinned.environment)
    }

    func graphicsSummary(for bottle: Bottle) -> String {
        guard let engine = engine(for: bottle) else { return bottle.config.graphics.displayName }
        return GraphicsResolver.plan(for: bottle.config.graphics, engine: engine).summary
    }

    /// Descarga el instalador oficial de la tienda y lo ejecuta en la botella.
    func install(_ store: GameStore, in bottle: Bottle) async {
        busy[bottle.id] = "Descargando \(store.displayName)…"
        do {
            let installer = try await store.downloadInstaller(into: bottle)
            busy[bottle.id] = nil
            launch(LaunchTarget(file: installer), in: bottle)
        } catch {
            busy[bottle.id] = nil
            report(error)
        }
    }

    /// Lanza un juego a través del Steam de la botella.
    func play(_ game: SteamGame, in bottle: Bottle) {
        guard let steam = programs[bottle.id]?.steam ?? SteamLibrary.installation(in: bottle) else { return }
        launch(.executable(steam.steamExecutable), in: bottle, arguments: SteamLibrary.launchArguments(for: game))
    }

    func usesWineD3D(_ game: SteamGame, in bottle: Bottle) -> Bool {
        let forced = Set(bottle.config.wineD3DExecutables.map { $0.lowercased() })
        return !game.executableNames.isEmpty && game.executableNames.allSatisfy { forced.contains($0.lowercased()) }
    }

    /// Activa o quita el Direct3D de Wine para todos los ejecutables del juego.
    func setWineD3D(_ enabled: Bool, for game: SteamGame, in bottle: Bottle) {
        var updated = bottle
        let names = Set(game.executableNames.map { $0.lowercased() })
        updated.config.wineD3DExecutables.removeAll { names.contains($0.lowercased()) }
        if enabled { updated.config.wineD3DExecutables += game.executableNames }
        Task { await update(updated, applyInWine: false) }
    }

    // MARK: - Iconos y accesos en el Mac

    /// Icono de un programa de Windows (del .exe o del destino del .lnk), en caché.
    func icon(for url: URL, in bottle: Bottle) -> NSImage? {
        let key = url.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        guard let ico = ProgramIcons.icoData(for: url, in: bottle), let image = NSImage(data: ico) else { return nil }
        iconCache.setObject(image, forKey: key)
        return image
    }

    func createMacShortcut(name: String, program: URL, arguments: [String] = [], icon: NSImage?, in bottle: Bottle) {
        do {
            let app = try MacShortcuts.create(name: name, bottle: bottle, program: program, arguments: arguments, icon: icon)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            report(error)
        }
    }

    func createMacShortcut(for game: SteamGame, in bottle: Bottle) {
        guard let steam = programs[bottle.id]?.steam else { return }
        let cover = (game.coverArt ?? game.headerArt).flatMap { NSImage(contentsOf: $0) }
        createMacShortcut(name: game.name, program: steam.steamExecutable, arguments: SteamLibrary.launchArguments(for: game), icon: cover, in: bottle)
    }

    /// Abre `bodega://run?bottle=…&path=…&arg=…` (lo usan los accesos del Dock y el Launchpad).
    func handleRunURL(_ url: URL) {
        guard url.scheme == "bodega", url.host == "run",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let bottleName = items.first(where: { $0.name == "bottle" })?.value,
              let path = items.first(where: { $0.name == "path" })?.value else { return }
        reloadBottles()
        guard let bottle = bottles.first(where: { $0.name == bottleName }) else {
            report(BodegaError.bottleNotFound(bottleName))
            return
        }
        let arguments = items.filter { $0.name == "arg" }.compactMap(\.value)
        let pinned = bottle.config.pinnedPrograms.first { $0.url(in: bottle).path == path }
        selection = bottle.id
        Task {
            if engines.isEmpty { await reloadEngines() }
            launch(LaunchTarget(file: URL(filePath: path)), in: bottle, arguments: arguments.isEmpty ? (pinned?.arguments ?? []) : arguments, environment: pinned?.environment ?? [:])
        }
    }

    // MARK: - Componentes de Windows

    func install(_ dependency: WindowsDependency, in bottle: Bottle) async {
        guard let runner = try? runner(for: bottle) else { report(BodegaError.noEngine); return }
        busy[bottle.id] = "\(dependency.displayName)…"
        defer { busy[bottle.id] = nil }
        do {
            try await dependency.install(in: runner) { message in
                Task { @MainActor [weak self] in if self?.busy[bottle.id] != nil { self?.busy[bottle.id] = message } }
            }
        } catch {
            report(error)
        }
    }

    func updatePinned(_ program: PinnedProgram, in bottle: Bottle) {
        var updated = bottle
        guard let index = updated.config.pinnedPrograms.firstIndex(where: { $0.id == program.id }) else { return }
        updated.config.pinnedPrograms[index] = program
        Task { await update(updated, applyInWine: false) }
    }

    private func programExited(in bottleID: Bottle.ID) {
        running.removeAll { !$0.isRunning }
        // Un instalador puede haber creado accesos directos nuevos.
        if let bottle = bottles.first(where: { $0.id == bottleID }) {
            Task { await scanPrograms(bottle) }
        }
    }

    func pin(_ program: DiscoveredProgram, in bottle: Bottle) {
        pinFile(program.url, name: program.name, in: bottle)
    }

    func pinWithPanel(in bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.windowsFileTypes
        panel.directoryURL = bottle.driveC
        panel.message = "Elige un programa de esta botella para anclarlo."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pinFile(url, name: url.deletingPathExtension().lastPathComponent, in: bottle)
    }

    private func pinFile(_ url: URL, name: String, in bottle: Bottle) {
        guard let relative = bottle.relativePath(of: url) else {
            errorMessage = "Solo se pueden anclar programas que estén dentro de la botella."
            return
        }
        var updated = bottle
        guard !updated.config.pinnedPrograms.contains(where: { $0.relativePath == relative }) else { return }
        updated.config.pinnedPrograms.append(PinnedProgram(name: name, relativePath: relative))
        Task { await update(updated, applyInWine: false) }
    }

    func unpin(_ pinned: PinnedProgram, in bottle: Bottle) {
        var updated = bottle
        updated.config.pinnedPrograms.removeAll { $0.id == pinned.id }
        Task { await update(updated, applyInWine: false) }
    }

    // MARK: - Utilidades

    func openDriveC(_ bottle: Bottle) {
        NSWorkspace.shared.open(bottle.driveC)
    }

    func openLogs(_ bottle: Bottle) {
        try? FileManager.default.createDirectory(at: bottle.logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(bottle.logsDirectory)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func runner(for bottle: Bottle) throws -> WineRunner {
        guard let engine = engine(for: bottle) else { throw BodegaError.noEngine }
        return WineRunner(engine: engine, bottle: bottle)
    }

    private func perform(_ message: String, on bottle: Bottle, _ work: @Sendable (WineRunner) async throws -> Void) async {
        busy[bottle.id] = message
        defer { busy[bottle.id] = nil }
        do {
            try await work(try runner(for: bottle))
        } catch {
            report(error)
        }
    }
}

import Foundation

/// Ejecuta Wine dentro de una botella concreta con un motor concreto.
public struct WineRunner: Sendable {
    public let engine: WineEngine
    public let bottle: Bottle

    public init(engine: WineEngine, bottle: Bottle) {
        self.engine = engine
        self.bottle = bottle
    }

    /// Variables que Bodega controla y que no se heredan del entorno del usuario.
    static let managedKeys = [
        "WINEPREFIX", "WINESERVER", "WINELOADER", "WINEDLLPATH", "WINEDLLOVERRIDES",
        "WINEARCH", "WINEDEBUG", "WINEMSYNC", "WINEESYNC", "MTL_HUD_ENABLED", "ROSETTA_ADVERTISE_AVX", "DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN",
    ]

    /// Traductores Direct3D efectivos para esta botella con este motor.
    public var graphicsPlan: GraphicsPlan {
        GraphicsResolver.plan(for: bottle.config.graphics, engine: engine)
    }

    /// Entorno de cada proceso Wine de la botella. `program` añade el perfil propio
    /// de un programa anclado (sus variables ganan a las de la botella).
    public func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        program: [String: String] = [:]
    ) -> [String: String] {
        let config = bottle.config
        let plan = graphicsPlan
        var env = base
        for key in Self.managedKeys { env.removeValue(forKey: key) }

        env["WINEPREFIX"] = bottle.url.path
        env["WINEDEBUG"] = config.debugChannels.isEmpty ? "-all" : config.debugChannels
        env["WINESERVER"] = engine.wineserver.path
        let dllPath = plan.dllPathAdditions + engine.dllSearchPath
        if !dllPath.isEmpty {
            env["WINEDLLPATH"] = dllPath.map(\.path).joined(separator: ":")
        }
        env.merge(engine.extraEnvironment) { _, new in new }
        if config.msync { env["WINEMSYNC"] = "1" }
        if config.esync { env["WINEESYNC"] = "1" }
        if config.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        // Chromium (Steam, Epic…) pinta desde su proceso de GPU en ventanas de otro proceso:
        // DXMT solo lo permite con esta variable; sin ella la interfaz se cierra o queda negra.
        if plan.backend == .dxmt { env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] = "1" }
        if config.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }

        // Los overrides gráficos van al registro (ver `prepareGraphics`); aquí solo los que
        // no deben poder cambiarse por programa y los que añada el usuario.
        var overrides = DllOverrides()
        // Bodega gestiona sus propios accesos directos: Wine no debe crear menús en el Mac.
        overrides["winemenubuilder.exe"] = "d"
        // Los overrides se suman por capas (botella y luego programa); el resto se sustituye.
        var bottleEnvironment = config.environment
        var programEnvironment = program
        for layer in [bottleEnvironment.removeValue(forKey: "WINEDLLOVERRIDES"), programEnvironment.removeValue(forKey: "WINEDLLOVERRIDES")] {
            if let layer { overrides.merge(parsing: layer) }
        }
        let custom = bottleEnvironment.merging(programEnvironment) { _, new in new }
        env["WINEDLLOVERRIDES"] = overrides.description
        env.merge(custom) { _, new in new }
        return env
    }

    // MARK: - Ejecución

    /// Antes de arrancar Wine: con la botella parada, aparta o restaura los programas de inicio.
    public func prepareSession() {
        if bottle.config.startupPrograms {
            _ = try? StartupItems.restore(in: bottle)
        } else {
            _ = try? StartupItems.disable(in: bottle)
        }
    }

    @discardableResult
    public func runAndWait(_ arguments: [String], workingDirectory: URL? = nil, check: Bool = true) async throws -> ProcessOutput {
        prepareSession()
        let output = try await ProcessRunner.run(
            executable: engine.loader,
            arguments: arguments,
            environment: environment(),
            workingDirectory: workingDirectory
        )
        if check, output.status != 0 {
            throw BodegaError.commandFailed(command: "wine " + arguments.joined(separator: " "), status: output.status, output: output.output)
        }
        return output
    }

    /// Lanza un programa sin esperar. Su salida se guarda en `logs/` de la botella.
    public func launch(
        _ target: LaunchTarget,
        arguments extra: [String] = [],
        environment programEnvironment: [String: String] = [:],
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) async throws -> RunningProgram {
        let fm = FileManager.default
        let plan = graphicsPlan
        prepareSession()
        if bottle.isInitialized {
            try await prepareGraphics()
        }
        try fm.createDirectory(at: bottle.logsDirectory, withIntermediateDirectories: true)
        let stamp = Self.logDateFormatter.string(from: Date())
        let safeName = target.displayName.replacingOccurrences(of: "/", with: "-")
        let logURL = bottle.logsDirectory.appending(path: "\(stamp) \(safeName).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let (arguments, workingDirectory) = target.wineArguments(extra: extra, windowsPath: bottle.windowsPath(for:))
        let header = "# \(Date())\n# \(engine.displayName)\n# Gráficos: \(plan.summary)\n# wine \(arguments.joined(separator: " "))\n\n"
        log.write(Data(header.utf8))

        let process = Process()
        process.executableURL = engine.loader
        process.arguments = arguments
        process.environment = environment(program: programEnvironment)
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            try? log.close()
            onExit(finished.terminationStatus)
        }
        try process.run()
        return RunningProgram(name: target.displayName, bottleID: bottle.id, logURL: logURL, process: process)
    }

    // MARK: - Ciclo de vida de la botella

    /// Crea el prefijo de Wine (drive_c, registro…) y aplica los ajustes.
    public func initializePrefix() async throws {
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        try await runAndWait(["wineboot", "--init"])
        try await waitForServer()
        try await applySettings()
    }

    /// Aplica versión de Windows, modo Retina y traductores Direct3D según `bodega.json`.
    public func applySettings() async throws {
        let config = bottle.config
        try await runAndWait(["winecfg", "/v", config.windowsVersion.rawValue])
        try await runAndWait([
            "reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
            "/v", "RetinaMode", "/t", "REG_SZ", "/d", config.retinaMode ? "y" : "n", "/f",
        ])
        // En modo Retina Windows ve los píxeles reales (p. ej. 3024×1964): se dobla la escala
        // (192 ppp) para que menús y lanzadores no queden diminutos; los juegos usan la resolución nativa.
        try await runAndWait([
            "reg", "add", #"HKCU\Control Panel\Desktop"#,
            "/v", "LogPixels", "/t", "REG_DWORD", "/d", config.retinaMode ? "192" : "96", "/f",
        ])
        try await waitForServer()
        try await prepareGraphics(force: true)
    }

    var graphicsMarker: URL { bottle.url.appending(path: ".bodega-graphics.reg") }

    /// Deja la botella lista para el plan gráfico: DLL nativas copiadas y overrides en el
    /// registro (globales y por ejecutable). Solo trabaja si algo ha cambiado: Wine puede
    /// reponer sus DLL al actualizar el prefijo, y el plan cambia con el motor o los ajustes.
    public func prepareGraphics(force: Bool = false) async throws {
        let plan = graphicsPlan
        if force || !GraphicsResolver.isInstalled(plan, in: bottle) {
            try GraphicsResolver.install(plan, into: bottle)
        }
        // La interfaz de Steam la arregla Motor Bodega (engine/patches/0001): un solo proceso.
        let registry = GraphicsResolver.registryFile(for: plan, rules: CompatibilityRules.rules(for: bottle.config))
        let applied = try? String(contentsOf: graphicsMarker, encoding: .utf8)
        guard force || applied != registry else { return }

        // Importar un .reg no borra lo que ya no aparece: antes se eliminan las reglas por
        // ejecutable de la vez anterior (y las de versiones antiguas de Bodega).
        let legacy = ["steamwebhelper.exe", "EpicWebHelper.exe", "GalaxyClient Helper.exe", "Battle.net.exe", "UplayWebCore.exe", "QtWebEngineProcess.exe"]
        let prefix = #"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\"#, suffix = #"\DllOverrides]"#
        var previous = Set(legacy)
        for line in (applied ?? "").components(separatedBy: "\r\n") where line.hasPrefix(prefix) && line.hasSuffix(suffix) {
            previous.insert(String(line.dropFirst(prefix.count).dropLast(suffix.count)))
        }
        let deletions = previous.sorted().map { "[-" + prefix.dropFirst() + $0 + suffix }.joined(separator: "\r\n")
        let importFile = registry.replacingOccurrences(of: "REGEDIT4\r\n", with: "REGEDIT4\r\n\r\n" + deletions + "\r\n", options: .anchored)

        // reg.exe trata como opción cualquier argumento que empiece por «/»: se usa una ruta C:\.
        let temp = bottle.driveC.appending(path: "windows/temp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appending(path: "bodega-graphics.reg")
        try importFile.write(to: file, atomically: true, encoding: .utf8)
        try await runAndWait(["reg", "import", #"C:\windows\temp\bodega-graphics.reg"#])
        try? FileManager.default.removeItem(at: file)
        try registry.write(to: graphicsMarker, atomically: true, encoding: .utf8)
    }

    /// Espera a que terminen los procesos de la botella, con límite: programas que arrancan solos
    /// con la sesión (Steam con «-silent», por ejemplo) no terminan nunca y bloqueaban los ajustes.
    public func waitForServer(timeout: TimeInterval = 20) async throws {
        _ = try await ProcessRunner.run(executable: engine.wineserver, arguments: ["-w"], environment: environment(), timeout: timeout)
    }

    /// Cierra a la fuerza todos los procesos de Windows de la botella, incluidos los huérfanos
    /// cuyo `wineserver` ya no existe (Epic se quedó así 11 h al 100 % de CPU). Devuelve cuántos
    /// tuvo que cerrar a mano.
    @discardableResult
    public func killAll() async throws -> Int {
        _ = try await ProcessRunner.run(executable: engine.wineserver, arguments: ["-k"], environment: environment(), timeout: 20)
        try? await Task.sleep(for: .seconds(1))
        return await BottleProcesses.forceQuit(BottleProcesses.processIDs(for: bottle))
    }

    static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

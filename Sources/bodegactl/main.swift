import AppKit
import BodegaCore
import Foundation

// bodegactl: interfaz de línea de comandos del núcleo de Bodega.

let usage = """
uso: bodegactl <orden> [opciones]

  engines                                   Lista los motores Wine detectados
  install-engine                            Descarga e instala el motor propio (Wine + DXMT + DXVK)
  list                                      Lista las botellas
  create <botella> [--engine RUTA] [--windows win10|win11|win81|win7|winxp64]
                   [--graphics automatic|d3dmetal|dxmt|dxvk|wined3d] [--retina]
                                            Crea e inicializa una botella
  graphics <botella>                        Traductores Direct3D que usará la botella
  apply <botella>                           Vuelve a aplicar los ajustes (Windows, Retina, gráficos)
  startup <botella> [on|off]               Programas de inicio de Windows (por defecto, desactivados)
  shortcut <botella> <programa|appid> [nombre]
                                            Crea una app en ~/Applications/Bodega Apps
  steam <botella>                           Juegos de Steam instalados en la botella
  store <botella> <steam|epic|gog|battlenet>
                                            Descarga el instalador oficial y lo ejecuta
  exec <botella> -- <args de wine…>         Ejecuta y espera (p. ej. -- cmd /c ver)
  run <botella> <fichero> [args…]           Lanza un .exe/.msi/.bat/.lnk y espera a que cierre
  tool <botella> <winecfg|regedit|taskmgr|control|explorer|cmd|uninstaller>
  programs <botella>                        Programas encontrados en la botella
  env <botella>                             Variables de entorno que usa la botella
  kill <botella>                            Termina todos sus procesos
  trash <botella>                           Mueve la botella a la Papelera
  export <botella> <archivo.tar.gz>         Exporta la botella
  import <archivo.tar.gz>                   Importa una botella

BODEGA_HOME cambia la carpeta de datos (por defecto ~/Library/Application Support/Bodega).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String, in args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}

func resolveEngine(for bottle: Bottle?, explicit: String?) -> WineEngine {
    if let explicit {
        guard let engine = EngineLocator.engine(at: URL(filePath: explicit)) else {
            fail(BodegaError.engineNotFound(explicit).localizedDescription)
        }
        return engine
    }
    let engines = EngineLocator.discover(detectVersions: false)
    if let id = bottle?.config.engineID {
        if let match = engines.first(where: { $0.id == id }) { return match }
        if let engine = EngineLocator.engine(at: URL(filePath: id)) { return engine }
    }
    guard let first = engines.first else { fail(BodegaError.noEngine.localizedDescription) }
    return first
}

let store = BottleStore()
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

@MainActor
func bottleArgument() -> Bottle {
    guard !args.isEmpty else { fail("falta el nombre de la botella") }
    let name = args.removeFirst()
    do { return try store.bottle(named: name) } catch { fail(error.localizedDescription) }
}

do {
    switch command {
    case "install-engine":
        print("Instalando el motor de Bodega (≈\(EngineInstaller.totalMegabytes) MB, componentes libres)…")
        let url = try await EngineInstaller.install { print("  \($0)") }
        print("Listo: \(url.path)")

    case "engines":
        let engines = EngineLocator.discover()
        if engines.isEmpty { print("No se ha encontrado ningún motor Wine.") }
        for engine in engines {
            print("• \(engine.displayName)\(EngineLocator.isBodegaEngine(engine) ? "  [propio]" : "")")
            print("    ruta: \(engine.root.path)")
            print("    gráficos: \(engine.availableBackends.map(\.rawValue).joined(separator: ", "))")
            print("    automático → \(GraphicsResolver.plan(for: .automatic, engine: engine).summary)")
        }

    case "list":
        let bottles = try store.list()
        if bottles.isEmpty { print("No hay botellas en \(store.root.path)") }
        for bottle in bottles {
            let state = bottle.isInitialized ? "" : "  (sin inicializar)"
            print("• \(bottle.name) — \(bottle.config.windowsVersion.displayName), \(bottle.config.graphics.displayName)\(state)")
        }

    case "create":
        guard !args.isEmpty else { fail("falta el nombre de la botella") }
        let name = args.removeFirst()
        let enginePath = option("--engine", in: &args)
        var config = BottleConfig()
        if let version = option("--windows", in: &args) {
            guard let parsed = WindowsVersion(rawValue: version) else { fail("versión de Windows desconocida: \(version)") }
            config.windowsVersion = parsed
        }
        if let graphics = option("--graphics", in: &args) {
            guard let parsed = GraphicsBackend(rawValue: graphics) else { fail("modo gráfico desconocido: \(graphics)") }
            config.graphics = parsed
        }
        config.retinaMode = flag("--retina", in: &args)
        let engine = resolveEngine(for: nil, explicit: enginePath)
        config.engineID = engine.id
        if !engine.availableBackends.contains(config.graphics) {
            fail(BodegaError.backendUnavailable(config.graphics.displayName).localizedDescription)
        }
        let bottle = try store.prepareNewBottle(named: name, config: config)
        print("Creando «\(name)» con \(engine.displayName)…")
        let started = Date()
        try await WineRunner(engine: engine, bottle: bottle).initializePrefix()
        print(String(format: "Lista en %.0f s: %@", Date().timeIntervalSince(started), bottle.url.path))

    case "exec":
        let bottle = bottleArgument()
        if args.first == "--" { args.removeFirst() }
        guard !args.isEmpty else { fail("faltan los argumentos para wine") }
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        let output = try await runner.runAndWait(args, check: false)
        print(output.output, terminator: "")
        exit(output.status)

    case "run":
        let bottle = bottleArgument()
        guard !args.isEmpty else { fail("falta el fichero a ejecutar") }
        let file = URL(filePath: args.removeFirst()).standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { fail("no existe \(file.path)") }
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        let program = try await runner.launch(LaunchTarget(file: file), arguments: args) { status in
            exitContinuation.yield(status)
            exitContinuation.finish()
        }
        print("Ejecutando \(program.name) (pid \(program.pid)). Registro: \(program.logURL.path)")
        var status: Int32 = 0
        for await code in exits { status = code }
        print("Terminó con código \(status)")

    case "tool":
        let bottle = bottleArgument()
        guard let raw = args.first, let tool = WineTool(rawValue: raw) else { fail("herramienta desconocida") }
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        let program = try await runner.launch(.tool(tool))
        print("Abierto \(tool.displayName) (pid \(program.pid))")

    case "programs":
        let bottle = bottleArgument()
        let found = ProgramScanner.scan(bottle)
        print("Accesos directos (\(found.shortcuts.count)):")
        for program in found.shortcuts { print("  • \(program.name)  —  \(program.url.path)") }
        print("Ejecutables (\(found.executables.count)):")
        for program in found.executables { print("  • \(program.name)  —  \(program.url.path)") }

    case "env":
        let bottle = bottleArgument()
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        let env = runner.environment(base: [:])
        for key in env.keys.sorted() { print("\(key)=\(env[key]!)") }

    case "graphics":
        let bottle = bottleArgument()
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        let plan = runner.graphicsPlan
        print("Elegido: \(bottle.config.graphics.displayName)")
        print("Efectivo: \(plan.summary)")
        print("Nativas: \(plan.native.map(\.name).joined(separator: ", "))")
        print("Instaladas en la botella: \(GraphicsResolver.isInstalled(plan, in: bottle) ? "sí" : "no")")
        print("Overrides globales (registro): \(plan.overrides)")
        for rule in CompatibilityRules.builtIn {
            print("Regla: \(rule.executable) → Direct3D de Wine\(rule.verified ? " (verificada)" : "")")
        }

    case "apply":
        let bottle = bottleArgument()
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        try await runner.applySettings()
        print("Ajustes aplicados en «\(bottle.name)»: \(bottle.config.windowsVersion.displayName), \(runner.graphicsPlan.summary)\(bottle.config.retinaMode ? ", Retina" : "")")

    case "steam":
        let bottle = bottleArgument()
        let games = SteamLibrary.games(in: bottle)
        if games.isEmpty { print("No hay juegos de Steam en «\(bottle.name)».") }
        let forced = Set(bottle.config.wineD3DExecutables.map { $0.lowercased() })
        for game in games {
            let wined3d = game.executableNames.contains { forced.contains($0.lowercased()) } ? " · Direct3D de Wine" : ""
            print("• \(game.name) [\(game.appID)]\(game.isInstalled ? "" : " (instalando)")\(wined3d)")
            print("    ejecutables: \(game.executableNames.joined(separator: ", "))")
            print("    carátula: \(game.coverArt?.lastPathComponent ?? "—")")
        }

    case "shortcut":
        // shortcut <botella> <programa.exe | appid de Steam> [nombre]
        let bottle = bottleArgument()
        guard let target = args.first else { fail("falta el programa o el appid de Steam") }
        var program = URL(filePath: target)
        var arguments: [String] = []
        var name = args.count > 1 ? args[1] : program.deletingPathExtension().lastPathComponent
        var icon: NSImage?
        if let game = SteamLibrary.games(in: bottle).first(where: { $0.appID == target }), let steam = SteamLibrary.installation(in: bottle) {
            program = steam.steamExecutable
            arguments = SteamLibrary.launchArguments(for: game)
            if args.count < 2 { name = game.name }
            icon = (game.coverArt ?? game.headerArt).flatMap { NSImage(contentsOf: $0) }
        } else {
            icon = ProgramIcons.icoData(for: program, in: bottle).flatMap { NSImage(data: $0) }
        }
        let app = try MacShortcuts.create(name: name, bottle: bottle, program: program, arguments: arguments, icon: icon)
        print("Acceso creado: \(app.path)")

    case "startup":
        // startup <botella> [on|off]: programas de inicio de Windows (Steam/Epic con -silent)
        var bottle = bottleArgument()
        if let choice = args.first {
            guard choice == "on" || choice == "off" else { fail("usa on u off") }
            bottle.config.startupPrograms = choice == "on"
            try store.save(bottle)
            if BottleProcesses.isServerRunning(for: bottle) {
                print("La botella está en marcha: el cambio se aplicará la próxima vez que arranque (o tras «bodegactl kill»).")
            }
            let changed = choice == "on" ? try StartupItems.restore(in: bottle) : try StartupItems.disable(in: bottle)
            if !changed.isEmpty { print((choice == "on" ? "Restaurados: " : "Apartados: ") + changed.joined(separator: ", ")) }
        }
        print("Programas de inicio: \(bottle.config.startupPrograms ? "permitidos" : "desactivados")")
        let active = StartupItems.active(in: bottle)
        print("Activos ahora: \(active.isEmpty ? "ninguno" : active.joined(separator: ", "))")

    case "store":
        let bottle = bottleArgument()
        guard let raw = args.first, let store = GameStore(rawValue: raw) else { fail("tienda desconocida") }
        print("Descargando \(store.displayName)…")
        let installer = try await store.downloadInstaller(into: bottle)
        let runner = WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle)
        let program = try await runner.launch(LaunchTarget(file: installer))
        print("Instalador abierto (pid \(program.pid)). Registro: \(program.logURL.path)")

    case "kill":
        let bottle = bottleArgument()
        let orphans = try await WineRunner(engine: resolveEngine(for: bottle, explicit: nil), bottle: bottle).killAll()
        print("Procesos de «\(bottle.name)» terminados." + (orphans > 0 ? " Cerrados a la fuerza: \(orphans)." : ""))

    case "trash":
        let bottle = bottleArgument()
        let trashed = try store.moveToTrash(bottle)
        print("«\(bottle.name)» movida a la Papelera\(trashed.map { ": \($0.path)" } ?? "").")

    case "export":
        let bottle = bottleArgument()
        guard let path = args.first else { fail("falta el archivo de destino") }
        try await store.export(bottle, to: URL(filePath: path))
        print("Exportada a \(path)")

    case "import":
        guard let path = args.first else { fail("falta el archivo") }
        let bottle = try await store.importArchive(URL(filePath: path))
        print("Importada como «\(bottle.name)»")

    case "help", "-h", "--help":
        print(usage)

    default:
        fail("orden desconocida «\(command)»\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}

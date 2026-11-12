import Foundation

/// Busca motores Wine instalados en el Mac.
public enum EngineLocator {
    /// Rutas donde buscar Wine, por orden de preferencia: primero los motores propios de
    /// Bodega y después los Wine libres instalados en el Mac.
    public static func defaultCandidates() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        for folder in [Paths.engines, Paths.defaultHome.appending(path: "Engines", directoryHint: .isDirectory)] {
            let installed = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            // Motor Bodega (compilado con MSync) primero; después, el más reciente.
            candidates += installed.sorted { lhs, rhs in
                let l = lhs.lastPathComponent.hasPrefix("Motor Bodega"), r = rhs.lastPathComponent.hasPrefix("Motor Bodega")
                if l != r { return l }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
            }
        }
        for base in [URL(filePath: "/Applications"), home.appending(path: "Applications")] {
            for app in ["Wine Stable.app", "Wine Devel.app", "Wine Staging.app"] {
                candidates.append(base.appending(path: app, directoryHint: .isDirectory))
            }
        }
        candidates.append(URL(filePath: "/opt/homebrew", directoryHint: .isDirectory))
        candidates.append(URL(filePath: "/usr/local", directoryHint: .isDirectory))
        return candidates
    }

    /// Indica si el motor es uno de los propios de Bodega (instalado en su carpeta Engines).
    public static func isBodegaEngine(_ engine: WineEngine) -> Bool {
        let path = engine.root.resolvingSymlinksInPath().path
        return [Paths.engines, Paths.defaultHome.appending(path: "Engines")].contains {
            path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }
    }

    /// Detecta motores en las rutas por defecto más las añadidas por el usuario.
    /// Ejecuta `wine --version` en cada uno, así que conviene llamarla fuera del hilo principal.
    public static func discover(customRoots: [URL] = [], detectVersions: Bool = true) -> [WineEngine] {
        var seen = Set<String>()
        var engines: [WineEngine] = []
        for candidate in defaultCandidates() + customRoots {
            guard var engine = engine(at: candidate) else { continue }
            let key = engine.loader.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { continue }
            if detectVersions, engine.version == nil {
                engine.version = detectVersion(of: engine)
            }
            engines.append(engine)
        }
        return engines
    }

    /// Reconoce un motor a partir de una carpeta: una `.app` de Wine (como «Wine Staging.app»)
    /// o una raíz con `bin/wine` y `bin/wineserver`.
    public static func engine(at url: URL) -> WineEngine? {
        if url.pathExtension == "app" {
            let name = url.deletingPathExtension().lastPathComponent
            return standardEngine(root: url.appending(path: "Contents/Resources/wine", directoryHint: .isDirectory), name: name)
        }
        return standardEngine(root: url, name: nil)
    }

    public static func standardEngine(root: URL, name: String?) -> WineEngine? {
        let fm = FileManager.default
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let loader = ["wine", "wine64"]
            .map { bin.appending(path: $0) }
            .first { fm.isExecutableFile(atPath: $0.path) }
        let server = bin.appending(path: "wineserver")
        guard let loader, fm.isExecutableFile(atPath: server.path) else { return nil }
        let external = root.appending(path: "lib/external", directoryHint: .isDirectory)
        let hasD3DMetal = fm.fileExists(atPath: external.appending(path: "D3DMetal.framework").path)
        // Motor Bodega (Wine de CodeWeavers) precarga libd3dshared de Apple si se le indica la ruta.
        var environment: [String: String] = [:]
        let d3dShared = external.appending(path: "libd3dshared.dylib")
        if hasD3DMetal, fm.fileExists(atPath: d3dShared.path) {
            environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dShared.path
        }
        return WineEngine(
            name: name ?? "Wine (\(root.path))",
            layout: .standard,
            root: root,
            loader: loader,
            wineserver: server,
            extraEnvironment: environment,
            dxvkDirectory: [root.appending(path: "lib/dxvk"), Paths.components.appending(path: "dxvk")].first(where: hasDXVK),
            dxmtDirectory: [root.appending(path: "lib/dxmt"), Paths.components.appending(path: "dxmt")].first(where: hasDXMT),
            d3dMetalDirectory: hasD3DMetal ? external : nil
        )
    }

    static func hasDXVK(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return ["x86_64-windows/d3d11.dll", "x64/d3d11.dll", "x86_64-windows/d3d9.dll", "x64/d3d9.dll"].contains {
            fm.fileExists(atPath: dir.appending(path: $0).path)
        }
    }

    static func hasDXMT(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appending(path: "x86_64-windows/d3d11.dll").path)
            && fm.fileExists(atPath: dir.appending(path: "x86_64-windows/winemetal.dll").path)
    }

    public static func detectVersion(of engine: WineEngine) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = engine.loader
        process.arguments = ["--version"]
        var env = ProcessInfo.processInfo.environment
        env["WINEDEBUG"] = "-all"
        process.environment = env
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

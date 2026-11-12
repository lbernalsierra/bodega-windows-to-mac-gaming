import Foundation

/// Añade D3DMetal (DirectX 11/12 → Metal, del Game Porting Toolkit de Apple) a un motor.
/// D3DMetal es software de Apple: Bodega no lo descarga ni lo redistribuye; lo importa del
/// GPTK que el usuario descarga con su cuenta de Apple. Se crea un clon APFS del motor, así el
/// original sigue disponible para los juegos que van mejor con DXMT.
public enum D3DMetalInstaller {
    public static let downloadPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    /// Busca en el GPTK la carpeta `lib` que contiene `external/D3DMetal.framework` y `wine/`.
    public static func locateRedistributable(in root: URL, depth: Int = 0) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appending(path: "external/D3DMetal.framework").path),
           fm.fileExists(atPath: root.appending(path: "wine/x86_64-windows").path) {
            return root
        }
        guard depth < 5, let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && item.pathExtension != "framework" {
            if let found = locateRedistributable(in: item, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Importa D3DMetal desde un `.dmg` o una carpeta del GPTK. Devuelve la carpeta del nuevo motor.
    @discardableResult
    public static func install(from source: URL, basedOn engine: WineEngine, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        var mountPoint: URL?
        defer {
            if let mountPoint {
                let detach = Process()
                detach.executableURL = URL(filePath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint.path, "-quiet"]
                try? detach.run()
                detach.waitUntilExit()
            }
        }
        var searchRoot = source
        if source.pathExtension.lowercased() == "dmg" {
            progress("Abriendo la imagen del Game Porting Toolkit…")
            let mount = FileManager.default.temporaryDirectory.appending(path: "bodega-gptk-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            let output = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/hdiutil"),
                arguments: ["attach", source.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path],
                environment: ProcessInfo.processInfo.environment
            )
            guard output.status == 0 else { throw BodegaError.commandFailed(command: "hdiutil attach", status: output.status, output: output.output) }
            mountPoint = mount
            searchRoot = mount
        }
        guard let redist = locateRedistributable(in: searchRoot) else {
            throw BodegaError.archiveInvalid("no se encuentra D3DMetal.framework (¿es el Game Porting Toolkit de Apple?)")
        }
        return try await install(redistributable: redist, basedOn: engine, progress: progress)
    }

    /// Paso común: clona el motor y copia D3DMetal dentro.
    @discardableResult
    public static func install(redistributable redist: URL, basedOn engine: WineEngine, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let baseApp = engine.root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let isAppLayout = baseApp.pathExtension == "app" && engine.root.path.hasSuffix("Contents/Resources/wine")
        let baseFolder = isAppLayout ? baseApp : engine.root
        let name = baseFolder.deletingPathExtension().lastPathComponent + " + D3DMetal" + (isAppLayout ? ".app" : "")
        let destination = Paths.defaultHome.appending(path: "Engines/\(name)", directoryHint: .isDirectory)
        let staging = destination.deletingLastPathComponent().appending(path: ".d3dmetal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        progress("Clonando \(engine.name)…")
        // cp -c clona en APFS: instantáneo y sin duplicar espacio.
        let clone = try await ProcessRunner.run(executable: URL(filePath: "/bin/cp"), arguments: ["-cR", baseFolder.path, staging.path], environment: [:])
        guard clone.status == 0 else { throw BodegaError.commandFailed(command: "cp -cR", status: clone.status, output: clone.output) }
        let root = isAppLayout ? staging.appending(path: "Contents/Resources/wine", directoryHint: .isDirectory) : staging
        let lib = root.appending(path: "lib", directoryHint: .isDirectory)

        progress("Copiando D3DMetal…")
        let external = lib.appending(path: "external", directoryHint: .isDirectory)
        try? fm.removeItem(at: external)
        try fm.copyItem(at: redist.appending(path: "external"), to: external)
        for arch in ["x86_64-windows", "x86_64-unix", "i386-windows"] {
            let from = redist.appending(path: "wine/\(arch)", directoryHint: .isDirectory)
            guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { continue }
            let to = lib.appending(path: "wine/\(arch)", directoryHint: .isDirectory)
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for item in items {
                let target = to.appending(path: item.lastPathComponent)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: item, to: target)
            }
        }
        try "D3DMetal © Apple Inc., importado del Game Porting Toolkit descargado por el usuario desde \(downloadPage.absoluteString).\nUso personal según la licencia de Apple; no redistribuir este motor.\nOrigen: \(redist.path)\nImportado: \(Date())\n"
            .write(to: staging.appending(path: "BODEGA-D3DMETAL.txt"), atomically: true, encoding: .utf8)

        guard let result = EngineLocator.engine(at: staging), result.d3dMetalDirectory != nil else {
            try? fm.removeItem(at: staging)
            throw BodegaError.archiveInvalid("el motor con D3DMetal no quedó bien montado")
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        progress("D3DMetal añadido.")
        return destination
    }
}

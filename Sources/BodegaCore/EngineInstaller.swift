import CryptoKit
import Foundation

/// Descarga y monta el motor propio de Bodega a partir de compilaciones libres publicadas:
/// Wine (LGPL), DXMT y DXVK-macOS (zlib).
public enum EngineInstaller {
    public struct Component: Sendable {
        public var name: String
        public var url: URL
        public var sha256: String
        public var approximateMegabytes: Int
    }

    public static let engineFolderName = "Wine Staging 11.21.app"

    /// Versiones fijadas y comprobadas (8-nov-2026). La suma SHA-256 impide instalar algo distinto.
    public static let wine = Component(
        name: "Wine Staging 11.21",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-staging-11.21-osx64.tar.xz")!,
        sha256: "d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452",
        approximateMegabytes: 218
    )
    public static let dxmt = Component(
        name: "DXMT 0.80",
        url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!,
        sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
        approximateMegabytes: 18
    )
    public static let dxvk = Component(
        name: "DXVK-macOS 1.10.3",
        url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")!,
        sha256: "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00",
        approximateMegabytes: 3
    )
    public static var components: [Component] { [wine, dxmt, dxvk] }
    public static var totalMegabytes: Int { components.reduce(0) { $0 + $1.approximateMegabytes } }

    public static var destination: URL {
        Paths.defaultHome.appending(path: "Engines/\(engineFolderName)", directoryHint: .isDirectory)
    }

    public static var isInstalled: Bool {
        EngineLocator.engine(at: destination) != nil
    }

    /// Instala el motor. `progress` recibe mensajes cortos para la interfaz.
    @discardableResult
    public static func install(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let engines = destination.deletingLastPathComponent()
        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        let staging = engines.appending(path: ".instalando-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Descargar y verificar, cada archivo en su propia carpeta.
        var extracted: [String: URL] = [:]
        for component in components {
            progress("Descargando \(component.name) (\(component.approximateMegabytes) MB)…")
            let (temporary, response) = try await URLSession.shared.download(from: component.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw BodegaError.downloadFailed("\(component.name): respuesta \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            progress("Comprobando \(component.name)…")
            let digest = try sha256(of: temporary)
            guard digest == component.sha256 else {
                try? fm.removeItem(at: temporary)
                throw BodegaError.downloadFailed("\(component.name): la suma SHA-256 no coincide (\(digest.prefix(12))…)")
            }
            let folder = staging.appending(path: component.name, directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            progress("Descomprimiendo \(component.name)…")
            let output = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/tar"),
                arguments: ["-xf", temporary.path, "-C", folder.path],
                environment: ProcessInfo.processInfo.environment
            )
            try? fm.removeItem(at: temporary)
            guard output.status == 0 else {
                throw BodegaError.commandFailed(command: "tar", status: output.status, output: output.output)
            }
            extracted[component.name] = folder
        }

        // 2. Montar el motor: Wine + DXMT y DXVK dentro de lib/.
        progress("Montando el motor…")
        guard let wineApp = firstDirectory(in: extracted[wine.name]!, where: { $0.pathExtension == "app" }),
              let dxmtRoot = firstDirectory(in: extracted[dxmt.name]!, where: { fm.fileExists(atPath: $0.appending(path: "x86_64-unix/winemetal.so").path) }),
              let dxvkRoot = firstDirectory(in: extracted[dxvk.name]!, where: { fm.fileExists(atPath: $0.appending(path: "x86_64-windows/d3d11.dll").path) })
        else { throw BodegaError.archiveInvalid("estructura inesperada en las descargas del motor") }

        let assembled = staging.appending(path: engineFolderName, directoryHint: .isDirectory)
        try fm.moveItem(at: wineApp, to: assembled)
        let root = assembled.appending(path: "Contents/Resources/wine", directoryHint: .isDirectory)
        let lib = root.appending(path: "lib", directoryHint: .isDirectory)
        try fm.copyItem(at: dxmtRoot, to: lib.appending(path: "dxmt"))
        try fm.copyItem(at: dxvkRoot, to: lib.appending(path: "dxvk"))
        // winemetal como builtin del motor, tal y como indica DXMT.
        for (from, to) in [("x86_64-windows/winemetal.dll", "wine/x86_64-windows/winemetal.dll"),
                           ("i386-windows/winemetal.dll", "wine/i386-windows/winemetal.dll"),
                           ("x86_64-unix/winemetal.so", "wine/x86_64-unix/winemetal.so")] {
            let target = lib.appending(path: to)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: lib.appending(path: "dxmt/\(from)"), to: target)
        }
        let provenance = components.map { "\($0.name)\n  \($0.url.absoluteString)\n  sha256 \($0.sha256)" }.joined(separator: "\n")
        try "Motor de Bodega — componentes libres.\n\(provenance)\nInstalado: \(Date())\n"
            .write(to: assembled.appending(path: "BODEGA-PROCEDENCIA.txt"), atomically: true, encoding: .utf8)

        guard EngineLocator.engine(at: assembled) != nil else {
            throw BodegaError.archiveInvalid("el motor montado no tiene bin/wine y bin/wineserver")
        }

        // 3. Sustituir el anterior (si lo hay) de forma atómica.
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: assembled)
        } else {
            try fm.moveItem(at: assembled, to: destination)
        }
        progress("Motor instalado.")
        return destination
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func firstDirectory(in folder: URL, where predicate: (URL) -> Bool) -> URL? {
        if predicate(folder) { return folder }
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.first(where: predicate)
    }
}

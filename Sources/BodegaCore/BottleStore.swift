import Foundation

/// Guarda y enumera botellas en una carpeta raíz (por defecto `Paths.bottles`).
public struct BottleStore: Sendable {
    public let root: URL

    public init(root: URL = Paths.bottles) {
        self.root = root
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func list() throws -> [Bottle] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return entries
            .compactMap { try? load(at: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func load(at url: URL) throws -> Bottle {
        let configURL = url.appending(path: Bottle.configFileName)
        guard let data = FileManager.default.contents(atPath: configURL.path) else {
            throw BodegaError.bottleNotFound(url.lastPathComponent)
        }
        let config = try Self.decoder.decode(BottleConfig.self, from: data)
        return Bottle(url: url, config: config)
    }

    public func bottle(named name: String) throws -> Bottle {
        try load(at: root.appending(path: name, directoryHint: .isDirectory))
    }

    public func save(_ bottle: Bottle) throws {
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(bottle.config)
        try data.write(to: bottle.configURL, options: .atomic)
    }

    /// Crea la carpeta y el `bodega.json`. El prefijo de Wine lo inicializa `WineRunner`.
    public func prepareNewBottle(named name: String, config: BottleConfig) throws -> Bottle {
        try BottleName.validate(name)
        let url = root.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw BodegaError.bottleExists(name)
        }
        let bottle = Bottle(url: url, config: config)
        try save(bottle)
        return bottle
    }

    /// Mueve la botella a la Papelera (recuperable), nunca la borra definitivamente.
    @discardableResult
    public func moveToTrash(_ bottle: Bottle) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: bottle.url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Exporta la botella a un `.tar.gz` (equivalente funcional a un archivo de botella).
    public func export(_ bottle: Bottle, to archive: URL) async throws {
        let output = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/tar"),
            arguments: ["-czf", archive.path, "--exclude", "\(bottle.name)/logs", "-C", root.path, bottle.name],
            environment: ProcessInfo.processInfo.environment
        )
        guard output.status == 0 else {
            throw BodegaError.commandFailed(command: "tar", status: output.status, output: output.output)
        }
    }

    /// Importa un `.tar.gz` exportado por Bodega. Si el nombre ya existe, añade un sufijo.
    public func importArchive(_ archive: URL) async throws -> Bottle {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let output = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", staging.path],
            environment: ProcessInfo.processInfo.environment
        )
        guard output.status == 0 else {
            throw BodegaError.commandFailed(command: "tar", status: output.status, output: output.output)
        }
        let candidates = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard let extracted = candidates.first(where: { fm.fileExists(atPath: $0.appending(path: Bottle.configFileName).path) }) else {
            throw BodegaError.archiveInvalid("no contiene \(Bottle.configFileName)")
        }
        var name = extracted.lastPathComponent
        var suffix = 2
        while fm.fileExists(atPath: root.appending(path: name).path) {
            name = "\(extracted.lastPathComponent) \(suffix)"
            suffix += 1
        }
        let destination = root.appending(path: name, directoryHint: .isDirectory)
        try fm.moveItem(at: extracted, to: destination)
        return try load(at: destination)
    }
}

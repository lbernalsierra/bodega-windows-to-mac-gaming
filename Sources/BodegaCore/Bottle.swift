import Foundation

/// Una botella es un prefijo de Wine (WINEPREFIX) más su `bodega.json`.
public struct Bottle: Identifiable, Hashable, Sendable {
    public static let configFileName = "bodega.json"

    public var url: URL
    public var config: BottleConfig

    public init(url: URL, config: BottleConfig) {
        self.url = url
        self.config = config
    }

    public var id: String { url.standardizedFileURL.path }
    public var name: String { url.lastPathComponent }
    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
    public var logsDirectory: URL { url.appending(path: "logs", directoryHint: .isDirectory) }
    public var configURL: URL { url.appending(path: Bottle.configFileName) }
    /// Indica si Wine ya ha creado el prefijo.
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "system.reg").path)
    }

    /// Ruta de Windows para un fichero: `C:\…` si está en la unidad C: de la botella y
    /// `Z:\…` (la raíz del Mac) en otro caso. Los programas de Windows como msiexec o cmd
    /// toman lo que empieza por «/» como una opción, así que nunca deben recibir rutas Unix.
    public func windowsPath(for fileURL: URL) -> String {
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let c = driveC.standardizedFileURL.resolvingSymlinksInPath().path
        if file == c { return #"C:\"# }
        if file.hasPrefix(c + "/") {
            return #"C:\"# + file.dropFirst(c.count + 1).replacingOccurrences(of: "/", with: #"\"#)
        }
        return "Z:" + file.replacingOccurrences(of: "/", with: #"\"#)
    }

    /// `C:\Program Files\App\app.exe` → ruta Unix, resolviendo la letra con `dosdevices`.
    public func unixURL(forWindowsPath path: String) -> URL? {
        var clean = path.replacingOccurrences(of: "\\\\", with: "\\").trimmingCharacters(in: .whitespaces)
        // «"C:\…\app.exe",0» (ubicación de icono con índice): primero el índice, luego las comillas.
        if let comma = clean.lastIndex(of: ","), clean[clean.index(after: comma)...].allSatisfy({ $0.isNumber || $0 == "-" }) {
            clean = String(clean[..<comma]).trimmingCharacters(in: .whitespaces)
        }
        if clean.hasPrefix("\""), clean.hasSuffix("\""), clean.count >= 2 { clean = String(clean.dropFirst().dropLast()) }
        guard clean.count >= 2, clean.dropFirst().first == ":", let letter = clean.first?.lowercased() else { return nil }
        let base = url.appending(path: "dosdevices/\(letter):").resolvingSymlinksInPath()
        let rest = clean.dropFirst(2).split(separator: "\\").map(String.init)
        return rest.reduce(base) { $0.appending(path: $1) }.standardizedFileURL
    }

    /// Carpeta de descargas dentro de la botella (`C:\users\Public\Downloads`).
    public var downloadsDirectory: URL {
        driveC.appending(path: "users/Public/Downloads", directoryHint: .isDirectory)
    }

    /// Ruta relativa a la botella, o nil si `fileURL` está fuera de ella.
    public func relativePath(of fileURL: URL) -> String? {
        let root = url.standardizedFileURL.resolvingSymlinksInPath().path
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard file.hasPrefix(root + "/") else { return nil }
        return String(file.dropFirst(root.count + 1))
    }

    public static func == (lhs: Bottle, rhs: Bottle) -> Bool {
        lhs.id == rhs.id && lhs.config == rhs.config
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum BottleName {
    public static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.()"))
        guard !trimmed.isEmpty,
              trimmed == name,
              !trimmed.hasPrefix("."),
              trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy(allowed.contains)
        else { throw BodegaError.invalidBottleName(name) }
    }
}

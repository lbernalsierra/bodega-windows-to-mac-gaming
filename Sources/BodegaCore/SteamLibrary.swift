import Foundation

public struct SteamInstallation: Hashable, Sendable {
    public var root: URL
    public var steamExecutable: URL
}

public struct SteamGame: Identifiable, Hashable, Sendable {
    public var appID: String
    public var name: String
    public var installDirectory: URL
    public var isInstalled: Bool
    public var lastPlayed: Date?
    /// Carátula vertical (600×900) y cabecera horizontal que Steam guarda en su caché.
    public var coverArt: URL?
    public var headerArt: URL?
    /// Ejecutables del juego, sin instaladores ni gestores de errores.
    public var executables: [URL]

    public var id: String { appID }
    public var executableNames: [String] { executables.map { $0.lastPathComponent } }
}

/// Lee la biblioteca de Steam de una botella (manifiestos `appmanifest_*.acf`,
/// `libraryfolders.vdf` y la caché de carátulas), sin depender de que Steam esté abierto.
public enum SteamLibrary {
    /// Steamworks Common Redistributables: no es un juego.
    static let ignoredAppIDs: Set<String> = ["228980"]
    static let ignoredExecutableWords = [
        "crashhandler", "crashreport", "unins", "vcredist", "vc_redist", "dxsetup", "dotnet",
        "directx", "redist", "setup", "prereq", "easyanticheat", "battleye", "cefprocess", "helper",
    ]

    public static func installation(in bottle: Bottle) -> SteamInstallation? {
        let fm = FileManager.default
        for folder in ["Program Files (x86)/Steam", "Program Files/Steam"] {
            let root = bottle.driveC.appending(path: folder, directoryHint: .isDirectory)
            let exe = root.appending(path: "steam.exe")
            if fm.fileExists(atPath: exe.path) {
                return SteamInstallation(root: root, steamExecutable: exe)
            }
        }
        return nil
    }

    public static func games(in bottle: Bottle) -> [SteamGame] {
        guard let steam = installation(in: bottle) else { return [] }
        let fm = FileManager.default
        var libraries = [steam.root]
        let foldersFile = steam.root.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: foldersFile, encoding: .utf8) {
            for path in values(of: "path", in: text) {
                if let url = unixURL(forWindowsPath: path, in: bottle) { libraries.append(url) }
            }
        }
        // Steam se lista a sí mismo en libraryfolders.vdf; la misma carpeta puede llegar como
        // /private/tmp/… o /tmp/…, así que se compara la ruta canónica.
        var seenLibraries = Set<String>()
        libraries = libraries.filter { seenLibraries.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }

        var games: [SteamGame] = []
        var seenApps = Set<String>()
        for library in libraries {
            let steamapps = library.appending(path: "steamapps", directoryHint: .isDirectory)
            guard let items = try? fm.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }
            for manifest in items where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
                let fields = firstValues(in: text)
                guard let appID = fields["appid"], !ignoredAppIDs.contains(appID),
                      let name = fields["name"], let installDir = fields["installdir"],
                      seenApps.insert(appID).inserted else { continue }
                let directory = steamapps.appending(path: "common/\(installDir)", directoryHint: .isDirectory)
                // StateFlags 4 = «completamente instalado».
                let flags = Int(fields["StateFlags"] ?? "") ?? 0
                let lastPlayed = (Double(fields["LastPlayed"] ?? "")).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                let cache = steam.root.appending(path: "appcache/librarycache/\(appID)", directoryHint: .isDirectory)
                games.append(SteamGame(
                    appID: appID,
                    name: name,
                    installDirectory: directory,
                    isInstalled: flags & 4 != 0 && fm.fileExists(atPath: directory.path),
                    lastPlayed: lastPlayed,
                    coverArt: existing(cache.appending(path: "library_600x900.jpg")),
                    headerArt: existing(cache.appending(path: "header.jpg")),
                    executables: executables(in: directory)
                ))
            }
        }
        return games.sorted { ($0.lastPlayed ?? .distantPast, $1.name) > ($1.lastPlayed ?? .distantPast, $0.name) }
    }

    /// Argumentos para que el Steam de la botella lance el juego (DRM, overlay y nube incluidos).
    public static func launchArguments(for game: SteamGame) -> [String] {
        ["-applaunch", game.appID]
    }

    static func executables(in directory: URL) -> [URL] {
        let found = ProgramScanner.files(in: directory, extensions: ["exe"], maxDepth: 3)
        return found
            .filter { url in
                let lower = url.lastPathComponent.lowercased()
                return !ignoredExecutableWords.contains { lower.contains($0) }
            }
            .sorted { lhs, rhs in
                let l = lhs.pathComponents.count, r = rhs.pathComponents.count
                return l != r ? l < r : lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    static func unixURL(forWindowsPath path: String, in bottle: Bottle) -> URL? {
        bottle.unixURL(forWindowsPath: path)
    }

    /// Primer valor de cada clave en un fichero KeyValues de Valve («"clave" "valor"»).
    static func firstValues(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in pairs(in: text) where result[key] == nil {
            result[key] = value
        }
        return result
    }

    static func values(of key: String, in text: String) -> [String] {
        pairs(in: text).filter { $0.0 == key }.map(\.1)
    }

    private static func pairs(in text: String) -> [(String, String)] {
        let regex = /"([^"]+)"[ \t]+"((?:[^"\\]|\\.)*)"/
        return text.matches(of: regex).map { (String($0.output.1), String($0.output.2)) }
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

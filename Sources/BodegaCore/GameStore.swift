import Foundation

/// Tiendas de juegos de Windows con su instalador oficial.
public enum GameStore: String, CaseIterable, Sendable, Identifiable {
    case steam, epic, gog, battlenet

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .gog: "GOG Galaxy"
        case .battlenet: "Battle.net"
        }
    }

    public var symbolName: String {
        switch self {
        case .steam: "gamecontroller"
        case .epic: "bolt.shield"
        case .gog: "sparkles"
        case .battlenet: "shield.lefthalf.filled"
        }
    }

    /// Enlaces de descarga oficiales de cada tienda (comprobados el 8-nov-2026).
    public var installerURL: URL {
        switch self {
        case .steam: URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
        case .epic: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!
        case .gog: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!
        case .battlenet: URL(string: "https://www.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live")!
        }
    }

    public var installerFileName: String {
        switch self {
        case .steam: "SteamSetup.exe"
        case .epic: "EpicGamesLauncherInstaller.msi"
        case .gog: "GOG_Galaxy_2.0.exe"
        case .battlenet: "Battle.net-Setup.exe"
        }
    }

    /// Descarga el instalador a `C:\users\Public\Downloads` de la botella (ruta corta de Windows).
    public func downloadInstaller(into bottle: Bottle) async throws -> URL {
        let folder = bottle.downloadsDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: installerFileName)
        var request = URLRequest(url: installerURL)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BodegaError.downloadFailed("respuesta \((response as? HTTPURLResponse)?.statusCode ?? 0) de \(installerURL.host() ?? "")")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

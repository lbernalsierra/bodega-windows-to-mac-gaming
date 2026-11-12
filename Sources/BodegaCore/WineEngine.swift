import Foundation

/// Un motor Wine: el cargador, su `wineserver` y lo que haga falta para ejecutarlo.
public struct WineEngine: Codable, Hashable, Identifiable, Sendable {
    public enum Layout: String, Codable, Sendable {
        /// Distribución estándar de Wine: `bin/wine` (o `bin/wine64`) y `bin/wineserver`.
        case standard
    }

    public var name: String
    public var version: String?
    public var layout: Layout
    public var root: URL
    public var loader: URL
    public var wineserver: URL
    public var dllSearchPath: [URL]
    public var extraEnvironment: [String: String]
    /// DXVK: carpeta con `x86_64-windows`/`i386-windows` (o `x64`/`x32`).
    public var dxvkDirectory: URL?
    /// DXMT: misma estructura, más `x86_64-unix/winemetal.so`.
    public var dxmtDirectory: URL?
    /// Carpeta `lib/external` con D3DMetal.framework, si el motor lleva D3DMetal integrado
    /// (un Wine instalado con el Game Porting Toolkit de Apple).
    public var d3dMetalDirectory: URL?

    public init(
        name: String,
        version: String? = nil,
        layout: Layout,
        root: URL,
        loader: URL,
        wineserver: URL,
        dllSearchPath: [URL] = [],
        extraEnvironment: [String: String] = [:],
        dxvkDirectory: URL? = nil,
        dxmtDirectory: URL? = nil,
        d3dMetalDirectory: URL? = nil
    ) {
        self.name = name
        self.version = version
        self.layout = layout
        self.root = root
        self.loader = loader
        self.wineserver = wineserver
        self.dllSearchPath = dllSearchPath
        self.extraEnvironment = extraEnvironment
        self.dxvkDirectory = dxvkDirectory
        self.dxmtDirectory = dxmtDirectory
        self.d3dMetalDirectory = d3dMetalDirectory
    }

    public var id: String { root.standardizedFileURL.path }
    public var supportsDXVK: Bool { dxvkDirectory != nil }
    public var availableBackends: [GraphicsBackend] { GraphicsResolver.availableBackends(for: self) }

    public var displayName: String {
        if let version, !version.isEmpty { "\(name) · \(version)" } else { name }
    }

    /// Etiquetas cortas de lo que trae el motor para juegos.
    public var gamingBadges: [String] {
        var badges: [String] = []
        if d3dMetalDirectory != nil { badges.append("D3DMetal") }
        if dxmtDirectory != nil { badges.append("DXMT") }
        if dxvkDirectory != nil { badges.append("DXVK") }
        return badges
    }
}

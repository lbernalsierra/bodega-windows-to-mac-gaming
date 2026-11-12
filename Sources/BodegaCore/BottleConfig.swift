import Foundation

public enum WindowsVersion: String, Codable, CaseIterable, Sendable, Identifiable {
    case win11, win10, win81, win7, winxp64

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        case .winxp64: "Windows XP (64 bits)"
        }
    }
}

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Elige el mejor traductor disponible en el motor.
    case automatic
    /// Direct3D 11/12 → Metal con D3DMetal (Game Porting Toolkit de Apple).
    case d3dmetal
    /// Direct3D 10/11 → Metal con DXMT (libre).
    case dxmt
    /// Direct3D 9–11 → Vulkan con DXVK y → Metal con MoltenVK (libres).
    case dxvk
    /// Direct3D → OpenGL con el traductor propio de Wine.
    case wined3d

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automático"
        case .d3dmetal: "D3DMetal (D3D11/12 → Metal)"
        case .dxmt: "DXMT (D3D10/11 → Metal)"
        case .dxvk: "DXVK (D3D9–11 → Vulkan → Metal)"
        case .wined3d: "WineD3D (OpenGL)"
        }
    }
}

/// Programa anclado por el usuario. La ruta es relativa a la carpeta de la botella
/// para que sobreviva a exportar/importar o renombrar.
public struct PinnedProgram: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var relativePath: String
    /// Perfil de lanzamiento propio del programa (p. ej. un juego que necesita «-dx11»).
    public var arguments: [String]
    public var environment: [String: String]
    /// Fuerza el Direct3D de Wine (WineD3D) solo para este ejecutable, con una regla en el
    /// registro (`AppDefaults`): sirve también cuando el juego lo lanza Steam.
    public var forceWineD3D: Bool

    public var id: String { relativePath }
    public var executableName: String { (relativePath as NSString).lastPathComponent }

    public init(name: String, relativePath: String, arguments: [String] = [], environment: [String: String] = [:], forceWineD3D: Bool = false) {
        self.name = name
        self.relativePath = relativePath
        self.arguments = arguments
        self.environment = environment
        self.forceWineD3D = forceWineD3D
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        forceWineD3D = try c.decodeIfPresent(Bool.self, forKey: .forceWineD3D) ?? false
    }

    public func url(in bottle: Bottle) -> URL {
        bottle.url.appending(path: relativePath)
    }
}

/// Configuración propia de Bodega, guardada como `bodega.json` dentro de la botella.
public struct BottleConfig: Codable, Hashable, Sendable {
    public var engineID: String?
    public var windowsVersion: WindowsVersion
    public var graphics: GraphicsBackend
    public var msync: Bool
    public var esync: Bool
    public var retinaMode: Bool
    /// HUD de rendimiento de Metal (FPS, GPU, memoria) — `MTL_HUD_ENABLED`.
    public var metalHUD: Bool
    /// Anuncia AVX/AVX2 bajo Rosetta 2, que piden muchos juegos recientes — `ROSETTA_ADVERTISE_AVX`.
    public var advertiseAVX: Bool
    /// Deja que los programas de inicio de Windows (Steam, Epic con «-silent») arranquen solos.
    public var startupPrograms: Bool
    public var debugChannels: String
    public var environment: [String: String]
    public var pinnedPrograms: [PinnedProgram]
    /// Ejecutables (p. ej. de juegos de Steam) que usan el Direct3D de Wine en esta botella.
    public var wineD3DExecutables: [String]
    public var notes: String
    public var created: Date

    public init(
        engineID: String? = nil,
        windowsVersion: WindowsVersion = .win10,
        graphics: GraphicsBackend = .automatic,
        msync: Bool = true,
        esync: Bool = false,
        retinaMode: Bool = false,
        metalHUD: Bool = false,
        advertiseAVX: Bool = true,
        startupPrograms: Bool = false,
        debugChannels: String = "-all",
        environment: [String: String] = [:],
        pinnedPrograms: [PinnedProgram] = [],
        wineD3DExecutables: [String] = [],
        notes: String = "",
        created: Date = Date()
    ) {
        self.engineID = engineID
        self.windowsVersion = windowsVersion
        self.graphics = graphics
        self.msync = msync
        self.esync = esync
        self.retinaMode = retinaMode
        self.metalHUD = metalHUD
        self.advertiseAVX = advertiseAVX
        self.startupPrograms = startupPrograms
        self.debugChannels = debugChannels
        self.environment = environment
        self.pinnedPrograms = pinnedPrograms
        self.wineD3DExecutables = wineD3DExecutables
        self.notes = notes
        self.created = created
    }

    // Decodificación tolerante: los campos ausentes toman su valor por defecto,
    // así las botellas antiguas siguen abriendo cuando se añaden ajustes nuevos.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BottleConfig()
        engineID = try c.decodeIfPresent(String.self, forKey: .engineID)
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? defaults.windowsVersion
        graphics = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics) ?? defaults.graphics
        msync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? defaults.msync
        esync = try c.decodeIfPresent(Bool.self, forKey: .esync) ?? defaults.esync
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? defaults.retinaMode
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? defaults.metalHUD
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? defaults.advertiseAVX
        startupPrograms = try c.decodeIfPresent(Bool.self, forKey: .startupPrograms) ?? defaults.startupPrograms
        debugChannels = try c.decodeIfPresent(String.self, forKey: .debugChannels) ?? defaults.debugChannels
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        pinnedPrograms = try c.decodeIfPresent([PinnedProgram].self, forKey: .pinnedPrograms) ?? []
        wineD3DExecutables = try c.decodeIfPresent([String].self, forKey: .wineD3DExecutables) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? defaults.created
    }
}

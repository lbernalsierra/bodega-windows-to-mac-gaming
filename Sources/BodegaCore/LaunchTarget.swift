import Foundation

/// Qué ejecutar dentro de una botella y cómo pedírselo a Wine.
public enum LaunchTarget: Hashable, Sendable {
    case executable(URL)
    case installer(URL)
    case batch(URL)
    case shortcut(URL)
    case tool(WineTool)

    public init(file: URL) {
        switch file.pathExtension.lowercased() {
        case "msi", "msp": self = .installer(file)
        case "bat", "cmd": self = .batch(file)
        case "lnk": self = .shortcut(file)
        default: self = .executable(file)
        }
    }

    public var displayName: String {
        switch self {
        case .executable(let url), .installer(let url), .batch(let url), .shortcut(let url):
            url.deletingPathExtension().lastPathComponent
        case .tool(let tool):
            tool.displayName
        }
    }

    /// Argumentos para el cargador de Wine y carpeta de trabajo. `windowsPath` convierte las
    /// rutas que reciben programas de Windows (msiexec, cmd): con una ruta Unix, msiexec de
    /// Wine se colgaba con un desbordamiento al instalar Epic Games.
    public func wineArguments(
        extra: [String] = [],
        windowsPath: (URL) -> String = { "Z:" + $0.path.replacingOccurrences(of: "/", with: #"\"#) }
    ) -> (arguments: [String], workingDirectory: URL?) {
        switch self {
        case .executable(let url):
            // El cargador de Wine sí entiende rutas Unix para el programa principal.
            ([url.path] + extra, url.deletingLastPathComponent())
        case .installer(let url):
            (["msiexec", "/i", windowsPath(url)] + extra, url.deletingLastPathComponent())
        case .batch(let url):
            (["cmd", "/c", windowsPath(url)] + extra, url.deletingLastPathComponent())
        case .shortcut(let url):
            // `start /wait` mantiene vivo el proceso mientras dura el programa del acceso directo.
            (["start", "/wait", "/unix", url.path] + extra, nil)
        case .tool(let tool):
            (tool.wineArguments + extra, nil)
        }
    }

    public static let supportedExtensions = ["exe", "com", "msi", "msp", "bat", "cmd", "lnk"]
}

/// Utilidades de Windows que incluye Wine.
public enum WineTool: String, CaseIterable, Sendable, Identifiable {
    case winecfg, regedit, taskmgr, control, explorer, cmd, uninstaller

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .winecfg: "Configuración de Wine"
        case .regedit: "Editor del registro"
        case .taskmgr: "Administrador de tareas"
        case .control: "Panel de control"
        case .explorer: "Explorador de archivos"
        case .cmd: "Símbolo del sistema"
        case .uninstaller: "Desinstalar programas"
        }
    }

    public var symbolName: String {
        switch self {
        case .winecfg: "gearshape"
        case .regedit: "list.bullet.indent"
        case .taskmgr: "chart.bar.xaxis"
        case .control: "slider.horizontal.3"
        case .explorer: "folder"
        case .cmd: "terminal"
        case .uninstaller: "trash"
        }
    }

    var wineArguments: [String] {
        switch self {
        case .cmd: ["start", "cmd"]
        case .explorer: ["explorer", "C:\\"]
        default: [rawValue]
        }
    }
}

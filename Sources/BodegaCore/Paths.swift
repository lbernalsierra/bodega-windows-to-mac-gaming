import Foundation

/// Ubicaciones en disco de Bodega. `BODEGA_HOME` permite aislarlas (tests, pruebas).
public enum Paths {
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["BODEGA_HOME"], !custom.isEmpty {
            return URL(filePath: custom, directoryHint: .isDirectory)
        }
        return defaultHome
    }

    /// Carpeta de datos estándar, aunque `BODEGA_HOME` apunte a otra: los motores instalados
    /// allí se comparten con cualquier carpeta de pruebas.
    public static var defaultHome: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Bodega", directoryHint: .isDirectory)
    }

    public static var bottles: URL { home.appending(path: "Bottles", directoryHint: .isDirectory) }
    /// Motores Wine instalados por el usuario (cada subcarpeta es un motor con `bin/wine`).
    public static var engines: URL { home.appending(path: "Engines", directoryHint: .isDirectory) }
    /// Componentes opcionales compartidos, p. ej. `Components/dxvk`.
    public static var components: URL { home.appending(path: "Components", directoryHint: .isDirectory) }
}

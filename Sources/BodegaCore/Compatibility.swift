import Foundation

/// Ajuste de Bodega para un ejecutable concreto, aplicado con el mecanismo estándar de Wine
/// `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`. Es la alternativa propia a la base
/// de datos de compatibilidad de otros lanzadores comerciales.
public struct CompatibilityRule: Sendable, Equatable {
    public var executable: String
    public var dllOverrides: [String: String]
    public var reason: String
    /// Comprobado en este Mac con trazas de Wine; las demás reglas aplican el mismo
    /// remedio a lanzadores con el mismo motor (Chromium/CEF o QtWebEngine).
    public var verified: Bool
}

public enum CompatibilityRules {
    /// Las interfaces web de los lanzadores sondean dxgi/d3d11 al arrancar y Chromium aborta
    /// (excepción 0x80000003 en libcef.dll) con DXMT. No necesitan Metal: usan el Direct3D de Wine.
    static let wineD3D = Dictionary(uniqueKeysWithValues: GraphicsResolver.managedDLLs.map { ($0, "builtin") })

    /// Sin reglas gráficas para las interfaces web de los lanzadores. Comprobado en este Mac
    /// (Wine 11): si la interfaz de Steam dibuja sin GPU, o con el Direct3D de Wine, su ventana
    /// queda en negro. Lo que funciona es la GPU activa con DXMT y swapchain entre procesos
    /// (ver `WineRunner.environment` y `GraphicsResolver.registryFile`).
    public static let builtIn: [CompatibilityRule] = []
}

extension CompatibilityRules {
    /// Reglas integradas más las que el usuario ha marcado en sus programas anclados.
    public static func rules(for config: BottleConfig) -> [CompatibilityRule] {
        let pinned = config.pinnedPrograms.filter(\.forceWineD3D).map {
            CompatibilityRule(executable: $0.executableName, dllOverrides: wineD3D, reason: "Elegido por el usuario para \($0.name).", verified: true)
        }
        let games = config.wineD3DExecutables.map {
            CompatibilityRule(executable: $0, dllOverrides: wineD3D, reason: "Elegido por el usuario.", verified: true)
        }
        var seen = Set<String>()
        let user = (pinned + games).filter { seen.insert($0.executable.lowercased()).inserted }
        let userNames = Set(user.map { $0.executable.lowercased() })
        return builtIn.filter { !userNames.contains($0.executable.lowercased()) } + user
    }
}

extension GraphicsResolver {
    /// Fichero .reg que fija el plan gráfico de la botella y las reglas por ejecutable.
    /// Va en el registro, no en WINEDLLOVERRIDES: la variable de entorno tiene prioridad
    /// sobre AppDefaults y anularía las reglas por programa.
    public static func registryFile(for plan: GraphicsPlan, rules: [CompatibilityRule] = CompatibilityRules.builtIn) -> String {
        func mode(_ short: String) -> String {
            switch short {
            case "n,b": "native,builtin"
            case "b,n": "builtin,native"
            case "n": "native"
            case "b": "builtin"
            case "": ""
            default: short
            }
        }
        var lines = ["REGEDIT4", "", #"[HKEY_CURRENT_USER\Software\Wine\DllOverrides]"#]
        for dll in plan.overrides.entryNames {
            lines.append("\"\(dll)\"=\"\(mode(plan.overrides[dll] ?? ""))\"")
        }
        for rule in rules {
            lines.append("")
            lines.append(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\"# + rule.executable + #"\DllOverrides]"#)
            for dll in rule.dllOverrides.keys.sorted() {
                lines.append("\"\(dll)\"=\"\(rule.dllOverrides[dll]!)\"")
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

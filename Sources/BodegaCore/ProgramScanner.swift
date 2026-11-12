import Foundation

public struct DiscoveredProgram: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case shortcut, executable }

    public var name: String
    public var url: URL
    public var kind: Kind

    public var id: String { url.path }
}

/// Encuentra los programas instalados en una botella: accesos directos del menú Inicio
/// y del Escritorio, y ejecutables dentro de Program Files.
public enum ProgramScanner {
    static let ignoredWords = [
        "uninst", "desinst", "unins0", "readme", "léame", "leame", "license", "licencia",
        "help", "ayuda", "website", "sitio web", "manual", "setup", "update", "updater",
        "crash", "report", "helper", "redist", "vcredist", "dotnet",
    ]

    /// Carpetas que crea Wine y no contienen programas del usuario.
    static let ignoredProgramFolders: Set<String> = [
        "common files", "internet explorer", "windows media player", "windows nt", "microsoft.net", "windowspowershell",
    ]

    public static func scan(_ bottle: Bottle) -> (shortcuts: [DiscoveredProgram], executables: [DiscoveredProgram]) {
        (shortcuts(in: bottle), executables(in: bottle))
    }

    public static func shortcuts(in bottle: Bottle) -> [DiscoveredProgram] {
        let fm = FileManager.default
        let c = bottle.driveC
        var roots = [
            c.appending(path: "ProgramData/Microsoft/Windows/Start Menu/Programs"),
            c.appending(path: "users/Public/Desktop"),
        ]
        if let users = try? fm.contentsOfDirectory(at: c.appending(path: "users"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for user in users {
                roots.append(user.appending(path: "AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
                roots.append(user.appending(path: "Desktop"))
            }
        }
        var byName: [String: DiscoveredProgram] = [:]
        for root in roots {
            for file in files(in: root, extensions: ["lnk"], maxDepth: 4) {
                let name = file.deletingPathExtension().lastPathComponent
                guard !isIgnored(name) else { continue }
                byName[name.lowercased()] = byName[name.lowercased()] ?? DiscoveredProgram(name: name, url: file, kind: .shortcut)
            }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func executables(in bottle: Bottle) -> [DiscoveredProgram] {
        let fm = FileManager.default
        var result: [DiscoveredProgram] = []
        for folder in ["Program Files", "Program Files (x86)"] {
            let root = bottle.driveC.appending(path: folder, directoryHint: .isDirectory)
            guard let vendors = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for vendor in vendors where !ignoredProgramFolders.contains(vendor.lastPathComponent.lowercased()) {
                for exe in files(in: vendor, extensions: ["exe"], maxDepth: 3) {
                    let name = exe.deletingPathExtension().lastPathComponent
                    guard !isIgnored(name) else { continue }
                    result.append(DiscoveredProgram(name: name, url: exe, kind: .executable))
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isIgnored(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ignoredWords.contains { lower.contains($0) }
    }

    static func files(in root: URL, extensions: Set<String>, maxDepth: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if extensions.contains(item.pathExtension.lowercased()),
               (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(item)
            }
        }
        return found
    }
}

import Foundation

/// Representa `WINEDLLOVERRIDES` («d3d11,dxgi=n,b;winemenubuilder.exe=d»).
public struct DllOverrides: Equatable, Sendable, CustomStringConvertible {
    private var entries: [String: String] = [:]

    public init() {}

    public init(parsing text: String) {
        merge(parsing: text)
    }

    /// Nombres de DLL con override, ordenados.
    public var entryNames: [String] { entries.keys.sorted() }

    public subscript(dll: String) -> String? {
        get { entries[dll.lowercased()] }
        set { entries[dll.lowercased()] = newValue }
    }

    /// Las entradas de `text` sustituyen a las existentes con el mismo nombre.
    public mutating func merge(parsing text: String) {
        for group in text.split(separator: ";") {
            let parts = group.split(separator: "=", maxSplits: 1)
            guard let dlls = parts.first else { continue }
            let mode = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            for dll in dlls.split(separator: ",") {
                let name = dll.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { self[name] = mode }
            }
        }
    }

    public var description: String {
        // Agrupa las DLL con el mismo modo para obtener una cadena estable y compacta.
        let grouped = Dictionary(grouping: entries.keys, by: { entries[$0] ?? "" })
        return grouped.keys.sorted()
            .map { mode in grouped[mode, default: []].sorted().joined(separator: ",") + "=" + mode }
            .joined(separator: ";")
    }
}

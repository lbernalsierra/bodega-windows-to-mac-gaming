import Foundation

/// Programas de inicio de Windows (`HKCU\…\CurrentVersion\Run`). Steam y Epic se apuntan ahí
/// con `-silent`: en una botella eso significa que, abras lo que abras, arrancan en segundo plano
/// (y Epic se queda en la bandeja al cerrarlo). Bodega los aparta a una clave propia, de la que se
/// pueden restaurar.
///
/// Se edita `user.reg` directamente y solo con la botella parada: usar `reg delete` arrancaría
/// Wine, que es justo lo que ejecuta esas entradas, y con el servidor activo Wine sobrescribe el fichero.
public enum StartupItems {
    static let runHeader = #"[Software\\Microsoft\\Windows\\CurrentVersion\\Run]"#
    static let parkedHeader = #"[Software\\Bodega\\InicioDesactivado]"#

    /// Nombres de las entradas apartadas en esta llamada.
    @discardableResult
    public static func disable(in bottle: Bottle) throws -> [String] {
        try move(from: runHeader, to: parkedHeader, in: bottle)
    }

    @discardableResult
    public static func restore(in bottle: Bottle) throws -> [String] {
        try move(from: parkedHeader, to: runHeader, in: bottle)
    }

    /// Entradas activas ahora mismo (nombre → orden).
    public static func active(in bottle: Bottle) -> [String] {
        guard let text = try? String(contentsOf: bottle.url.appending(path: "user.reg"), encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        return extractValues(of: runHeader, from: &lines).map(valueName)
    }

    static func move(from source: String, to destination: String, in bottle: Bottle) throws -> [String] {
        guard !BottleProcesses.isServerRunning(for: bottle) else { return [] }
        let file = bottle.url.appending(path: "user.reg")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let (result, moved) = moveValues(in: text, from: source, to: destination)
        guard !moved.isEmpty else { return [] }
        try result.write(to: file, atomically: true, encoding: .utf8)
        return moved
    }

    /// Transformación pura del texto de `user.reg` (probada en los tests).
    static func moveValues(in text: String, from source: String, to destination: String) -> (String, [String]) {
        var lines = text.components(separatedBy: "\n")
        let values = extractValues(of: source, from: &lines)
        guard !values.isEmpty else { return (text, []) }
        let names = values.map(valueName)

        if let header = lines.firstIndex(where: { $0.hasPrefix(destination + " ") || $0 == destination }) {
            // Sustituye las del mismo nombre y añade el resto al final de la sección.
            var end = header + 1
            while end < lines.count, !lines[end].isEmpty, !lines[end].hasPrefix("[") { end += 1 }
            var body = Array(lines[(header + 1)..<end])
            body = removeValues(named: Set(names), from: body)
            body += values.flatMap { $0 }
            lines.replaceSubrange((header + 1)..<end, with: body)
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", destination + " \(Int(Date().timeIntervalSince1970))"] + values.flatMap { $0 } + [""]
        }
        return (lines.joined(separator: "\n"), names)
    }

    /// Saca los valores (cada uno con sus líneas de continuación) de una sección.
    static func extractValues(of header: String, from lines: inout [String]) -> [[String]] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix(header + " ") || $0 == header }) else { return [] }
        var index = start + 1
        var values: [[String]] = []
        var kept: [String] = []
        while index < lines.count, !lines[index].isEmpty, !lines[index].hasPrefix("[") {
            let line = lines[index]
            if line.hasPrefix("\"") {
                var value = [line]
                while value.last?.hasSuffix("\\") == true, index + 1 < lines.count {
                    index += 1
                    value.append(lines[index])
                }
                values.append(value)
            } else {
                kept.append(line)   // #time=…, @=…
            }
            index += 1
        }
        lines.replaceSubrange((start + 1)..<index, with: kept)
        return values
    }

    static func removeValues(named names: Set<String>, from body: [String]) -> [String] {
        var result: [String] = []
        var skipping = false
        for line in body {
            if skipping {
                skipping = line.hasSuffix("\\")
                continue
            }
            if line.hasPrefix("\""), names.contains(valueName([line])) {
                skipping = line.hasSuffix("\\")
                continue
            }
            result.append(line)
        }
        return result
    }

    static func valueName(_ value: [String]) -> String {
        let line = value.first ?? ""
        guard line.hasPrefix("\""), let end = line.dropFirst().firstIndex(of: "\"") else { return line }
        return String(line[line.index(after: line.startIndex)..<end])
    }
}

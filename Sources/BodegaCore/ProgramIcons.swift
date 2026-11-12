import Foundation

/// Lee iconos de ejecutables de Windows (recursos RT_GROUP_ICON/RT_ICON del formato PE)
/// y destinos de accesos directos `.lnk` (formato MS-SHLLINK). Solo lee bytes: no ejecuta nada.
public enum ProgramIcons {
    /// Icono más grande del ejecutable como fichero `.ico` (un solo tamaño), o nil.
    public static func icoData(forExecutable url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return PEResources(data: data)?.bestIcon()
    }

    /// Icono para un programa: el del `.exe`, o el del destino de un `.lnk`.
    public static func icoData(for url: URL, in bottle: Bottle) -> Data? {
        if url.pathExtension.lowercased() == "lnk" {
            guard let link = ShellLink(url: url) else { return nil }
            for candidate in [link.iconLocation, link.targetPath].compactMap({ $0 }) {
                if let unix = bottle.unixURL(forWindowsPath: candidate) {
                    if unix.pathExtension.lowercased() == "ico", let ico = try? Data(contentsOf: unix) { return ico }
                    if let ico = icoData(forExecutable: unix) { return ico }
                }
            }
            return nil
        }
        return icoData(forExecutable: url)
    }
}

/// Lector mínimo de la tabla de recursos de un PE.
struct PEResources {
    let data: Data
    let resourceOffset: Int
    let resourceRVA: Int
    let sections: [(va: Int, size: Int, raw: Int)]

    init?(data: Data) {
        self.data = data
        guard data.count > 0x40, data.u16(0) == 0x5A4D else { return nil }
        let pe = Int(data.u32(0x3C))
        guard pe > 0, pe + 24 < data.count, data.u32(pe) == 0x0000_4550 else { return nil }
        let sectionCount = Int(data.u16(pe + 6))
        let optionalSize = Int(data.u16(pe + 20))
        let optional = pe + 24
        let magic = data.u16(optional)
        let directories = optional + (magic == 0x20B ? 112 : 96)
        guard directories + 24 <= data.count else { return nil }
        let rva = Int(data.u32(directories + 16))
        guard rva > 0 else { return nil }
        var sections: [(Int, Int, Int)] = []
        var table = optional + optionalSize
        for _ in 0..<sectionCount where table + 40 <= data.count {
            let virtualSize = Int(data.u32(table + 8)), va = Int(data.u32(table + 12))
            let rawSize = Int(data.u32(table + 16)), raw = Int(data.u32(table + 20))
            sections.append((va, max(virtualSize, rawSize), raw))
            table += 40
        }
        self.sections = sections
        self.resourceRVA = rva
        guard let offset = PEResources.offset(ofRVA: rva, in: sections) else { return nil }
        self.resourceOffset = offset
    }

    static func offset(ofRVA rva: Int, in sections: [(va: Int, size: Int, raw: Int)]) -> Int? {
        for section in sections where rva >= section.va && rva < section.va + section.size {
            return rva - section.va + section.raw
        }
        return nil
    }

    /// Entradas (id, offset) de un directorio de recursos; `isDirectory` si apunta a otro nivel.
    func entries(at directory: Int) -> [(id: UInt32, offset: Int, isDirectory: Bool)] {
        let base = resourceOffset + directory
        guard base + 16 <= data.count else { return [] }
        let count = Int(data.u16(base + 12)) + Int(data.u16(base + 14))
        var result: [(UInt32, Int, Bool)] = []
        for i in 0..<min(count, 4096) {
            let entry = base + 16 + i * 8
            guard entry + 8 <= data.count else { break }
            let target = data.u32(entry + 4)
            result.append((data.u32(entry), Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0))
        }
        return result
    }

    /// Primer bloque de datos bajo un directorio (primer nombre, primer idioma).
    func firstData(under offset: Int, isDirectory: Bool, depth: Int = 0) -> Data? {
        if !isDirectory {
            let entry = resourceOffset + offset
            guard entry + 8 <= data.count else { return nil }
            let rva = Int(data.u32(entry)), size = Int(data.u32(entry + 4))
            guard let start = PEResources.offset(ofRVA: rva, in: sections), size > 0, start + size <= data.count else { return nil }
            return data.subdata(in: start..<(start + size))
        }
        guard depth < 3, let first = entries(at: offset).first else { return nil }
        return firstData(under: first.offset, isDirectory: first.isDirectory, depth: depth + 1)
    }

    func bestIcon() -> Data? {
        let types = entries(at: 0)
        guard let groups = types.first(where: { $0.id == 14 }), let icons = types.first(where: { $0.id == 3 }) else { return nil }
        // Iconos individuales por id.
        var iconData: [UInt32: Data] = [:]
        for icon in entries(at: icons.offset) {
            if let blob = firstData(under: icon.offset, isDirectory: icon.isDirectory, depth: 1) { iconData[icon.id] = blob }
        }
        guard let firstGroup = entries(at: groups.offset).first,
              let group = firstData(under: firstGroup.offset, isDirectory: firstGroup.isDirectory, depth: 1),
              group.count >= 6 else { return nil }
        let count = Int(group.u16(4))
        var best: (score: Int, entry: Data, id: UInt32)?
        for i in 0..<count {
            let e = 6 + i * 14
            guard e + 14 <= group.count else { break }
            let width = Int(group[e]) == 0 ? 256 : Int(group[e])
            let bits = Int(group.u16(e + 6))
            let id = UInt32(group.u16(e + 12))
            guard iconData[id] != nil else { continue }
            let score = width * 100 + bits
            if best == nil || score > best!.score { best = (score, group.subdata(in: e..<(e + 12)), id) }
        }
        guard let chosen = best, let image = iconData[chosen.id] else { return nil }
        // ICONDIR + una ICONDIRENTRY (16 bytes) + imagen.
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(chosen.entry.prefix(8))                 // ancho, alto, colores, reservado, planos, bits
        ico.append(UInt32(image.count).littleEndianData)   // tamaño
        ico.append(UInt32(22).littleEndianData)            // desplazamiento de la imagen
        ico.append(image)
        return ico
    }
}

/// Lector mínimo de accesos directos `.lnk`.
public struct ShellLink {
    public var targetPath: String?
    public var arguments: String?
    public var iconLocation: String?

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count >= 0x4C, data.u32(0) == 0x4C else { return nil }
        let flags = data.u32(0x14)
        var position = 0x4C
        if flags & 0x1 != 0 { position += 2 + Int(data.u16(position)) }
        if flags & 0x2 != 0, position + 28 <= data.count {
            let info = position
            let size = Int(data.u32(info))
            let infoFlags = data.u32(info + 8)
            if infoFlags & 0x1 != 0 {
                let base = data.cString(at: info + Int(data.u32(info + 16)))
                let suffix = data.cString(at: info + Int(data.u32(info + 24)))
                if let base { targetPath = base + (suffix ?? "") }
            }
            position = info + size
        }
        let unicode = flags & 0x80 != 0
        func readString() -> String? {
            guard position + 2 <= data.count else { return nil }
            let count = Int(data.u16(position))
            let length = unicode ? count * 2 : count
            let start = position + 2
            position = start + length
            guard position <= data.count else { return nil }
            let bytes = data.subdata(in: start..<position)
            return unicode ? String(data: bytes, encoding: .utf16LittleEndian) : String(data: bytes, encoding: .windowsCP1252)
        }
        if flags & 0x04 != 0 { _ = readString() }               // nombre
        var relative: String?
        if flags & 0x08 != 0 { relative = readString() }
        if flags & 0x10 != 0 { _ = readString() }               // carpeta de trabajo
        if flags & 0x20 != 0 { arguments = readString() }
        if flags & 0x40 != 0 { iconLocation = readString().flatMap { $0.isEmpty ? nil : $0 } }
        if targetPath == nil { targetPath = relative }
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    func cString(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        let slice = self[(startIndex + offset)...]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(data: self[(startIndex + offset)..<end], encoding: .windowsCP1252)
    }
}

extension UInt32 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

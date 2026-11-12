import AppKit
import Foundation

/// Crea apps de macOS que abren un programa de una botella, para el Dock o el Launchpad
/// (`~/Applications/Bodega Apps`). La app solo abre una URL `bodega://run?...`: el programa
/// lo lanza Bodega, que le cede el primer plano.
public enum MacShortcuts {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Bodega Apps", directoryHint: .isDirectory)
    }

    public static func runURL(bottle: Bottle, program: URL, arguments: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = "bodega"
        components.host = "run"
        components.queryItems = [URLQueryItem(name: "bottle", value: bottle.name), URLQueryItem(name: "path", value: program.path)]
            + arguments.map { URLQueryItem(name: "arg", value: $0) }
        return components.url
    }

    /// Devuelve la ruta de la app creada.
    @discardableResult
    public static func create(name: String, bottle: Bottle, program: URL, arguments: [String] = [], icon: NSImage?, in folder: URL = MacShortcuts.folder) throws -> URL {
        let fm = FileManager.default
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let app = folder.appending(path: "\(safe).app", directoryHint: .isDirectory)
        try? fm.removeItem(at: app)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)

        guard let url = runURL(bottle: bottle, program: program, arguments: arguments) else {
            throw BodegaError.archiveInvalid("no se pudo crear el enlace del programa")
        }
        let script = "#!/bin/sh\nexec /usr/bin/open '\(url.absoluteString.replacingOccurrences(of: "'", with: "%27"))'\n"
        let executable = contents.appending(path: "MacOS/abrir")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var hasIcon = false
        if let icon, let icns = try? makeICNS(from: icon) {
            try icns.write(to: contents.appending(path: "Resources/AppIcon.icns"))
            hasIcon = true
        }
        // Identificador estable (FNV-1a), para que macOS reconozca la misma app al recrearla.
        let hash = (bottle.name + "|" + program.path).utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        let identifier = "io.github.lbernalsierra.bodega.app." + String(hash, radix: 36)
        let plist: [String: Any] = [
            "CFBundleExecutable": "abrir",
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
            "CFBundleIconFile": hasIcon ? "AppIcon" : "",
            "BodegaBottle": bottle.name,
            "BodegaProgram": program.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        return app
    }

    /// Convierte una imagen en .icns con `iconutil` (herramienta del sistema).
    static func makeICNS(from image: NSImage) throws -> Data {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "bodega-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        let iconset = work.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let png = pngData(of: image, size: px) else { continue }
                try png.write(to: iconset.appending(path: scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"))
            }
        }
        let output = work.appending(path: "AppIcon.icns")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: output)
    }

    static func pngData(of image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Los iconos de Windows son cuadrados; las carátulas de Steam se recortan al centro.
        let source = image.size
        let side = min(source.width, source.height)
        let crop = NSRect(x: (source.width - side) / 2, y: (source.height - side) / 2, width: side, height: side)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

import Foundation

/// Componentes de Windows que piden muchos juegos y programas fuera de Steam (Steam ya
/// instala los suyos por juego). Se usan los instaladores oficiales de Microsoft, en modo
/// normal: la licencia la acepta el usuario en el propio instalador.
public enum WindowsDependency: String, CaseIterable, Sendable, Identifiable {
    case vcRedist
    case directX

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vcRedist: "Visual C++ 2015–2022"
        case .directX: "DirectX (junio 2010)"
        }
    }

    public var detail: String {
        switch self {
        case .vcRedist: "Bibliotecas de C++ que usan casi todos los juegos modernos (64 y 32 bits)."
        case .directX: "D3DX9/10/11, XAudio, XInput y XACT para juegos de 2005 a 2015."
        }
    }

    public var symbolName: String {
        switch self {
        case .vcRedist: "curlybraces"
        case .directX: "gamecontroller"
        }
    }

    struct Download {
        var url: URL
        var fileName: String
    }

    var downloads: [Download] {
        switch self {
        case .vcRedist:
            [Download(url: URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!, fileName: "vc_redist.x64.exe"),
             Download(url: URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!, fileName: "vc_redist.x86.exe")]
        case .directX:
            [Download(url: URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!, fileName: "directx_Jun2010_redist.exe")]
        }
    }

    /// Descarga los instaladores a `C:\users\Public\Downloads` y los ejecuta uno tras otro,
    /// esperando a que el usuario termine cada uno.
    public func install(in runner: WineRunner, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let bottle = runner.bottle
        let folder = bottle.downloadsDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for download in downloads {
            progress("Descargando \(download.fileName)…")
            let (temporary, response) = try await URLSession.shared.download(from: download.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw BodegaError.downloadFailed("\(download.fileName): respuesta \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let destination = folder.appending(path: download.fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            files.append(destination)
        }
        switch self {
        case .vcRedist:
            for file in files {
                progress("Instalando \(file.lastPathComponent)…")
                try await runAndWait(.executable(file), runner: runner)
            }
        case .directX:
            // El paquete de junio de 2010 es un autoextraíble: se descomprime (sin instalar nada)
            // y luego se abre DXSETUP, donde el usuario acepta la licencia.
            let extracted = folder.appending(path: "DirectX", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: extracted)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            progress("Descomprimiendo DirectX…")
            _ = try await runner.runAndWait([files[0].path, "/Q", "/T:" + bottle.windowsPath(for: extracted)], workingDirectory: folder, check: false)
            let setup = extracted.appending(path: "DXSETUP.exe")
            guard FileManager.default.fileExists(atPath: setup.path) else {
                throw BodegaError.archiveInvalid("el paquete de DirectX no contiene DXSETUP.exe")
            }
            progress("Instalando DirectX…")
            try await runAndWait(.executable(setup), runner: runner)
        }
        progress("Listo.")
    }

    private func runAndWait(_ target: LaunchTarget, runner: WineRunner) async throws {
        let (exits, continuation) = AsyncStream<Int32>.makeStream()
        _ = try await runner.launch(target) { status in
            continuation.yield(status)
            continuation.finish()
        }
        for await _ in exits {}
    }
}

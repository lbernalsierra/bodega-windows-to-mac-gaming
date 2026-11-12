import Darwin
import Foundation

/// Procesos de Wine de una botella, identificados por su carpeta de servidor
/// `/tmp/.wine-<uid>/server-<dispositivo>-<inodo>` (dispositivo e inodo de la carpeta de la
/// botella, en hexadecimal). Todo proceso de la botella, incluso huérfano tras caerse su
/// `wineserver`, mantiene abiertos ficheros `tmpmap-*` en esa carpeta.
public enum BottleProcesses {
    public static func serverDirectory(for bottle: Bottle) -> URL? {
        var info = stat()
        guard stat(bottle.url.path, &info) == 0 else { return nil }
        let name = String(format: "server-%llx-%llx", UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
        return URL(filePath: "/private/tmp/.wine-\(getuid())/\(name)", directoryHint: .isDirectory)
    }

    /// El `wineserver` de la botella está activo si su socket acepta conexiones.
    public static func isServerRunning(for bottle: Bottle) -> Bool {
        guard let socketPath = serverDirectory(for: bottle)?.appending(path: "socket").path else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    /// PID de los procesos con ficheros abiertos en la carpeta de servidor de la botella.
    public static func processIDs(for bottle: Bottle) async -> [Int32] {
        guard let directory = serverDirectory(for: bottle),
              FileManager.default.fileExists(atPath: directory.path),
              let output = try? await ProcessRunner.run(
                  executable: URL(filePath: "/usr/sbin/lsof"),
                  arguments: ["-t", "+d", directory.path],
                  environment: [:],
                  timeout: 15
              )
        else { return [] }
        let own = getpid()
        return Set(output.output.split(whereSeparator: \.isNewline).compactMap { Int32($0) })
            .filter { $0 != own }
            .sorted()
    }

    /// Cierra esos procesos: primero con SIGTERM y, si siguen vivos, con SIGKILL.
    @discardableResult
    public static func forceQuit(_ pids: [Int32]) async -> Int {
        guard !pids.isEmpty else { return 0 }
        for pid in pids { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(2))
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return pids.count
    }
}

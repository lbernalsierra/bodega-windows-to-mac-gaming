import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var output: String
}

public enum ProcessRunner {
    /// Ejecuta un proceso hasta que termina y devuelve stdout+stderr.
    /// La salida va a un fichero temporal para no bloquear con tuberías llenas.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessOutput {
        let fm = FileManager.default
        let capture = fm.temporaryDirectory.appending(path: "bodega-\(UUID().uuidString).log")
        fm.createFile(atPath: capture.path, contents: nil)
        defer { try? fm.removeItem(at: capture) }
        let handle = try FileHandle(forWritingTo: capture)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                if let timeout {
                    // Al vencer el plazo se termina solo este proceso (p. ej. «wineserver -w»).
                    let box = ProcessBox(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.terminateIfRunning() }
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? handle.close()
        let data = (try? Data(contentsOf: capture)) ?? Data()
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return ProcessOutput(status: status, output: text)
    }
}

/// Permite terminar un `Process` desde otra cola.
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminateIfRunning() { if process.isRunning { process.terminate() } }
}

/// Un programa lanzado en segundo plano. Envuelve `Process` (que no es Sendable);
/// solo se consulta su estado y se le pide terminar.
public final class RunningProgram: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    public let bottleID: String
    public let started = Date()
    public let logURL: URL
    private let process: Process

    init(name: String, bottleID: String, logURL: URL, process: Process) {
        self.name = name
        self.bottleID = bottleID
        self.logURL = logURL
        self.process = process
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }
}

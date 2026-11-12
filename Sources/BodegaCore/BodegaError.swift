import Foundation

public enum BodegaError: LocalizedError, Equatable {
    case invalidBottleName(String)
    case bottleExists(String)
    case bottleNotFound(String)
    case noEngine
    case engineNotFound(String)
    case commandFailed(command: String, status: Int32, output: String)
    case archiveInvalid(String)
    case backendUnavailable(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBottleName(let name):
            "El nombre «\(name)» no es válido. Usa letras, números, espacios, guiones o puntos, sin «/» y sin empezar por punto."
        case .bottleExists(let name):
            "Ya existe una botella llamada «\(name)»."
        case .bottleNotFound(let name):
            "No se encuentra la botella «\(name)»."
        case .noEngine:
            "No hay ningún motor Wine disponible. Instala uno (por ejemplo Wine Stable) o añade su carpeta en Ajustes › Motores."
        case .engineNotFound(let id):
            "No se encuentra el motor Wine en \(id)."
        case .commandFailed(let command, let status, let output):
            "«\(command)» terminó con código \(status).\n\(output.suffix(800))"
        case .archiveInvalid(let reason):
            "El archivo de botella no es válido: \(reason)"
        case .backendUnavailable(let name):
            "Este motor no incluye \(name). Añade el componente en \(Paths.components.path) o elige «Automático»."
        case .downloadFailed(let reason):
            "No se pudo descargar el instalador: \(reason)"
        }
    }
}

import Foundation

/// Una DLL de un componente gráfico, en sus variantes de 64 y 32 bits.
public struct ComponentDLL: Equatable, Sendable {
    public var name: String
    public var x64: URL?
    public var x32: URL?
}

/// Cómo quedan los gráficos Direct3D de una botella con un motor concreto.
public struct GraphicsPlan: Equatable, Sendable {
    /// Motor efectivo (nunca `.automatic`).
    public var backend: GraphicsBackend
    public var summary: String
    /// Se copian a system32/syswow64 y se cargan como nativas.
    public var native: [ComponentDLL]
    /// Auxiliares que Wine debe cargar como builtin (p. ej. winemetal de DXMT).
    public var helpers: [ComponentDLL]
    /// Carpetas donde Wine debe buscar la parte Unix de los auxiliares.
    public var dllPathAdditions: [URL]
    public var overrides: DllOverrides
}

/// Elige e instala los traductores Direct3D. Método verificado con trazas `+loaddll`:
/// las DLL se copian a la botella sin la marca «Wine builtin DLL» (Wine se niega a cargar
/// como nativa una DLL marcada) y se fijan como `n,b`; el resto queda en builtin.
public enum GraphicsResolver {
    /// DLL de Direct3D que Bodega controla en cada botella.
    public static let managedDLLs = ["d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "d3d12", "dxgi"]
    static let dxmtHelpers: Set<String> = ["winemetal"]
    /// Capas NVIDIA (DLSS/NVAPI) de DXMT: se dejan fuera para no hacer creer al juego que hay una GPU NVIDIA.
    static let dxmtExcluded: Set<String> = ["nvapi64", "nvngx"]

    public static func availableBackends(for engine: WineEngine) -> [GraphicsBackend] {
        var result: [GraphicsBackend] = [.automatic]
        if engine.d3dMetalDirectory != nil { result.append(.d3dmetal) }
        if engine.dxmtDirectory != nil { result.append(.dxmt) }
        if engine.dxvkDirectory != nil { result.append(.dxvk) }
        // En un Wine con D3DMetal integrado, sus d3d11/dxgi sustituyen a los de Wine.
        if engine.d3dMetalDirectory == nil { result.append(.wined3d) }
        return result
    }

    public static func plan(for requested: GraphicsBackend, engine: WineEngine) -> GraphicsPlan {
        let available = availableBackends(for: engine)
        let backend = available.contains(requested) ? requested : .automatic
        let note = backend == requested ? "" : " (\(requested.displayName) no está disponible en este motor)"
        let dxvk = libraries(in: engine.dxvkDirectory)
        let dxmt = libraries(in: engine.dxmtDirectory)

        // En Automático, D3D9 va por WineD3D: la DXVK que funciona sobre MoltenVK (1.10.x)
        // no compila los shaders de muchos juegos D3D9 (Bulb Boy/Unity 5: pantalla negra con
        // «DxvkGraphicsPipeline: Failed to compile pipeline»). DXVK sigue disponible a mano.
        var plan: GraphicsPlan
        switch backend {
        case .automatic:
            if engine.d3dMetalDirectory != nil {
                plan = d3dMetalPlan()
                plan.summary = "D3DMetal (D3D11/12) · D3D9 con WineD3D"
            } else if !dxmt.isEmpty {
                plan = dxmtPlan(dxmt, engine: engine)
                plan.summary = "DXMT (D3D10/11 → Metal) · D3D9 con WineD3D"
            } else if !dxvk.isEmpty {
                plan = GraphicsPlan(backend: .dxvk, summary: "DXVK (D3D9–11 → Vulkan → Metal)", native: dxvk, helpers: [], dllPathAdditions: [], overrides: DllOverrides())
            } else {
                plan = GraphicsPlan(backend: .wined3d, summary: "WineD3D (OpenGL)", native: [], helpers: [], dllPathAdditions: [], overrides: DllOverrides())
            }
        case .d3dmetal:
            plan = d3dMetalPlan()
        case .dxmt:
            plan = dxmtPlan(dxmt, engine: engine)
        case .dxvk:
            plan = GraphicsPlan(backend: .dxvk, summary: "DXVK (D3D9–11 → Vulkan → Metal)", native: dxvk, helpers: [], dllPathAdditions: [], overrides: DllOverrides())
        case .wined3d:
            plan = GraphicsPlan(backend: .wined3d, summary: "WineD3D (OpenGL)", native: [], helpers: [], dllPathAdditions: [], overrides: DllOverrides())
        }

        let nativeNames = Set(plan.native.map(\.name))
        for dll in managedDLLs {
            plan.overrides[dll] = nativeNames.contains(dll) ? "n,b" : "b"
        }
        for dll in nativeNames where !managedDLLs.contains(dll) {
            plan.overrides[dll] = "n,b"
        }
        for helper in plan.helpers {
            plan.overrides[helper.name] = "b"
        }
        plan.summary += note
        return plan
    }

    private static func d3dMetalPlan() -> GraphicsPlan {
        // Las DLL de D3DMetal ya son las builtin del motor: basta con no sustituirlas.
        GraphicsPlan(backend: .d3dmetal, summary: "D3DMetal (D3D11/12)", native: [], helpers: [], dllPathAdditions: [], overrides: DllOverrides())
    }

    private static func dxmtPlan(_ dlls: [ComponentDLL], engine: WineEngine) -> GraphicsPlan {
        let root = engine.dxmtDirectory
        return GraphicsPlan(
            backend: .dxmt,
            summary: "DXMT (D3D10/11 → Metal)",
            native: dlls.filter { !dxmtHelpers.contains($0.name) && !dxmtExcluded.contains($0.name) },
            helpers: dlls.filter { dxmtHelpers.contains($0.name) },
            dllPathAdditions: root.map { [$0, $0.appending(path: "x86_64-windows"), $0.appending(path: "i386-windows")] } ?? [],
            overrides: DllOverrides()
        )
    }

    /// DLL de un componente (`x86_64-windows`/`i386-windows` o `x64`/`x32`).
    public static func libraries(in directory: URL?) -> [ComponentDLL] {
        guard let directory else { return [] }
        let fm = FileManager.default
        func dlls(_ candidates: [String]) -> [String: URL] {
            for sub in candidates {
                let folder = directory.appending(path: sub, directoryHint: .isDirectory)
                guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
                let found = items.filter { $0.pathExtension.lowercased() == "dll" }
                if !found.isEmpty {
                    return Dictionary(found.map { ($0.deletingPathExtension().lastPathComponent.lowercased(), $0) }) { first, _ in first }
                }
            }
            return [:]
        }
        let x64 = dlls(["x86_64-windows", "x64"])
        let x32 = dlls(["i386-windows", "x32"])
        return Set(x64.keys).union(x32.keys).sorted().map { ComponentDLL(name: $0, x64: x64[$0], x32: x32[$0]) }
    }

    // MARK: - Instalación en la botella

    static let builtinMarker = Data("Wine builtin DLL".utf8)

    public static func install(_ plan: GraphicsPlan, into bottle: Bottle) throws {
        let (system32, syswow64) = systemFolders(of: bottle)
        let fm = FileManager.default
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
        for dll in plan.native {
            if let x64 = dll.x64 { try copyDLL(x64, to: system32.appending(path: "\(dll.name).dll"), asNative: true) }
            if let x32 = dll.x32 { try copyDLL(x32, to: syswow64.appending(path: "\(dll.name).dll"), asNative: true) }
        }
        for dll in plan.helpers {
            if let x64 = dll.x64 { try copyDLL(x64, to: system32.appending(path: "\(dll.name).dll"), asNative: false) }
            if let x32 = dll.x32 { try copyDLL(x32, to: syswow64.appending(path: "\(dll.name).dll"), asNative: false) }
        }
    }

    /// Comprueba que las DLL nativas del plan siguen en la botella (Wine puede
    /// sustituirlas por las suyas al actualizar el prefijo).
    public static func isInstalled(_ plan: GraphicsPlan, in bottle: Bottle) -> Bool {
        let (system32, syswow64) = systemFolders(of: bottle)
        for dll in plan.native {
            let pairs: [(URL?, URL)] = [(dll.x64, system32), (dll.x32, syswow64)]
            for case let (source?, folder) in pairs {
                let target = folder.appending(path: "\(dll.name).dll")
                guard let handle = try? FileHandle(forReadingFrom: target) else { return false }
                defer { try? handle.close() }
                let head = (try? handle.read(upToCount: 0x100)) ?? Data()
                if head.range(of: builtinMarker) != nil { return false }
                let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let targetSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
                if sourceSize != targetSize { return false }
            }
        }
        return true
    }

    static func systemFolders(of bottle: Bottle) -> (URL, URL) {
        let windows = bottle.driveC.appending(path: "windows", directoryHint: .isDirectory)
        return (windows.appending(path: "system32", directoryHint: .isDirectory), windows.appending(path: "syswow64", directoryHint: .isDirectory))
    }

    static func copyDLL(_ source: URL, to target: URL, asNative: Bool) throws {
        var data = try Data(contentsOf: source)
        if asNative, let range = data.range(of: builtinMarker, in: 0..<min(data.count, 0x100)) {
            data.replaceSubrange(range, with: Data(count: range.count))
        }
        try data.write(to: target, options: .atomic)
    }
}

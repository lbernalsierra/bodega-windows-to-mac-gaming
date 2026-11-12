import AppKit
import Foundation
import Testing
@testable import BodegaCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bodega-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func touch(_ url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    if executable {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private func fakeEngine(root: URL, dxvk: URL? = nil) -> WineEngine {
    WineEngine(
        name: "Prueba",
        layout: .standard,
        root: root,
        loader: root.appending(path: "bin/wine"),
        wineserver: root.appending(path: "bin/wineserver"),
        dxvkDirectory: dxvk
    )
}

@Suite struct BottleNameTests {
    @Test(arguments: ["Juegos", "Office 2016", "Steam-x64", "Mi.Botella", "Programas (viejos)"])
    func acceptsValidNames(_ name: String) throws {
        try BottleName.validate(name)
    }

    @Test(arguments: ["", " ", ".oculta", "a/b", " espacio", "dos:puntos", String(repeating: "x", count: 65)])
    func rejectsInvalidNames(_ name: String) {
        #expect(throws: BodegaError.invalidBottleName(name)) { try BottleName.validate(name) }
    }
}

@Suite struct LaunchTargetTests {
    @Test func mapsExtensionsToWineCommands() {
        let dir = URL(filePath: "/tmp/app")
        let exe = LaunchTarget(file: dir.appending(path: "Juego.EXE"))
        #expect(exe == .executable(dir.appending(path: "Juego.EXE")))
        #expect(exe.wineArguments().arguments == ["/tmp/app/Juego.EXE"])
        #expect(exe.wineArguments().workingDirectory?.path == "/tmp/app")

        let msi = LaunchTarget(file: dir.appending(path: "setup.msi"))
        // msiexec nunca recibe rutas Unix (las toma por opciones y se colgaba con Epic Games).
        #expect(msi.wineArguments().arguments == ["msiexec", "/i", #"Z:\tmp\app\setup.msi"#])

        let bat = LaunchTarget(file: dir.appending(path: "run.bat"))
        #expect(bat.wineArguments(extra: ["-x"]).arguments == ["cmd", "/c", #"Z:\tmp\app\run.bat"#, "-x"])

        let lnk = LaunchTarget(file: dir.appending(path: "App.lnk"))
        #expect(lnk.wineArguments().arguments == ["start", "/wait", "/unix", "/tmp/app/App.lnk"])
        #expect(lnk.displayName == "App")
    }

    @Test func toolsUseBuiltinPrograms() {
        #expect(LaunchTarget.tool(.regedit).wineArguments().arguments == ["regedit"])
        #expect(LaunchTarget.tool(.cmd).wineArguments().arguments == ["start", "cmd"])
    }
}

@Suite struct DllOverridesTests {
    @Test func parsesAndGroupsByMode() {
        var overrides = DllOverrides(parsing: "d3d11,dxgi=n,b;winemenubuilder.exe=d")
        #expect(overrides["D3D11"] == "n,b")
        overrides.merge(parsing: "dxgi=b")
        #expect(overrides["dxgi"] == "b")
        #expect(overrides.description == "dxgi=b;winemenubuilder.exe=d;d3d11=n,b")
    }
}

/// Crea una DLL falsa con la marca builtin de Wine en 0x40, como las de los paquetes «builtin» de DXVK/DXMT.
private func fakeDLL(_ url: URL, builtin: Bool = true) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = Data("MZ".utf8) + Data(count: 0x3E)
    data += builtin ? Data("Wine builtin DLL".utf8) : Data(count: 16)
    data += Data(count: 0x200)
    try data.write(to: url)
}

private func gamingEngine(root: URL, d3dmetal: Bool = false) throws -> WineEngine {
    let dxvk = root.appending(path: "dxvk")
    for dll in ["d3d9", "d3d10core", "d3d11", "dxgi"] {
        try fakeDLL(dxvk.appending(path: "x86_64-windows/\(dll).dll"))
        try fakeDLL(dxvk.appending(path: "i386-windows/\(dll).dll"))
    }
    let dxmt = root.appending(path: "dxmt")
    for dll in ["d3d10core", "d3d11", "dxgi", "winemetal", "nvapi64"] {
        try fakeDLL(dxmt.appending(path: "x86_64-windows/\(dll).dll"))
    }
    var engine = fakeEngine(root: root, dxvk: dxvk)
    engine.dxmtDirectory = dxmt
    if d3dmetal { engine.d3dMetalDirectory = root.appending(path: "lib/external") }
    return engine
}

@Suite struct WineRunnerEnvironmentTests {
    @Test func buildsIsolatedEnvironment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root.appending(path: "Botella"), config: BottleConfig(msync: true, esync: true, metalHUD: true))
        let runner = WineRunner(engine: fakeEngine(root: root), bottle: bottle)

        let env = runner.environment(base: ["HOME": "/Users/x", "WINEPREFIX": "/otro", "WINEARCH": "win32", "MTL_HUD_ENABLED": "0"])
        #expect(env["HOME"] == "/Users/x")
        #expect(env["WINEPREFIX"] == bottle.url.path)
        #expect(env["WINEARCH"] == nil)
        #expect(env["WINEDEBUG"] == "-all")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == "1")
        #expect(env["MTL_HUD_ENABLED"] == "1")
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(env["WINESERVER"] == root.appending(path: "bin/wineserver").path)
        let overrides = DllOverrides(parsing: env["WINEDLLOVERRIDES"] ?? "")
        #expect(overrides["winemenubuilder.exe"] == "d")
        // Los gráficos no van en el entorno (anularía las reglas por ejecutable) sino en el registro.
        #expect(overrides["d3d11"] == nil)
        #expect(env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] == nil)
        // Sin componentes, todo Direct3D queda en el WineD3D builtin.
        #expect(runner.graphicsPlan.overrides["d3d11"] == "b")
        #expect(runner.graphicsPlan.backend == .wined3d)
    }

    @Test func registryCarriesPlanAndPerExecutableRules() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = GraphicsResolver.plan(for: .automatic, engine: try gamingEngine(root: root))
        let reg = GraphicsResolver.registryFile(for: plan)
        let lines = reg.components(separatedBy: "\r\n")
        #expect(lines.first == "REGEDIT4")
        let global = try #require(lines.firstIndex(of: #"[HKEY_CURRENT_USER\Software\Wine\DllOverrides]"#))
        #expect(lines[global...].contains(#""d3d11"="native,builtin""#))
        #expect(lines[global...].contains(#""winemetal"="builtin""#))
        // Las interfaces web (Steam…) ya no se fuerzan a WineD3D: en Wine 11 eso las dejaba en negro.
        #expect(!reg.contains("steamwebhelper.exe"))
        #expect(CompatibilityRules.builtIn.isEmpty)
    }

    @Test func programProfileOverridesBottleEnvironment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = BottleConfig()
        config.environment = ["DXVK_HUD": "fps", "WINEDLLOVERRIDES": "mscoree=d"]
        let runner = WineRunner(engine: fakeEngine(root: root), bottle: Bottle(url: root, config: config))
        let env = runner.environment(base: [:], program: ["DXVK_HUD": "full", "WINEDLLOVERRIDES": "xinput1_3=n"])
        #expect(env["DXVK_HUD"] == "full")
        let overrides = DllOverrides(parsing: env["WINEDLLOVERRIDES"] ?? "")
        #expect(overrides["mscoree"] == "d")
        #expect(overrides["xinput1_3"] == "n")
    }
}

@Suite struct GraphicsTests {
    @Test func automaticUsesDXMTAndWineD3DForD3D9() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try gamingEngine(root: root)
        #expect(engine.availableBackends == [.automatic, .dxmt, .dxvk, .wined3d])

        let plan = GraphicsResolver.plan(for: .automatic, engine: engine)
        #expect(plan.backend == .dxmt)
        #expect(plan.native.map(\.name) == ["d3d10core", "d3d11", "dxgi"])
        #expect(plan.helpers.map(\.name) == ["winemetal"])
        #expect(plan.overrides["d3d11"] == "n,b")
        // DXVK 1.10 sobre MoltenVK deja en negro juegos D3D9 (Bulb Boy): en Automático, WineD3D.
        #expect(plan.overrides["d3d9"] == "b")
        #expect(plan.overrides["d3d12"] == "b")
        #expect(plan.overrides["winemetal"] == "b")
        #expect(plan.overrides["nvapi64"] == nil)
        #expect(plan.dllPathAdditions.first == engine.dxmtDirectory)
        // Chromium presenta desde otro proceso: DXMT lo permite solo con esta variable.
        let env = WineRunner(engine: engine, bottle: Bottle(url: root, config: BottleConfig())).environment(base: [:])
        #expect(env["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"] == "1")
    }

    @Test func explicitBackendsAndFallback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try gamingEngine(root: root)

        let dxvk = GraphicsResolver.plan(for: .dxvk, engine: engine)
        #expect(dxvk.backend == .dxvk)
        #expect(dxvk.native.map(\.name) == ["d3d10core", "d3d11", "d3d9", "dxgi"])

        let wined3d = GraphicsResolver.plan(for: .wined3d, engine: engine)
        #expect(wined3d.native.isEmpty)
        #expect(wined3d.overrides["dxgi"] == "b")

        let missing = GraphicsResolver.plan(for: .d3dmetal, engine: engine)
        #expect(missing.backend == .dxmt)
        #expect(missing.summary.contains("no está disponible"))
    }

    @Test func d3dMetalEnginesUseTheirBuiltins() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try gamingEngine(root: root, d3dmetal: true)
        #expect(!engine.availableBackends.contains(.wined3d))
        let plan = GraphicsResolver.plan(for: .automatic, engine: engine)
        #expect(plan.backend == .d3dmetal)
        #expect(plan.overrides["d3d12"] == "b")
        #expect(plan.overrides["d3d11"] == "b")
        #expect(plan.native.isEmpty)
    }

    @Test func installsNativeCopiesWithoutBuiltinMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try gamingEngine(root: root)
        let bottle = Bottle(url: root.appending(path: "Botella"), config: BottleConfig(graphics: .dxmt))
        let plan = GraphicsResolver.plan(for: .dxmt, engine: engine)
        #expect(GraphicsResolver.isInstalled(plan, in: bottle) == false)

        try GraphicsResolver.install(plan, into: bottle)
        let system32 = bottle.driveC.appending(path: "windows/system32")
        let d3d11 = try Data(contentsOf: system32.appending(path: "d3d11.dll"))
        let winemetal = try Data(contentsOf: system32.appending(path: "winemetal.dll"))
        #expect(d3d11.range(of: Data("Wine builtin DLL".utf8)) == nil)
        #expect(winemetal.range(of: Data("Wine builtin DLL".utf8)) != nil)
        #expect(GraphicsResolver.isInstalled(plan, in: bottle))

        // Si Wine repone su propia DLL builtin, se detecta para reinstalar.
        try fakeDLL(system32.appending(path: "d3d11.dll"))
        #expect(GraphicsResolver.isInstalled(plan, in: bottle) == false)
    }
}

@Suite struct CompatibilityRulesTests {
    @Test func userPinnedGamesCanForceWineD3D() throws {
        var config = BottleConfig()
        config.pinnedPrograms = [
            PinnedProgram(name: "Bulb Boy", relativePath: "drive_c/Program Files (x86)/Steam/steamapps/common/Bulb Boy/BulbBoy.exe", forceWineD3D: true),
            PinnedProgram(name: "Otro", relativePath: "drive_c/Juegos/otro.exe"),
        ]
        let rules = CompatibilityRules.rules(for: config)
        let bulb = try #require(rules.first { $0.executable == "BulbBoy.exe" })
        #expect(bulb.dllOverrides["d3d9"] == "builtin")
        #expect(!rules.contains { $0.executable == "otro.exe" })
        #expect(rules.count == 1)

        let reg = GraphicsResolver.registryFile(for: GraphicsResolver.plan(for: .wined3d, engine: fakeEngine(root: URL(filePath: "/nonexistent"))), rules: rules)
        #expect(reg.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\BulbBoy.exe\DllOverrides]"#))
    }
}

@Suite struct SteamLibraryTests {
    @Test func readsManifestsArtworkAndExecutables() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root, config: BottleConfig())
        try FileManager.default.createDirectory(at: root.appending(path: "dosdevices"), withIntermediateDirectories: true)
        // Como en una botella real: enlace relativo, para que la ruta resuelta no coincida literalmente.
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
        let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam")
        try touch(steam.appending(path: "steam.exe"))
        try touch(steam.appending(path: "appcache/librarycache/390290/library_600x900.jpg"))
        let game = steam.appending(path: "steamapps/common/Bulb Boy")
        try touch(game.appending(path: "BulbBoy.exe"))
        try touch(game.appending(path: "UnityCrashHandler64.exe"))
        try touch(game.appending(path: "_CommonRedist/vcredist_x64.exe"))
        try #"""
        "AppState"
        {
        	"appid"		"390290"
        	"name"		"Bulb Boy"
        	"StateFlags"		"4"
        	"installdir"		"Bulb Boy"
        	"LastPlayed"		"1700000000"
        	"InstalledDepots" { "390291" { "manifest" "1" } }
        }
        """#.write(to: steam.appending(path: "steamapps/appmanifest_390290.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "installdir" "Steamworks Shared" }"#
            .write(to: steam.appending(path: "steamapps/appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try #""libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } }"#
            .write(to: steam.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let games = SteamLibrary.games(in: bottle)
        #expect(games.map(\.name) == ["Bulb Boy"])
        let bulb = try #require(games.first)
        #expect(bulb.appID == "390290")
        #expect(bulb.isInstalled)
        #expect(bulb.coverArt?.lastPathComponent == "library_600x900.jpg")
        #expect(bulb.executableNames == ["BulbBoy.exe"])
        #expect(SteamLibrary.launchArguments(for: bulb) == ["-applaunch", "390290"])

        var config = BottleConfig()
        config.wineD3DExecutables = bulb.executableNames
        #expect(CompatibilityRules.rules(for: config).contains { $0.executable == "BulbBoy.exe" })
    }
}

/// .lnk mínimo con LinkInfo (ruta local) y argumentos, según MS-SHLLINK.
private func makeShellLink(target: String, arguments: String) -> Data {
    var header = Data(count: 0x4C)
    header[0] = 0x4C
    let clsid: [UInt8] = [0x01, 0x14, 0x02, 0x00, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]
    header.replaceSubrange(4..<20, with: clsid)
    let flags: UInt32 = 0x2 | 0x20 | 0x80
    header.replaceSubrange(0x14..<0x18, with: flags.littleEndianData)
    let volume = Data([0x10, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0])
    let base = Data(target.utf8) + Data([0])
    let suffix = Data([0])
    let headerSize = 0x1C
    let baseOffset = headerSize + volume.count
    let suffixOffset = baseOffset + base.count
    var info = Data()
    let total = suffixOffset + suffix.count
    for value in [total, headerSize, 1, headerSize, baseOffset, 0, suffixOffset] { info += UInt32(value).littleEndianData }
    info += volume + base + suffix
    let args = Data(arguments.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    return header + info + Data([UInt8(arguments.utf16.count & 0xFF), UInt8(arguments.utf16.count >> 8)]) + args
}

@Suite struct ProgramIconTests {
    @Test func readsShellLinkTargetAndArguments() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lnk = root.appending(path: "Juego.lnk")
        try makeShellLink(target: #"C:\Juegos\juego.exe"#, arguments: "-dx11 -windowed").write(to: lnk)
        let link = try #require(ShellLink(url: lnk))
        #expect(link.targetPath == #"C:\Juegos\juego.exe"#)
        #expect(link.arguments == "-dx11 -windowed")
    }

    @Test func mapsWindowsPathsThroughDosDevices() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root, config: BottleConfig())
        try FileManager.default.createDirectory(at: root.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
        try touch(bottle.driveC.appending(path: "Juegos/juego.exe"))
        let url = try #require(bottle.unixURL(forWindowsPath: #""C:\Juegos\juego.exe",0"#))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(bottle.unixURL(forWindowsPath: "juego.exe") == nil)
    }

    @Test func rejectsFilesThatAreNotPE() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "falso.exe")
        try Data("no soy un ejecutable".utf8).write(to: file)
        #expect(ProgramIcons.icoData(forExecutable: file) == nil)
    }

    /// Con un ejecutable real de Wine (si Bodega tiene motor instalado), el icono sale como .ico válido.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: Paths.defaultHome.appending(path: "Engines/Motor Bodega 26.3.app/Contents/Resources/wine/lib/wine/x86_64-windows/notepad.exe").path)))
    func extractsIconFromRealExecutable() throws {
        let notepad = Paths.defaultHome.appending(path: "Engines/Motor Bodega 26.3.app/Contents/Resources/wine/lib/wine/x86_64-windows/notepad.exe")
        let ico = try #require(ProgramIcons.icoData(forExecutable: notepad))
        #expect(ico.prefix(4) == Data([0, 0, 1, 0]))
        #expect(ico.count > 100)
    }
}

@Suite struct D3DMetalInstallerTests {
    @Test func locatesAndInstallsIntoAClonedEngine() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // GPTK de prueba con la estructura de Apple: redist/lib/{external,wine}.
        let lib = root.appending(path: "GPTK/redist/lib")
        try touch(lib.appending(path: "external/D3DMetal.framework/D3DMetal"))
        try touch(lib.appending(path: "external/libd3dshared.dylib"))
        try touch(lib.appending(path: "wine/x86_64-windows/d3d12.dll"))
        try touch(lib.appending(path: "wine/x86_64-unix/d3d12.so"))
        #expect(D3DMetalInstaller.locateRedistributable(in: root.appending(path: "GPTK"))?.resolvingSymlinksInPath().path == lib.resolvingSymlinksInPath().path)

        // Motor de prueba con estructura estándar (bin/wine, bin/wineserver).
        let engineRoot = root.appending(path: "Motor de prueba")
        try touch(engineRoot.appending(path: "bin/wine"), executable: true)
        try touch(engineRoot.appending(path: "bin/wineserver"), executable: true)
        try touch(engineRoot.appending(path: "lib/wine/x86_64-windows/d3d12.dll"))
        let base = try #require(EngineLocator.engine(at: engineRoot))
        #expect(base.d3dMetalDirectory == nil)

        let installed = try await D3DMetalInstaller.install(redistributable: lib, basedOn: base)
        defer { try? FileManager.default.removeItem(at: installed) }
        let engine = try #require(EngineLocator.engine(at: installed))
        #expect(engine.d3dMetalDirectory != nil)
        #expect(engine.availableBackends.contains(.d3dmetal))
        #expect(engine.extraEnvironment["CX_APPLEGPTK_LIBD3DSHARED_PATH"]?.hasSuffix("lib/external/libd3dshared.dylib") == true)
        // El motor original queda intacto.
        #expect(EngineLocator.engine(at: engineRoot)?.d3dMetalDirectory == nil)
    }
}

@Suite struct MacShortcutTests {
    @Test func createsAnAppThatOpensTheProgramThroughBodega() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root.appending(path: "Mis juegos"), config: BottleConfig())
        let program = bottle.driveC.appending(path: "Program Files (x86)/Steam/steam.exe")
        let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        let app = try MacShortcuts.create(name: "Bulb Boy", bottle: bottle, program: program,
                                          arguments: ["-applaunch", "390290"], icon: icon, in: root.appending(path: "Apps"))
        #expect(app.lastPathComponent == "Bulb Boy.app")
        let plist = try #require(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")))
        #expect(plist["CFBundleExecutable"] as? String == "abrir")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/AppIcon.icns").path))
        let script = try String(contentsOf: app.appending(path: "Contents/MacOS/abrir"), encoding: .utf8)
        #expect(script.contains("bodega://run?bottle=Mis%20juegos"))
        #expect(script.contains("arg=-applaunch&arg=390290"))
        #expect(FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/abrir").path))
        // La URL se interpreta igual que la lee Bodega.
        let url = try #require(MacShortcuts.runURL(bottle: bottle, program: program, arguments: ["-applaunch", "390290"]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "path" }?.value == program.path)
    }
}

@Suite struct StartupItemsTests {
    // Fragmento con el formato real de user.reg (como el de una botella con Steam y Epic).
    static let userReg = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

    [Software\\Microsoft\\Windows\\CurrentVersion\\Run] 1700000200
    #time=1da0000000000c8
    "EpicGamesLauncher"="\"C:\\Program Files\\Epic Games\\Launcher\\Portal\\Binaries\\Win64\\EpicGamesLauncher.exe\" -silent -launchcontext=boot"
    "Largo"=hex:01,02,\
      03,04
    "Steam"="\"C:\\Program Files (x86)\\Steam\\steam.exe\" -silent"

    [Software\\Microsoft\\Windows\\CurrentVersion\\ThemeManager] 1700000100
    #time=1da000000000064
    "ColorName"="Blue"

    """#

    @Test func parksAndRestoresRunEntries() {
        let (parked, moved) = StartupItems.moveValues(in: Self.userReg, from: StartupItems.runHeader, to: StartupItems.parkedHeader)
        #expect(moved == ["EpicGamesLauncher", "Largo", "Steam"])
        var lines = parked.components(separatedBy: "\n")
        #expect(StartupItems.extractValues(of: StartupItems.runHeader, from: &lines).isEmpty)
        #expect(parked.contains(#"[Software\\Microsoft\\Windows\\CurrentVersion\\Run] 1700000200"#))
        #expect(parked.contains("#time=1da0000000000c8"))
        #expect(parked.contains(#"[Software\\Bodega\\InicioDesactivado]"#))
        #expect(parked.contains("  03,04"))
        #expect(parked.contains(#""ColorName"="Blue""#))

        // Steam vuelve a apuntarse: al apartarlo otra vez se sustituye, no se duplica.
        let readded = parked.replacingOccurrences(of: "#time=1da0000000000c8", with: "#time=1da0000000000c8\n\"Steam\"=\"nuevo\"")
        let (twice, again) = StartupItems.moveValues(in: readded, from: StartupItems.runHeader, to: StartupItems.parkedHeader)
        #expect(again == ["Steam"])
        #expect(twice.components(separatedBy: #""Steam"="#).count == 2)
        #expect(twice.contains(#""Steam"="nuevo""#))

        let (restored, back) = StartupItems.moveValues(in: twice, from: StartupItems.parkedHeader, to: StartupItems.runHeader)
        #expect(Set(back) == ["EpicGamesLauncher", "Largo", "Steam"])
        var restoredLines = restored.components(separatedBy: "\n")
        #expect(StartupItems.extractValues(of: StartupItems.runHeader, from: &restoredLines).count == 3)
    }

    @Test func leavesFilesWithoutRunEntriesUntouched() {
        let text = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n\"a\"=\"b\"\n"
        let (result, moved) = StartupItems.moveValues(in: text, from: StartupItems.runHeader, to: StartupItems.parkedHeader)
        #expect(moved.isEmpty)
        #expect(result == text)
    }

    @Test func serverDirectoryUsesDeviceAndInodeInHex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root, config: BottleConfig())
        let values = try FileManager.default.attributesOfItem(atPath: root.path)
        let inode = try #require(values[.systemFileNumber] as? UInt64)
        let directory = try #require(BottleProcesses.serverDirectory(for: bottle))
        #expect(directory.lastPathComponent.hasSuffix("-" + String(inode, radix: 16)))
        #expect(directory.path.hasPrefix("/private/tmp/.wine-"))
        #expect(BottleProcesses.isServerRunning(for: bottle) == false)
    }
}

@Suite struct BottleStoreTests {
    @Test func createsListsAndReloadsBottles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)

        var bottle = try store.prepareNewBottle(named: "Zeta", config: BottleConfig(windowsVersion: .win7))
        _ = try store.prepareNewBottle(named: "alfa", config: BottleConfig())
        #expect(throws: BodegaError.bottleExists("Zeta")) {
            try store.prepareNewBottle(named: "Zeta", config: BottleConfig())
        }

        bottle.config.pinnedPrograms = [PinnedProgram(name: "Juego", relativePath: "drive_c/Juego/juego.exe")]
        try store.save(bottle)

        let listed = try store.list()
        #expect(listed.map(\.name) == ["alfa", "Zeta"])
        let reloaded = try store.bottle(named: "Zeta")
        #expect(reloaded.config.windowsVersion == .win7)
        #expect(reloaded.config.pinnedPrograms.first?.url(in: reloaded).lastPathComponent == "juego.exe")
        #expect(reloaded.isInitialized == false)
    }

    @Test func decodesOlderConfigsWithDefaults() throws {
        let json = #"{"windowsVersion":"win81"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(BottleConfig.self, from: Data(json.utf8))
        #expect(config.windowsVersion == .win81)
        #expect(config.graphics == .automatic)
        #expect(config.advertiseAVX == true)
        #expect(config.msync == true)
        #expect(config.debugChannels == "-all")
    }

    @Test func windowsPathsPreferDriveC() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root.appending(path: "Mis juegos"), config: BottleConfig())
        let msi = bottle.downloadsDirectory.appending(path: "EpicGamesLauncherInstaller.msi")
        try touch(msi)
        #expect(bottle.windowsPath(for: msi) == #"C:\users\Public\Downloads\EpicGamesLauncherInstaller.msi"#)
        #expect(bottle.windowsPath(for: URL(filePath: "/Users/ana/Downloads/setup.msi")) == #"Z:\Users\ana\Downloads\setup.msi"#)
        let (args, _) = LaunchTarget(file: msi).wineArguments(windowsPath: bottle.windowsPath(for:))
        #expect(args == ["msiexec", "/i", #"C:\users\Public\Downloads\EpicGamesLauncherInstaller.msi"#])
    }

    @Test func relativePathStaysInsideBottle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root.appending(path: "B"), config: BottleConfig())
        try touch(bottle.driveC.appending(path: "App/app.exe"))
        #expect(bottle.relativePath(of: bottle.driveC.appending(path: "App/app.exe")) == "drive_c/App/app.exe")
        #expect(bottle.relativePath(of: URL(filePath: "/etc/hosts")) == nil)
    }
}

@Suite struct EngineLocatorTests {
    @Test func recognisesStandardLayouts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(EngineLocator.engine(at: root) == nil)

        try touch(root.appending(path: "bin/wine"), executable: true)
        try touch(root.appending(path: "bin/wineserver"), executable: true)
        let engine = try #require(EngineLocator.engine(at: root))
        #expect(engine.layout == .standard)
        #expect(engine.loader.lastPathComponent == "wine")

        let app = root.appending(path: "Wine Stable.app")
        try touch(app.appending(path: "Contents/Resources/wine/bin/wine64"), executable: true)
        try touch(app.appending(path: "Contents/Resources/wine/bin/wineserver"), executable: true)
        let appEngine = try #require(EngineLocator.engine(at: app))
        #expect(appEngine.name == "Wine Stable")
        #expect(appEngine.loader.lastPathComponent == "wine64")
    }

    @Test func commercialLaunchersAreNotUsedAsEngines() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Una app con su Wine dentro de SharedSupport (como algunos lanzadores comerciales) no es un motor para Bodega.
        let app = root.appending(path: "Lanzador.app")
        try touch(app.appending(path: "Contents/SharedSupport/Lanzador/lib/wine/x86_64-unix/wine"), executable: true)
        try touch(app.appending(path: "Contents/SharedSupport/Lanzador/bin/wineserver"), executable: true)
        #expect(EngineLocator.engine(at: app) == nil)
        #expect(EngineLocator.engine(at: app.appending(path: "Contents/SharedSupport/Lanzador")) == nil)
    }

    @Test func modernWineFoldersUseTheirStandardLoader() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Un Wine 11 compilado (como Motor Bodega) también tiene lib/wine/x86_64-unix/wine.
        try touch(root.appending(path: "bin/wine"), executable: true)
        try touch(root.appending(path: "bin/wineserver"), executable: true)
        try touch(root.appending(path: "lib/wine/x86_64-unix/wine"), executable: true)
        let engine = try #require(EngineLocator.engine(at: root))
        #expect(engine.layout == .standard)
        #expect(engine.loader.path.hasSuffix("bin/wine"))
    }
}

@Suite struct ProgramScannerTests {
    @Test func findsShortcutsAndExecutablesButSkipsNoise() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root, config: BottleConfig())
        let c = bottle.driveC
        try touch(c.appending(path: "ProgramData/Microsoft/Windows/Start Menu/Programs/Editor/Editor.lnk"))
        try touch(c.appending(path: "ProgramData/Microsoft/Windows/Start Menu/Programs/Editor/Uninstall Editor.lnk"))
        try touch(c.appending(path: "users/ana/Desktop/Juego.lnk"))
        try touch(c.appending(path: "users/ana/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Juego.lnk"))
        try touch(c.appending(path: "Program Files/Editor/editor.exe"))
        try touch(c.appending(path: "Program Files/Editor/unins000.exe"))
        try touch(c.appending(path: "Program Files (x86)/Juego/bin/juego.exe"))
        try touch(c.appending(path: "Program Files/Common Files/System/ole.exe"))
        try touch(c.appending(path: "Program Files/Deep/a/b/c/d/oculto.exe"))

        let found = ProgramScanner.scan(bottle)
        #expect(found.shortcuts.map(\.name) == ["Editor", "Juego"])
        #expect(found.executables.map(\.name) == ["editor", "juego"])
    }
}

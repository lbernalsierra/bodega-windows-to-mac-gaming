# Bodega

Ejecuta programas y **juegos de Windows en macOS** usando Wine. Es una app libre (licencia MIT), escrita desde cero en Swift/SwiftUI. Usa su propio motor, compilado en tu Mac desde el código fuente LGPL de Wine que publica CodeWeavers, y no necesita ningún programa comercial.

¿Cómo funciona por dentro? → [docs/COMO-FUNCIONA.md](docs/COMO-FUNCIONA.md)

## Instalar en otro Mac

Requisitos: Mac con Apple Silicon y macOS 14 o posterior.

1. Herramientas de Apple (si no están ya):
   ```bash
   xcode-select --install
   softwareupdate --install-rosetta
   ```
2. Descargar el código e instalar la app en `~/Applications`:
   ```bash
   git clone https://github.com/lbernalsierra/bodega-windows-to-mac-gaming.git ~/Developer/Bodega
   cd ~/Developer/Bodega && scripts/build-app.sh --install
   ```
3. Abrir **Bodega** y, en Ajustes › Motores, pulsar **Instalar** (motor libre, unos 240 MB).
4. **Para Steam** hace falta Motor Bodega, que trae el arreglo de la ventana negra. Se compila una vez (unos 15 minutos):
   ```bash
   brew install mingw-w64 bison flex freetype gnutls sdl2 glib
   ```
   Luego, en Ajustes › Motores, pulsar **Compilar…** (o ejecutar `engine/build-motor.sh`).
5. Crear una botella, pulsar **Steam** en «Tiendas de juegos» y a jugar.

Para actualizar: `git pull` y `scripts/build-app.sh --install`.

## Qué hace

- **Botellas**: Windows aislados (prefijos de Wine). Puedes crearlas, exportarlas e importarlas (`.tar.gz`) o moverlas a la Papelera.
- **Ejecutar** `.exe`, `.msi`, `.bat` y `.lnk`: arrastrándolos a la ventana, con «Ejecutar…» o con «Abrir con › Bodega». Cada ejecución guarda su registro en `logs/`. A los programas de Windows (msiexec, cmd) se les pasan siempre rutas `C:\…`/`Z:\…`.
- **Programas**:
  - Accesos directos y ejecutables de la botella, cada uno **con su icono real** (leído del `.exe` o del destino del `.lnk`).
  - Perfiles de lanzamiento: argumentos, variables y forzar WineD3D.
  - **Accesos en el Mac**: apps en `~/Applications/Bodega Apps` para el Dock y el Launchpad, que abren el programa a través de `bodega://run?…`.
- **Juegos**:
  - **Automático**: D3DMetal si el motor lo tiene; si no, DXMT (D3D10/11); si no, DXVK; si no, WineD3D. D3D9 va por WineD3D.
  - **Reglas por ejecutable** en el registro (por ejemplo, forzar WineD3D en un juego concreto). La interfaz de Steam funciona gracias a un **parche propio de Motor Bodega** (`engine/patches/`, mismo síntoma que el fallo 56014 de Wine): un solo proceso y sin GPU. Con otros motores se vería en negro.
  - Opciones: **MSync**, **AVX en Rosetta**, **HUD de Metal** y **Retina** (resolución nativa con escala de 192 ppp). Retina se aplica a toda la botella, porque Wine no permite activarlo por programa.
  - **Juegos de Steam**: carátulas, botón Jugar (`steam -applaunch`), WineD3D por juego y acceso en el Mac.
  - **Tiendas**: Steam, Epic Games, GOG Galaxy y Battle.net, con su instalador oficial.
  - **Componentes de Windows**: Visual C++ 2015–2022 y DirectX (junio 2010), con los instaladores de Microsoft (la licencia la aceptas tú). .NET va incluido con Wine Mono.
- **Herramientas de Windows**: winecfg, regedit, administrador de tareas, panel de control, explorador, cmd y desinstalador.

## Motores

| Motor | Qué es | Cómo se obtiene |
|---|---|---|
| **Motor Bodega 26.3** (preferido) | Wine 11.0 de CodeWeavers **con MSync**, FFmpeg y GStreamer (vídeo), Wine Mono 10.4.1, Gecko, DXMT 0.80 y DXVK 1.10.3 | `engine/build-motor.sh`, o Ajustes › Motores › «Compilar…» (unos 15 min) |
| Wine Staging 11.21 | Wine libre (Gcenx) con DXMT y DXVK; aporta las bibliotecas x86_64 para compilar Motor Bodega | Ajustes › Motores › «Instalar» o `bodegactl install-engine` (descarga verificada con SHA-256) |
| + D3DMetal (opcional) | Clon APFS de un motor con D3DMetal (DirectX 11/12 → Metal) | Descarga el Game Porting Toolkit de [Apple](https://developer.apple.com/games/game-porting-toolkit/) y pulsa «Añadir D3DMetal…». Úsalo solo si su licencia te lo permite |

Los motores están en `~/Library/Application Support/Bodega/Engines`, cada uno con un `BODEGA-PROCEDENCIA.txt` que indica de dónde sale cada pieza.

## Compilar y ejecutar

Solo hacen falta las Command Line Tools de Xcode (Swift 6).

```bash
scripts/build-app.sh --install  # crea build/Bodega.app y la copia a ~/Applications
scripts/test.sh                 # 31 tests (Swift Testing)
engine/build-motor.sh           # Motor Bodega (brew: mingw-w64 bison flex freetype gnutls sdl2 glib)
```

CLI `bodegactl` (en `Bodega.app/Contents/Resources`):

```bash
bodegactl engines | install-engine
bodegactl create Juegos
bodegactl apply Juegos
bodegactl graphics Juegos
bodegactl store Juegos steam
bodegactl steam Juegos
bodegactl shortcut Juegos 390290
bodegactl run Juegos ~/Downloads/setup.exe
```

`BODEGA_HOME` cambia la carpeta de datos (por defecto `~/Library/Application Support/Bodega`).

## Arquitectura

```
Sources/BodegaCore   motores, botellas, WineRunner, gráficos, reglas por ejecutable, Steam, tiendas,
                     dependencias, iconos PE/.lnk, accesos en el Mac, instaladores de motor y de D3DMetal
Sources/BodegaApp    SwiftUI
Sources/bodegactl    CLI
engine/              build-motor.sh y patches/ (compilación reproducible de Motor Bodega)
Tests/               31 tests
```

## Licencia

Bodega se publica bajo la [licencia MIT](LICENSE): puedes usarlo, copiarlo, modificarlo y redistribuirlo libremente, conservando el aviso de copyright. Se ofrece **tal cual, sin garantías**. Los parches de `engine/patches/` modifican Wine y son LGPL-2.1 o posterior, como Wine.

Este repositorio solo contiene código propio. Los componentes de terceros se descargan o se compilan en tu Mac y mantienen sus licencias:
- Wine (LGPL-2.1+), compilado desde las fuentes que publica CodeWeavers; Wine Mono y Wine Gecko.
- DXVK y DXMT (zlib), MoltenVK (Apache-2.0), FFmpeg y GStreamer (LGPL).
- **D3DMetal** es software de Apple: Bodega no lo incluye ni lo redistribuye. Cada usuario lo importa de su propia copia del Game Porting Toolkit y es responsable de cumplir la licencia de Apple.
- Las tiendas (Steam, Epic Games, GOG, Battle.net) y los componentes de Microsoft se descargan de sus webs oficiales, y sus condiciones las aceptas tú al instalarlos.

## Aviso

Bodega es un proyecto independiente. No está afiliado, patrocinado ni respaldado por CodeWeavers, Apple, Microsoft, Valve, Epic Games, GOG ni Blizzard. Todas las marcas pertenecen a sus respectivos dueños y se mencionan solo para describir con qué es compatible.

#!/bin/zsh
# Compila «Motor Bodega»: Wine 11.0 de CodeWeavers (con MSync) desde el código fuente LGPL
# que publican en su web. Reproducible de principio a fin.
#
# Requisitos: Command Line Tools, Homebrew con `mingw-w64 bison flex freetype gnutls sdl2 glib`
# y el motor libre «Wine Staging 11.21» instalado por Bodega (aporta las bibliotecas x86_64:
# freetype, gnutls, SDL2, MoltenVK, GStreamer/FFmpeg, Gecko, DXMT y DXVK).
#
# Uso: engine/build-motor.sh [carpeta-de-trabajo]     (por defecto ~/Library/Caches/Bodega/motor)
set -euo pipefail

CX_VERSION=26.3.0
CX_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
MONO_VERSION=10.4.1
MONO_SHA256=a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb
FFMPEG_VERSION=7.1.1     # misma ABI que las bibliotecas FFmpeg del motor libre (libavcodec 61)
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1

W=${1:-$HOME/Library/Caches/Bodega/motor}
ENGINES="$HOME/Library/Application Support/Bodega/Engines"
FREE="$ENGINES/Wine Staging 11.21.app/Contents/Resources/wine"
DEST="$ENGINES/Motor Bodega ${CX_VERSION%.*}.app"
mkdir -p "$W"/{src,build,install}
[[ -d "$FREE/lib/wine" ]] || { echo "Falta el motor libre: instálalo antes desde Bodega (Ajustes › Motores)"; exit 1; }
for tool in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
  command -v $tool >/dev/null || [[ -x /opt/homebrew/bin/$tool ]] || { echo "Falta mingw-w64: brew install mingw-w64 bison flex freetype gnutls sdl2 glib"; exit 1; }
done

fetch() { # url destino sha256
  [[ -f "$2" ]] || curl -fL --retry 3 -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c - >/dev/null || { echo "Suma SHA-256 incorrecta: $2"; exit 1; }
}

echo "== Fuentes"
fetch "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz" "$W/src/cx.tar.gz" $CX_SHA256
fetch "https://dl.winehq.org/wine/wine-mono/$MONO_VERSION/wine-mono-$MONO_VERSION-x86.tar.xz" "$W/src/mono.tar.xz" $MONO_SHA256
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$W/src/ffmpeg.tar.xz" $FFMPEG_SHA256
[[ -d "$W/src/sources/wine" ]] || tar -xzf "$W/src/cx.tar.gz" -C "$W/src"
# Parches propios de Bodega (engine/patches), aplicados una sola vez.
for p in "${0:A:h}"/patches/*.patch(N); do
  if ! patch -p1 -R -s -f --dry-run -d "$W/src/sources/wine" < "$p" >/dev/null 2>&1; then
    echo "   parche ${p:t}"; patch -p1 -s -d "$W/src/sources/wine" < "$p"
  fi
done
FF="$W/src/ffmpeg-$FFMPEG_VERSION"
if [[ ! -d "$FF" ]]; then
  tar -xJf "$W/src/ffmpeg.tar.xz" -C "$W/src"
  # Solo hacen falta las cabeceras: se escriben a mano las dos que generaría su configure.
  printf '#ifndef AVUTIL_AVCONFIG_H\n#define AVUTIL_AVCONFIG_H\n#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n#endif\n' > "$FF/libavutil/avconfig.h"
  printf '#ifndef AVUTIL_FFVERSION_H\n#define AVUTIL_FFVERSION_H\n#define FFMPEG_VERSION "%s"\n#endif\n' $FFMPEG_VERSION > "$FF/libavutil/ffversion.h"
fi
# Cabeceras de GStreamer: del paquete de Homebrew, sin instalarlo.
GSTH="$W/src/gst-headers"
if [[ ! -d "$GSTH" ]]; then
  brew fetch gstreamer >/dev/null
  mkdir -p "$GSTH" && tar -xzf "$(brew --cache gstreamer)" -C "$GSTH" --include='*/include/*'
fi
GSTINC=$(echo "$GSTH"/gstreamer/*/include/gstreamer-1.0)

echo "== Enlaces sin espacios a las bibliotecas x86_64 del motor libre"
ln -sfn "$FREE/lib" "$W/deplib"
mkdir -p "$W/medialink"
for f in "$FREE"/lib/GStreamer.framework/Versions/1.0/lib/*.dylib; do
  b=${f:t}; ln -sf "$f" "$W/medialink/$b"
  u=$(echo $b | sed -E 's/^(lib[a-z0-9_]+(-[0-9.]+)?)\.[0-9.]+\.dylib$/\1.dylib/')
  [[ "$u" != "$b" && ! -e "$W/medialink/$u" ]] && ln -sf "$f" "$W/medialink/$u"
done
# Las herramientas del propio build (sfnt2fon) necesitan freetype en la carpeta de trabajo.
for f in "$W"/deplib/*.dylib; do ln -sf "$f" "$W/build/${f:t}"; done

export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Versión mínima 10.15, como CodeWeavers: el código Cocoa del controlador de Wine elige caminos de
# dibujo según ella, y con la del sistema (26.x) las ventanas de Steam salían en negro.
export MACOSX_DEPLOYMENT_TARGET=10.15
export CC="clang -arch x86_64 -mmacosx-version-min=10.15" CXX="clang++ -arch x86_64 -mmacosx-version-min=10.15"
export CFLAGS="-O2 -g0 -Wno-deprecated-declarations -Wno-incompatible-pointer-types -Wno-int-conversion" CROSSCFLAGS="-O2 -g0"
export LDFLAGS="-L$W/deplib -L$W/medialink -Wl,-rpath,@loader_path/../../ -Wl,-rpath,@loader_path/../../GStreamer.framework/Libraries"
export FREETYPE_CFLAGS="-I/opt/homebrew/include/freetype2" FREETYPE_LIBS="-L$W/deplib -lfreetype"
export GNUTLS_CFLAGS="-I/opt/homebrew/opt/gnutls/include -I/opt/homebrew/opt/nettle/include -I/opt/homebrew/opt/libtasn1/include -I/opt/homebrew/opt/p11-kit/include/p11-kit-1" GNUTLS_LIBS="-L$W/deplib -lgnutls"
export SDL2_CFLAGS="-I/opt/homebrew/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$W/deplib -lSDL2"
export FFMPEG_CFLAGS="-I$FF" FFMPEG_LIBS="-L$W/medialink -lavutil -lavformat -lavcodec"
export GSTREAMER_CFLAGS="-I$GSTINC -I/opt/homebrew/include/glib-2.0 -I/opt/homebrew/lib/glib-2.0/include -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_72 -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_72"
export GSTREAMER_LIBS="-L$W/medialink -lgstvideo-1.0 -lgstaudio-1.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0"

cd "$W/build"
if [[ ! -f Makefile ]]; then
  echo "== Configurando"
  # Las bibliotecas del motor libre traen el nombre interno recortado: se indican los sonames.
  arch -x86_64 "$W/src/sources/wine/configure" --prefix="$W/install" --enable-archs=i386,x86_64 --disable-tests \
    --with-mingw --with-coreaudio --with-opencl --with-freetype --with-gnutls --with-sdl --with-vulkan \
    --with-gstreamer --with-ffmpeg --without-x --without-wayland --without-dbus --without-fontconfig \
    --without-inotify --without-krb5 --without-netapi --without-oss --without-pulse --without-alsa --without-sane \
    --without-usb --without-v4l2 --without-gphoto --without-capi --without-udev --without-gettext --without-gettextpo \
    ac_cv_lib_soname_SDL2=libSDL2-2.0.0.dylib ac_cv_lib_soname_freetype=libfreetype.6.dylib \
    ac_cv_lib_soname_vulkan=libvulkan.1.dylib ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib ac_cv_lib_soname_gnutls=libgnutls.30.dylib
fi
echo "== Compilando"
make -j$(sysctl -n hw.ncpu)
make install

echo "== Montando $DEST"
STAGE="$W/stage.app"; R="$STAGE/Contents/Resources/wine"
rm -rf "$STAGE"; mkdir -p "$R"
ditto "$W/install/bin" "$R/bin"; ditto "$W/install/lib" "$R/lib"; ditto "$W/install/share" "$R/share"
( cd "$R/bin" && rm -f function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc )
rm -rf "$R/share/man" "$R/share/applications" "$R/lib/wine"/*/*.a
cp -a "$FREE"/lib/*.dylib "$R/lib/"
ditto "$FREE/lib/GStreamer.framework" "$R/lib/GStreamer.framework"
mkdir -p "$R/share/wine/gecko" "$R/share/wine/mono"
ditto "$FREE/share/wine/gecko" "$R/share/wine/gecko"
tar -xJf "$W/src/mono.tar.xz" -C "$R/share/wine/mono"
ditto "$FREE/lib/dxmt" "$R/lib/dxmt"; ditto "$FREE/lib/dxvk" "$R/lib/dxvk"
cp "$R/lib/dxmt/x86_64-windows/winemetal.dll" "$R/lib/wine/x86_64-windows/"
cp "$R/lib/dxmt/i386-windows/winemetal.dll" "$R/lib/wine/i386-windows/"
cp "$R/lib/dxmt/x86_64-unix/winemetal.so" "$R/lib/wine/x86_64-unix/"
cat > "$STAGE/BODEGA-PROCEDENCIA.txt" <<EOF
Motor Bodega ${CX_VERSION%.*} — compilado en este Mac desde el código LGPL que publica CodeWeavers.
Wine 11.0 de CodeWeavers (fuentes $CX_VERSION, con MSync), FFmpeg y GStreamer.
  https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz  sha256 $CX_SHA256
Wine Mono $MONO_VERSION (WineHQ)  sha256 $MONO_SHA256
Cabeceras de FFmpeg $FFMPEG_VERSION (ffmpeg.org) y GStreamer (Homebrew).
Wine Gecko, bibliotecas x86_64, GStreamer.framework, DXMT 0.80 y DXVK-macOS 1.10.3: del motor libre
  Wine Staging 11.21 (github.com/Gcenx/macOS_Wine_builds).
Compilado: $(date '+%Y-%m-%d %H:%M')
EOF
"$R/bin/wine" --version >/dev/null
rm -rf "$DEST"; mv "$STAGE" "$DEST"
echo "Listo: $DEST"

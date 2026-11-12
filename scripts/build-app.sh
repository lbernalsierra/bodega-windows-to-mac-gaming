#!/bin/zsh
# Compila Bodega y la empaqueta como build/Bodega.app (firma ad hoc, para uso local).
# Uso: scripts/build-app.sh [--install]   (--install la copia a ~/Applications)
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
VERSION="0.1.0"
APP="$ROOT/build/Bodega.app"

swift build -c release --product Bodega
swift build -c release --product bodegactl
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Bodega" "$APP/Contents/MacOS/Bodega"
cp "$BIN/bodegactl" "$APP/Contents/Resources/bodegactl"
cp "$ROOT/engine/build-motor.sh" "$APP/Contents/Resources/build-motor.sh"

# Icono
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon-1024.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleExecutable</key><string>Bodega</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.lbernalsierra.bodega</string>
  <key>CFBundleName</key><string>Bodega</string>
  <key>CFBundleDisplayName</key><string>Bodega</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Abrir programas de Bodega</string>
      <key>CFBundleURLSchemes</key><array><string>bodega</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Programa de Windows</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.microsoft.windows-executable</string></array>
      <key>CFBundleTypeExtensions</key><array><string>exe</string><string>com</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Instalador o acceso directo de Windows</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>msi</string><string>msp</string><string>bat</string><string>cmd</string><string>lnk</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Lista: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Bodega.app"
  cp -R "$APP" "$HOME/Applications/Bodega.app"
  # Una sola copia de la app en el Mac: se quita la de build/ del registro de apps y del disco.
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  "$LSREG" -f "$HOME/Applications/Bodega.app"
  echo "Instalada en ~/Applications/Bodega.app"
fi

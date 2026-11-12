#!/bin/zsh
# Ejecuta los tests. Con solo las Command Line Tools (sin Xcode), Swift Testing
# vive fuera de las rutas por defecto y hay que indicárselo al compilador.
set -euo pipefail
cd ${0:A:h:h}
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ -d "$F/Testing.framework" ]]; then
  swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
else
  swift test "$@"
fi

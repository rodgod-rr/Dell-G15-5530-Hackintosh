#!/usr/bin/env bash
# Compila o stencilfix NO PROPRIO MAC (sem VM) -> tools/macos-wex-stencilfix/impostor.dylib. Reexporta o impostor ORIGINAL do pacote (impostor-real.dylib, ja instalado ao lado).
# Uso: bash tools/macos-wex-stencilfix/build-mac.sh [diretorio-de-saida]   (padrao: grava impostor.dylib aqui; com um diretorio, grava la e copia o impostor-real.dylib para teste)
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); OUT=${1:-$D}; T=$(mktemp -d /tmp/stencilfix-build.XXXXXX); trap 'rm -rf "$T"' EXIT
M=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS
[ -f "$M/impostor-real.dylib" ] || { echo "nao achei $M/impostor-real.dylib (stencilfix instalado?)"; exit 1; }
cp "$M/impostor-real.dylib" "$T/impostor-real.dylib"; install_name_tool -id @loader_path/impostor-real.dylib "$T/impostor-real.dylib" 2>/dev/null
cp "$D/stencilfix.mm" "$T/"; ( cd "$T" && xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -arch x86_64 -dynamiclib -mmacosx-version-min=13.0 -install_name @rpath/impostor.dylib \
  -framework Foundation -framework Metal -Wl,-reexport_library,impostor-real.dylib stencilfix.mm -o impostor.dylib && codesign -f -s - impostor.dylib )
mkdir -p "$OUT"; cp "$T/impostor.dylib" "$OUT/impostor.dylib"; [ "$OUT" = "$D" ] || cp "$M/impostor-real.dylib" "$M/descriptor.dylib" "$OUT/"
otool -L "$OUT/impostor.dylib" | head -4; shasum -a 256 "$OUT/impostor.dylib" | cut -c1-16

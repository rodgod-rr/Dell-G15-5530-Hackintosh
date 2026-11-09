#!/bin/bash
# Correcao dos quadrados brancos do 3D (stencil lido por view; ver stencilfix.mm). Instala o shim no lugar do
# impostor.dylib do driver Metal da UHD; vale para todo app aberto DEPOIS (o WindowServer e o sistema ficam de fora).
#   sudo bash instalar.sh               instala (modo copy, o contorno provado no nb3d); se ja instalado, atualiza o shim
#   sudo bash instalar.sh modo noopt    troca o modo (copy | noopt | both | off), sem reinstalar; reabra o app
#   sudo bash instalar.sh voltashim     volta o shim ANTERIOR (guardado em /Library/G15-uhd/impostor-shim-anterior.dylib na ultima atualizacao)
#   sudo bash instalar.sh remove        volta o impostor original
#   bash instalar.sh log                o que o shim registrou nos ultimos 15 min
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle; M=$B/Contents/MacOS; HERE=$(cd "$(dirname "$0")" && pwd)
C=/Library/G15-uhd/stencilfix.conf
# IMPORTANTE (05/11): nunca sobrescrever no lugar um arquivo do driver que ja esta mapeado por processos (cp sobre o arquivo, codesign no lugar): o kernel guarda o
# mtime/assinatura por vnode e passa a rejeitar as paginas ("CODE SIGNING: rejecting invalid page ... cs_mtime != mtime"), e NENHUM app novo abre. Recriar com inode novo:
novoinode() { for f in "$@"; do cp -p "$M/$f" "$M/$f.novo" && mv -f "$M/$f.novo" "$M/$f"; done; }
case "${1:-}" in
  log) log show --last 15m --style compact --predicate 'subsystem == "com.g15.stencilfix"' | tail -40; exit 0;;
esac
[ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
[ -f "$M/AppleIntelTGLGraphicsMTLDriver" ] || { echo "nao achei o driver Metal do WEX em $B"; exit 1; }
case "${1:-}" in
  modo) case "${2:-}" in copy|noopt|both|off) ;; *) echo "modo: copy | noopt | both | off"; exit 1;; esac
        mkdir -p /Library/G15-uhd; echo "$2" > "$C"; echo "STENCILFIX: modo $2 (reabra o app)"; exit 0;;
  voltashim) [ -f /Library/G15-uhd/impostor-shim-anterior.dylib ] || { echo "sem shim anterior guardado"; exit 1; }
        cp /Library/G15-uhd/impostor-shim-anterior.dylib "$M/impostor.dylib.novo" && chmod 755 "$M/impostor.dylib.novo" && mv -f "$M/impostor.dylib.novo" "$M/impostor.dylib"
        codesign -f -s - "$B" >/dev/null 2>&1 || echo "  AVISO: codesign do bundle falhou"
        novoinode impostor.dylib AppleIntelTGLGraphicsMTLDriver
        echo "STENCILFIX: shim anterior de volta (reabra os apps)"; exit 0;;
  remove) [ -f "$M/impostor-real.dylib" ] || { echo "nada instalado"; exit 1; }
        mv -f "$M/impostor-real.dylib" "$M/impostor.dylib"
        codesign -f -s - "$B" >/dev/null 2>&1 || echo "  AVISO: codesign do bundle falhou"
        echo "STENCILFIX: removido (impostor original de volta)"; exit 0;;
esac
[ -f "$HERE/impostor.dylib" ] || { echo "falta $HERE/impostor.dylib (build-vm.sh)"; exit 1; }
if [ -f "$M/impostor-real.dylib" ]; then echo "  ja instalado: trocando so o shim pela versao nova (o atual fica em /Library/G15-uhd/impostor-shim-anterior.dylib)"; mkdir -p /Library/G15-uhd; cp "$M/impostor.dylib" /Library/G15-uhd/impostor-shim-anterior.dylib
else mv "$M/impostor.dylib" "$M/impostor-real.dylib"; fi
cp "$HERE/impostor.dylib" "$M/impostor.dylib.novo" && chmod 755 "$M/impostor.dylib.novo" && mv -f "$M/impostor.dylib.novo" "$M/impostor.dylib"
codesign -f -s - "$B" >/dev/null 2>&1 && echo "  bundle assinado de novo" || echo "  AVISO: codesign do bundle falhou"
novoinode impostor.dylib AppleIntelTGLGraphicsMTLDriver   # o codesign reescreve o binario principal no lugar
mkdir -p /Library/G15-uhd; [ -f "$C" ] || echo copy > "$C"
echo "STENCILFIX: instalado (modo $(cat "$C")). Abra o Novabench e rode o 3D; depois: bash $0 log"

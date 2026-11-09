#!/bin/bash
# Vazamento do driver Metal TGL 16.0.32 (b00t0x/WhateverXe#47): -[MTLIGAccelCommandBuffer dealloc] so libera o buffer POSH de
# 72 KB quando m_isOnlyActiveCommandBuffer = 0; o 'jne' em 0x7ed87 (75 0d) vira 'nop nop' (90 90) e o buffer e sempre liberado
# (seguro: o buffer compartilhado da fila, queue.m_pPoshUsedAsTarget, nunca existe). Vale para TODO processo, inclusive o
# WindowServer (o shim stencilfix/leakfix deixa o WindowServer de fora; la o vazamento passa de 400 MB/min). Convive com o
# leakfix do shim (ele zera o ponteiro antes; nada e liberado duas vezes). So vale para processos abertos depois: REINICIE.
#   sudo bash tools/macos-mtl-leakpatch.sh [aplicar|remover|estado]      depois de aplicar: reiniciar e 'sudo bash tools/macos-reaplica.sh validar'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle; M=$B/Contents/MacOS; D=$M/AppleIntelTGLGraphicsMTLDriver
K=/Library/G15-uhd/mtl-driver-antes-leakpatch
# assinatura do trecho 0x7ed6b..0x7ed95 (42 bytes) com o jne original e com o patch
ORIG=488b1d3eb14100498b3c1e4885ff741b488b0526b1410041803c0600750de87afa010049c7041e000000
PAT=488b1d3eb14100498b3c1e4885ff741b488b0526b1410041803c06009090e87afa010049c7041e000000
atual() { xxd -s $((0x7ed6b)) -l 42 -p "$D" | tr -d '\n'; }
estado() { a=$(atual); [ "$a" = "$PAT" ] && echo "aplicado" || { [ "$a" = "$ORIG" ] && echo "original" || echo "DESCONHECIDO"; }; }
case "${1:-aplicar}" in
  estado) echo "leakpatch do driver Metal: $(estado) | WindowServer RSS $(ps -o rss= -p "$(pgrep -x WindowServer)" | awk '{printf "%.0f MB", $1/1024}')"; exit 0;;
esac
[ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
[ -f "$D" ] || { echo "nao achei $D"; exit 1; }
case "${1:-aplicar}" in
  aplicar)
    e=$(estado); [ "$e" = aplicado ] && { echo "ja aplicado"; exit 0; }; [ "$e" = original ] || { echo "bytes em 0x7ed6b nao sao os esperados (outra versao do driver?): parei"; exit 1; }
    mkdir -p "$K"; cp -p "$D" "$K/AppleIntelTGLGraphicsMTLDriver"
    # arquivo NOVO (nunca alterar no lugar um binario mapeado pelos processos)
    cp -p "$D" "$D.novo" && printf '\x90\x90' | dd of="$D.novo" bs=1 seek=$((0x7ed87)) conv=notrunc 2>/dev/null && mv -f "$D.novo" "$D"
    codesign -f -s - "$B" >/dev/null 2>&1 && echo "  bundle assinado de novo" || echo "  AVISO: codesign do bundle falhou"
    for f in AppleIntelTGLGraphicsMTLDriver impostor.dylib; do cp -p "$M/$f" "$M/$f.novo" && mv -f "$M/$f.novo" "$M/$f"; done   # o codesign reescreve no lugar
    echo "LEAKPATCH: $(estado) (copia do driver anterior em $K). REINICIE o Mac; depois: sudo bash $0 estado ; sudo bash $(dirname "$0")/macos-reaplica.sh validar";;
  remover)
    [ -f "$K/AppleIntelTGLGraphicsMTLDriver" ] || { echo "sem copia em $K"; exit 1; }
    cp -p "$K/AppleIntelTGLGraphicsMTLDriver" "$D.novo" && mv -f "$D.novo" "$D"
    codesign -f -s - "$B" >/dev/null 2>&1; for f in AppleIntelTGLGraphicsMTLDriver impostor.dylib; do cp -p "$M/$f" "$M/$f.novo" && mv -f "$M/$f.novo" "$M/$f"; done
    echo "LEAKPATCH: $(estado). REINICIE o Mac.";;
  *) echo "uso: aplicar | remover | estado"; exit 1;;
esac

#!/bin/bash
# Contorno do travamento da App Store / app TV (WhateverXe #81, qqaoshi888/lymzzyh; confirmado na TGL por Aqpcet):
# no VA driver da Intel, a lista de saidas do pos-processamento de video (VP) com 'yuv2' + 'NV12' passa de 2 para 0
# itens (offset 0x786fc4). O AppleGVA deixa de escolher a configuracao do VP cujo lote (MEDIA_OBJECT) nunca termina na GPU;
# as listas ARGB ficam, o H.264/HEVC por hardware e o protetor de tela de video continuam.
# No VA do Tahoe 25G332 (original e o nosso com patches) a lista esta no mesmo offset (conferido em 10/11).
#   aplicar   confere os bytes, guarda o VA atual em /Library/G15-uhd/va-vp81-antes/, troca 02->00 e reassina ad hoc
#   desfazer  devolve o VA guardado.   estado: mostra os bytes no offset.
# Uso: sudo bash post-install/macos-va-vp81.sh aplicar|desfazer|estado   (vale para processos novos; reiniciar e o mais simples)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle; F=$B/Contents/MacOS/AppleIntelTGLGraphicsVADriver
S=/Library/G15-uhd/va-vp81-antes; O=$((0x786fc4))
bytes() { xxd -s $O -l 20 -p "$F"; }
case "${1:-}" in
estado) echo "0x786fc4: $(bytes)  (020000007975763205000000... = original; 000000007975763205000000... = com o contorno)";;
aplicar)
  [ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
  [ "$(bytes)" = "0200000079757632050000003231564e05000000" ] || { echo "bytes inesperados no offset: $(bytes) (VA diferente ou ja aplicado): nada mudou"; exit 1; }
  mkdir -p "$S" && rm -rf "$S/$(basename $B)" && cp -Rp "$B" "$S/" || { echo "falha na copia"; exit 1; }
  printf '\x00' | dd of="$F" bs=1 seek=$O count=1 conv=notrunc 2>/dev/null
  [ "$(bytes)" = "0000000079757632050000003231564e05000000" ] || { echo "a escrita nao conferiu: devolvendo"; rm -rf "$B" && cp -Rp "$S/$(basename $B)" "$B"; exit 1; }
  codesign -f -s - "$B" >/dev/null 2>&1 || { echo "falha ao reassinar"; exit 1; }
  echo "aplicado ($(md5 -q $F)). Copia do anterior em $S. Reinicie (ou feche os apps de video).";;
desfazer)
  [ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
  [ -d "$S/$(basename $B)" ] || { echo "sem copia em $S"; exit 1; }
  rm -rf "$B" && cp -Rp "$S/$(basename $B)" "$B" && echo "devolvido ($(md5 -q $F)). Reinicie.";;
*) echo "uso: sudo bash $0 aplicar | desfazer | estado"; exit 1;;
esac

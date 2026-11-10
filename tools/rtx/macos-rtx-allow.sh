#!/bin/bash
# Quem recebe a RTX no Metal (lista do NullMoth /Library/GPUBundles/nvmtl-allow.txt). O padrao do NullMoth e "*" (todos) e
# "!WindowServer" (o WindowServer so com tela na RTX): todo programa que lista as GPUs abre a RTX (centenas de conexoes
# mesmo sem tela) e o RTD3 da 2.9 (nvrtd3=1) nunca a ve ociosa por 60 s.
#   restrita  so o WindowServer com tela na RTX (HDMI) e os apps passados como argumento recebem a RTX; o resto fica na
#             Intel e a RTX pode dormir. Ex.: sudo bash tools/macos-rtx-allow.sh restrita Blender "Final Cut Pro"
#   padrao    devolve a lista guardada (a do NullMoth).   estado: mostra a lista e as conexoes abertas na RTX.
# Formato da lista (NullMoth): um nome de processo por linha; "*" todos; "!Nome" so com tela na RTX; "-Nome" nega.
# Vale para processos novos: reinicie (ou encerre a sessao) depois de trocar. Uma atualizacao do NullMoth sobrescreve a lista.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
L=/Library/GPUBundles/nvmtl-allow.txt; B=/Library/G15-uhd/nvmtl-allow.padrao
conexoes() { ioreg -rlw0 -c NVAccel | grep -oE '"IOUserClientCreator" = "pid [0-9]+, [^"]+"' | sed -E 's/pid [0-9]+, //; s/"IOUserClientCreator" = //' | sort | uniq -c | sort -rn | head -12; }
case "${1:-}" in
estado) echo "== $L"; cat "$L"; echo "== conexoes na RTX (por processo)"; conexoes;;
restrita)
  [ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
  shift; [ -f "$B" ] || cp -p "$L" "$B" || exit 1
  { echo "# G15 (tools/macos-rtx-allow.sh): so estes recebem a RTX, para o RTD3 poder desliga-la; padrao do NullMoth em $B"
    echo "!WindowServer"; for a in "$@"; do echo "$a"; done; } > "$L.novo" || exit 1
  chown root:wheel "$L.novo" && chmod 644 "$L.novo" && mv "$L.novo" "$L" || exit 1
  sudo -u _windowserver /bin/test -r "$L" || { cp -p "$B" "$L"; echo "o WindowServer nao le a lista: devolvida"; exit 1; }
  echo "== lista restrita:"; cat "$L"; echo "Reinicie para os programas soltarem a RTX.";;
padrao)
  [ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
  [ -f "$B" ] || { echo "sem copia em $B"; exit 1; }
  cp -p "$B" "$L" && chown root:wheel "$L" && chmod 644 "$L" && echo "== lista do NullMoth devolvida" && cat "$L";;
*) echo "uso: sudo bash $0 restrita [app ...] | padrao | estado"; exit 1;;
esac

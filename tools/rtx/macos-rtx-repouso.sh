#!/bin/bash
# "Imitar o repouso" (10/11/2026): pede ao IOPM, com o sistema acordado, o mesmo que o sono faz com a RTX: NVRM (e o
# audio HDMI NMXAudio) no estado 0 -> a NullMoth suspende a GPU (gpuSuspend), o IOPCIFamily desce PEGP/fn1/PEG1 e, se o
# G15Fan foi iniciado com -g15fan-rtxpm-corte, o GOFF corta a energia quando o PEG1 chega a 0. Precisa do G15Fan com
# RtxPm (tools/macos-g15fan-kext.sh instalar). Sem o boot-arg e so o teste seco (nada de GOFF).
#   sudo bash tools/macos-rtx-repouso.sh parar | parar-audio | ligar | estado
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
R=$(cd "$(dirname "$0")" && pwd); T=/private/tmp/g15-rtxpm
est() {
  echo "== $(ioreg -lw0 -c G15Fan | grep -o '"RtxPm" = "[^"]*"')"
  ioreg -p IOPower -lw0 | awk '/\+-o /{n=$0} /"IOPowerManagement"/{ if (n ~ /PEG1@1 |PEGP@0 |NVRM |22be@0,1 |NMXAudio/) {sub(/^.*\+-o /,"",n); sub(/ <.*/,"",n); s=$0; sub(/^.*"IOPowerManagement" = /,"",s); gsub(/"WQ-[A-Za-z]+"=[0-9]+,?/,"",s); print "   "n": "s}}'
  echo "   GSLP (SleepDebug): $(ioreg -lw0 -c G15Fan | grep -o '"SleepDebug" = [0-9]*')"
  echo "   conexoes Metal na RTX: $(ioreg -rlw0 -c NVAccel | grep -c IOUserClientCreator)"
}
[ "${1:-}" = estado ] && { est; exit 0; }
[ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
[ -x $T ] || clang -O2 -framework IOKit -framework CoreFoundation -o $T "$R/macos-rtx-repouso/rtxpm.c" || exit 1
case "${1:-}" in
  parar) $T 0;; parar-audio) $T 2;; ligar) $T 1;;
  *) echo "uso: parar | parar-audio | ligar | estado"; exit 1;;
esac
sleep 3; est

#!/bin/bash
# Instala o plug-in de audio XeSpeakers (do projeto do XPS, sem mudancas) no macOS do G15: cria no Core Audio os dispositivos
# "Alto-falantes internos" e "Microfone interno", que conversam com o AudShim.kext (modo driver). Sem o AudShim carregado
# (configs com VoodooHDA) o plug-in nao cria nada, entao pode ficar instalado.
# Uso no Mac: sudo bash /Volumes/EFI/EFI/G15/audio/install.sh          instala (ou atualiza) e reinicia o coreaudiod
#             sudo bash /Volumes/EFI/EFI/G15/audio/install.sh remove   tira o plug-in e reinicia o coreaudiod
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
D=/Library/Audio/Plug-Ins/HAL/XeSpeakers.driver
S=$(cd "$(dirname "$0")" && pwd)/XeSpeakers.driver
[ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }
if [ "${1:-}" = remove ]; then
    rm -rf "$D" && killall coreaudiod 2>/dev/null || true
    echo "XeSpeakers removido."; exit 0
fi
[ -d "$S" ] || { echo "falta $S"; exit 1; }
rm -rf "$D" && cp -R "$S" "$D" && chown -R root:wheel "$D" && chmod -R go+rX "$D"   # da EFI (FAT) vem drwx------: o coreaudiod nao leria
# preferencias do supressor: o G15.app (barra de atenuacao do microfone) grava este arquivo sem sudo, entao ele fica gravavel por todos
P=/Library/Preferences/local.g15.audio.plist
[ -f "$P" ] || defaults write /Library/Preferences/local.g15.audio noiseAttenDb -float 30
chmod 666 "$P"
killall coreaudiod 2>/dev/null || true
sleep 3
echo "XeSpeakers instalado em $D. Dispositivos de audio agora:"
system_profiler SPAudioDataType 2>/dev/null | grep -E "^        [A-Z].*:$|Default (Input|Output)" || true
if kextstat 2>/dev/null | grep AudShim >/dev/null; then echo "AudShim carregado."; else echo "AVISO: AudShim nao esta carregado (config sem ele): nenhum dispositivo novo."; fi   # grep -q + pipefail dava aviso falso

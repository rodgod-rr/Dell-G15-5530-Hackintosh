#!/bin/bash
# Instala/remove o G15.app (Fn+F5 = luz do teclado, Fn+F9 = perfil termico, icone na barra de menus) no macOS.
# Roda como o seu usuario, SEM sudo. Uso no Terminal do macOS (com a EFI montada, ver diag.sh):
#   bash /Volumes/EFI/EFI/G15/g15app/install.sh          instala e inicia
#   bash /Volumes/EFI/EFI/G15/g15app/install.sh tap      idem, mas le as teclas por event tap (pede Acessibilidade)
#   bash /Volumes/EFI/EFI/G15/g15app/install.sh remove   para e apaga tudo
# Arquivos (todos do usuario):
#   ~/Applications/G15.app
#   ~/Library/LaunchAgents/local.g15.plist (inicia no login; "Sair do G15" no menu fecha ate o proximo login)
#   ~/Library/Logs/g15.log, preferencias "local.g15"
#   ~/Library/KeyBindings/DefaultKeyBinding.dict (Home/End como no Windows; so se nao existir um seu)
# Tambem remove a versao anterior (g15kbd: ~/Library/Application Support/g15kbd, agente local.g15kbd).
set -euo pipefail
[ "$(id -u)" != 0 ] || { echo "rode SEM sudo (e um app do seu usuario)"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
APP="$HOME/Applications/G15.app"
PLIST="$HOME/Library/LaunchAgents/local.g15.plist"
LOG="$HOME/Library/Logs/g15.log"
KB="$HOME/Library/KeyBindings/DefaultKeyBinding.dict"
DOM="gui/$(id -u)"

# versao anterior (g15kbd)
launchctl bootout "$DOM/local.g15kbd" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.g15kbd.plist" "$HOME/Library/Logs/g15kbd.log"
rm -rf "$HOME/Library/Application Support/g15kbd"

launchctl bootout "$DOM/local.g15" 2>/dev/null || true
pkill -x G15 2>/dev/null || true
if [ "${1:-}" = remove ]; then
  rm -f "$PLIST" "$LOG"; rm -rf "$APP"
  grep -q "G15.app" "$KB" 2>/dev/null && rm -f "$KB"
  defaults delete local.g15 2>/dev/null || true; defaults delete local.g15kbd 2>/dev/null || true
  echo "OK: G15 removido"; exit 0
fi

ENV=""
[ "${1:-}" = tap ] && ENV="<key>EnvironmentVariables</key><dict><key>G15KBD_TAP</key><string>1</string></dict>"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"; ditto "$D/G15.app" "$APP"
xattr -cr "$APP" 2>/dev/null || true
codesign --verify "$APP" 2>/dev/null || codesign -f -s - "$APP"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.g15</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/G15</string><string>--daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  $ENV
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>StandardOutPath</key><string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
# Home/End (Fn+F11/F12) e Shift+Home/End: inicio/fim da linha, como no Windows (no macOS rolam o documento). Vale para os
# apps Cocoa abertos depois. Nao mexe num DefaultKeyBinding.dict que ja exista.
if [ ! -e "$KB" ]; then
  mkdir -p "$(dirname "$KB")"
  cat > "$KB" <<'KBEOF'
/* G15.app: Home/End como no Windows (Fn+F11/Fn+F12 no Dell G15) */
{
    "\UF729"  = "moveToBeginningOfLine:";
    "\UF72B"  = "moveToEndOfLine:";
    "$\UF729" = "moveToBeginningOfLineAndModifySelection:";
    "$\UF72B" = "moveToEndOfLineAndModifySelection:";
    "^\UF729" = "moveToBeginningOfDocument:";
    "^\UF72B" = "moveToEndOfDocument:";
}
KBEOF
  echo "Home/End: $KB (inicio/fim da linha; Ctrl+Home/End = documento)"
fi
launchctl bootstrap "$DOM" "$PLIST"
sleep 3
launchctl print "$DOM/local.g15" 2>/dev/null | grep -E "state|pid" | head -3 || true
tail -8 "$LOG" 2>/dev/null || true
echo "OK: icone de ventoinha na barra de menus. Fn+F5 = luz, Fn+F9 = perfil, Fn+F10 = captura de tela. Log: tail -f ~/Library/Logs/g15.log"
echo "   (na 1a vez o macOS pede para permitir as notificacoes do G15)"

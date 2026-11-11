#!/bin/bash
# Compila o G15.app no macOS (Command Line Tools) na pasta atual, com o G15.m/mkicon.m que estao ao lado deste script.
# Usado pela VM (build-vm.sh) e direto no Mac:
#   cd ~/hackintosh-g15/tools/macos-g15app && mkdir -p build && cd build && bash ../build.sh && cp ../install.sh . && bash install.sh
#   (o install.sh instala o G15.app que esta na pasta dele)
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
[ "$SRC" = "$(pwd)" ] || cp "$SRC/G15.m" "$SRC/mkicon.m" .
A=G15.app; mkdir -p $A/Contents/MacOS $A/Contents/Resources
clang -fobjc-arc -O2 -Wall -arch x86_64 -mmacosx-version-min=13.0 \
  -framework AppKit -framework Carbon -framework IOKit -framework UserNotifications -framework CoreAudio G15.m -o $A/Contents/MacOS/G15
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=13.0 -framework AppKit mkicon.m -o mkicon
./mkicon G15.iconset && iconutil -c icns G15.iconset -o $A/Contents/Resources/G15.icns
cat > $A/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleExecutable</key><string>G15</string>
  <key>CFBundleIdentifier</key><string>local.g15.app</string>
  <key>CFBundleName</key><string>G15</string>
  <key>CFBundleDisplayName</key><string>G15</string>
  <key>CFBundleIconFile</key><string>G15</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Desligar o Bluetooth quando nenhum aparelho estiver conectado (economia de energia).</string>
  <key>NSHumanReadableCopyright</key><string>Teclas Fn do Dell G15 5530 (luz do teclado e ventoinhas)</string>
</dict>
</plist>
EOF
plutil -lint $A/Contents/Info.plist
codesign -f -s - $A && codesign -dv $A 2>&1 | grep -E "Identifier|Format"
file $A/Contents/MacOS/G15
tar -czf g15app.tgz $A

#!/usr/bin/env bash
# Compila o G15PM.kext (XE-PM do NootedGreen num plugin Lilu proprio) na VM macOS e traz para kexts/out/G15PM.kext.
# Usa o MacKernelSDK e o Lilu 1.7.2 (DEBUG, para os headers) que o build do NootedGreen ja baixou na VM.
# Uso (VM ligada): bash kexts/G15PM/build-vm.sh
set -euo pipefail
R=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
S="$R/kexts/G15PM"; OUT="$R/kexts/out"
VM() { "$R/ssh-vm.sh" "$@"; }
VM 'rm -rf ~/g15pm && mkdir -p ~/g15pm'
for f in kern_start.cpp kern_xepm.cpp g15pm_control.cpp Info.plist; do VM "cat > ~/g15pm/$f" < "$S/$f"; done
VM 'bash -s' <<'EOS'
set -euo pipefail
cd ~/g15pm
DEPS=$(find ~ -maxdepth 4 -type d -path "*/build/deps" 2>/dev/null | head -1)
SDK=$DEPS/MacKernelSDK; LILU=$DEPS/Lilu.kext/Contents/Resources
[ -d "$SDK" ] && [ -d "$LILU" ] || { echo "faltam MacKernelSDK/Lilu em $DEPS"; exit 1; }
echo "SDK: $SDK"
NAME=G15PM; BID=local.g15.G15PM; VER=1.0.0
FLAGS=(-arch x86_64 -mkernel -nostdinc -fno-builtin -fno-common -fno-stack-protector -mmacosx-version-min=13.0 -mmmx -msse -msse2
       -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -DPRODUCT_NAME=$NAME -DMODULE_VERSION=$VER
       -isystem $SDK/Headers -I$LILU -O2 -g)
cat > info.c <<EOC
#include <mach/mach_types.h>
#include <mach/kmod.h>
extern kern_return_t ${NAME}_kern_start(kmod_info_t *ki, void *data);
extern kern_return_t ${NAME}_kern_stop(kmod_info_t *ki, void *data);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL($BID, "$VER", ${NAME}_kern_start, ${NAME}_kern_stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
EOC
clang "${FLAGS[@]}" -c info.c -o info.o
CXX=(-std=gnu++17 -nostdinc++ -fno-exceptions -fno-rtti -fapple-kext -Wall -Wno-deprecated-declarations -Wno-unused-parameter)
for s in kern_start kern_xepm g15pm_control; do clang++ "${FLAGS[@]}" "${CXX[@]}" -c $s.cpp -o $s.o; done
clang++ "${FLAGS[@]}" "${CXX[@]}" -c $LILU/Library/plugin_start.cpp -o plugin_start.o
K=$NAME.kext; rm -rf $K; mkdir -p $K/Contents/MacOS; cp Info.plist $K/Contents/
clang++ -arch x86_64 -mkernel -nostdlib -static -Xlinker -kext -Xlinker -export_dynamic -mmacosx-version-min=13.0 \
  info.o kern_start.o kern_xepm.o g15pm_control.o plugin_start.o $SDK/Library/x86_64/libkmod.a -lcc_kext -o $K/Contents/MacOS/$NAME
codesign -f -s - $K >/dev/null 2>&1 || true
plutil -lint $K/Contents/Info.plist
echo "-- simbolos por biblioteca (kmutil):"
kmutil libraries -p $K --undef-symbols 2>&1 | grep -oE "as\.vit9696\.Lilu[^ ]* \([^)]*\)|com\.apple[^ ]* \([^)]*\)|[Nn]ot found.*" | sort | uniq -c || true
EOS
mkdir -p "$OUT"; rm -rf "$OUT/G15PM.kext"
VM 'cd ~/g15pm && tar -cf - G15PM.kext' | tar -xf - -C "$OUT"
ls -l "$OUT/G15PM.kext/Contents/MacOS/G15PM"

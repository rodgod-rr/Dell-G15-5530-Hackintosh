#!/usr/bin/env bash
# Compila o G15PM.kext no proprio Mac (Command Line Tools + ~/xps/build/deps: MacKernelSDK e Lilu), mesma receita do
# build-vm.sh. Saida: <saida>/G15PM.kext (padrao kexts/out). Uso: bash kexts/G15PM/build-mac.sh [saida]
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); S="$R/kexts/G15PM"; OUT=${1:-$R/kexts/out}
DEPS=${DEPS:-$HOME/xps/build/deps}; SDK=$DEPS/MacKernelSDK; LILU=$DEPS/Lilu.kext/Contents/Resources
[ -d "$SDK" ] && [ -d "$LILU" ] || { echo "faltam MacKernelSDK/Lilu em $DEPS"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; cp "$S"/*.cpp "$S/Info.plist" "$W/"; cd "$W"
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
OBJ=(); for s in kern_start kern_xepm kern_rtd3 kern_wake g15pm_control; do clang++ "${FLAGS[@]}" "${CXX[@]}" -c $s.cpp -o $s.o; OBJ+=($s.o); done
clang++ "${FLAGS[@]}" "${CXX[@]}" -c $LILU/Library/plugin_start.cpp -o plugin_start.o
K=$NAME.kext; mkdir -p $K/Contents/MacOS; cp Info.plist $K/Contents/
clang++ -arch x86_64 -mkernel -nostdlib -static -Xlinker -kext -Xlinker -export_dynamic -mmacosx-version-min=13.0 \
  info.o "${OBJ[@]}" plugin_start.o $SDK/Library/x86_64/libkmod.a -lcc_kext -o $K/Contents/MacOS/$NAME
codesign -f -s - $K >/dev/null 2>&1 || true
plutil -lint $K/Contents/Info.plist >/dev/null
mkdir -p "$OUT"; rm -rf "$OUT/$K"; cp -R $K "$OUT/"; md5 -q "$OUT/$K/Contents/MacOS/$NAME"

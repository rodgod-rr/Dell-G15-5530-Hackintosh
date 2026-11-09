#!/usr/bin/env bash
# Compila o G15Fan.kext no proprio Mac (Command Line Tools + MacKernelSDK em ~/xps/build/deps), mesma receita do
# build-vm.sh. Saida: <saida>/G15Fan.kext (padrao kexts/out). Uso: bash kexts/G15Fan/build-mac.sh [saida]
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd); S="$R/kexts/G15Fan"; OUT=${1:-$R/kexts/out}
SDK=${SDK:-$HOME/xps/build/deps/MacKernelSDK}; [ -d "$SDK" ] || { echo "sem MacKernelSDK em $SDK"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; cd "$W"
K=G15Fan.kext; mkdir -p $K/Contents/MacOS; cp "$S/Info.plist" $K/Contents/
FLAGS=(-arch x86_64 -mkernel -nostdinc -fno-builtin -fno-common -fno-stack-protector -mmacosx-version-min=13.0
       -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -isystem $SDK/Headers -O2 -Wall)
cat > info.c <<'EOC'
#include <mach/mach_types.h>
static kern_return_t g15_start(kmod_info_t *ki, void *d) { return KERN_SUCCESS; }
static kern_return_t g15_stop(kmod_info_t *ki, void *d) { return KERN_SUCCESS; }
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(local.g15.G15Fan, "1.0.0", g15_start, g15_stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
EOC
clang "${FLAGS[@]}" -c info.c -o info.o
clang++ "${FLAGS[@]}" -std=gnu++17 -nostdinc++ -fno-exceptions -fno-rtti -fapple-kext -c "$S/G15Fan.cpp" -o G15Fan.o
clang++ -arch x86_64 -mkernel -nostdlib -static -Xlinker -kext -Xlinker -export_dynamic -mmacosx-version-min=13.0 \
  info.o G15Fan.o $SDK/Library/x86_64/libkmod.a -lcc_kext -o $K/Contents/MacOS/G15Fan
codesign -f -s - $K >/dev/null 2>&1 || true
U=$(kmutil libraries -p $K --undef-symbols 2>&1 | grep -iE "not found|unresolved" || true)
[ -z "$U" ] || { echo "simbolos sem dono:"; echo "$U"; exit 1; }
mkdir -p "$OUT"; rm -rf "$OUT/$K"; cp -R $K "$OUT/"; md5 -q "$OUT/$K/Contents/MacOS/G15Fan"

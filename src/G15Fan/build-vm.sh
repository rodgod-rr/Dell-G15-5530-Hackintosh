#!/usr/bin/env bash
# Compila o G15Fan.kext na VM macOS (Command Line Tools + acidanthera/MacKernelSDK, ja baixado para o NootedGreen)
# e traz o kext para kexts/out/G15Fan.kext.  Uso (VM ligada): bash kexts/G15Fan/build-vm.sh
set -euo pipefail
R=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
S="$R/kexts/G15Fan"; OUT="$R/kexts/out"
VM() { "$R/ssh-vm.sh" "$@"; }
VM 'rm -rf ~/g15fan && mkdir -p ~/g15fan'
VM 'cat > ~/g15fan/G15Fan.cpp' < "$S/G15Fan.cpp"
VM 'cat > ~/g15fan/Info.plist' < "$S/Info.plist"
VM 'bash -s' <<'EOS'
set -euo pipefail
SDK=$(find ~ -maxdepth 4 -type d -path "*/build/deps/MacKernelSDK" 2>/dev/null | head -1 || true)
[ -n "$SDK" ] || { echo "MacKernelSDK nao encontrado na VM"; exit 1; }
echo "SDK: $SDK"
cd ~/g15fan
K=G15Fan.kext; rm -rf $K; mkdir -p $K/Contents/MacOS; cp Info.plist $K/Contents/
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
clang++ "${FLAGS[@]}" -std=gnu++17 -nostdinc++ -fno-exceptions -fno-rtti -fapple-kext -c G15Fan.cpp -o G15Fan.o
clang++ -arch x86_64 -mkernel -nostdlib -static -Xlinker -kext -Xlinker -export_dynamic -mmacosx-version-min=13.0 \
  info.o G15Fan.o $SDK/Library/x86_64/libkmod.a -lcc_kext -o $K/Contents/MacOS/G15Fan
codesign -f -s - $K >/dev/null 2>&1 || true
echo "-- simbolos por biblioteca (kmutil):"; kmutil libraries -p $K --undef-symbols 2>&1 | grep -oE "com\.apple[^ ]* \([^)]*\)|[Nn]ot found.*" | sort | uniq -c || true
tar -czf g15fan.tgz $K
EOS
mkdir -p "$OUT"; rm -rf "$OUT/G15Fan.kext"
VM 'cat ~/g15fan/g15fan.tgz' | tar -xzf - -C "$OUT"
VM 'rm -rf ~/g15fan'
ls -l "$OUT/G15Fan.kext/Contents/MacOS/G15Fan"

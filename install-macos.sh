#!/bin/bash
# Post-install for the Dell G15 5530 EFI, run once in macOS after the first boot with WhateverXe Graphics installed.
#   sudo bash install-macos.sh check     only reports what is installed (changes nothing)
#   sudo bash install-macos.sh install   applies everything below, then asks you to reboot
# Steps (each one is also a script you can run alone; backups of every patched file go to /Library/G15-uhd):
#   1. (none since Graphics 0.4.4: it fixes the Metal leak, WhateverXe#47; the old 2-byte leak patch could hang the GPU)
#   2. VA driver patches (avcfix)     post-install/macos-patch-wex-va.sh, then ... avcfix
#      + video post-processing fix     post-install/macos-va-vp81.sh aplicar (WhateverXe#81: Apple TV/App Store no longer hang)
#   3. Metal stencil shim            prebuilt/stencilfix/instalar.sh
#   4. Audio HAL plug-in XeSpeakers  prebuilt/audio/install.sh
#   5. G15.app (as your user)        prebuilt/G15.app-installer/install.sh
#   6. pmset sleep settings          battery: display 3 min, sleep 5 min; AC: display 5 min, sleep 15 min
# Not done here: NullMoth (use its own installer) and BOOST=0 in /Library/GPUBundles/nvmtl/nvrm610.conf (see README).
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
H=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U=${SUDO_USER:-}; [ -n "$U" ] && [ "$U" != root ] || { echo "run with sudo from your own user account (not as root)"; exit 1; }
MTL=/Library/GPUBundles/AppleIntelTGLGraphicsMTLDriver.bundle/Contents/MacOS
VA=/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle/Contents/MacOS/AppleIntelTGLGraphicsVADriver

gfx() { pkgutil --pkg-info org.b00t0x.WhateverXe.Tahoe 2>/dev/null | awk '/^version/{print $2}'; }
mtl_state() {   # 0x7ed7b: Graphics 0.4.4 leak fix (jmp) / old 2-byte patch at 0x7ed87 / original
  case "$(xxd -s $((0x7ed7b)) -l 14 -p "$MTL/AppleIntelTGLGraphicsMTLDriver" 2>/dev/null)" in
    e98032f8ff9090909090909090*) echo "Graphics 0.4.4 fix (ok)";; 488b0526b1410041803c06009090) echo "OLD 2-byte patch: reinstall WhateverXe Graphics 0.4.4";;
    488b0526b1410041803c0600750d) echo "leaks (Graphics 0.4.0/0.4.1): install 0.4.4";; *) echo "unknown";; esac
}
va_state() {   # avcfix NOP at 0x228358
  [ -f "$VA" ] || { echo "no VA driver"; return; }
  [ "$(xxd -s $((0x228358)) -l 7 -p "$VA")" = "0f1f8000000000" ] && echo "avcfix applied" || echo "not patched"
}
vp_state() {   # WhateverXe#81: yuv2/NV12 VP output list count 2 -> 0 at 0x786fc4
  [ -f "$VA" ] || { echo "no VA driver"; return; }
  case "$(xxd -s $((0x786fc4)) -l 4 -p "$VA")" in 00000000) echo "VP fix applied";; 02000000) echo "VP fix not applied";; *) echo "VP fix: unexpected bytes";; esac
}
check() {
  local K; K=$(kmutil showloaded 2>/dev/null)
  loaded() { printf '%s\n' "$K" | grep -c "$1" >/dev/null && echo loaded || echo "NOT loaded"; }
  echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "WhateverXe Graphics: $(gfx || true)  (tested: 0.4.4)"
  echo "WhateverXe kext:     $(printf '%s\n' "$K" | awk '/org.b00t0x.WhateverXe /{print $7; exit}' | tr -d '()')"
  echo "1. Metal leak:       $(mtl_state)"
  echo "2. VA driver:        $(va_state); $(vp_state)"
  echo "3. stencil shim:     $([ -f "$MTL/impostor-real.dylib" ] && echo installed || echo "not installed")"
  echo "4. XeSpeakers:       $([ -d /Library/Audio/Plug-Ins/HAL/XeSpeakers.driver ] && echo installed || echo "not installed"); AudShim kext $(loaded AudShim)"
  echo "5. G15.app:          $([ -d "$(eval echo ~$U)/Applications/G15.app" ] && echo installed || echo "not installed"); G15Fan kext $(loaded G15Fan)"
  echo "6. pmset:            $(pmset -g custom | awk '/Battery Power/{b=1} /AC Power/{b=0} $1=="sleep"{printf "%s sleep %s  ", (b?"battery":"AC"), $2}')"
  echo "   NullMoth:         $(printf '%s\n' "$K" | awk '/com.nullmoth.NVRM /{print $7; exit}' | tr -d '()')"
}

case "${1:-check}" in
  check) check;;
  install)
    v=$(gfx || true)
    [ -n "$v" ] || { echo "install the WhateverXe Graphics package (0.4.4) first, then reboot and run this again"; exit 1; }
    [ "$v" = 0.4.4 ] || echo "WARNING: WhateverXe Graphics $v is installed; the patches are for 0.4.4 (0.4.0/0.4.1 leak Metal memory). Each patch checks its bytes and stops if they differ."
    echo "== 1. Metal leak: $(mtl_state)"
    echo "== 2. VA driver patches (avcfix)"
    if [ "$(va_state)" = "avcfix applied" ]; then echo "   already applied"; else
      # avcfix starts from the backup of the unpatched driver: a backup left by an older package would bring the old
      # driver back, so set it aside when the installed driver is unpatched and differs from it; the plain run makes a new one.
      BKD=/Library/G15-uhd/wex-va-original/driver
      if [ "$(xxd -s $((0x1336f3)) -l 5 -p "$VA")" = 488957088b ] && [ -f "$BKD" ] && ! cmp -s "$BKD" "$VA"; then
        mv "$BKD" "$BKD.obsolete-$(date +%Y%m%d%H%M)" && echo "   old VA backup set aside (other package version)"; fi
      bash "$H/post-install/macos-patch-wex-va.sh" && bash "$H/post-install/macos-patch-wex-va.sh" avcfix || echo "   (step 2 failed)"; fi
    if [ "$(vp_state)" = "VP fix applied" ]; then echo "   VP fix already applied"; else bash "$H/post-install/macos-va-vp81.sh" aplicar || echo "   (step 2, VP fix, failed)"; fi
    echo "== 3. Metal stencil shim"; bash "$H/prebuilt/stencilfix/instalar.sh" || echo "   (step 3 failed)"
    echo "== 4. Audio plug-in";       bash "$H/prebuilt/audio/install.sh" || echo "   (step 4 failed)"
    echo "== 5. G15.app";             sudo -u "$U" bash "$H/prebuilt/G15.app-installer/install.sh" || echo "   (step 5 failed)"
    echo "== 6. pmset"
    pmset -b displaysleep 3 sleep 5 && pmset -c displaysleep 5 sleep 15 && pmset -a hibernatemode 0 standby 0 && echo "   done"
    echo; check
    echo; echo "Now REBOOT. Then install NullMoth with its own installer and add BOOST=0 to /Library/GPUBundles/nvmtl/nvrm610.conf (README)."
    echo "Reinstalling WhateverXe Graphics undoes steps 2-3: run this script again afterwards.";;
  *) echo "usage: sudo bash install-macos.sh check | install"; exit 1;;
esac

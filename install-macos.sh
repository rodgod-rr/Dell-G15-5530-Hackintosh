#!/bin/bash
# Post-install for the Dell G15 5530 EFI, run once in macOS after the first boot with WhateverXe Graphics installed.
#   sudo bash install-macos.sh check     only reports what is installed (changes nothing)
#   sudo bash install-macos.sh install   applies everything below, then asks you to reboot
# Steps (each one is also a script you can run alone; backups of every patched file go to /Library/G15-uhd):
#   1. Metal driver leak patch       post-install/macos-mtl-leakpatch.sh aplicar
#   2. VA driver patches (avcfix)     post-install/macos-patch-wex-va.sh avcfix
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
  echo "WhateverXe Graphics: $(gfx || true)  (tested: 0.4.0)"
  echo "WhateverXe kext:     $(printf '%s\n' "$K" | awk '/org.b00t0x.WhateverXe /{print $7; exit}' | tr -d '()')"
  echo "1. leak patch:       $(bash "$H/post-install/macos-mtl-leakpatch.sh" estado 2>/dev/null | sed -e 's/leakpatch do driver Metal: //' -e 's/aplicado/applied/')"
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
    [ -n "$v" ] || { echo "install the WhateverXe Graphics package (0.4.0) first, then reboot and run this again"; exit 1; }
    [ "$v" = 0.4.0 ] || echo "WARNING: WhateverXe Graphics $v is installed; the patches were made for 0.4.0. Each patch checks its bytes and stops if they differ."
    echo "== 1. Metal driver leak patch"; bash "$H/post-install/macos-mtl-leakpatch.sh" aplicar || echo "   (step 1 failed)"
    echo "== 2. VA driver patches (avcfix)"
    if [ "$(va_state)" = "avcfix applied" ]; then echo "   already applied"; else bash "$H/post-install/macos-patch-wex-va.sh" avcfix || echo "   (step 2 failed)"; fi
    if [ "$(vp_state)" = "VP fix applied" ]; then echo "   VP fix already applied"; else bash "$H/post-install/macos-va-vp81.sh" aplicar || echo "   (step 2, VP fix, failed)"; fi
    echo "== 3. Metal stencil shim"; bash "$H/prebuilt/stencilfix/instalar.sh" || echo "   (step 3 failed)"
    echo "== 4. Audio plug-in";       bash "$H/prebuilt/audio/install.sh" || echo "   (step 4 failed)"
    echo "== 5. G15.app";             sudo -u "$U" bash "$H/prebuilt/G15.app-installer/install.sh" || echo "   (step 5 failed)"
    echo "== 6. pmset"
    pmset -b displaysleep 3 sleep 5 && pmset -c displaysleep 5 sleep 15 && pmset -a hibernatemode 0 standby 0 && echo "   done"
    echo; check
    echo; echo "Now REBOOT. Then install NullMoth with its own installer and add BOOST=0 to /Library/GPUBundles/nvmtl/nvrm610.conf (README)."
    echo "Reinstalling WhateverXe Graphics undoes steps 1-3: run this script again afterwards.";;
  *) echo "usage: sudo bash install-macos.sh check | install"; exit 1;;
esac

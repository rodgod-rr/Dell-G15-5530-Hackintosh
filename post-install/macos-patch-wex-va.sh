#!/bin/bash
# Patches for the Intel VA driver (AppleIntelTGLGraphicsVADriver, from WhateverXe Graphics 0.4.4) on macOS Tahoe 26.7.3.
# Video decode and encode stay on the hardware; H.264 decodes correctly.
#   1. 0x1336f3  NULL check before a store through a missing object (crash in VTDecoderXPCService)
#   2. 0x130e84  NULL check on a per-engine table lookup (same crash, second path)
#   3. 0x228358  H.264 fix: the driver kept the pointer passed with SetDriverParameter key 6 at this+0x390 and later read
#                it as a per-slice offset array; on Tahoe that key points to a structure, so slice 1 got garbage. NOP.
# Each patch checks the original bytes first and stops on a different driver. The patches are always applied to the
# original driver, saved once in /Library/G15-uhd/wex-va-original/driver.
#   sudo bash macos-patch-wex-va.sh           apply
#   bash macos-patch-wex-va.sh check          report (no sudo, changes nothing)
#   sudo bash macos-patch-wex-va.sh remove    put the original driver back
# Restart Safari and any video app afterwards (or reboot).
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle
BIN=${VA_BIN:-$B/Contents/MacOS/AppleIntelTGLGraphicsVADriver}
BK=/Library/G15-uhd/wex-va-original
PATCHES="1336f3:488957088b45e44883c4305dc3:4885ff740448895708c9c39090
130e84:8b88bc09000083c10089c989ca488bbcd010090000:8b90bc090000488bbcd0100900004885ff74c69090
228358:48898190030000:0f1f8000000000"
rd() { od -An -tx1 -j "$2" -N"$3" "$1" | tr -d " \n"; }
wr() { printf "$(echo "$3" | sed 's/../\\x&/g')" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
# state of one file: "original", "patched" or "other"
state() { local f=$1 a=1 p=1 t o orig new n v
  for t in $PATCHES; do o=$((0x${t%%:*})); orig=$(echo "$t" | cut -d: -f2); new=$(echo "$t" | cut -d: -f3); n=$(( ${#orig} / 2 ))
    v=$(rd "$f" $o $n); [ "$v" = "$orig" ] || a=0; [ "$v" = "$new" ] || p=0; done
  # older versions of this kit also patched 0x15f96 and 0x786fc4: those files count as "other"
  [ "$(rd "$f" $((0x15f96)) 6)" = 554889e54157 ] || { a=0; p=0; }
  [ "$(rd "$f" $((0x786fc4)) 4)" = 02000000 ] || { a=0; p=0; }
  [ $a = 1 ] && echo original && return; [ $p = 1 ] && echo patched && return; echo other; }
sign() { [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "warning: codesign of the bundle failed"; }

[ -f "$BIN" ] || { echo "no VA driver at $BIN (install WhateverXe Graphics 0.4.4 first)"; exit 1; }
case "${1:-apply}" in
  check)
    echo "VA driver: $(state "$BIN"); original backup: $([ -f "$BK/driver" ] && state "$BK/driver" || echo none)";;
  remove)
    [ -f "$BK/driver" ] || { echo "no backup in $BK"; exit 1; }
    cp -p "$BK/driver" "$BIN.new" && mv -f "$BIN.new" "$BIN"; sign; echo "VA: original driver back";;
  apply)
    [ "$(id -u)" = 0 ] || [ -n "${VA_BIN:-}" ] || { echo "run with sudo"; exit 1; }
    cur=$(state "$BIN")
    [ "$cur" = patched ] && { echo "VA: already patched"; exit 0; }
    if [ "$cur" = original ]; then
      # a backup from another package version would bring an old driver back: keep the current one instead
      if [ -f "$BK/driver" ] && ! cmp -s "$BK/driver" "$BIN"; then mv "$BK/driver" "$BK/driver.obsolete-$(date +%Y%m%d%H%M)"; fi
      mkdir -p "$BK"; [ -f "$BK/driver" ] || cp -p "$BIN" "$BK/driver"
    fi
    [ -f "$BK/driver" ] && [ "$(state "$BK/driver")" = original ] || { echo "VA driver is modified and there is no original backup: reinstall WhateverXe Graphics 0.4.4, then run this again"; exit 1; }
    T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"
    for t in $PATCHES; do o=$((0x${t%%:*})); new=$(echo "$t" | cut -d: -f3); wr "$T" $o "$new"; done
    [ "$(state "$T")" = patched ] || { rm -f "$T"; echo "VA: patch check failed, nothing changed"; exit 1; }
    cp -p "$T" "$BIN.new" && mv -f "$BIN.new" "$BIN"; rm -f "$T"; sign
    echo "VA: patched (backup of the original in $BK). Restart Safari and video apps, or reboot.";;
  *) echo "usage: sudo bash macos-patch-wex-va.sh [apply] | check | remove"; exit 1;;
esac

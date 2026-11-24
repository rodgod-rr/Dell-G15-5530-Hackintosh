# Changelog

What changed in this EFI and why, newest first. The [README](README.md) describes only the current state.

## 2026-11-24

- **NullMoth 3.1** (was 3.0). My NVRM build for GC6 and the lazy Metal plugin moved to the `g15-gc6-31` and
  `g15-lazy-31` branches of my [NullMoth fork](https://github.com/rodgod-rr/nvidia-macos-driver); `g15-gc6` and
  `g15-lazy` stay as the 3.0 versions.
- **WhateverXe fork: GPU clock governor** ([WhateverXe#176](https://github.com/b00t0x/WhateverXe/issues/176)). Without
  GuC, Apple's driver kept asking for the maximum clock (1450 MHz here), so every exit from RC6 ran at full speed. The
  fork now picks the clock from RC6 residency in 16 ms windows (no forcewake, no MMIO writes). Same-boot A/B on the GPU
  power plane (RAPL) at 60 fps: medium load 1.43 W -> 1.18 W (-17 %), light load about the same; frames take longer
  (4.0 -> 5.5 ms). `sysctl debug.g15gtgov=0` turns it off live, `-wex-g15-gtgov-off` from boot.
- **IntelHybridCores** updated: System Information shows 10 cores with Hyper-Threading (16 threads) instead of 16
  cores, and `hcpower=4,2` (optional) switches the mode between battery and AC.
- **Post-install, VA driver:** the patch at `0x15f96` (makes `SetDriverParameter` always fail) and the
  [WhateverXe#81](https://github.com/b00t0x/WhateverXe/issues/81) workaround (`0x786fc4`, yuv2/NV12 output list 2 -> 0)
  are no longer applied: on 26.7.3 both turned off H.264 hardware decode. Graphics 0.4.4 already fixes the video
  post-processing hang that #81 worked around. `post-install/macos-va-vp81.sh` is removed; `macos-patch-wex-va.sh`
  always starts from the original driver, so running `install-macos.sh install` again fixes an install made with an
  older version of this kit.
- **UHD hangs:** with `-wex-g15-noccs` the Live Text / photo analysis hangs are gone, but three render-engine hangs
  happened between 2026-11-21 and 11-23 (stuck in `GPGPU_WALKER` or `PIPE_CONTROL`, one with the RTX fully loaded,
  one that ended in a WindowServer watchdog). Geekbench 7.1 Metal on the UHD completes (score 717): Feature Matching
  runs clean; Horizon Detection causes two render-engine resets that recover; Face Tracking and Super Resolution fail
  validation.
- **Logitech Lightspeed receiver:** it polls at a fixed 1000 Hz (Windows shows the same), which is why it keeps the
  package in PC2; it is the receiver, not this EFI.
- **Camera/microphone prompt:** on my machine macOS's own prompt is back since 2026-11-22, by running with AMFI on
  (AMFIAnchor and the GPU bundles signed by my own certificate authority). This EFI still relaxes AMFI, so G15.app's
  own prompt is still used here.
- README rewritten to describe only the current state; the history moved here.

## 2026-11-22

- **WhateverXe fork on 0.8.3** with three render-context workarounds that i915/xe apply on this GPU (`0xE18C`, `0x7018`,
  `0x7300`; `-wex-g15-ctxwa-off` removes them).
- **Boot logo** ([WhateverXe#131](https://github.com/b00t0x/WhateverXe/issues/131)): when the driver arms the plane in
  X-tile while the GOP console is still on screen, the fork rewrites the console in the Gen12 X-tile layout (once per
  boot, ~110 ms; `-wex-g15-xtile-off`). The large shifted logo is gone and the rest are shorter. (The patch posted in
  #131 made it worse on this machine and is not used.)
- **NVIDIA's own GC6 for the RTX** (optional, needs my NVRM build): NVIDIA's resource manager decides when the RTX is
  idle, revokes the apps' mappings, enters GC6 with VRAM kept, and `G15Fan` (`G15RtxPower`) cuts power; it comes back
  in about 1.24 s. With it, G15.app shows RTX statistics (load, time in GC6, wakes) instead of the off/on/auto selector.
- **USB idle:** the webcam and the keyboard-light controller (AW-ELC) now suspend when idle (G15PM `UsbIdle`; a
  code-less `G15Fan` personality keeps Apple's HID driver off the AW-ELC so G15.app owns it through IOUSBHost).
- **Bluetooth idle time 2 s** (was 50 ms): with 50 ms a Bluetooth LE mouse made the controller suspend at every pause,
  and after about 1000 cycles the Intel firmware stopped signalling remote wake.
- PSR moved to "What works"; RTX idle power and the UHD hang moved out of "What partly works".

## 2026-11-17

- **UHD hang fixed: `-wex-g15-noccs`.** Apple turns on the compute engine (CCS) from `AppleIntelTGLGraphics`'
  `Info.plist` (`EnableMultiContext`), and CCS and RCS running in parallel is what Intel's TGL PRM Vol 14 forbids
  ("SVSM: Dual Context - Invalidate hang"); Linux never uses the CCS on this GPU. Preview's Live Text, `mediaanalysisd`
  and `photoanalysisd` hung the GPU; with the boot-arg compute runs on the RCS.
- **RTX as an external GPU** (`G15PM`, `-g15egpu`): apps with "Prefer External GPU" run on the RTX.
- `SSDT-BTRK`: the Intel Bluetooth is held in reset while it is off (about 0.5 W less).
- macOS 26.7.3. README: optional lazy NullMoth plugin.

## 2026-11-15

- **IntelHybridCores**: P-core/E-core scheduling by QoS, `hw.perflevel`, Activity Monitor labels, `hcmode=4`.

## 2026-11-14

- **PSR on** (`wexg15psr=3`): the fork forces a PSR exit before each vblank wait; without it every wait timed out
  after 500 ms and the first frame after a still screen could be late. The WindowServer freezes seen with PSR in the
  first days were the UHD hang, not PSR.
- **Bluetooth on no longer costs power:** `bluetoothd` never enables USB idle suspend (real Macs have UART/PCIe
  Bluetooth), so the port never suspended and the package stayed in PC2 (about +5 W). `G15PM` (`BtIdle`) sets the
  idle policy and takes the idle `IntelBluetoothFirmware` driver out of the power tree.
- **Headphone jack:** automatic switching, headset microphone, CTIA/OMTP detection as on Linux (AudShim 0.9.10).
- NullMoth 3.0; iMessage and FaceTime confirmed.

## 2026-11-13

- **WhateverXe Graphics 0.4.4** fixes the Metal memory leak
  ([WhateverXe#47](https://github.com/b00t0x/WhateverXe/issues/47)). The old two-byte leak patch at `0x7ed87` is
  removed: it was the main suspect of the UHD hang.
- WhateverXe fork on 0.8.2: forcewake on every engine while it executes, released as soon as the engine is idle (a
  still screen stays at about 1.2-1.7 W of package power); per-engine hang log.

## 2026-11-12

- WhateverXe fork: render forcewake while the render engine executes, hang log in `/private/var/log`, optional eDP
  PSR1 (`wexg15psr=3`, about 2.05 -> 1.17 W with a still screen). `LICENSE.i915` added for the DMC firmware embedded
  in WhateverXe.

## 2026-11-11

- **UHD RC6 fixed** (`G15AGPMIgpu`): the MacBookPro16,1 AGPM profile, made for 9th-gen graphics, stopped RC6 about
  60 s after boot (GT stuck in C0, no package C-states); RC6 back to about 87 % idle.
- **RTX wakes only for real use** (`G15PM` `RtxLazy`), counts idle as no driver calls (`RtxCalls`) so it can stop with
  apps open, refuses new opens on battery while off (`RtxDeny`); G15.app "App na RTX" card with pause in background;
  RTX auto off after 5 min on AC.
- Apple TV app / App Store video hang worked around with WhateverXe#81 (replaced on 2026-11-24, see above).

## 2026-11-10

- **RTX powered off when idle** (`G15Fan` `RtxPm` + `G15PM` NVAccel hook + G15.app selector).
- **Panel back after display sleep:** the fork turns the CDCLK PLL back on after a long display Doze
  ([WhateverXe#80](https://github.com/b00t0x/WhateverXe/issues/80)).
- No verbose boot; NullMoth 2.9.

## 2026-11-09

- First release: Deep Idle sleep with lid, keyboard, touchpad, power button and USB wake; prebuilt binaries, one
  post-install script, installer config and guide; G15.app keyboard-lighting window and BIOS backlight timeout.

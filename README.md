# Dell G15 5530 Hackintosh: macOS Tahoe 26.7.3, OpenCore EFI

This is the working EFI for my Dell G15 5530, with notes on what works, what partly works and what does not.
**It is a snapshot of my daily-use setup, not a polished guide.** Read the whole page before trying it. Your BIOS,
SSD and panel may differ, and the DSDT shipped here was dumped from my machine.

| | |
|---|---|
| CPU | Intel Core i5-13450HX (Raptor Lake-HX, 6P + 4E) |
| iGPU | Intel UHD Graphics 8086:A78B (16 EU), drives the internal panel |
| dGPU | NVIDIA RTX 4050 Laptop 10de:28e1 (HDMI is wired to it) |
| Panel | 1920x1080 120 Hz eDP |
| Wi-Fi / BT | Intel AX211 (CNVi) |
| Ethernet | Realtek RTL8111 |
| Touchpad | Synaptics I2C HID 06CB:CE81 |
| SSD | Samsung 970 EVO (macOS); Fedora on a second NVMe |
| BIOS | 1.0 (2026-01-21), shown in macOS as firmware 2094.80.5.0.0 |
| macOS | Tahoe 26.7.3 (25G342) |
| OpenCore | 1.0.8, SMBIOS MacBookPro16,1 |

## What works

- **Intel UHD graphics with acceleration:** Metal 2, QE/CI, 1536 MB shared VRAM, internal panel at 120 Hz.
  - Brightness keys and slider work, and so does Night Shift.
  - It uses [WhateverXe](https://github.com/b00t0x/WhateverXe) through my fork:
    [rodgod-rr/WhateverXe `g15-deep-idle`](https://github.com/rodgod-rr/WhateverXe/tree/g15-deep-idle)
    ([write-up](https://github.com/rodgod-rr/WhateverXe/blob/g15-deep-idle/docs/g15-deep-idle/README.md)).
  - It needs the [WhateverXe Graphics](https://github.com/b00t0x/WhateverXe-Graphics) **0.4.4** package (the
    WhateverXe fork is based on 0.8.3 (since 2026-11-22) and publishes the activation token that Graphics 0.4.2+ requires). My patch layer
    on top of it is also in [rodgod-rr/WhateverXe-Graphics `g15`](https://github.com/rodgod-rr/WhateverXe-Graphics/tree/g15).
  - **GT frequency governor (since 2026-11-24, on by default).** Without GuC, Apple's driver always asked for the
    maximum GT clock (1450 MHz here), so every exit from RC6 ran at full speed
    ([WhateverXe#176](https://github.com/b00t0x/WhateverXe/issues/176)). The fork now picks the clock from RC6
    residency in 16 ms windows, without forcewake or MMIO writes. Measured on the GT power plane (RAPL) at 60 fps:
    medium load 1.43 W -> 1.18 W (-17 %), light load about the same; frames take a little longer (4.0 -> 5.5 ms).
    `sysctl debug.g15gtgov=0` turns it off live (no sudo), `debug.g15gtgov_info` shows its state, and
    `-wex-g15-gtgov-off` disables it from boot.
  - Fewer repeated Apple logos at boot ([WhateverXe#131](https://github.com/b00t0x/WhateverXe/issues/131)): when
    the driver arms the plane in X-tile while the GOP console is still on screen, the fork rewrites the console in the
    Gen12 X-tile layout (once per boot, ~110 ms; `-wex-g15-xtile-off` disables it). The large shifted logo is gone and
    the remaining ones are shorter, but not all are gone yet.
- **RTX 4050 for Metal/compute**, through [NullMoth](https://github.com/nullmoth/nvidia-macos-driver) 3.1. It runs
  alongside the UHD: Metal 3, about 4.9 TFLOPS.
  - **RTX as an external GPU (since 2026-11-16, boot-arg `-g15egpu`).** `G15PM` marks the RTX as removable for Metal
    (`IOAccelDevice2::get_config` bit 13 and `Removable` on NVAccel; the kernel's own eGPU path is not used, so sleep is
    unaffected). Apps with "Prefer External GPU" in Finder > Get Info run on the RTX by themselves (Hollow Knight, the
    Novabench GPU test); everything else stays on the UHD. With this, NullMoth's default list `*` is fine.
  - **Optional: lazy start of the Metal plugin.** Every Metal app used to wake the RTX just by listing the GPUs (the
    plugin created the whole NVK device in `initWithAcceleratorPort:`). The `g15-lazy-31` branch of my NullMoth fork
    ([rodgod-rr/nvidia-macos-driver](https://github.com/rodgod-rr/nvidia-macos-driver/tree/g15-lazy-31), on 3.1;
    `docs/G15-LAZY-INIT.md`) answers the device properties from a saved snapshot and starts NVK on first real use:
    Safari, TextEdit or WhatsApp no longer wake it; Preview's Live Text and games do. Not in this EFI (it replaces
    NullMoth's `NVMTLDriver`).
  - `BOOST=0` in `/Library/GPUBundles/nvmtl/nvrm610.conf` lets it drop to P8 while it is on and idle, saving about 12 W.
- **RTX powered off when idle.** Stock NullMoth's own RTD3 (2.9 to 3.1) cannot cut power here (Apple's
  `evaluateObject` only runs plain method names, and forcing it froze the system;
  [nullmoth#428](https://github.com/nullmoth/nvidia-macos-driver/issues/428)). There are two ways around it:
  - **NVIDIA's own GC6 (since 2026-11-22, what I use; needs my NVRM build, not included).** With an NVRM built from the
    [`g15-gc6-31` branch of my NullMoth fork](https://github.com/rodgod-rr/nvidia-macos-driver/tree/g15-gc6-31) (on 3.1; `g15-gc6` is the 3.0 version)
    (`kexts/NVRM/nv_xnu_dynpm.cpp`), NVIDIA's resource manager decides when the RTX is idle and runs the whole
    transition itself (RTD3 "OSPM" mode, no `_DSM` JT): it revokes the apps' mappings of the card
    (`IOMemoryDescriptor::redirect`), enters GC6 (VRAM kept in self-refresh), D3hot, and `G15Fan` cuts power
    (`PG01._OFF`). Any driver call or touch of a mapping brings it back synchronously in about 1.24 s, with VRAM intact;
    the rest of the desktop does not stutter meanwhile, and turning the screen on wakes it without a visible pause.
    G15.app never stops the RTX itself: its RTX card shows statistics read without waking the card (core/memory/video
    load while awake, share of the time in GC6, number of wakes, how long the last one took and what asked for it).
    Boot-args, only together with that NVRM: `nvrmdynpm=2 nvrmnvpcf=1
    nvregdwords=DynamicPowerManagement=3;DynamicPowerManagementVideoMemoryThreshold=0;PCIEPowerControl_8086a7190bf81028=39`.
    Do not add the `nvregdwords` with the stock NVRM: its `os_strtoul` is a stub, so every key there becomes 0.
    Write-up (Portuguese): `docs/RTX-GC6.md` in my main repository; findings for NullMoth are being reported upstream.
  - **With stock NullMoth (since 2026-11-10): the RTX goes through the system sleep path while the system stays
    awake.** `G15Fan` asks IOPM to put NVRM and the HDMI audio function in power state 0, NullMoth suspends the GPU with
    its own sleep code, and when the PCIe bridge reaches state 0 `G15Fan` calls `GOFF` (`PG01._OFF`, boot-arg
    `-g15fan-rtxpm-corte`); `GONN` brings it back and NullMoth resumes in about 1.2 s. `G15PM` turns it back on when an
    app opens the RTX and waits for it (`NVAccel::newUserClient`), only at the first real GPU call (`RtxLazy`), counts
    "idle" as no driver calls (`RtxCalls`) so it can stop with apps open, refuses `systemstats` while it is off, and in
    the Battery profile refuses new RTX opens while it is off (`RtxDeny`). G15.app decides when: an
    "RTX ( Desligada | Ligada | Automática )" selector, where Auto turns it off after 30 s idle on battery or 5 min on AC.
  - **"App na RTX" card in G15.app (both ways):** shows the app using the RTX, with a "Pausar em 2º plano" (pause in
    background) button for that app only, until it quits. After 30 s in the background the app is frozen (SIGSTOP, its
    sound muted), so the RTX can turn off; switching back to it resumes it at once.
  - **Measured on battery with the RTX powered off (both ways):** about 1.2-1.7 W of CPU package with the screen on
    (PC8 ~75-80 %) and 1.5-1.7 W with it off (PC10 ~70 %). With the RTX on, the package almost never leaves PC2/C0.
    A Logitech Lightspeed USB receiver (`046d:c539`) adds about 2 W on its own: it sends input reports all the time and
    never suspends, so the package stays in PC2. On battery, use the mouse over Bluetooth (the G603 is dual).
  - **HDMI:** a powered-off RTX cannot see a cable. With stock NullMoth, pick "Ligada" before connecting one; with the
    GC6 build this is not tested yet.
- **Sleep (Deep Idle / S0, since the firmware has no S3).** Sleep and wake work, and the panel comes back every time.
  - Tested with 5 RTC cycles in a row, idle sleep, lid-close sleep, and 1 h 44 min on battery.
  - Overnight on battery (5 h 15 min, lid closed): package in PC10 ~100% of the time, about 0.9-1.0 W (~2 %/h).
  - **Wake sources:** lid, internal keyboard, touchpad, power button, USB.
  - The fix needs three pieces: my WhateverXe fork, `SSDT-DeepIdle` and `SSDT-LIDWAKE`.
  - The RTX is powered off during sleep by `G15Fan` + `SSDT-RTXKEXT` (ACPI `PG01._OFF`).
  - Display sleep without system sleep also works: the panel comes back. The WhateverXe fork turns the CDCLK PLL
    back on after a long display Doze ([WhateverXe#80](https://github.com/b00t0x/WhateverXe/issues/80)).
- **Video:**
  - H.264 and HEVC hardware decode (YouTube 1080p H.264 in Safari).
  - H.264 hardware encode.
  - Live Text / Vision.
  - Apple Music with FairPlay.
  - Apple TV app, App Store videos and video screen savers, without hanging the GPU. The video post-processing batch
    used to get stuck on `MEDIA_OBJECT` ([WhateverXe#23](https://github.com/b00t0x/WhateverXe/issues/23),
    [#60](https://github.com/b00t0x/WhateverXe/issues/60)); the workaround from
    [WhateverXe#81](https://github.com/b00t0x/WhateverXe/issues/81) avoids that path and keeps H.264 hardware decode.
  - The VA driver needs patches; see Post-install.
- **UHD RC6 (since 2026-11-11).** With the MacBookPro16,1 SMBIOS, AGPM applies a profile made for 9th-gen graphics whose
  `RCxControl`/`CPGControl` blocks stopped RC6 about 60 s after boot (GT stuck in C0, no package C-states).
  `G15AGPMIgpu.kext` (no code) re-injects the same AGPM profile without those two blocks: RC6 back to ~87% idle
  ([WhateverXe#87](https://github.com/b00t0x/WhateverXe/issues/87)).
- **UHD hang fixed (since 2026-11-16, `-wex-g15-noccs`).** The UHD hung (screen frozen, `gpuRestart`, WindowServer
  watchdog) when Apple's ML frameworks ran compute on the GPU: opening PDFs in Preview (Live Text), `mediaanalysisd`,
  `photoanalysisd`. The compute engine (CCS) and the render engine (RCS) ran in parallel, which Intel's TGL PRM Vol 14
  forbids ("SVSM: Dual Context - Invalidate hang"); Linux never uses the CCS on this GPU. Apple turns it on from
  `AppleIntelTGLGraphics`' `Info.plist` (`EnableMultiContext`); with `-wex-g15-noccs` the WhateverXe fork makes the
  driver read 0, so compute runs on the RCS as on Linux. No hang since. (Before that, the old two-byte Metal leak patch
  also caused restarts; Graphics 0.4.4 fixes the leak safely and the patch is gone from this repository.) The
  WhateverXe fork also keeps forcewake on every engine while it executes and releases it as soon as the engine is idle
  (a still screen stays at about 1.2-1.7 W of package power), and applies three render-context workarounds that i915/xe
  use on this GPU (`0xE18C`, `0x7018`, `0x7300`; `-wex-g15-ctxwa-off` removes them). Each hang is written with per-engine registers to `/private/var/log/g15-uhd-hang-*.txt`; `wexg15unstick=31` tries to recover.
- **eDP Panel Self Refresh (on in this config, since 2026-11-14).** The boot-arg `wexg15psr=3` turns on PSR1 for
  the internal LG panel: with a still screen the package drops from about 2.4 W to 1.5 W (PSR active 97% of the time). Since 2026-11-14 the
  WhateverXe fork forces a PSR exit before each vblank wait: without it every wait timed out after 500 ms ("Wait for VBL
  timed out" in the kernel log) and the first frame after a still screen could be late. The WindowServer freezes seen
  with PSR in the first days were the hang above. Remove the boot-arg, or `sudo sysctl debug.g15psr=0`, to turn it off.
- **Audio:** internal speakers with volume and mute, and the internal microphone (DMIC) with DeepFilterNet3 noise
  suppression. This is `AudShim` + the `XeSpeakers` HAL plug-in.
  - **Headphone jack (since 2026-11-14):** headphones switch automatically with the speakers ("Fones de ouvido"), and a
    headset microphone works ("Microfone do fone"). The CTIA/OMTP type is detected like Linux does (headphone muted and
    300 ms before reading the codec), so plugging in with audio playing no longer records the playback. Headphones
    without a microphone are detected and keep the internal microphone.
- **Connectivity:** Wi-Fi (AirportItlwm), Bluetooth, Ethernet (RTL8111) and USB.
  - **Bluetooth on no longer costs power (since 2026-11-14).** The Intel Bluetooth is a USB device owned by `bluetoothd`,
    which never enables USB idle suspend (real Macs have UART/PCIe Bluetooth), so the port never suspended and the package
    stayed at PC2 (about +5 W). `G15PM` (`BtIdle`) sets the IOUSBHost idle policy on the Bluetooth interfaces and its IN
    pipes, and takes the idle `IntelBluetoothFirmware` driver out of the power tree (it blocked idle suspend). The port is
    now suspended about half the time and idle power with Bluetooth on is the same as with it off (about 2.2 W). Headsets,
    mice and sleep work. The idle time is 2 s (as Linux's USB autosuspend): with 50 ms a Bluetooth LE mouse made the
    controller suspend at every pause, and after about 1000 cycles the Intel firmware stopped signalling remote wake
    (the mouse stayed "connected" but dead until Bluetooth was toggled). `sudo sysctl debug.g15btidle=0` turns it off,
    or sets another time in ms (then toggle Bluetooth).
  - **Webcam and keyboard-light controller idle too (since 2026-11-22).** The webcam and the AW-ELC (keyboard light, USB
    `187c:0551`) stayed 100 % powered: Apple's HID and UVC drivers never set a USB idle policy on them. `G15PM` (`UsbIdle`)
    sets a 2 s idle policy on the webcam (Photo Booth still works) and, for the AW-ELC, a code-less personality in `G15Fan`
    keeps Apple's HID driver off the interface so G15.app owns it through IOUSBHost (idle policy + SET/GET_REPORT on the
    control pipe). Both now suspend fully when idle. The keyboard light turns off after 1 min and back on at a key press.
    `sudo sysctl debug.g15usbidle=0` turns it off; `debug.g15usbidle_dev` is a device mask (1 Logitech receiver, 2 AW-ELC,
    4 webcam; default 5). The Logitech receiver still never suspends (it sends reports all the time): use Bluetooth.
- **iMessage and FaceTime** work (tested 2026-11-14).
- **Input:** keyboard via VoodooPS2, touchpad via VoodooI2C in GPIO interrupt mode, keyboard backlight (AW-ELC), and the
  Fn keys F5 / F9 / F10 through G15.app.
- **Keyboard lighting (G15.app → "Luz do teclado…"):** a window with a drawing of the keyboard and a live preview.
  - One color for the whole keyboard, or 4 zones (left, center, right, numpad).
  - Effects from the AW-ELC controller: static, breathing, morph, spectrum and wave, with speed.
  - Brightness, presets, and named profiles of your own.
  - "Turn off after": the BIOS backlight timeout, set through `G15Fan` (Dell SMBIOS class 4/11 via `\_SB.AMW0.WMBA`).
  - Nothing is written to the controller's flash; G15.app re-applies your choice at login and on wake.
  - The protocol can be tested from Linux with `tools/test-kbd-elc.py`.
- **Power and thermals:**
  - Battery status and charging.
  - CPU power management with HWP and full turbo (4.2-4.6 GHz single core), the C8/C10 idle table, and EPP per
    profile (`G15PM`).
  - Fans and thermal profiles (Battery, Quiet, Balanced, Performance, G-Mode) through Dell WMAX (`G15Fan`).
  - CPU/RTX temperatures in the menu bar (G15.app).
- **P-cores and E-cores** (6P + 4E) through [IntelHybridCores](https://github.com/rodgod-rr/IntelHybridCores):
  - Background work (Spotlight, Time Machine, photo analysis) runs on the E-cores and the foreground on the P-cores,
    by the QoS each app declares. This EFI uses `hcmode=4` (background only on E-cores, as on Apple Silicon): under
    heavy background load the CPU package draws about half (27 W instead of 52 W on AC), at the cost of slower
    background tasks. `hcmode=2` makes it a preference instead; `sysctl debug.hc_mode=N` changes it live.
    `hcpower=4,2` (optional) switches the mode by itself: 4 on battery, 2 on AC.
  - `hw.nperflevels` = 2 ("Performance" 6/12, "Efficiency" 4/4) and Activity Monitor's CPU History shows
    "Core 1-12 — Performance" and "Core 13-16 — Efficiency". System Information shows 10 cores with Hyper-Threading (16 threads).
  - CpuTopologyRebuild is included but must stay disabled: it reports the E-cores as SMT siblings, which defeats this.
- **Dual boot with Fedora** on a separate NVMe, chosen from the Dell F12 menu.

## What partly works

- **HDMI (wired to the RTX):** with NullMoth 3.0, a cable connected at boot works in extended and mirrored mode, and
  resolution changes work; unplugging and replugging in that boot works too. A cable connected after a boot without one
  needs a WindowServer restart: NullMoth only creates the RTX output when a display is present, and WindowServer fixes its
  display pipes when it starts ([nullmoth#288](https://github.com/nullmoth/nvidia-macos-driver/issues/288), #581). The
  workaround (arm the output with NullMoth's sysctls, then restart WindowServer) is described in #288.
- **Boot logo:** for a few frames, when the UHD takes over from the firmware (the moment the brightness drops), the
  Apple logo is drawn several times. It used to last about 0.9 s; the vblank fix above shortened it.
  [WhateverXe#131](https://github.com/b00t0x/WhateverXe/issues/131) explains the cause; its fix made it worse on this
  machine, so it is not used.
- **Rare flicker** at the bottom of translucent windows when the UHD is heavily loaded. Turning on Reduce Transparency
  hides it.
- **Camera/microphone permissions:** with AMFI relaxed, macOS never shows the permission prompt for third-party apps.
  G15.app shows its own prompt and writes the TCC entry.

## What does not work

- **Prime Video app / FairPlay Streaming:** the key request fails with -15842. Use a Widevine browser (Chrome,
  Firefox or Edge) instead.
- **VP9 / AV1 hardware decode:** the driver does not expose them, so YouTube above 1080p is not available in Safari.
- **Hibernation:** not set up (`hibernatemode 0`).
- **Not tested:** HDMI audio, FileVault, Sidecar, AirDrop and Handoff.
  (The G15 5530 has no card reader and no video output on USB-C.)

## Will it work on my G15?

| Your machine | Expected |
|---|---|
| G15 5530, i5-13450HX, RTX 4050, FHD 120 Hz, BIOS 1.0 | Same as mine (this is the tested machine) |
| Other BIOS version | Probably boots, but `DSDT.aml` is from BIOS 1.0: rebuild it from your own dump (see step 3 below) |
| i7-13650HX / i9-13900HX (other UHD device ID) | **Untested.** The WhateverXe fork's RPL-S GGTT fix is gated on A78B; another user with a 13650HX had no acceleration ([WhateverXe#51](https://github.com/b00t0x/WhateverXe/issues/51)) |
| RTX 4060 | Untested; NullMoth supports it in general |
| 165 Hz or QHD panel | Untested |
| G15 5535 (AMD) / 5520 / 5511 | **No.** Different platform |

The touchpad wake uses a hard-coded GPIO pad (GPP_E3); on another touchpad wiring it would not wake (everything else
still works).

## BIOS settings

- Secure Boot **off**.
- Storage in **AHCI** (no RAID/VMD).
- **Hybrid Graphics ON** (Video > Enable Hybrid Graphics / Advanced Optimus), so the internal panel stays on the UHD.
  Without it the panel is on the RTX, and this EFI is not set up for that.

## Install from scratch

1. **Make the USB installer.**
   - Download macOS Tahoe recovery with `macrecovery.py` from the
     [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg/releases) `Utilities` folder (or make a full installer
     USB on a real Mac).
   - Format the USB stick as FAT32 / GPT ([Dortania guide](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/)).
   - Copy this `EFI` folder to it.
2. **Use the installer config.** On the USB stick, rename `EFI/OC/config.plist` to `config-system.plist`, and
   `EFI/OC/config-install.plist` to `config.plist`. The installer config is the one I installed with:
   - WhateverGreen with `-wegnoegpu` and no WhateverXe, so there is no iGPU acceleration during setup.
   - Touchpad in polling mode; Wi-Fi, keyboard and USB work.
3. **SMBIOS.** Generate a `MacBookPro16,1` serial with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS). Put the
   **same** `SystemSerialNumber`, `MLB`, `SystemUUID` and `ROM` in both configs, under `PlatformInfo > Generic`.
4. **`ACPI/DSDT.aml` is a full patched DSDT from my BIOS 1.0.** The patches are `_OSI` -> `XOSI` (brightness keys)
   and the `_S3` removal. On another BIOS version, dump your own DSDT (for example from Linux,
   `sudo cat /sys/firmware/acpi/tables/DSDT > DSDT.aml`) and apply the same two changes. Or remove `DSDT.aml` from
   `ACPI > Add`, and accept that brightness keys and sleep may break.
5. **Install macOS** from the USB stick (F12 boot menu), then boot the new install through the USB stick.
6. **Copy the EFI to the SSD.** Mount the SSD's EFI partition and copy the EFI folder there, this time with the
   **system** `config.plist` (and your SMBIOS). Boot from the SSD.
7. **Install the WhateverXe Graphics package 0.4.4**
   ([releases](https://github.com/b00t0x/WhateverXe-Graphics/releases)) and reboot. The UHD is now accelerated.
8. **Run the post-install script** (next section), then install NullMoth.

### Boot-args of the system config

```
keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -allow3d -disablegfxfirmware
amfi_get_out_of_my_way=1 gfxrst=1 -g15pm -igfxdvmt -wexdbg wexblmin=4900 -wex-blmin=4900 nvfb=1 nvaccel=1 acpi=0xC
-g15fan-rtxpm-corte -nvmefaspm wexg15psr=3 wexg15unstick=31 hcmode=4 -wex-g15-gsync -wex-g15-ccsreset-off
-wex-g15-noccs -g15egpu nvfbheads=4
```

- Required: `-allow3d -disablegfxfirmware amfi_get_out_of_my_way=1 -igfxdvmt gfxrst=1 -g15pm wexblmin=4900
  -wex-blmin=4900 nvfb=1 nvaccel=1`.
- Strongly recommended: `-wex-g15-noccs` (the UHD hang fix above).
- Optional: `-g15fan-rtxpm-corte` (cut RTX power when idle), `wexg15psr=3` (PSR1), `wexg15unstick=31` (tries to restart
  a stuck engine before the GPU reset), `hcmode=4` (IntelHybridCores mode; without it the default is 2), `-g15egpu`
  (RTX as an external GPU), `nvfbheads=4` (NullMoth's recommended display heads), `-nvmefaspm` (NVMeFix: ASPM L1 on
  both NVMe drives), `-wex-g15-gsync -wex-g15-ccsreset-off` (GPU reset details in the WhateverXe fork).
- Logging only, safe to remove (add `-v` for a verbose boot): `keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -wexdbg acpi=0xC`.

SIP is partly disabled (`csr-active-config` 0x0A43) and AMFI is relaxed, because the GPU bundles are re-signed ad hoc.
Know what that means for your security.

## EFI contents

- `EFI/OC/config.plist`: the system config. `EFI/OC/config-install.plist`: the installer config (see Install from scratch).
- `EFI/OC/ACPI` (sources in `acpi-src/`; the comments are in Portuguese):
  - `SSDT-AWAC`, `SSDT-EC-USBX`, `SSDT-PLUG-ALT` (from Dortania) and `SSDT-PNLF` (prebuilt).
  - `SSDT-XOSI`: answers the Windows `_OSI` strings on macOS.
  - `SSDT-DeepIdle`: `\_SB.LPS0` / `\_GPE.LXEN`, for S0 sleep.
  - `SSDT-LIDWAKE`: lid `PRW0` = EC GPE 0x6E, so the lid wakes from Deep Idle.
  - `SSDT-RTXKEXT`: `GOFF` / `GONN` methods used by G15Fan to cut RTX power during sleep.
  - `SSDT-PS2K-RMCF`: VoodooPS2 settings.
  - `SSDT-BTRK`: `\_SB.AMWW.BTOF/BTON/BTST` around the DSDT's Bluetooth reset GPIO (`\_SB.BTRK`). G15Fan `BtReset`
    holds the Intel BT in reset while it is off: it leaves USB and the package idles about 0.5 W lower.
- `EFI/OC/Kexts`:
  - Lilu 1.7.3, VirtualSMC 1.3.9 (+ SMCBatteryManager, SMCProcessor), RestrictEvents 1.1.7, NVMeFix 1.1.4.
  - AirportItlwm 2.4.0, IntelBluetoothFirmware / IntelBTPatcher 2.5.3, BlueToolFixup 2.7.3, RealtekRTL8111 3.0.0.
  - USBToolBox 1.2.0 + UTBDefault, XHCI-unsupported.
  - VoodooPS2Controller 2.3.8, VoodooI2C 2.9.1 (CI build 6be653a2) + VoodooI2CHID, BrightnessKeys 1.0.4.
  - AMFIPass-Mod 1.4.1.
  - WhateverGreen 1.7.2: used only by `config-install.plist`; the system config does not load it.
  - **My builds:**
    - `WhateverXe` (fork above).
    - `G15Fan`: fans and profiles via Dell WMAX, RTX power cut in sleep and when idle (`RtxPm`, or `G15RtxPower` called
      by my NVRM build for GC6), EC wake arming.
    - `G15PM`: the XE-PM part of NootedGreen as its own Lilu plug-in (HWP, turbo, C-states, EPP), plus the RTX hooks
      (`RtxLazy`, `RtxCalls`, `RtxDeny`) and Bluetooth USB idle suspend (`BtIdle`, plus `UsbIdle` for Logitech
      receivers that go quiet; `sysctl debug.g15usbidle`, 0 turns it off).
    - `AudShim`: speakers, DMIC, headphone jack and headset microphone.
    - `IntelHybridCores`: P-core/E-core scheduling, `hw.perflevel` and Activity Monitor labels. Its own repository:
      [rodgod-rr/IntelHybridCores](https://github.com/rodgod-rr/IntelHybridCores) (source, write-up, measurements).
    - `G15AGPMIgpu`: AGPM profile for the UHD without `RCxControl`/`CPGControl` (RC6, see "What works").
  - Sources are in `src/`.

NullMoth (the RTX driver) is not in the EFI. Its installer puts it in `/Library/Extensions`.

## Post-install (in macOS)

Run it after the WhateverXe Graphics package, from this repository's folder:

```
sudo bash install-macos.sh check      # shows what is installed, changes nothing
sudo bash install-macos.sh install    # applies everything, then reboot
```

It runs these steps, which are also separate scripts. Every patched file is backed up to `/Library/G15-uhd`, and
every binary patch checks its bytes first, so it stops on a different driver version.

1. **Metal driver memory leak:** nothing to do. Graphics 0.4.4 fixes it
   ([WhateverXe#47](https://github.com/b00t0x/WhateverXe/issues/47)); `check` warns if the old two-byte patch or a
   leaking package is still installed. Do not use the old `0x7ed87` patch: it can hang the GPU.
2. **VA driver patches, `avcfix` mode** (`post-install/macos-patch-wex-va.sh`).
   - Fixes H.264 hardware decode on Tahoe (key 6 of `SetParam`), plus two NULL checks.
   - Then the video post-processing fix (`post-install/macos-va-vp81.sh aplicar`,
     [WhateverXe#81](https://github.com/b00t0x/WhateverXe/issues/81)): in the VA driver, the `yuv2`/`NV12` output
     list at `0x786fc4` goes from 2 entries to 0, so the Apple TV app and App Store videos no longer hang the GPU.
   - My machine uses the `avcfix-vame-k7` mode, which adds FairPlay (Apple Music). That mode needs the Tiger Lake VAME
     bundle, an Apple binary that is not included here.
3. **Metal shim `stencilfix`** (`prebuilt/stencilfix`). Fixes wrong stencil reads, the white blocks in 3D apps.
4. **Audio HAL plug-in XeSpeakers** with DeepFilterNet3 (`prebuilt/audio`). It creates the "Alto-falantes internos"
   (speakers, or "Fones de ouvido" with headphones plugged in) and "Microfone interno" (microphone, or "Microfone do fone"
   with a headset) devices.
   - The DSP firmware (Linux SOF `sof-rpl-s.ri`) is built into `AudShim.kext`.
5. **G15.app** for your user (`prebuilt/G15.app-installer`).
   - It handles the Fn keys, keyboard light, profiles and fans, menu-bar temperatures and permission prompts.
   - Its menus are in Portuguese. It needs the `G15Fan` and `G15PM` kexts (in the EFI).
6. **pmset:** battery display 3 min / sleep 5 min, AC display 5 min / sleep 15 min, `hibernatemode 0`, `standby 0`.

Then do two things by hand:
- Install **NullMoth 3.0** with its own installer. With `-g15egpu` keep its default app list (`*`) and mark the apps
  that should use the RTX with "Prefer External GPU". Without `-g15egpu`, restrict the RTX to the apps that need it:
  `sudo bash tools/rtx/macos-rtx-allow.sh restrita [app ...]` (again after every NullMoth update).
- Add `BOOST=0` to `/Library/GPUBundles/nvmtl/nvrm610.conf` so the RTX idles at P8.

**Reinstalling the WhateverXe Graphics package undoes steps 1-3.** Run `install-macos.sh install` again afterwards.

Sources for everything in `prebuilt/` are in `src/`. To rebuild:
- `src/G15.app/build.sh`
- `src/AudShim/XeSpeakers/build.sh`
- `src/stencilfix/build-mac.sh`

## Credits

[Acidanthera](https://github.com/acidanthera) (OpenCore, Lilu, VirtualSMC and friends),
[b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe), [NullMoth](https://github.com/nullmoth/nvidia-macos-driver),
[OpenIntelWireless](https://github.com/OpenIntelWireless), [VoodooI2C](https://github.com/VoodooI2C/VoodooI2C),
[USBToolBox](https://github.com/USBToolBox), [NootedGreen](https://github.com/sgiammori/NootedGreen) (XE-PM in G15PM),
[JulioNectar's XPS 13 Plus project](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe) (AudShim origin),
[Dortania](https://dortania.github.io/OpenCore-Install-Guide/).
Each component keeps its own license. AudShim is under the "Thou Shalt Not Profit" license (see `src/AudShim`).
WhateverXe.kext embeds the Intel ADL-S display microcontroller firmware (`adls_dmc_ver2_01.bin` from linux-firmware), redistributed under the Intel license in [`LICENSE.i915`](LICENSE.i915).

Built with a lot of help from Claude (Anthropic). Use at your own risk.

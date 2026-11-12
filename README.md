# Dell G15 5530 Hackintosh: macOS Tahoe 26.7.2, OpenCore EFI

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
| macOS | Tahoe 26.7.2 (25G332) |
| OpenCore | 1.0.8, SMBIOS MacBookPro16,1 |

## What works

- **Intel UHD graphics with acceleration:** Metal 2, QE/CI, 1536 MB shared VRAM, internal panel at 120 Hz.
  - Brightness keys and slider work, and so does Night Shift.
  - It uses [WhateverXe](https://github.com/b00t0x/WhateverXe) through my fork:
    [rodgod-rr/WhateverXe `g15-deep-idle`](https://github.com/rodgod-rr/WhateverXe/tree/g15-deep-idle)
    ([write-up](https://github.com/rodgod-rr/WhateverXe/blob/g15-deep-idle/docs/g15-deep-idle/README.md)).
  - It needs the [WhateverXe Graphics](https://github.com/b00t0x/WhateverXe-Graphics) **0.4.0** package.
- **RTX 4050 for Metal/compute**, through [NullMoth](https://github.com/nullmoth/nvidia-macos-driver) 2.9. It runs
  alongside the UHD: Metal 3, about 4.9 TFLOPS.
- **RTX powered off when idle (since 2026-11-10).** NullMoth 2.9's own RTD3 cannot cut power here (Apple's
  `evaluateObject` only runs plain method names, and forcing it froze the system). Instead, the RTX goes through the
  same path as system sleep, while the system stays awake:
  - `G15Fan` asks IOPM to put NVRM and the HDMI audio function in power state 0. NullMoth then suspends the GPU with
    its own sleep code.
  - When the PCIe bridge reaches state 0, `G15Fan` calls `GOFF` (`PG01._OFF`). This needs the boot-arg
    `-g15fan-rtxpm-corte`.
  - Turning it back on calls `GONN`, and NullMoth resumes in about 1.2 s.
  - `G15PM` hooks `NVAccel::newUserClient`, so an app that opens the RTX turns it back on first and waits for it.
    macOS `systemstats` is refused while the RTX is off (it opened the RTX every ~10 min just to read stats).
  - **Turn on only for real use (since 2026-11-11, `G15PM` `RtxLazy`).** Opening an app (Notes, TextEdit, Safari)
    no longer wakes the RTX; the first real GPU call does (a windowed app waits about 2.7 s, VRAM intact).
  - **"Idle" means no driver calls** (`G15PM` `RtxCalls`) and utilization under 2%, so the RTX can stop with apps
    still open. A game that keeps drawing in the background keeps it on.
  - In the Battery profile, `G15PM` `RtxDeny` refuses new RTX opens while it is off (the app falls back to the UHD).
  - G15.app has an "RTX ( Desligada | Ligada | Automática )" selector (off / on / auto). Auto turns the RTX off after
    30 s idle on battery or 5 min on AC, and back on when the charger is plugged in. The menu bar shows "RTX" in red
    when it is off, with the temperature from the EC sensor.
  - **"App na RTX" card in G15.app:** shows the app using the RTX, with a "Pausar em 2º plano" (pause in background)
    button for that app only, until it quits. After 30 s in the background the app is frozen (SIGSTOP, its sound
    muted), so the RTX can turn off; switching back to it resumes it at once and the RTX comes back in about 3 s.
    Tested with Hollow Knight, including unplugging the charger while it was frozen.
  - Idle on battery: about 24-29 W, against about 34 W with the RTX on.
  - Apps reach the RTX only if listed in `/Library/GPUBundles/nvmtl-allow.txt`. Use
    `tools/rtx/macos-rtx-allow.sh restrita [app ...]`; NullMoth's default `*` keeps it busy.
  - While it is off, the RTX cannot see an HDMI cable. Pick "Ligada" before connecting one.
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
- **Audio:** internal speakers with volume and mute, and the internal microphone (DMIC) with DeepFilterNet3 noise
  suppression. This is `AudShim` + the `XeSpeakers` HAL plug-in.
- **Connectivity:** Wi-Fi (AirportItlwm), Bluetooth, Ethernet (RTL8111) and USB.
  - Bluetooth on keeps the package at PC2 while awake (about +5 W). G15.app turns Bluetooth off after 3 min with
    no device connected (it asks for the Bluetooth permission once). In sleep it does not matter.
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
- **Dual boot with Fedora** on a separate NVMe, chosen from the Dell F12 menu.

## What partly works

- **HDMI (wired to the RTX):** with NullMoth 2.9, a cable connected at boot works in extended and mirrored mode, and
  resolution changes work. Hotplug is unreliable; a workaround is described in
  [nullmoth#288](https://github.com/nullmoth/nvidia-macos-driver/issues/288).
- **RTX idle power:** solved since 2026-11-10 by `G15Fan` + `G15PM` (see "What works"). NullMoth's own RTD3/GC6 still
  cannot cut power on this machine ([nullmoth#428](https://github.com/nullmoth/nvidia-macos-driver/issues/428)).
  - `BOOST=0` in `/Library/GPUBundles/nvmtl/nvrm610.conf` lets it drop to P8 when idle, saving about 12 W.
  - With the RTX visible, the CPU package almost never reaches deep C-states.
- **UHD hang (under investigation).** Since RC6 came back, the UHD sometimes stops answering the last submission on
  the render engine (`gpuRestart`), the screen goes black and WindowServer is killed by its watchdog. The WhateverXe
  fork now keeps render forcewake while the render engine executes (candidate fix, on by default) and writes each
  hang to `/private/var/log/g15-uhd-hang-*.txt`. The boot-arg `wexg15unstick=31` also tries to recover a stuck queue.
- **eDP Panel Self Refresh (optional, experimental).** The boot-arg `wexg15psr=3` turns on PSR1 for the internal LG
  panel: with a still screen the package drops from about 2.05 W to 1.17 W. It once froze WindowServer with a still
  screen (possibly the same problem as the hang above), so it is off unless you add the boot-arg. The mode can be
  changed at runtime with `sudo sysctl debug.g15psr=0` (off) or `=3`.
- **Rare flicker** at the bottom of translucent windows when the UHD is heavily loaded. Turning on Reduce Transparency
  hides it.
- **Camera/microphone permissions:** with AMFI relaxed, macOS never shows the permission prompt for third-party apps.
  G15.app shows its own prompt and writes the TCC entry.
- **P-cores and E-cores** are not distinguished by macOS (CpuTopologyRebuild is included but disabled).

## What does not work

- **Prime Video app / FairPlay Streaming:** the key request fails with -15842. Use a Widevine browser (Chrome,
  Firefox or Edge) instead.
- **VP9 / AV1 hardware decode:** the driver does not expose them, so YouTube above 1080p is not available in Safari.
- **Hibernation:** not set up (`hibernatemode 0`).
- **Not tested:** the headphone jack, HDMI audio, iMessage/FaceTime, FileVault, Sidecar, AirDrop and Handoff.
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
7. **Install the WhateverXe Graphics package 0.4.0**
   ([releases](https://github.com/b00t0x/WhateverXe-Graphics/releases)) and reboot. The UHD is now accelerated.
8. **Run the post-install script** (next section), then install NullMoth.

### Boot-args of the system config

```
keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -allow3d -disablegfxfirmware
amfi_get_out_of_my_way=1 gfxrst=1 -g15pm -igfxdvmt -wexdbg wexblmin=4900 -wex-blmin=4900 nvfb=1 nvaccel=1 acpi=0xC
-g15fan-rtxpm-corte
```

- Required: `-allow3d -disablegfxfirmware amfi_get_out_of_my_way=1 -igfxdvmt gfxrst=1 -g15pm wexblmin=4900
  -wex-blmin=4900 nvfb=1 nvaccel=1`.
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
- `EFI/OC/Kexts`:
  - Lilu 1.7.3, VirtualSMC 1.3.9 (+ SMCBatteryManager, SMCProcessor), RestrictEvents 1.1.7, NVMeFix 1.1.4.
  - AirportItlwm 2.4.0, IntelBluetoothFirmware / IntelBTPatcher 2.5.1, BlueToolFixup 2.7.3, RealtekRTL8111 3.0.0.
  - USBToolBox 1.2.0 + UTBDefault, XHCI-unsupported.
  - VoodooPS2Controller 2.3.8, VoodooI2C 2.9.1 (CI build 6be653a2) + VoodooI2CHID, BrightnessKeys 1.0.4.
  - AMFIPass-Mod 1.4.1.
  - WhateverGreen 1.7.2: used only by `config-install.plist`; the system config does not load it.
  - **My builds:**
    - `WhateverXe` (fork above).
    - `G15Fan`: fans and profiles via Dell WMAX, RTX power cut in sleep, EC wake arming.
    - `G15PM`: the XE-PM part of NootedGreen as its own Lilu plug-in, for HWP, turbo, C-states and EPP.
    - `AudShim`: speakers and DMIC.
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

1. **Metal driver memory leak fix** (`post-install/macos-mtl-leakpatch.sh`).
   - Patches the TGL Metal driver at `0x7ed87`, `75 0d` -> `90 90`
     ([WhateverXe#47](https://github.com/b00t0x/WhateverXe/issues/47)).
   - Without it, WindowServer grows by hundreds of MB per minute.
2. **VA driver patches, `avcfix` mode** (`post-install/macos-patch-wex-va.sh`).
   - Fixes H.264 hardware decode on Tahoe (key 6 of `SetParam`), plus two NULL checks.
   - Then the video post-processing fix (`post-install/macos-va-vp81.sh aplicar`,
     [WhateverXe#81](https://github.com/b00t0x/WhateverXe/issues/81)): in the VA driver, the `yuv2`/`NV12` output
     list at `0x786fc4` goes from 2 entries to 0, so the Apple TV app and App Store videos no longer hang the GPU.
   - My machine uses the `avcfix-vame-k7` mode, which adds FairPlay (Apple Music). That mode needs the Tiger Lake VAME
     bundle, an Apple binary that is not included here.
3. **Metal shim `stencilfix`** (`prebuilt/stencilfix`). Fixes wrong stencil reads, the white blocks in 3D apps.
4. **Audio HAL plug-in XeSpeakers** with DeepFilterNet3 (`prebuilt/audio`). It creates the "Alto-falantes internos"
   (speakers) and "Microfone interno" (microphone) devices.
   - The DSP firmware (Linux SOF `sof-rpl-s.ri`) is built into `AudShim.kext`.
5. **G15.app** for your user (`prebuilt/G15.app-installer`).
   - It handles the Fn keys, keyboard light, profiles and fans, menu-bar temperatures and permission prompts.
   - Its menus are in Portuguese. It needs the `G15Fan` and `G15PM` kexts (in the EFI).
6. **pmset:** battery display 3 min / sleep 5 min, AC display 5 min / sleep 15 min, `hibernatemode 0`, `standby 0`.

Then do two things by hand:
- Install **NullMoth 2.9** with its own installer. Then restrict the RTX to the apps that need it:
  `sudo bash tools/rtx/macos-rtx-allow.sh restrita [app ...]`. Run this again after every NullMoth update, because the
  update resets the list.
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

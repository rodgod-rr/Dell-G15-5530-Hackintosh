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
- **RTX 4050 for Metal/compute**, through [NullMoth](https://github.com/nullmoth/nvidia-macos-driver) 2.8.1. It runs
  alongside the UHD: Metal 3, about 4.9 TFLOPS.
- **Sleep (Deep Idle / S0, since the firmware has no S3).** Sleep and wake work, and the panel comes back every time.
  - Tested with 5 RTC cycles in a row, idle sleep, lid-close sleep, and 1 h 44 min on battery.
  - **Wake sources:** lid, internal keyboard, touchpad, power button, USB.
  - The fix needs three pieces: my WhateverXe fork, `SSDT-DeepIdle` and `SSDT-LIDWAKE`.
  - The RTX is powered off during sleep by `G15Fan` + `SSDT-RTXKEXT` (ACPI `PG01._OFF`).
- **Video:**
  - H.264 and HEVC hardware decode (YouTube 1080p H.264 in Safari).
  - H.264 hardware encode.
  - Live Text / Vision.
  - Apple Music with FairPlay.
  - The VA driver needs patches; see Post-install.
- **Audio:** internal speakers with volume and mute, and the internal microphone (DMIC) with DeepFilterNet3 noise
  suppression. This is `AudShim` + the `XeSpeakers` HAL plug-in.
- **Connectivity:** Wi-Fi (AirportItlwm), Bluetooth, Ethernet (RTL8111) and USB.
- **Input:** keyboard via VoodooPS2, touchpad via VoodooI2C in GPIO interrupt mode, keyboard backlight (AW-ELC), and the
  Fn keys F5 / F9 / F10 through G15.app.
- **Power and thermals:**
  - Battery status and charging.
  - CPU power management with HWP and full turbo (4.2-4.6 GHz single core), the C8/C10 idle table, and EPP per
    profile (`G15PM`).
  - Fans and thermal profiles (Battery, Quiet, Balanced, Performance, G-Mode) through Dell WMAX (`G15Fan`).
  - CPU/RTX temperatures in the menu bar (G15.app).
- **Dual boot with Fedora** on a separate NVMe, chosen from the Dell F12 menu.

## What partly works

- **HDMI (wired to the RTX):** it works only if the cable is connected at boot, in extended mode. Mirroring corrupts
  one screen, and hotplug does not work. Last tested with NullMoth 2.6.0; not re-tested on 2.8.1.
- **RTX idle power:** the RTX never powers off at runtime, because NullMoth has no RTD3/GC6
  ([nullmoth#428](https://github.com/nullmoth/nvidia-macos-driver/issues/428)).
  - `BOOST=0` in `/Library/GPUBundles/nvmtl/nvrm610.conf` lets it drop to P8 when idle, saving about 12 W.
  - With the RTX visible, the CPU package almost never reaches deep C-states.
- **Power draw while asleep is about 19 W.** In October, with the iGPU still unaccelerated, I measured about 3-5 W.
  The cause is not isolated yet.
- **Rare flicker** at the bottom of translucent windows when the UHD is heavily loaded. Turning on Reduce Transparency
  hides it.
- **Camera/microphone permissions:** with AMFI relaxed, macOS never shows the permission prompt for third-party apps.
  G15.app shows its own prompt and writes the TCC entry.
- **P-cores and E-cores** are not distinguished by macOS (CpuTopologyRebuild is included but disabled).

## What does not work

- **Apple TV app and App Store videos hang the GPU**, which can reboot the Mac. Don't open them.
  - The cause is the video post-processing media batch: the RCS stays stuck on `MEDIA_OBJECT`
    ([WhateverXe#23](https://github.com/b00t0x/WhateverXe/issues/23), [#60](https://github.com/b00t0x/WhateverXe/issues/60)).
  - A known workaround removes the hang but loses H.264 hardware decode. It is not applied here.
- **Prime Video app / FairPlay Streaming:** the key request fails with -15842. Use a Widevine browser (Chrome,
  Firefox or Edge) instead.
- **VP9 / AV1 hardware decode:** the driver does not expose them, so YouTube above 1080p is not available in Safari.
- **Hibernation:** not set up (`hibernatemode 0`).
- **Not tested:** the headphone jack, HDMI audio, USB-C video, the card reader, iMessage/FaceTime, FileVault,
  Sidecar, AirDrop and Handoff.

## BIOS settings

- Secure Boot **off**.
- Storage in **AHCI** (no RAID/VMD).
- **Hybrid Graphics ON** (Video > Enable Hybrid Graphics / Advanced Optimus), so the internal panel stays on the UHD.
  Without it the panel is on the RTX, and this EFI is not set up for that.

## Before you boot

1. **Generate your own SMBIOS** for `MacBookPro16,1`, for example with
   [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS). Fill `SystemSerialNumber`, `MLB`, `SystemUUID` and `ROM` in
   `PlatformInfo > Generic`; they are blank here.
2. **`ACPI/DSDT.aml` is a full patched DSDT from my BIOS.** The patches are `_OSI` -> `XOSI` for the brightness keys,
   and no `_S3`. If your BIOS version differs, dump your own DSDT and apply the same changes, or remove `DSDT.aml`
   from `ACPI > Add` and accept what breaks.
3. **The boot-args are my diagnostic set:**
   ```
   -v keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -allow3d -disablegfxfirmware
   amfi_get_out_of_my_way=1 gfxrst=1 -g15pm -igfxdvmt -wexdbg wexblmin=4900 -wex-blmin=4900 nvfb=1 nvaccel=1 acpi=0xC
   ```
   - Required: `-allow3d -disablegfxfirmware amfi_get_out_of_my_way=1 -igfxdvmt gfxrst=1 -g15pm wexblmin=4900
     -wex-blmin=4900 nvfb=1 nvaccel=1`.
   - Logging only, safe to remove: `-v keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -wexdbg acpi=0xC`.
4. **SIP** is partly disabled (`csr-active-config` 0x0A43), and AMFI is relaxed: the GPU bundles are re-signed ad hoc.
   Know what that means for your security.

## EFI contents

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
  - **My builds:**
    - `WhateverXe` (fork above).
    - `G15Fan`: fans and profiles via Dell WMAX, RTX power cut in sleep, EC wake arming.
    - `G15PM`: the XE-PM part of NootedGreen as its own Lilu plug-in, for HWP, turbo, C-states and EPP.
    - `AudShim`: speakers and DMIC.
  - Sources are in `src/`.

NullMoth (the RTX driver) is not in the EFI. Its installer puts it in `/Library/Extensions`.

## Post-install (in macOS)

1. **WhateverXe Graphics 0.4.0** package (0.4.1 is untested here).
2. **Metal driver memory leak fix:** run `post-install/macos-mtl-leakpatch.sh aplicar`, then reboot.
   - The patch changes the TGL Metal driver at `0x7ed87`, `75 0d` -> `90 90`
     ([WhateverXe#47](https://github.com/b00t0x/WhateverXe/issues/47)).
   - Without it, WindowServer grows by hundreds of MB per minute.
3. **VA driver patches:** run `post-install/macos-patch-wex-va.sh avcfix`.
   - This fixes H.264 hardware decode on Tahoe (key 6 of `SetParam`).
   - The `avcfix-vame-k7` mode also needs the Tiger Lake VAME bundle for FairPlay. It is not included because it is an
     Apple binary.
4. **Metal shim `stencilfix`:** run `src/stencilfix/instalar.sh`. It fixes wrong stencil reads (white blocks in 3D
   apps).
5. **NullMoth 2.8.1** from its installer, with HDMI audio (NMXAudio). Then add `BOOST=0` to
   `/Library/GPUBundles/nvmtl/nvrm610.conf`.
6. **Audio plug-in XeSpeakers** with DeepFilterNet3: see `src/AudShim/XeSpeakers`.
7. **G15.app:** build it with `src/G15.app/build.sh`. It handles the Fn keys, keyboard light, profiles, fans,
   temperatures and permission prompts.
8. **pmset (my values):**
   - Battery: `displaysleep 3`, `sleep 5`.
   - AC: `displaysleep 5`, `sleep 15`.
   - `hibernatemode 0`, `standby 0`.

Reinstalling the WhateverXe Graphics package undoes steps 2-4, so run them again afterwards.

## Credits

[Acidanthera](https://github.com/acidanthera) (OpenCore, Lilu, VirtualSMC and friends),
[b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe), [NullMoth](https://github.com/nullmoth/nvidia-macos-driver),
[OpenIntelWireless](https://github.com/OpenIntelWireless), [VoodooI2C](https://github.com/VoodooI2C/VoodooI2C),
[USBToolBox](https://github.com/USBToolBox), [NootedGreen](https://github.com/sgiammori/NootedGreen) (XE-PM in G15PM),
[JulioNectar's XPS 13 Plus project](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe) (AudShim origin),
[Dortania](https://dortania.github.io/OpenCore-Install-Guide/).
Each component keeps its own license. AudShim is under the "Thou Shalt Not Profit" license (see `src/AudShim`).

Built with a lot of help from Claude (Anthropic). Use at your own risk.

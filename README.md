# Dell G15 5530 Hackintosh: macOS Tahoe 26.7.3, OpenCore EFI

The EFI I use every day on my Dell G15 5530, with what works, what partly works and what does not.
**It is a snapshot of a working setup, not a polished guide.** Read the whole page before trying it. Your BIOS, SSD
and panel may differ, and the DSDT here was dumped from my machine. What changed and why: [CHANGELOG](CHANGELOG.md).

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

- **Intel UHD graphics with acceleration:** Metal 2, QE/CI, 1536 MB shared VRAM, internal panel at 120 Hz, brightness
  keys and slider, Night Shift.
  - Uses [WhateverXe](https://github.com/b00t0x/WhateverXe) through my fork
    [rodgod-rr/WhateverXe `g15-deep-idle`](https://github.com/rodgod-rr/WhateverXe/tree/g15-deep-idle)
    ([write-up](https://github.com/rodgod-rr/WhateverXe/blob/g15-deep-idle/docs/g15-deep-idle/README.md)), based on
    WhateverXe 0.8.3, with the [WhateverXe Graphics](https://github.com/b00t0x/WhateverXe-Graphics) **0.4.4** package.
  - **GPU hang fix (`-wex-g15-noccs`).** Apple's driver turns on the compute engine (CCS) alongside the render engine,
    which Intel's TGL PRM Vol 14 forbids ("Dual Context - Invalidate hang"); Preview's Live Text, `mediaanalysisd` and
    `photoanalysisd` hung the GPU. With the boot-arg, compute runs on the render engine, as on Linux. Rare render-engine
    hangs remain under heavy load; the fork logs each one to `/private/var/log/g15-uhd-hang-*.txt` and
    `wexg15unstick=31` helps the reset recover.
  - **GPU clock governor.** Without GuC, Apple's driver always asks for the maximum GPU clock. The fork picks the clock
    from GPU activity instead: about 17 % less GPU power under medium load
    ([WhateverXe#176](https://github.com/b00t0x/WhateverXe/issues/176)). `sysctl debug.g15gtgov=0` turns it off live,
    `-wex-g15-gtgov-off` from boot.
  - **Panel Self Refresh (`wexg15psr=3`):** with a still screen the package drops from about 2.4 W to 1.5 W.
    `sudo sysctl debug.g15psr=0` turns it off.
  - **RC6:** `G15AGPMIgpu.kext` re-injects the AGPM profile without the `RCxControl`/`CPGControl` blocks of the
    MacBookPro16,1 profile, which stopped RC6 shortly after boot.
- **RTX 4050 for Metal/compute** through [NullMoth](https://github.com/nullmoth/nvidia-macos-driver) 3.1, alongside
  the UHD: Metal 3, about 4.9 TFLOPS.
  - **As an external GPU (`-g15egpu`):** apps with "Prefer External GPU" in Finder > Get Info run on the RTX; everything
    else stays on the UHD. NullMoth's default app list (`*`) is fine with it.
  - Add `BOOST=0` to `/Library/GPUBundles/nvmtl/nvrm610.conf` so the RTX idles at P8 while it is on (about 12 W less).
  - Optional, not in this EFI: the `g15-lazy-31` branch of my
    [NullMoth fork](https://github.com/rodgod-rr/nvidia-macos-driver/tree/g15-lazy-31) replaces NullMoth's Metal plugin
    so that listing the GPUs no longer wakes the RTX (only real use does).
- **RTX powered off when idle.** NullMoth's own RTD3 cannot cut power on this laptop
  ([nullmoth#428](https://github.com/nullmoth/nvidia-macos-driver/issues/428)). Two ways that work here:
  - **With stock NullMoth (this EFI):** G15.app's "RTX ( Desligada | Ligada | Automática )" selector. Auto turns it off
    after 30 s idle on battery or 5 min on AC: `G15Fan` suspends it through NullMoth's sleep code and cuts power
    (`PG01._OFF`, boot-arg `-g15fan-rtxpm-corte`); `G15PM` turns it back on (about 1.2 s) when an app makes its first
    real GPU call. G15.app's "App na RTX" card can pause a background app that keeps the RTX busy.
  - **With NVIDIA's own GC6 (what I use, needs my NVRM build, not included):** an NVRM built from the
    [`g15-gc6-31` branch](https://github.com/rodgod-rr/nvidia-macos-driver/tree/g15-gc6-31) lets NVIDIA's resource
    manager decide and do the whole transition (GC6 with VRAM kept, then power cut); any GPU use brings it back in about
    1.2 s with no desktop stutter. Boot-args, only with that NVRM: `nvrmdynpm=2 nvrmnvpcf=1
    nvregdwords=DynamicPowerManagement=3;DynamicPowerManagementVideoMemoryThreshold=0;PCIEPowerControl_8086a7190bf81028=39`.
  - **On battery with the RTX off:** about 1.2-1.7 W of CPU package with the screen on and 1.5-1.7 W with it off.
  - A Logitech Lightspeed USB receiver (`046d:c539`) adds about 2 W: it polls at a fixed 1000 Hz and never lets USB
    idle (Windows shows the same). On battery, use the mouse over Bluetooth if it has it.
- **Sleep (Deep Idle / S0; the firmware has no S3).** Sleep and wake work every time; overnight on battery the package
  stays in PC10, about 1 W (~2 %/h).
  - Wakes from the lid, internal keyboard, touchpad, power button and USB.
  - Needs my WhateverXe fork, `SSDT-DeepIdle` and `SSDT-LIDWAKE`; the RTX is powered off during sleep by `G15Fan` +
    `SSDT-RTXKEXT`.
  - Display sleep without system sleep works too.
- **Video:** H.264 and HEVC hardware decode (YouTube up to 1080p in Safari), H.264 hardware encode, Live Text / Vision,
  the Apple TV app, App Store videos and video screen savers. The VA driver needs the post-install patches.
  - Apple Music with FairPlay also works on my machine, but it needs Apple's Tiger Lake VAME bundle, which is not
    included here.
- **Audio** (`AudShim` + the `XeSpeakers` HAL plug-in): internal speakers with volume and mute, internal microphone
  with DeepFilterNet3 noise suppression, and the headphone jack with automatic switching and headset microphone.
- **Connectivity:** Wi-Fi (AirportItlwm), Bluetooth, Ethernet (RTL8111), USB, iMessage and FaceTime.
  - `G15PM` lets the Bluetooth controller, the webcam and the keyboard-light controller suspend when idle (macOS never
    sets an idle policy on them), so leaving Bluetooth on costs no extra power. `sudo sysctl debug.g15btidle=0` and
    `debug.g15usbidle=0` turn this off.
- **Input:** keyboard (VoodooPS2), touchpad (VoodooI2C, GPIO interrupt mode), and the Fn keys F5 / F9 / F10 through
  G15.app.
- **Keyboard lighting** (G15.app → "Luz do teclado…"): one color or 4 zones, the controller's effects (static,
  breathing, morph, spectrum, wave), brightness, presets and your own profiles, and the BIOS "turn off after" timeout.
  Nothing is written to the controller's flash; G15.app applies your choice at login and on wake.
- **Power and thermals:** battery status and charging; HWP with full turbo, C8/C10 and EPP per profile (`G15PM`); fans
  and thermal profiles (Battery, Quiet, Balanced, Performance, G-Mode) through Dell WMAX (`G15Fan`); CPU/RTX
  temperatures in the menu bar (G15.app).
- **P-cores and E-cores** through [IntelHybridCores](https://github.com/rodgod-rr/IntelHybridCores): background work
  runs on the E-cores and the foreground on the P-cores. `hcmode=4` keeps background work on the E-cores only (about
  half the package power under heavy background load); `hcmode=2` makes it a preference; `hcpower=4,2` switches between
  them on battery and AC. Activity Monitor shows Performance and Efficiency cores; System Information shows 10 cores,
  16 threads. CpuTopologyRebuild is included but must stay disabled.
- **Dual boot with Fedora** on a separate NVMe, chosen from the Dell F12 menu.

## What partly works

- **HDMI (wired to the RTX):** a cable connected at boot works (extended and mirrored, resolution changes, unplug and
  replug). A cable connected after a boot without one needs a WindowServer restart
  ([nullmoth#288](https://github.com/nullmoth/nvidia-macos-driver/issues/288)); #288 also describes a workaround. The
  RTX must be on: with the selector, pick "Ligada" before connecting.
- **Boot logo:** the Apple logo is drawn a few times in a row when the UHD takes over from the firmware
  ([WhateverXe#131](https://github.com/b00t0x/WhateverXe/issues/131)).
- **Camera/microphone permissions:** with AMFI relaxed, macOS does not show its permission prompt to third-party apps.
  G15.app shows its own prompt and writes the permission. (Running with AMFI on, with
  [AMFIAnchor](https://github.com/b00t0x/AMFIAnchor) and the GPU bundles signed by your own certificate authority, brings
  back macOS's own prompt; that needs your own keys, so it is not set up here.)
- **Rare flicker** at the bottom of translucent windows under heavy GPU load. Reduce Transparency hides it.

## What does not work

- **Prime Video app / FairPlay Streaming** (error -15842). Use Chrome, Firefox or Edge.
- **VP9 / AV1 hardware decode**, so Safari does not offer YouTube above 1080p.
- **Hibernation** (not set up, `hibernatemode 0`).
- **Not tested:** HDMI audio, FileVault, Sidecar, AirDrop and Handoff. (The G15 5530 has no card reader and no video
  output on USB-C.)

## Will it work on my G15?

| Your machine | Expected |
|---|---|
| G15 5530, i5-13450HX, RTX 4050, FHD 120 Hz, BIOS 1.0 | Same as mine (this is the tested machine) |
| Other BIOS version | Probably boots, but `DSDT.aml` is from BIOS 1.0: rebuild it from your own dump (step 4 below) |
| i7-13650HX / i9-13900HX (other UHD device ID) | **Untested.** The WhateverXe fork's RPL-S fix is gated on A78B; another user with a 13650HX had no acceleration ([WhateverXe#51](https://github.com/b00t0x/WhateverXe/issues/51)) |
| RTX 4060 | Untested; NullMoth supports it in general |
| 165 Hz or QHD panel | Untested |
| G15 5535 (AMD) / 5520 / 5511 | **No.** Different platform |

The touchpad wake uses a hard-coded GPIO pad (GPP_E3); with other touchpad wiring it will not wake (everything else
still works).

## BIOS settings

- Secure Boot **off**.
- Storage in **AHCI** (no RAID/VMD).
- **Hybrid Graphics ON** (Video > Enable Hybrid Graphics / Advanced Optimus), so the internal panel stays on the UHD.

## Install from scratch

1. **Make the USB installer.** Download macOS Tahoe recovery with `macrecovery.py` from the
   [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg/releases) `Utilities` folder (or make a full installer on a
   real Mac), format the stick as FAT32 / GPT ([Dortania guide](https://dortania.github.io/OpenCore-Install-Guide/installer-guide/))
   and copy this `EFI` folder to it.
2. **Use the installer config.** On the stick, rename `EFI/OC/config.plist` to `config-system.plist` and
   `EFI/OC/config-install.plist` to `config.plist`. It boots without iGPU acceleration (WhateverGreen with `-wegnoegpu`,
   no WhateverXe) and with the touchpad in polling mode.
3. **SMBIOS.** Generate a `MacBookPro16,1` serial with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) and put the
   **same** `SystemSerialNumber`, `MLB`, `SystemUUID` and `ROM` in both configs (`PlatformInfo > Generic`).
4. **DSDT.** `ACPI/DSDT.aml` is my BIOS 1.0 DSDT with two changes: `_OSI` -> `XOSI` (brightness keys) and the `_S3`
   removal. On another BIOS, dump yours (from Linux: `sudo cat /sys/firmware/acpi/tables/DSDT > DSDT.aml`) and make the
   same two changes, or remove `DSDT.aml` from `ACPI > Add` and accept that brightness keys and sleep may break.
5. **Install macOS** from the stick (F12 boot menu), then boot the new install through the stick.
6. **Copy the EFI to the SSD**, this time with the **system** `config.plist` (and your SMBIOS). Boot from the SSD.
7. **Install WhateverXe Graphics 0.4.4** ([releases](https://github.com/b00t0x/WhateverXe-Graphics/releases)) and
   reboot.
8. **Run the post-install** (next section), then install NullMoth 3.1 with its own installer and add `BOOST=0` to
   `/Library/GPUBundles/nvmtl/nvrm610.conf`.

### Boot-args of the system config

```
keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -allow3d -disablegfxfirmware
amfi_get_out_of_my_way=1 gfxrst=1 -g15pm -igfxdvmt -wexdbg wexblmin=4900 -wex-blmin=4900 nvfb=1 nvaccel=1 acpi=0xC
-g15fan-rtxpm-corte -nvmefaspm wexg15psr=3 wexg15unstick=31 hcmode=4 -wex-g15-gsync -wex-g15-ccsreset-off
-wex-g15-noccs -g15egpu nvfbheads=4
```

- Required: `-allow3d -disablegfxfirmware amfi_get_out_of_my_way=1 -igfxdvmt gfxrst=1 -g15pm wexblmin=4900
  -wex-blmin=4900 nvfb=1 nvaccel=1`.
- Strongly recommended: `-wex-g15-noccs` (GPU hang fix).
- Optional: `-g15fan-rtxpm-corte` (cut RTX power when idle), `wexg15psr=3` (PSR), `wexg15unstick=31` (helps GPU
  hang recovery), `hcmode=4` (IntelHybridCores mode), `-g15egpu` (RTX as an external GPU), `nvfbheads=4` (NullMoth's
  recommended display heads), `-nvmefaspm` (ASPM L1 on both NVMe drives), `-wex-g15-gsync -wex-g15-ccsreset-off`
  (GPU reset details in the WhateverXe fork).
- Logging only, safe to remove: `keepsyms=1 debug=0x100 msgbuf=4194304 -g15diag IGLogLevel=3 -wexdbg acpi=0xC`.

SIP is partly disabled (`csr-active-config` 0x0A43) and AMFI is relaxed, because the GPU bundles are re-signed ad hoc.
Know what that means for your security.

## EFI contents

- `EFI/OC/config.plist`: system config. `EFI/OC/config-install.plist`: installer config.
- `EFI/OC/ACPI` (sources in `acpi-src/`, comments in Portuguese):
  - `SSDT-AWAC`, `SSDT-EC-USBX`, `SSDT-PLUG-ALT` (Dortania) and `SSDT-PNLF`.
  - `SSDT-XOSI`: Windows `_OSI` strings on macOS.
  - `SSDT-DeepIdle`: `\_SB.LPS0` / `\_GPE.LXEN`, for S0 sleep.
  - `SSDT-LIDWAKE`: lid `PRW0` = EC GPE 0x6E, so the lid wakes from Deep Idle.
  - `SSDT-RTXKEXT`: `GOFF` / `GONN`, used by G15Fan to cut RTX power.
  - `SSDT-PS2K-RMCF`: VoodooPS2 settings.
  - `SSDT-BTRK`: holds the Intel Bluetooth in reset while it is off (about 0.5 W less).
- `EFI/OC/Kexts`:
  - Lilu 1.7.3, VirtualSMC 1.3.9 (+ SMCBatteryManager, SMCProcessor), RestrictEvents 1.1.7, NVMeFix 1.1.4.
  - AirportItlwm 2.4.0, IntelBluetoothFirmware / IntelBTPatcher 2.5.3, BlueToolFixup 2.7.3, RealtekRTL8111 3.0.0.
  - USBToolBox 1.2.0 + UTBDefault, XHCI-unsupported.
  - VoodooPS2Controller 2.3.8, VoodooI2C 2.9.1 + VoodooI2CHID, BrightnessKeys 1.0.4.
  - AMFIPass-Mod 1.4.1.
  - WhateverGreen 1.7.2: only for `config-install.plist`.
  - **My builds** (sources in `src/`):
    - `WhateverXe` (fork above).
    - `G15Fan`: fans and thermal profiles via Dell WMAX, RTX power cut, EC wake arming, keyboard-light timeout.
    - `G15PM`: CPU power management (HWP, turbo, C-states, EPP; the XE-PM part of NootedGreen), the RTX hooks, and USB
      idle for Bluetooth, webcam and keyboard light.
    - `AudShim`: speakers, microphone, headphone jack and headset microphone.
    - `IntelHybridCores`: P-core/E-core scheduling ([repository](https://github.com/rodgod-rr/IntelHybridCores)).
    - `G15AGPMIgpu`: AGPM profile for the UHD (RC6).

NullMoth (the RTX driver) is not in the EFI; its installer puts it in `/Library/Extensions`.

## Post-install (in macOS)

Run it after installing WhateverXe Graphics 0.4.4, from this repository's folder:

```
sudo bash install-macos.sh check      # shows what is installed, changes nothing
sudo bash install-macos.sh install    # applies everything, then reboot
```

1. **Metal driver:** nothing to apply; `check` confirms Graphics 0.4.4
   ([WhateverXe#47](https://github.com/b00t0x/WhateverXe/issues/47)).
2. **VA driver patches** (`post-install/macos-patch-wex-va.sh`): fix H.264 hardware decode on Tahoe and two crashes
   in the video service. The original driver is backed up to `/Library/G15-uhd` and every patch checks its bytes first.
3. **Metal shim `stencilfix`** (`prebuilt/stencilfix`): fixes wrong stencil reads (white blocks in 3D apps).
4. **Audio HAL plug-in XeSpeakers** (`prebuilt/audio`): creates "Alto-falantes internos" / "Fones de ouvido" and
   "Microfone interno" / "Microfone do fone".
5. **G15.app** for your user (`prebuilt/G15.app-installer`): Fn keys, keyboard light, profiles and fans, menu-bar
   temperatures, RTX selector and permission prompts. Its menus are in Portuguese; it needs the `G15Fan` and `G15PM`
   kexts.
6. **pmset:** battery display 3 min / sleep 5 min, AC display 5 min / sleep 15 min, `hibernatemode 0`, `standby 0`.

**Reinstalling WhateverXe Graphics undoes steps 2-3:** run `install-macos.sh install` again afterwards.

To rebuild `prebuilt/`: `src/G15.app/build.sh`, `src/AudShim/XeSpeakers/build.sh`, `src/stencilfix/build-mac.sh`.

## Credits

[Acidanthera](https://github.com/acidanthera) (OpenCore, Lilu, VirtualSMC and friends),
[b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe), [NullMoth](https://github.com/nullmoth/nvidia-macos-driver),
[OpenIntelWireless](https://github.com/OpenIntelWireless), [VoodooI2C](https://github.com/VoodooI2C/VoodooI2C),
[USBToolBox](https://github.com/USBToolBox), [NootedGreen](https://github.com/sgiammori/NootedGreen) (XE-PM in G15PM),
[JulioNectar's XPS 13 Plus project](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe) (AudShim origin),
[Dortania](https://dortania.github.io/OpenCore-Install-Guide/).
Each component keeps its own license. AudShim is under the "Thou Shalt Not Profit" license (see `src/AudShim`).
WhateverXe.kext embeds the Intel ADL-S display microcontroller firmware (`adls_dmc_ver2_01.bin` from linux-firmware),
redistributed under the Intel license in [`LICENSE.i915`](LICENSE.i915).

Built with a lot of help from Claude (Anthropic). Use at your own risk.

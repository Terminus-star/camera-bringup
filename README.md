# Rear camera for the ASUS ROG Flow Z13 2025 (GZ302EA) on Linux

The rear camera of the 2025 Flow Z13 (AMD Ryzen AI Max "Strix Halo") does not work on stock Linux: the
OmniVision **OV13B10** sensor sits behind AMD's image signal processor (**ISP 4.1**), and the kernel's ISP
drivers only know AMD's reference board. This repository makes it work: kernel patches, an AUR kernel
package, a firmware package that you build from your own Windows install, and the notes and tools from
the bring-up.

> **Status: working, still being tuned.** `/dev/video0` gives live **1920x1080 NV12 at 30 fps**
> (YUYV and 1920x1440 also offered) with auto exposure and neutral colours; tested with ffplay and OBS.
> Not done yet: autofocus (the lens stays at its rest position, sharp at room distance), white balance
> and image tuning matched to Windows. The driver still writes a lot of debug output (`EXP-...` lines)
> to the kernel log. The front and IR cameras are separate USB cameras and already work on stock Linux.

## Install (Arch / CachyOS)

1. Copy three files from your **own Windows install** into `~/cam-firm-gz302ea/` (any upper/lower case):

   | file | Windows folder |
   |---|---|
   | `OV13B_3001_ROG_SRX.atb` | `C:\Windows\System32\DriverStore\FileRepository\sensorov13b.inf_amd64_*\` |
   | `asm_OV13B.asm` | `C:\Windows\System32\DriverStore\FileRepository\sensorov13b.inf_amd64_*\` |
   | `srx_h_isp_firmware_signed.ram` | `C:\Windows\System32\DriverStore\FileRepository\amdcamera.inf_amd64_*\` |

   With the Windows partition mounted (read-only is enough), e.g. at `/mnt/windows`:

   ```sh
   mkdir ~/cam-firm-gz302ea
   cp /mnt/windows/Windows/System32/DriverStore/FileRepository/sensorov13b.inf_amd64_*/OV13B_3001_ROG_SRX.atb ~/cam-firm-gz302ea/
   cp /mnt/windows/Windows/System32/DriverStore/FileRepository/sensorov13b.inf_amd64_*/asm_OV13B.asm ~/cam-firm-gz302ea/
   cp /mnt/windows/Windows/System32/DriverStore/FileRepository/amdcamera.inf_amd64_*/srx_h_isp_firmware_signed.ram ~/cam-firm-gz302ea/
   ```

2. Build and install the two packages from a clone of this repository (the packages are not on the
   AUR yet, because the AUR is not accepting new accounts at the moment):

   ```sh
   git clone https://github.com/Terminus-star/camera-bringup.git
   cd camera-bringup
   bash scripts/install-local-packages.sh
   ```

   The script first checks the folder above and that no camera files copied by hand are in the way
   (it lists every problem with the command to fix it), then builds and installs
   `gz302-camera-firmware`, then builds and installs `linux-cachyos-camera` and its headers. It asks
   for sudo before installing anything and stops at the first problem. Running it again is safe: it
   skips packages already installed at that version, and if the kernel was compiled but not installed
   (for example the sudo prompt timed out) it installs the built packages without compiling again
   (`--rebuild` forces a new compile, `--dry-run` only shows what it would do). The packages are
   normal pacman packages, so `pacman -Q linux-cachyos-camera` shows them and `pacman -R` removes them.

   The same by hand, firmware first (the kernel package depends on it):

   ```sh
   cd aur/gz302-camera-firmware && makepkg -si
   cd ../linux-cachyos-camera && makepkg -si
   ```

   Once the packages are on the AUR, `paru -S linux-cachyos-camera` will do both steps.

3. Reboot into **linux-cachyos-camera** and check: `uname -r` ends in `-cachyos-camera`, then
   `ffplay -f v4l2 -video_size 1920x1080 -input_format nv12 /dev/video0`.

Updating: when CachyOS releases a new kernel, `git pull` in the clone and run the script again (the
kernel package is updated in this repository for each release).

Details and troubleshooting: [`aur/README.md`](aur/README.md).

Not on Arch? The patches in [`kernel/patches/`](kernel/patches/) apply to mainline Linux (tested against
7.2.9 and 7.3-rc6); you still need the firmware files the AUR package builds
([`tools/`](tools/), see below).

## What it takes

The camera needs changes in four kernel drivers plus a set of firmware and data files.

```
amdgpu (ISP power, firmware)         0001 recognise the GZ302's ACPI camera  0003/0005 GPIO lookups
  └─ amd_isp4 (board description)    0002 describe the OV13B10 and its CSI-2 link
       ├─ ov13b10 (sensor driver)    0004 I2C id, 0006 GZ302 PLL and mode registers
       └─ amd_isp4_capture (V4L2)    0007 everything the ISP firmware needs to stream (from 0009-0037)
```

| patch | driver | why |
|---|---|---|
| 0001 | amdgpu | amdgpu only starts the ISP for AMD's reference sensor (`OMNI5C10`); the GZ302 reports `OMNI13B1` |
| 0002 | amd_isp4 | ASUS's ACPI table describes no I2C address, lanes or clock for the sensor; this adds them |
| 0003 | amdgpu | provides the `enable_isp` GPIO the capture driver asks for before it registers (on the GZ302 that line only drives the camera LED, so the driver leaves it alone) |
| 0004 | ov13b10 | lets the sensor driver bind to the I2C device the board code creates |
| 0005 | amdgpu | maps the sensor reset line so the sensor powers up before its I2C probe |
| 0006 | ov13b10 | the PLL and mode registers Windows uses on this laptop (wrong values give a magenta image) |
| 0007 | amd_isp4_capture | firmware memory pool sized like Windows, MMHUB prefetch, I2C descriptors in the device script, per-frame meta-data buffers, sensor start, data files loaded as firmware |

Run-time files (in `/usr/lib/firmware/`, installed by `gz302-camera-firmware`):

| file | made from | shipped here? |
|---|---|---|
| `updates/amdgpu/isp_4_1_1.bin` | the Windows ISP firmware (`srx_h_isp_firmware_signed.ram`) with the Linux header | no, built on your machine |
| `amdgpu/gz302-ov13b-script.bin` | the Windows sensor script `asm_OV13B.asm`, assembled | no, built on your machine |
| `amdgpu/OV13B_3001_ROG_SRX.atb` | the Windows sensor tuning file, unchanged | no, your copy |
| `amdgpu/gz302-ov13b-phy-seq.bin` | the MIPI D-PHY receiver register sequence | yes, [`data/`](data/) |
| `amdgpu/gz302-ov13b-sensor-prop.bin` | the sensor property block | yes, [`data/`](data/) |

AMD's and ASUS's files are never distributed here; the firmware package builds the first two from the
files you copy, with [`tools/build_winfw.py`](tools/build_winfw.py) and
[`tools/assemble_ov13b.py`](tools/assemble_ov13b.py).

## Newer CachyOS release than this repository

The kernel package in [`aur/linux-cachyos-camera/`](aur/linux-cachyos-camera/) is updated here for each
CachyOS release. If CachyOS is ahead of it:

```sh
bash scripts/rebuild-camera-kernel.sh
```

Fetches CachyOS's current PKGBUILD, checks every patch applies without fuzz, builds the same
`linux-cachyos-camera` (BORE scheduler, GCC without LTO, znver4 tuning) and installs it with
`pacman -U`; it stops at the first problem. That build does not declare the firmware dependency, so
install `gz302-camera-firmware` first (step 2 above). [`kernel/hooks/`](kernel/hooks/) has a pacman
hook that reminds you when CachyOS releases a new kernel.

## Repository layout

| path | contents |
|---|---|
| [`kernel/patches/`](kernel/patches/) | the 7-patch kernel series (the thing to use) |
| [`aur/`](aur/) | the two AUR packages and their instructions |
| [`driver/`](driver/) | the capture driver as an out-of-tree module, with its development history as patches 0009-0037 ([`driver/README.md`](driver/README.md)) |
| [`sensor/`](sensor/) | the ov13b10 sensor driver with the GZ302 quirk, out of tree |
| [`dkms/`](dkms/) | DKMS package for the capture driver (for kernels that already carry the amdgpu changes) |
| [`data/`](data/) | the two data files shipped with the firmware package |
| [`tools/`](tools/) | firmware/script builders, D-PHY and disassembly helpers, Windows trace decoders |
| [`scripts/`](scripts/) | build, test and release scripts (each one starts with a comment saying what it does) |
| [`docs/`](docs/) | [`findings.md`](docs/findings.md) (the full bring-up log), [`upstream-plan.md`](docs/upstream-plan.md), [`learning-notes.md`](docs/learning-notes.md) |

## How it was done

The Linux ISP 4.1 driver works on AMD's reference board but not here, and the Windows driver is the
only working reference. The bring-up compared the two: Windows ETW traces of every command the driver
sends to the ISP firmware, static analysis of `amdcamera.sys` and `sensorOV13B.sys` for payload layouts
and register tables, and many test runs on Linux, each changing one thing. The result of each run, right
or wrong, is in [`docs/findings.md`](docs/findings.md).

## Upstream

The goal is to need no custom kernel: the amdgpu and amd_isp4 changes (0001-0005) are small and could
go to CachyOS or mainline, after which a stock kernel plus a DKMS package would be enough. Patch 0007
needs its debug code removed and splitting into reviewable pieces first. The ISP firmware itself would
have to come from AMD through linux-firmware. See [`docs/upstream-plan.md`](docs/upstream-plan.md).

## Contributing

Reports from other GZ302 owners are welcome, especially whether the `gz302-camera-firmware` build says
"different version" for your Windows files and whether the camera still works then. Please include
`uname -r`, the package versions and `journalctl -k -b | grep -i -E "isp|ov13b"`.

## License and disclaimer

GPL-2.0 ([`LICENSE`](LICENSE)), the license of the kernel code the patches change. Not affiliated with
ASUS, AMD or OmniVision. The files you copy from Windows remain their owners' property. This changes
your kernel; keep another kernel installed to boot from if something goes wrong.

Built on CachyOS's kernel PKGBUILDs and the upstream AMD ISP4 drivers.

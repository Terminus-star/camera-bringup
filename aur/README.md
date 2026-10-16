# GZ302 rear camera packages (AUR)

Two Arch/CachyOS packages that make the rear camera (OmniVision OV13B10 behind the AMD ISP 4.1) of the
**ASUS ROG Flow Z13 2025 (GZ302EA)** work on Linux:

| package | what it is |
|---|---|
| `gz302-camera-firmware` | firmware and data files for the camera, built on your machine from three files you copy from your own Windows install |
| `linux-cachyos-camera` (+ `-headers`) | the CachyOS kernel (BORE scheduler, GCC without LTO, znver4) with the 7 camera patches from [`kernel/patches/`](../kernel/patches/); installs next to your other kernels |

The kernel package depends on the firmware package, so it will not build or install without it.
The camera is still being tuned: the driver writes a lot of debug output to the kernel log
(`EXP-...` lines), autofocus is not driven yet, and colours are not yet matched to Windows.

## 1. Copy three files from Windows

Create the folder `~/cam-firm-gz302ea/` (upper/lower case does not matter) and copy into it:

| file | from (in Windows) |
|---|---|
| `OV13B_3001_ROG_SRX.atb` | `C:\Windows\System32\DriverStore\FileRepository\sensorov13b.inf_amd64_*\` |
| `asm_OV13B.asm` | same folder |
| `srx_h_isp_firmware_signed.ram` | `C:\Windows\System32\DriverStore\FileRepository\amdcamera.inf_amd64_*\` |

From Linux you can read them from the Windows partition (mount it read-only), or copy them to a USB
stick while Windows is running. They are AMD/ASUS files and are not distributed by these packages: the
firmware package uses your copies to build the ISP firmware image and the sensor script locally.

## 2. Install

```sh
paru -S linux-cachyos-camera        # builds gz302-camera-firmware first; or yay
```

Without an AUR helper: build and install `gz302-camera-firmware` first (`makepkg -si` in its folder),
then `linux-cachyos-camera`. The kernel build takes a while (no LTO keeps it shorter).

If you copied camera files into `/lib/firmware/amdgpu/` by hand before, pacman stops with
"exists in filesystem": remove those files (`gz302-ov13b-*.bin`, `OV13B_3001_ROG_SRX.atb`) and install again.

## 3. Boot and test

Reboot and pick the `linux-cachyos-camera` entry in your boot menu. Then:

```sh
uname -r                 # ends in -cachyos-camera
ls /dev/video*
ffplay /dev/video0       # or OBS, a browser, ...
```

If no video device appears, try `sudo modprobe amd_isp4` (the board driver is a module in this
kernel; it should load by itself) and check `journalctl -k | grep -i isp`.

## Notes

- The ISP firmware image is installed to `/usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin`, which the
  kernel and mkinitcpio prefer over the linux-firmware image, so your other kernels load it too
  (they have no camera support, so nothing else changes for them).
- Each new CachyOS release needs a new version of `linux-cachyos-camera`; until it is out, keep using
  the previous one.

## Maintainers: version bump and release

From the repository root:

1. New CachyOS release: `bash scripts/make-aur-kernel.sh` (regenerates `aur/linux-cachyos-camera/`; it
   stops if a patch no longer applies, then `scripts/refresh-patch.sh` helps rebase it).
2. Build and test it on the laptop.
3. New firmware package version: change `pkgver`, set `b2sums=('SKIP')`, tag `v<pkgver>` and push the
   tag, then `bash scripts/aur-firmware-checksum.sh`.
4. `bash scripts/aur-sync.sh` copies both packages into `aur-git/` and prints the commit/push commands.

# GZ302 rear-camera bring-up

This directory contains the first half of a kernel enablement patch for the
GZ302EA rear OV13B10 sensor (`OMNI13B1`).  It supplies the software-node graph
which ASUS's ACPI table omits.  Nothing here overwrites a system file.

## Important correction after the first live test

The temporary `amd_isp4.ko` module loaded and bound to `OMNI13B1`, but no ISP
MFD children or I2C adapter appeared.  This proves the software-node patch is
valid at the platform-driver boundary, but it cannot activate the hardware on
its own.

The second missing change is in `drivers/gpu/drm/amd/amdgpu/amdgpu_acpi.c`:
AMDGPU's ISP allow-list has only `OMNI5C10`, so it declines to create the ISP
capture, I2C, and GPIO MFD devices for this machine.  The required one-line
AMDGPU change is recorded in `amdgpu-acpi-omni13b1.patch`.

Both patches must be present in a kernel build.  The platform graph must also
be registered before AMDGPU starts ISP hardware initialization, so build
`CONFIG_AMD_ISP_PLATFORM=y` (not a late-loaded module) for the first real boot
test.  The present external module is still useful only after that MFD layer
exists.

## Build result

`amd_isp4.ko` was built successfully against the local
`7.1.6-1-cachyos-deckify` headers.  Its vermagic exactly matches the running
kernel and it advertises both the existing `OMNI5C10` and new `OMNI13B1` ACPI
aliases.  Kernel lockdown is `none`; unsigned test modules are permitted.

## Initial assumptions

- I2C address: `0x10`, from the camera ACPI `_DSM`.
- CSI-2 configuration: four data lanes, link frequency 560 MHz.  This selects
  the OV13B10 driver's full-resolution 4208x3120 mode.
- Declared sensor clock: 19.2 MHz, which is what the upstream OV13B10 driver
  requires.  On this software-node platform that declaration is a fixed-rate
  dummy clock, so image quality—not probe success—will validate the real clock.

## Current cleanup

If you ran the initial loader, return to the normal module state now:

```bash
cd ~/Projects/camera-bringup
./load-patched-isp4.sh unload
```

## Future reversible test

Run from a normal desktop terminal:

```bash
cd ~/Projects/camera-bringup
./load-patched-isp4.sh load
```

The script loads the patched platform driver first, then the in-tree capture
driver, and prints adapter, media-node and kernel-log evidence.  Run it only
after a custom kernel with both source changes has booted.  To undo it:

```bash
./load-patched-isp4.sh unload
```

Do not install this module into `/lib/modules` yet.  First boot the combined
kernel patch and verify that the three ISP MFD devices exist, then test a
stream only after an ISP media/video node appears.

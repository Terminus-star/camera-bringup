# GZ302 rear camera (OV13B10 via AMD ISP4): deployment and upstream plan

Written 2026-10-16, after the first frames (`docs/findings.md` sections 83-85). Based on what the bring-up
established; points marked "unknown" were not checked, in particular what is already in mainline today.

## What "the driver" actually is

Once polished, the camera needs six pieces:

| Piece | Where it lives | Our state |
|---|---|---|
| 1. ACPI/board glue | `amdgpu` (ACPI HID `OMNI13B1`) and `amd_isp4.c` platform data: sensor node, I2C, GPIO, clock | local patches (`amdgpu-acpi-omni13b1.patch`, the GZ302 software node) |
| 2. Sensor driver | `ov13b10` (media/i2c) | needs a 24 MHz clock mode with the Windows PLL values (0x0303=01, 0x0305=46, 0x0325=55) and a proper power-on fix; today the PLL is patched over raw I2C and a runtime-PM cycle is forced |
| 3. ISP capture driver | `amd_isp4_capture` (media/platform/amd/isp4) | `driver/`, patches 0009-0031, still full of experiment parameters |
| 4. ISP firmware | `/lib/firmware/amdgpu/isp_4_1_1.bin` | an image rebuilt from the **Windows** driver's `.ram` files (`firmware/`, git-ignored) |
| 5. Sensor setup data | device script, sensor properties, D-PHY sequence, tuning file `OV13B_3001_ROG_SRX.atb` | all derived from Windows files, compiled into `driver/isp4_ov13b_script.h`, `isp4_ov13b_sensor_prop.h`, `isp4_phy_seq.h` (git-ignored) or read from the Windows partition |
| 6. Userspace | plain V4L2 (the ISP outputs NV12 directly), then PipeWire / libcamera for applications | untested beyond `v4l2-ctl` |

Pieces 4 and 5 decide everything else: they are AMD/OEM property, so they can be neither redistributed
nor upstreamed by us.

## A new machine from scratch (personal use, same laptop model)

Realistic route until things are upstream:

1. **Kernel**: a kernel with amdgpu ISP support plus pieces 1 and 2, as a patched distro kernel or a DKMS
   package for the modules. (Built and tested so far against CachyOS 7.2.0-1.7.)
2. **Capture module**: `amd_isp4_capture` built out of tree, ideally via DKMS so it rebuilds on kernel updates.
3. **Firmware, extracted from the user's own Windows install** (like `b43-fwcutter`): a script reads that
   machine's Windows driver store, builds the image (`tools/build_winfw.py`), installs it to
   `/lib/firmware/updates/amdgpu/` and adds it to the initramfs (amdgpu loads it early). Each user takes it
   from their own licensed copy; we never ship it.
4. **Sensor setup data, the same way**: generate the device script, sensor properties and D-PHY headers at
   install time from the user's Windows files (`tools/assemble_ov13b.py`, `tools/build_sensor_prop.py`,
   `tools/build_phy_seq.py`), or better turn them into a file loaded at run time, so the module itself
   contains no Windows-derived data. The tuning file is read from the Windows partition or copied to
   `/lib/firmware`.
5. **No test scaffolding**: no sudoers rule, test script, logger or burst limit; just the module with sane
   defaults and the camera on `/dev/video0`.

Weak point: every machine needs a Windows partition (or the Windows driver package).

## Getting it upstream

### 1. Polishing (our work)

- Remove all experiment parameters (`win_cmds`, `start_sensor`, `prefetch_flags`, `sensor_pll`, `phy_init`,
  `replay_sensor_setup`, `sensor_burst_ms`, ...); the Windows-matching behaviour becomes unconditional and
  in the right order.
- Compute the memory-pool size from the sensor mode (formula in `docs/findings.md` section 75).
- Send `ENABLE_PREFETCH` on the global ring (RT-pipe prefetch), re-send META_DATA / META_INFO buffers after
  every frame (like Windows' `ResendMetaInFrameDone`), and send the 3A configuration through the indirect
  command path.
- Fix the device-script encoding error (`SvmSetINc ... addr mode`) so exposure and white balance work.
- Start the sensor through the normal V4L2 subdev flow, not from inside the buffer-send loop; fix the
  locking in `start_streaming`; remove debug sleeps and diagnostics.
- Pass `checkpatch.pl`; test suspend/resume, repeated open/close, several resolutions.

### 2. Split into series by subsystem

Each has its own maintainers and mailing list:

1. **media/i2c `ov13b10`**: 24 MHz PLL/mode table, power sequencing, ACPI `OMNI13B1` support -> linux-media.
2. **platform/x86 `amd_isp4`**: GZ302 board data -> platform-driver-x86.
3. **drm/amdgpu**: ACPI ID / ISP enablement -> amd-gfx.
4. **media/platform/amd/isp4**: the capture-driver changes -> linux-media (AMD's developers maintain this
   driver). Unknown: how much of the AMD ISP4 capture driver is merged by now (it was under review in 2025);
   the patches must be rebased on the current mainline version.

Every patch needs a commit message that says why, a `Signed-off-by` (Developer Certificate of Origin) and
testing notes.

### 3. Hard blockers that need AMD

- **Firmware**: upstream drivers may only rely on firmware that is in `linux-firmware` under a redistributable
  licence. AMD would need to publish an `isp_4_1_1.bin` that supports this sensor, plus the tuning data. The
  Windows-rebuilt image cannot be submitted.
- **Sensor setup blobs**: the device script, sensor properties and D-PHY sequence are copies of Windows
  driver data. Upstream code cannot carry them; AMD would have to document them, ship them in firmware, or
  let the firmware provide them.
- **Undocumented interface**: command IDs and payloads (`ENABLE_PREFETCH`, `APPLY_TUNING_SCENARIO`, the
  pool formula, ...) are reverse-engineered from the Windows driver. Maintainers will ask what they mean;
  AMD's ISP developers can confirm them and are the natural co-authors or reviewers.

A realistic first step: an RFC to linux-media with the AMD ISP4 developers on CC, describing that the GZ302
rear camera works with these firmware commands and this pool sizing, and asking AMD for firmware and tuning
data in `linux-firmware` and for confirmation of the interface. The ov13b10 and board-data patches can go
upstream on their own once the sensor side is clean.

### 4. Legal hygiene

Keep upstream code independent of the Windows binaries: describe facts needed for interoperability (command
IDs, sizes, register values), never copy code or data tables. Not legal advice; check before publishing
anything derived from the Windows driver.

## Suggested order

1. Fix exposure / white balance and get continuous streaming in our tree.
2. Clean up the ov13b10 and board-data patches and send those first (least dependent on AMD).
3. Contact AMD (RFC) about firmware, tuning data and command semantics.
4. Meanwhile, offer a DKMS package with a "build the firmware from your own Windows partition" script for
   GZ302 owners.

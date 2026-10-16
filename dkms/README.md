# DKMS package `amd-isp4-capture` 0.1.0

Builds the experimental AMD ISP4 capture module from `../driver/` (`amd_isp4_capture.ko`) automatically for every
installed kernel via DKMS. **Nothing in this folder installs anything by itself**: `install.sh` and `uninstall.sh` only
print commands for you to review and run.

Status: the Makefile/Kbuild build was verified out-of-tree (see "Verified"); the DKMS install itself (`dkms add/build/
install`) has **not** been run.

## Files

| File | Purpose |
|---|---|
| `dkms.conf` | DKMS description: name, version, MAKE, CLEAN, PRE_BUILD, BUILD_EXCLUSIVE_*, AUTOINSTALL |
| `Kbuild` | read by kbuild for `make -C <kdir> M=<this dir>`; includes `driver/Kbuild` (no duplicated object list) |
| `Makefile` | outer wrapper for manual builds and for DKMS's MAKE line; picks `LLVM=1` per kernel |
| `check-generated-headers.sh` | PRE_BUILD check: kernel has the amdgpu ISP buffer helpers (error); run-time firmware files present (warning, since patch 0037) |
| `install.sh`, `uninstall.sh` | print (do not run) the install / removal commands |

## How the sources are found (and why this way)

DKMS copies the package directory into `/var/lib/dkms/amd-isp4-capture/0.1.0/build/` and builds there, so symlinks or
paths that leave the package tree would break. Chosen approach: **copy in a documented install step, and keep one
Kbuild that understands both layouts**:

```
repository                          installed (/usr/src/amd-isp4-capture-0.1.0/, then DKMS's build/ copy)
dkms/Kbuild  -> ../driver/          Kbuild     -> driver/
dkms/Makefile                       Makefile, dkms.conf, check-generated-headers.sh (mode 755)
driver/*.c *.h Kbuild               driver/*.c *.h Kbuild   (only the listed files, see install.sh)
```

`Kbuild` picks `driver/` if it exists next to it, otherwise `../driver/`, then:

- `include <srcdir>/Kbuild` takes `obj-m` and the object list from `driver/Kbuild`, so the list exists only once;
- `vpath %.c <srcdir>` lets make find the `.c` files there. Since Linux 6.13 kbuild's rule is
  `$(obj)/%.o: $(obj)/%.c` and sources are located through make's directory search (`VPATH` = the M= directory), so
  this works and **all output lands in the M= directory**, never in `driver/`. Only `%.c` is added to the search on
  purpose: `driver/` also holds stale build output (`*.o`, `*.cmd`, `Module.symvers`) from
  `scripts/build-isp4-threshold.sh`, which make must not pick up.

Rejected alternatives: (a) `amd_isp4_capture-objs := ../driver/isp4.o`: works, but writes the objects into `driver/`;
(b) wrapper files `dkms/isp4.c` containing `#include "../driver/isp4.c"`: duplicates the object list and breaks after the
DKMS copy; (c) a build-time copy of the sources into `dkms/`: stale copies; (d) kbuild's `MO=` (separate output dir):
fine for the Makefile, but DKMS and the required verification call `M=<this dir>` directly.

Caveat: the `vpath` trick depends on the kbuild rule shape described above; it relies on kbuild internals, not on a
documented interface. The rule shape was checked in v6.17 (upstream `scripts/Makefile.build`), 6.18.55 and 7.2.0. I
believe, but did not check, that older kbuild (before 6.13) used `$(src)/%.c` and would ignore `vpath`. Either way that
is below the minimum kernel.

## Prerequisites

1. **A kernel whose amdgpu exports the ISP buffer helpers** (`isp_user_buffer_alloc/free`, `isp_kernel_buffer_alloc/
   free` in `include/drm/amd/isp.h`) and has `CONFIG_DRM_AMD_ISP=y`: **Linux >= 6.17** (see "Minimum kernel version").
   `dkms.conf` sets `BUILD_EXCLUSIVE_CONFIG="CONFIG_DRM_AMD_ISP"` and `BUILD_EXCLUSIVE_KERNEL_MIN="6.17"`, so DKMS skips
   other kernels instead of failing.
2. **Kernel headers** for every kernel you want it built for (`/lib/modules/<kver>/build`), and the compiler that kernel
   was built with: clang + lld for clang-built kernels (CachyOS: `CONFIG_CC_IS_CLANG=y`, ThinLTO), gcc otherwise.
3. **dkms** (checked against dkms 3.4.3, which is installed here).
4. **Run-time files in `/lib/firmware/amdgpu/`** (since driver patch 0037 they are NOT needed to build; the PRE_BUILD
   script only warns if they are missing, the camera does not work without them): `gz302-ov13b-script.bin`,
   `gz302-ov13b-sensor-prop.bin`, `gz302-ov13b-phy-seq.bin` and `OV13B_3001_ROG_SRX.atb`. Make the first three with
   `python3 -I tools/header_to_fw.py driver firmware` (it reads the three generated headers below, which stay
   git-ignored) and copy them yourself:
   `sudo cp firmware/gz302-ov13b-*.bin /lib/firmware/amdgpu/`. The headers themselves are produced as before;
   the inputs come from a Windows install of the laptop's camera driver (on this machine read-only under
   `/mnt/windows/Windows/System32/DriverStore/FileRepository/`, see `docs/findings.md`):

   | Header | Command | Input |
   |---|---|---|
   | `isp4_ov13b_script.h` | `python3 -I tools/assemble_ov13b.py /path/to/asm_OV13B.asm --c-header driver/isp4_ov13b_script.h` | `asm_OV13B.asm` (Windows sensor package) |
   | `isp4_ov13b_sensor_prop.h` | `python3 -I tools/build_sensor_prop.py --c-header driver/isp4_ov13b_sensor_prop.h` | none (values transcribed from `sensorOV13B.sys` into the script) |
   | `isp4_phy_seq.h` | `python3 -I tools/build_phy_seq.py --exe /path/to/amdcamera.sys --pseudo scratch/phy-src/FUN_1400535d8.txt --c-header driver/isp4_phy_seq.h` | `amdcamera.sys` + saved Ghidra pseudo code (git-ignored, `scratch/phy-src/`) |

   Defaults (mode 0, 1120 Mbps, phy 0, 4 lanes) are the ones used so far; see each script's docstring. These headers
   are derived from AMD/OEM files: keep them local.
5. **amdgpu must create the ISP capture platform device for this laptop.** The module matches
   `platform:amd_isp_capture`, which amdgpu creates. Stock amdgpu does not recognise the GZ302's ACPI HID `OMNI13B1`
   (`driver/README.md`: the stock 7.2.9 kernel has no ISP capture device; the 1.7 kernel carries the allow-list patches).
   On a kernel without that amdgpu change the DKMS module builds and loads but never probes. See "Needed source
   changes".
6. **ISP firmware** (`/lib/firmware/amdgpu/isp_4_1_1.bin`). It is loaded by **amdgpu**, not by this module, and is
   **not** part of this package. The image used so far was rebuilt from the Windows driver's `.ram` files and is **not
   redistributable** (AMD/OEM property; see `docs/upstream-plan.md`, pieces 4 and 5). The `linux-firmware` image may
   not support this sensor.
7. Secure Boot: if module signature enforcement is on, the DKMS module must be signed with a key the kernel trusts
   (dkms signs with its MOK key if configured). Not needed on this machine's kernels (`CONFIG_MODULE_SIG=y`, not
   forced); an unsigned module only taints the kernel.

## Build

### Manual build (no install), to check a kernel

```sh
make -C dkms                                    # running kernel: /lib/modules/$(uname -r)/build
make -C dkms KDIR=/lib/modules/<kver>/build     # another kernel
make -C dkms KDIR=... clean                     # remove the build output from dkms/
```

The `Makefile` greps `$(KDIR)/.config` for `CONFIG_CC_IS_CLANG=y` and passes `LLVM=1` only then. You can override it
with `make LLVM=1` or `make LLVM=` on the command line. The output is `dkms/amd_isp4_capture.ko` (plus `*.o`, `.*.cmd`
etc. in `dkms/`).

The direct kbuild call works too: `make -C <kdir> M=$PWD/dkms [LLVM=1] modules`. In that case you choose `LLVM=1`
yourself and the PRE_BUILD script does not run; only the `Kbuild` header check does.

### DKMS

Print the commands, review them, then run them yourself:

```sh
sh dkms/install.sh
```

They copy the listed files to `/usr/src/amd-isp4-capture-0.1.0/` (with `driver/` as a subdirectory), then run
`dkms add`, `dkms build`, `dkms install` and `depmod`. With `AUTOINSTALL=yes`, DKMS rebuilds the module whenever a new
kernel (with headers) is installed.

How dkms 3.4.3 runs it (read from `/usr/bin/dkms`):

- MAKE becomes `make -j<n> KERNELRELEASE=<kver> KDIR=<kernel_source_dir> modules`, run in the build directory (dkms
  does `cd "$build_dir"` first, `/usr/bin/dkms` line 1583, so no `-C` is needed). dkms
  appends `LLVM=1` itself for clang-built kernels. The Makefile adds it too (for older dkms versions); passing it twice
  is harmless.
- PRE_BUILD runs `check-generated-headers.sh <kernel_source_dir>` **only if the file is executable**. Otherwise dkms
  skips it silently, which is why `install.sh` uses `install -m755`. The `Kbuild` check is the backstop.
- `CLEAN` is deprecated in dkms 3.x: it is not run, and dkms only prints a deprecation warning. It is kept because older
  dkms versions run it. DKMS builds in a fresh copy anyway.

## The in-kernel module of the same name

Kernels with the in-tree driver (7.2+) ship
`/lib/modules/<kver>/kernel/drivers/media/platform/amd/isp4/amd_isp4_capture.ko.zst`. On this machine it exists for
7.2.0-1.7-cachyos, 7.2.9-2-cachyos and 7.3.0-rc6-2-cachyos-rc, but not for 6.18.55-2-cachyos-lts. DKMS installs to
`/lib/modules/<kver>/updates/dkms/`, and depmod prefers `updates/` (`/usr/lib/depmod.d/search.conf` here:
`search updates extramodules built-in`). So after `dkms install`, `modprobe amd_isp4_capture`, and automatic loading
by the `platform:amd_isp_capture` alias, use the **DKMS copy**.

Consequences:

- `scripts/test-isp4-threshold.sh` uses `insmod driver/amd_isp4_capture.ko`, so it is unaffected. Its last step,
  `modprobe amd_isp4_capture` ("reload the stock module"), would load the DKMS module instead of the stock one.
- To go back to the in-tree module: `sh dkms/uninstall.sh` prints `dkms remove -m amd-isp4-capture -v 0.1.0 --all`
  (deletes the `updates/dkms` copies and runs depmod), the `/usr/src` cleanup and a final `depmod`.

## Check

```sh
modinfo -n amd_isp4_capture        # expect /lib/modules/<kver>/updates/dkms/amd_isp4_capture.ko*
modinfo amd_isp4_capture | grep -E '^(vermagic|depends|parm):'
dkms status amd-isp4-capture
sudo modprobe amd_isp4_capture     # or let the alias load it at boot
sudo dmesg | grep -iE 'isp4|amd_isp|EXP-' | tail -50
ls /dev/video*                     # a capture node appears only if amdgpu created the ISP device (prerequisite 5)
```

Build logs: `/var/lib/dkms/amd-isp4-capture/0.1.0/build/make.log`.

## Remove

```sh
sh dkms/uninstall.sh               # prints: modprobe -r, dkms remove --all, rm -r /usr/src/..., depmod
```

## Minimum kernel version

**Linux 6.17** for building and linking. How this was determined:

- The module's only non-standard dependency is amdgpu's ISP buffer API: `driver/isp4.h` and `isp4_interface.h` include
  `<drm/amd/isp.h>`, and the sources call `isp_kernel_buffer_alloc/free` and `isp_user_buffer_alloc/free`. These are
  exported by amdgpu (`Module.symvers` of the 1.7 headers: `drivers/gpu/drm/amd/amdgpu EXPORT_SYMBOL`).
- Upstream tags (GitHub mirror `torvalds/linux`; git.kernel.org refused the fetch): `include/drm/amd/isp.h` **does not
  exist in v6.16** and **declares all four helpers in v6.17**.
- Local proof: the package builds cleanly against **6.18.55-2-cachyos-lts** (gcc, no `LLVM=1`, no warnings,
  `vermagic: 6.18.55-2-cachyos-lts SMP preempt mod_unload`) and **7.2.0-1.7-cachyos** (clang/ThinLTO).
- The in-tree driver (`drivers/media/platform/amd/isp4/Kconfig`) is absent in v7.1 and present in v7.2 (and master). So
  between 6.17 and 7.1 there is no in-tree module to conflict with, but also no distribution-tested combination.
- Other APIs used (`vb2_queue.min_queued_buffers`, `v4l2_subdev_init_finalize`, `dev_pm_genpd_set_performance_state`,
  `kernel_read_file_from_path`) are older than 6.17, and the 6.18 build confirms they exist there.

## Needed source changes

None are needed in `driver/` to **build** on 6.18 and 7.2 (both verified). To make the module **work** on a
distribution kernel:

1. **amdgpu** (not this module) must recognise the laptop's ISP/sensor ACPI description (`OMNI13B1`) and create the
   `amd_isp_capture` platform device (the allow-list patches in the 1.7 kernel, `docs/upstream-plan.md` piece 1). DKMS
   cannot provide that from this package. It needs a patched amdgpu (the project's `scripts/build-amdgpu-oot.sh` path)
   or upstream support.
2. DONE in driver patch 0037: the device script, sensor properties and D-PHY sequence are loaded at run time with
   `request_firmware()` (`amdgpu/gz302-ov13b-*.bin`), so the module source and the built `.ko` contain no
   Windows-derived data; the files themselves are still non-redistributable and must be made locally.

## Not verified

- `dkms add/build/install/remove` were **not run**, and neither were the commands printed by `install.sh` and
  `uninstall.sh`. The dkms behaviour described above comes from reading `/usr/bin/dkms` 3.4.3, not from running it.
- Not built against 6.17 itself (no headers here); 6.17 is the API floor from the upstream header check only. Kernels
  6.17-7.1 may differ in V4L2/vb2 details that the 6.18 build did not exercise.
- The `vpath` source lookup was tested by building on 6.18 and 7.2 only. For 6.17 only the rule shape was read.
- Loading/probing was not tested with the DKMS-built module on any kernel. In particular, it is unknown whether 6.18's
  amdgpu creates `amd_isp_capture` at all, and whether its firmware interface matches this 7.2-derived driver.
- Distribution kernels other than CachyOS (Fedora, Ubuntu, Arch) were not tried. Their dkms versions may still run
  `CLEAN` or not support `BUILD_EXCLUSIVE_KERNEL_MIN`. I expect (unverified) that they ignore unknown directives, in
  which case the PRE_BUILD check still stops a build on a kernel without the helpers.
- The output of the generator scripts was not regenerated here; the headers in `driver/` were used as they were.

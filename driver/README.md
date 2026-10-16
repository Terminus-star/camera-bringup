# START_STREAM buffer-threshold experiment

> Layout since 2026-10-16: this folder (`driver/`) holds the working module source; the patches listed below are in
> `driver/patches/` (the amdgpu one in `driver/patches/amdgpu/`). Build with `./scripts/build-isp4-threshold.sh`
> (output `driver/amd_isp4_capture.ko`); test results still go to `scratch/isp4-threshold/results/`.

**Question.** The handoff (2026-08-25) found that `ISP4FW_CMD_ID_START_STREAM` is never sent, because only 3 of the 4 buffers
required by `ISP4SD_MIN_BUF_CNT_BEF_START_STREAM` reach the ISP. So "the firmware does not respond to the OV13B10" was never
actually tested. This experiment lowers the threshold and observes what the firmware does.

**Method.** A patched `amd_isp4_capture.ko` with a module parameter `min_start_bufs` (default 4 = stock behaviour). No other
behaviour changes. See `0009-isp4-start-threshold-param.patch` (review it first; it is about 50 lines).

## Why the 1.7 kernel

The running 7.2.9 kernel has no ISP capture device at all, because its amdgpu does not recognise `OMNI13B1`. Your prebuilt
7.2.0-1.7 kernel has the allow-list patch (0001-0005). It also contains patch 0007, which forces sensor PLL register `0x0305` to
`0x8c` (Windows uses `0x46`). That does not affect whether `START_STREAM` is sent, but keep it in mind when reading any frame
results.

## Files

| Path | What it is |
|---|---|
| `isp4_*.c/.h`, `isp4.[ch]` | pristine 7.2.0-1 ISP4 sources, except `isp4_subdev.c` (patched) |
| `Kbuild` | out-of-tree build file |
| `0009-isp4-start-threshold-param.patch` | the diff against pristine (the `min_start_bufs` parameter) |
| `0010-isp4-ring-pointer-diagnostic.patch` | second diff, on top of 0009: logs command/response ring pointers and interrupt state (`EXP-RING` lines) |
| `0011-isp4-fw-log-drain.patch` | third diff, on top of 0010: drains and prints the firmware log ring (`EXP-FWLOG` lines) |
| `0012-isp4-replay-windows-sensor-setup.patch` | fourth diff, on top of 0011: `replay_sensor_setup=1` sends the Windows `SET_DEVICE_SCRIPT` + `SET_SENSOR_PROP` before `SET_STREAM_CONFIG` (`EXP-REPLAY` lines). Includes the two generated headers below as new files |
| `0013-isp4-print-cmd-done-error.patch` | fifth diff, on top of 0012 (`isp4_subdev.c` only): prints status, `isp4fw_error_code` and the 36-byte payload of every command-done response (`EXP-RESP` lines) |
| `0014-isp4-sensor-prop-variant.patch` | sixth diff, on top of 0013 (`isp4_interface.c` only): module parameter `sensor_prop_variant` (0 as built, 1 caps only 352 B, 2 sensor id 1, 3 all zero) selects the `SET_SENSOR_PROP` payload. Run all four: `./scripts/test-isp4-threshold.sh --values "4" --replay --variants "0 1 2 3"`; compare the `EXP-RESP` error code of seq 2 |
| `0015-isp4-bogus-cmd.patch` | seventh diff, on top of 0014 (`isp4_interface.c` only): module parameter `bogus_cmd` also sends an invalid command ID after `SET_SENSOR_PROP`. Run: `./scripts/test-isp4-threshold.sh --values "4" --replay --bogus-cmd 0x0badbad`; compare the `EXP-RESP` code of the bogus command with the 0x1b of seq 2 |
| `0016-isp4-tuning-file-replay.patch` | eighth diff, on top of 0015 (`isp4_interface.c` only): module parameter `tuning_file` reads the sensor tuning file at run time and sends it with `SET_TUNING_DATA` (0x02050008) between the script and the sensor properties. Run on the Windows-firmware boot entry: `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb` |
| `0017-isp4-fw-mem-pool-param.patch` | ninth diff, on top of 0016 (`isp4_interface.c` only): module parameter `fw_mem_pool_mb` sets the firmware memory pool size (0 = stock 100 MiB; Windows uses 200). Run: add `--pool-mb 200` to the command of 0016 |
| `0018-isp4-start-sensor.patch` | tenth diff, on top of 0017 (`isp4_subdev.c` only): module parameter `start_sensor` (1 = after START_STREAM is queued, 2 = before) finds the `ov13b10` I2C client and calls its `s_stream(1)`/`s_stream(0)`; logs `EXP-SENSOR` lines. Run: add `--start-sensor 1` to the command of 0017 |
| `0019-isp4-sensor-i2c-probe.patch` | eleventh diff, on top of 0018 (`isp4_subdev.c` only): when `start_sensor` is set, does a raw `i2c_transfer()` chip-ID read and a harmless write on the sensor's adapter before `s_stream` (and again after a failure) and logs the real return values (`EXP-SENSOR: raw I2C` lines). Same command as 0018 |
| `0020-isp4-sensor-pm-cycle.patch` | twelfth diff, on top of 0019 (`isp4_subdev.c` only): module parameter `sensor_pm_cycle` forces an `ov13b10` runtime suspend+resume (re-drives its enable GPIO) once the ISP is up, with a raw I2C probe before and after (needs `start_sensor`). Run: add `--sensor-pm-cycle` to the command of 0018 |
| `0021-isp4-phy-init.patch` | thirteenth diff, on top of 0020 (`isp4_interface.c/.h`, `isp4_subdev.c` and the new generated `isp4_phy_seq.h`): module parameter `phy_init` starts the MIPI D-PHY receiver from the host like Windows (reset pulse, lane masks, 296 evaluated analog register operations for phy 0 / 1120 Mbps / 4 lanes, enable, ready and lane stop-state polling), called from the sensor start helper with the sensor powered. Needs `start_sensor`. Run: add `--phy-init` to the command of 0018 (mode 2 recommended). The first version oopsed (it used `ispif->mmio`, which does not reach 0x66xxx); the current patch maps its own window 0x66000-0x67fff, see findings section 43 |
| `0022-isp4-phy-diag.patch` | fourteenth diff, on top of 0021 (`isp4_interface.c/.h`, `isp4_subdev.c`): read-only snapshot of the D-PHY receiver (13 direct PHY dwords at 0x66700-0x66730, global reset, lane stop-state) right after the sensor's `s_stream(1)`, +100 ms and +1 s, logged as `EXP-PHYDIAG[...]`. Active with `phy_init` (no new parameter, same command as 0021). Tells "sensor silent" (data lanes stay in stop state) from "sensor transmits but undecodable" (lanes leave stop state) |
| `0023-isp4-skip-enable-gpio.patch` | fifteenth diff, on top of 0022 (`isp4_subdev.c` only): module parameter `skip_enable_gpio` makes `isp4sd_module_enable()` leave the `enable_isp` GPIO (AMDI0030:00 pin 85) alone, so it stays low from probe. For the front-camera LED investigation (findings sections 50-52). Run: add `--skip-enable-gpio` to any command of `scripts/test-isp4-threshold.sh` |
| `0024-isp4-ispgpio-dump.patch` | sixteenth diff, on top of 0023 (`isp4_interface.c` only): every `EXP-RING` snapshot also prints the ISP's three output-only sensor-control pins (registers at ISP offsets 0x6613c / 0x66140 / 0x6618c, output value = bit 4), read-only. Window mapped once in `isp4if_init()`. No parameter and no new script option; the existing ring section of the console output shows it. For the front-camera LED investigation (findings sections 53-54) |
| `0025-isp4-sensor-pll.patch` | seventeenth diff, on top of 0024 (`isp4_subdev.c`): module parameter `sensor_pll`: after the ov13b10 `s_stream(1)`, 1 = read back and log the sensor PLL/MIPI registers over raw I2C, 2 = also write the Windows (24 MHz) PLL values (`0x0303=01 0x0305=46 0x0325=55`) in software standby and stream on again. Makes the CSI-2 link decode (findings 59). Run: `--sensor-pll 1|2`. WARNING: `--sensor-pll 2` without a burst limit froze the machine (findings 59) |
| `0026-isp4-sensor-burst-limit.patch` | eighteenth diff, on top of 0025 (`isp4_subdev.c`): module parameter `sensor_burst_ms`: N ms after the sensor started streaming a delayed work puts it into software standby (`0x0100=0`), so the data flood that wedged the ISP ends early; cancelled in the sensor stop path and in `isp4sd_deinit()`. Use with `--start-sensor 1`. Run: `--sensor-burst-ms 300` |
| `0027-isp4-meta-data-buffers.patch` | nineteenth diff, on top of 0026 (`isp4_subdev.c`): module parameter `meta_data_bufs` (max 6): allocates 128 KiB GPU buffers (`isp_kernel_buffer_alloc`, kept until module unload) and sends them as SEND_BUFFER type 13 (META_DATA) right before the type-10 buffers, like the Windows `isp_send_metadata_buf` (findings 65). Removes the firmware warnings "queue empty:type=13" and "No meta data buffer is available". Run: `--meta-data-bufs 6` (safe without a sensor start) |
| `0028-isp4-windows-cmds.patch` | twentieth diff, on top of 0027 (`isp4_subdev.c`): module parameter `win_cmds` (bit mask, 0 = off): sends the six Windows-only stream commands whose payload is known, in the Windows order (ENABLE_RTA `{1}` after the pool; APPLY_TUNING_SCENARIO `{0}` after SET_STREAM_CONFIG; SET_OUT_CHAN_FRAME_RATE_RATIO `{0,1}` between PROP and ENABLE; SET_SCENE_MODE `{0}` after ENABLE_OUT_CHAN; SET_FPS_RANGE `{15000,30000}` and SET_ITIME_RANGE `{40,66666}` after the META buffers). Bits 1,2,4,8,0x10,0x20. Not included: SET_3A_CONFIG (92 bytes, indirect), ENABLE_PREFETCH and the global commands, M2M cal, adaptive RTA (findings 71/72). Logs `EXP-WINCMD:` per command. Run: `--win-cmds 0x3f` |
| `0029-isp4-global-prefetch.patch` | twenty-first diff, on top of 0028 (`isp4_interface.c`, `isp4_subdev.c`): `isp4if_get_fw_stream()` now routes commands of type 0x01 (bits 31:24) to the GLOBAL ring (`CMD_RB_GBL0`, firmware stream id -1) instead of stream 1; existing type-0x02 commands are unchanged. New `win_cmds` bit 0x40 sends the global `ENABLE_PREFETCH` (0x01030003) with payload `{1,1,1}` (INFERRED, findings 72/78) after the META buffers and before SET_FPS_RANGE, like Windows. Logs `EXP-WINCMD: ENABLE_PREFETCH ...`; the firmware reply shows in `EXP-RESP` (global stream) and its MMHUB log lines. Run: `--win-cmds 0x77` (0x37 + 0x40) |
| `0030-isp4-prefetch-flags.patch` | twenty-second diff, on top of 0029 (`isp4_subdev.c`): module parameter `prefetch_flags` (default 7 = the 0029 payload `{1,1,1}`): bit N sets ENABLE_PREFETCH payload word N, so each of the three firmware switches (`RTPipe MMHub Prefetch`, `SoftRTPipe MMHub Prefetch`, `Add YUV GAP for 32K alignment`) can be tested alone; with `{1,1,1}` the firmware hangs in `MMhubPrefetchSingleStream` during START_STREAM (findings 80). Needs `win_cmds` bit 0x40. Run (no sensor): `--win-cmds 0x77 --prefetch-flags 0` (then 4, 1, 2) |
| `0031-isp4-start-streaming-safe-iter.patch` | twenty-third diff, on top of 0030 (`isp4_video.c`): `isp4vid_qops_start_streaming` walks `buf_list` with `list_for_each_entry_safe` instead of `list_for_each_entry`. Fixes the oops of findings 83 (GPF in `isp4if_alloc_buffer_node`, LIST_POISON in RBX/RSI): the frame-done path `list_del`s a completed buffer while the loop is still inside `isp4sd_ioc_send_img_buf` for it. No parameter; always active. Run: the data run of findings 83 (`--win-cmds 0x77 --prefetch-flags 1` ...) with the logger |
| `0032-isp4-script-i2c-descriptors.patch` | twenty-fourth diff, on top of 0031 (`isp4_interface.c`): module parameters `script_i2c` (0 off, 1 sensor, 2 sensor + focus motor, 3 all four = sensor) and `script_i2c_restart` (default 1). Before the checksum is computed, fills the four 20-byte I2C descriptors at payload offset 0x169c of SET_DEVICE_SCRIPT ({deviceId, enRestart, deviceAddrType, regAddrType, deviceAddr}) with the sensor at 0x10 / code 0x102 and the focus motor at 0x0c / code 0x101 (from `get_i2c_config_OV13B`; meaning of the codes INFERRED). Goal: the firmware's `SvmSetI2c: Set i2c addr mode not 7bit nor 10bit` error that stops all exposure/gain writes (findings 86). Logs `EXP-SCRIPT-I2C:`. Only visible in a data run (the script runs only when AE is active). Run: `--script-i2c 1` |
| `0033-isp4-sensor-windows-mode-regs.patch` | twenty-fifth diff, on top of 0032 (`isp4_subdev.c`): `sensor_pll=3` = `sensor_pll=2` (Windows PLL in software standby) plus the other Windows mode values that differ from the Linux ov13b10 table: `0x3813=08` (vertical window offset, Linux 09: suspected Bayer-phase shift behind the magenta cast, findings 88), `0x3600=1a`, `0x380f=94`, `0x3011=7c`, `0x3774=2d`, `0x3823=18`, `0x3827=01`; exposure/gain registers left to the AE. The PLL readback now also lists these registers. Run: section 88's command with `--sensor-pll 3` |
| `0034-isp4-meta-data-resend-phy-diag.patch` | twenty-sixth diff, on top of 0033 (`isp4_subdev.c`): tuning steps 2 and 4. `meta_data_resend` (bool, default 0): after every frame-done also re-send one type-13 META_DATA buffer, round-robin from the first (restart at each stream start), like Windows' ResendMetaInFrameDone (findings 92). `phy_diag` (bool, default 1 = as before): 0 skips the D-PHY dumps that sleep 1.1 s inside the buffer-send path. Continuous streaming = `sensor_burst_ms=0` (already the default). Run: `--meta-data-resend --no-phy-diag --sensor-burst-ms 0` |
| `0035-isp4-working-defaults.patch` | twenty-seventh diff, on top of 0034 (`isp4_interface.c`, `isp4_subdev.c`): the working configuration of findings 93 becomes the MODULE DEFAULT, parameters kept for experiments: `replay_sensor_setup=1`, `phy_init=1`, `script_i2c=2`, `tuning_file=/lib/firmware/amdgpu/OV13B_3001_ROG_SRX.atb` (copy it there yourself; Windows-derived, not shipped), `fw_mem_pool_mb=0` now = Windows' pool formula (275,054,592 bytes for 4208x3120), `start_sensor=1`, `sensor_pm_cycle=1`, `sensor_pll=3`, `win_cmds=0x77`, `prefetch_flags=1`, `meta_data_bufs=6`, `meta_data_resend=1`, `phy_diag=0`. The test script's defaults are the same values; `--module-defaults` loads the module with no experiment parameters. Run: `./scripts/test-isp4-threshold.sh --module-defaults --seconds 8` |
| `0036-isp4-sensor-pll-default-off.patch` | twenty-eighth diff, on top of 0035 (`isp4_subdev.c`): `sensor_pll` default 3 -> 0. The 24 MHz PLL and the Windows mode registers are now written by the ov13b10 driver itself (`sensor/`, GZ302 DMI quirk, `gz302_fixups`), before stream-on instead of over raw I2C afterwards. `sensor_pll=3` still works for experiments (load ov13b10 with `gz302_fixups=0`). Needs the new `sensor/ov13b10.ko` loaded. |
| `0037-isp4-load-gz302-data-as-firmware.patch` | twenty-ninth diff, on top of 0036 (`isp4_interface.c`): the three Windows-derived payloads are no longer compiled in (`#include` of `isp4_ov13b_script.h`, `isp4_ov13b_sensor_prop.h`, `isp4_phy_seq.h` removed). They are loaded with `request_firmware()` from `amdgpu/gz302-ov13b-script.bin` (5868 B), `amdgpu/gz302-ov13b-sensor-prop.bin` (360 B) and `amdgpu/gz302-ov13b-phy-seq.bin` (header `GZPH` v1 + operations), made by `tools/header_to_fw.py` from the same headers (identical bytes). Size/format checked; a missing file is logged (`EXP-FW:`) and that step skipped. Install: `sudo cp firmware/gz302-ov13b-*.bin /lib/firmware/amdgpu/` |
| `isp4_phy_seq.h` | generated by `../build_phy_seq.py` from the Windows driver (see `../findings.md` section 42); numbers only |
| `isp4_ov13b_script.h`, `isp4_ov13b_sensor_prop.h` | generated payloads (by `../assemble_ov13b.py --c-header` and `../build_sensor_prop.py --c-header`); unverified against real firmware |
| `base-0009/`, `base-0010/`, `base-0011/` | the files as they were before 0010 / 0011 / 0012 (used only to generate those diffs) |
| `../headers-1.7/` | 1.7 kernel headers (extracted `.pkg.tar.zst`) |
| `../kernel-1.7/` | 1.7 kernel image and modules (extracted `.pkg.tar.zst`) |
| `amd_isp4_capture.ko` | built module, vermagic `7.2.0-1.7-cachyos` (build output) |
| `../../scripts/build-isp4-threshold.sh` | builds the module (already run once, succeeded) |
| `../../scripts/install-kernel-1.7-sidebyside.sh` | copies the 1.7 kernel in next to the others (you run it) |
| `../../scripts/test-isp4-threshold.sh` | the reload-and-capture loop (run on the 1.7 boot) |

## Procedure

1. **Read** `0009-isp4-start-threshold-param.patch` and the three scripts.
2. **Install the 1.7 kernel side by side** (does not touch 7.2.9, deckify, pacman or `limine.conf`):

   ```bash
   cd ~/Projects/camera-bringup
   ./scripts/install-kernel-1.7-sidebyside.sh
   ```

   It creates only `/usr/lib/modules/7.2.0-1.7-cachyos/`, `/boot/camera-test/vmlinuz` and `/boot/camera-test/initramfs.img`, and
   refuses to run if any of them exists. **Do not use `pacman -U` on the 1.7 package:** it is named `linux-cachyos`, so pacman
   would treat it as a downgrade of your current kernel and remove the 7.2.9 modules.

3. **Add a Limine entry** (you do this and the re-enroll yourself). The install script ends by printing the finished entry
   with both file hashes filled in; paste that. To print it again later without installing anything, run
   `./scripts/install-kernel-1.7-sidebyside.sh --print-entry`. The entry is named `7.2.0-1.7-cachyos-camera` (display name only;
   `uname -r` still reports `7.2.0-1.7-cachyos`). Shape of the entry (checked against your `limine.conf`, which I read):

   ```
   /7.2.0-1.7-cachyos-camera
     comment: GZ302 START_STREAM threshold experiment (manual entry, not managed by limine-entry-tool)
     protocol: linux
     path: boot():/camera-test/vmlinuz#<b2sum of vmlinuz>
     module_path: boot():/camera-test/initramfs.img#<b2sum of initramfs.img>
     cmdline: <same as your other entries>
   ```

   What your `limine.conf` shows, and what that means for the entry:
   - **Hashes are used on every file.** All generated entries end each path with `#<128 hex digits>`. I checked that this is
     plain `b2sum` (BLAKE2b-512): `b2sum /usr/lib/modules/7.2.9-2-cachyos/vmlinuz` equals the hash on the `linux-cachyos`
     entry's `path:` line. The script computes the same for the new files. `vmlinuz` is
     `38f45412…cd0eda5` (also computed from the package file, so you can compare). The initramfs hash cannot be known until
     the script builds it, since initramfs images are not reproducible.
   - **Placement.** Put it at the top level (`/`, no indentation), between the last line of the `/+CachyOS` block (line 298 in
     your pasted copy, a blank line) and `/+Other systems and bootloaders` (line 299). `default_entry: 2` counts from the top, so
     entries before the new one keep their numbers; entries after it (Windows, EFI fallback) shift by one.
   - **`remember_last_entry: yes`.** After you boot the test entry, Limine will pre-select it next time. Choose a normal entry
     once afterwards, or the next boot starts the test kernel again.
   - **`timeout: 0.5` and `quiet: yes`.** The menu is only up for half a second; press a key at the Limine screen to stop the timer.
   - **Auto-generated blocks.** The `/+CachyOS` group, its `//Snapshots`, and `/EFI fallback` are marked as generated by
     `limine-entry-tool` / `limine-snapper-sync`. I do not know whether a regeneration keeps a hand-written entry, so keep a
     copy of the entry, and re-enroll after every edit (`ENABLE_ENROLL_LIMINE_CONFIG=yes`).
   - **Command line.** Identical to your other entries (including `resume=` for your swapfile). Do **not** hibernate while on
     this test kernel.

4. **Reboot into the new entry**, then confirm `uname -r` prints `7.2.0-1.7-cachyos`.

5. **Run the test** (needs sudo; takes about a minute per value):

   ```bash
   cd ~/Projects/camera-bringup
   ./scripts/test-isp4-threshold.sh --values "4 2 1"
   ```

   If it cannot identify the ISP video node it prints the nodes and asks for `--dev /dev/videoN`.

6. **Reboot into your normal kernel.** Results are in `scratch/isp4-threshold/results/` (tell me; I will read them).

## Round 2: ring-pointer diagnostic

Round 1 (`min_start_bufs` 4 / 2 / 1) showed `START_STREAM` is queued but nothing is answered; see `../findings.md` section 11. The
module in this directory now also contains patch 0010. Because the threshold turned out not to matter, one value is enough:

```bash
cd ~/Projects/camera-bringup
./scripts/test-isp4-threshold.sh --values "4"
```
You can stay on the same 7.2.0-1.7 boot; the script swaps the module itself. It now also saves its console output
(`results/*-console.txt`), prints whether `fw_log_enable` took effect, and shows the `EXP-RING` lines at the end of each run.
How to read them: `../findings.md` section 12.

## Round 3: firmware-log drain (patch 0011)

Round 2 showed the firmware reads every command but answers only the first (`../findings.md` section 13). The firmware's own log was never
read after that, because the driver only drains it when a response arrives. Patch `0011-isp4-fw-log-drain.patch` (on top of 0010) drains
and prints it whenever the ring dump runs (`EXP-FWLOG` lines, plus the log ring's read/write pointers). The module in this directory
already contains it. Same command as round 2:

```bash
cd ~/Projects/camera-bringup
./scripts/test-isp4-threshold.sh --values "4"
```
The console output (saved in `results/*-console.txt`) now ends with the first 150 `EXP-FWLOG` lines. What to look for: findings section 15.

## Round 4: replay of the Windows sensor setup (patch 0012)

Round 3 result: the firmware log ring stayed at read = write = 0 (no text), so it gave no hint. Windows sends two sensor commands that Linux
never sends. Patch `0012` (module already rebuilt with it) adds the module parameter `replay_sensor_setup`; when set, `isp4sd_init_stream`
sends `SET_DEVICE_SCRIPT` (0x02090002, 5868-byte payload) and `SET_SENSOR_PROP` (0x02090001, 360-byte payload) synchronously, after the
memory pool and before `SET_STREAM_CONFIG`. Each logs one `EXP-REPLAY` line saying `answered` or `NO ANSWER / FAILED`.

```bash
cd ~/Projects/camera-bringup
./scripts/test-isp4-threshold.sh --values "4" --replay
```
Same boot as before. Without `--replay` the module behaves as in round 3. How to read the output: `../findings.md` section 16.

## Reading the results (round 1)

Each run prints one line: `queued`, `fw-reply`, `frames`, `bytes`.

| Observation | Meaning |
|---|---|
| `min=4`: `queued=0`, `no-send>0` | Reproduces the handoff finding: stock logic never sends `START_STREAM`. |
| `min=4`: `queued=1` | Not reproduced. Something differs from the handoff's runs; the other rows then matter less. |
| `min=2/1`: `queued=1`, `fw-reply>=1`, `frames>0` | It was a host bug. The firmware streams. Check whether the image is usable. |
| `min=2/1`: `queued=1`, `fw-reply>=1`, `frames=0` | The firmware accepts `START_STREAM` but produces no frames. Only now is the sensor/firmware question truly tested. |
| `min=2/1`: `queued=1`, `fw-reply=0` | The command is queued but the firmware never answers it. |
| `failed>0` | The command ring rejected the command; the log has the errno. |
| `queued=0` for every value | Buffers never reach the send path at all. Look at the `no send` lines and the `queue buf` lines. |

Remember `queued` only proves the driver put the command in the ring (`isp4if_send_command` is the asynchronous variant). Only the
`fw-reply` count shows that the firmware responded.

## Known caveats

- The build used clang 23.1.1 and pahole 132; the 1.7 kernel was built with clang 22.1.8 and pahole 131. Both produced warnings
  during the build. If the module loads but its BTF is rejected, that is harmless.
- Loading an unsigned out-of-tree module taints the kernel. `MODULE_SIG_FORCE` is off and lockdown is forced to none on that kernel,
  so loading is allowed.
- The test captures at 1920x1080 NV12 with 4 mmap buffers, as the earlier diagnostic script did.

## Cleanup (you run these; I do not delete files)

```bash
sudo rm -r /usr/lib/modules/7.2.0-1.7-cachyos /boot/camera-test
# and remove the Limine entry you added
```

The project-side artefacts (`scratch/headers-1.7`, `scratch/kernel-1.7`, `scratch/isp4-threshold/results`) can be removed when you
are finished.

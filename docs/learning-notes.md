# Learning notes

## 2026-10-15: reverse engineering the Windows ISP camera stack for the GZ302 OV13B10

**What changed.** Nothing in the kernel patches. I installed `jdk21-openjdk` and `ghidra`, pointed the rea MCP server at
`/opt/ghidra`, and decompiled the Windows `amdcamera.sys` and `sensorOV13B.sys`. Results are in `scratch/findings.md`.

**Why.** The earlier conclusion ("the ISP firmware has no sensor-configuration command, so only AMD can add the OV13B10")
was based on Linux's `isp4_fw_cmd_resp.h`, which lists only six commands. The Windows driver defines many more, and sets a
sensor up with `SET_DEVICE_SCRIPT`, `SET_SENSOR_EMB_PROP` and `SET_SENSOR_PROP`. Whether the Linux firmware accepts them is
still unknown.

**Concept to understand: indirect firmware commands.** A command ring entry is small (the Linux `struct isp4fw_cmd` has a
12-word parameter area). Large data, such as a 360-byte sensor description or a 5.8 KB script, is not copied into the ring.
The host writes it to memory the firmware can read and puts only `{address lo, address hi, size, checksum}` in the command.
Look up: DMA-visible buffers, GPU virtual addresses (`ISP4FW_ADDR_SPACE_TYPE_GPU_VA`), and why a checksum accompanies the pointer.

**Related concept: a tiny VM inside firmware.** `asm_OV13B.asm` is not Linux or Windows code. It is source for a small
register machine (opcodes like `WI2C`, `RI2C`, `DIV`) that the ISP firmware runs to read and write sensor registers when it
needs to change exposure or gain. Look up: bytecode, assemblers, and why vendors use a script instead of hard-coding each sensor.

**What could go wrong.** Everything in `scratch/findings.md` that is marked INFERENCE is a reading of decompiler output, not a
tested fact. The script bit layout in particular must be checked against a test vector before it is sent to real hardware.

## 2026-10-15 (later): assembler prototype

**What changed.** Added `scratch/assemble_ov13b.py`, a stdlib-only Python re-implementation of the Windows script assembler. It
turns `asm_OV13B.asm` into the 5,868-byte `SET_DEVICE_SCRIPT` payload (96 instructions, 10 functions). Findings section 10 records
the result.

**Why.** To turn a reading of decompiled code into something that can be run and checked, and to produce the payload a future
kernel experiment would send.

**Concept to understand: a round-trip test checks consistency, not correctness.** The script encodes every instruction, decodes
it again and compares. That proves the bit fields do not overlap (nothing is lost), but a wrong understanding of the format would
round-trip perfectly too. Independent evidence has to come from somewhere else (here: the firmware interpreter, or real hardware).
Also look up: two-pass assemblers (first pass collects labels, second resolves them), and why the Python is run with `-I`
(isolated mode: it ignores the current directory and environment when importing, so a hostile file next to the script cannot hijack it).

**What could go wrong.** The trailing 0x104 bytes of the payload and the MOV front-end rules are assumptions; see findings
section 10, risks 1-4.

## 2026-10-15 (later still): START_STREAM threshold experiment, prepared but not yet run

**What changed.** Built `scratch/isp4-threshold/amd_isp4_capture.ko`, a copy of the AMD ISP4 capture driver with one new module
parameter, `min_start_bufs`. Added three scripts in `scripts/` (build, side-by-side kernel install, test loop) and a README with
the procedure and how to read each outcome. Nothing was installed or loaded; the experiment itself needs a reboot into the 1.7
kernel, which is yours to do.

**Why.** The handoff showed the driver never sends `START_STREAM`, so "the firmware rejects the sensor" was never tested. The
running 7.2.9 kernel has no ISP device (its amdgpu does not know `OMNI13B1`), hence the 1.7 kernel.

**Concepts to understand.**
- *Out-of-tree module vs `vermagic`.* A module only loads into the kernel it was built for. The build used the headers of
  `7.2.0-1.7-cachyos`, so its vermagic matches that kernel and it will be refused by 7.2.9. The kernel config also mattered:
  that kernel is built with clang and ThinLTO, so the module needs `LLVM=1`.
- *Package names collide.* The 1.7 package is called `linux-cachyos`, like the kernel you run now. `pacman -U` would treat it as a
  downgrade and remove the 7.2.9 module directory. Copying the files by hand into unique paths (`/usr/lib/modules/<version>/`
  is already versioned, `/boot/camera-test/` is new) avoids that. Look up: pacman file ownership, `depmod`, `mkinitcpio -k/-g`.
- *Asynchronous commands.* `isp4if_send_command` puts a command in a ring and returns; `isp4if_send_command_sync` waits for the
  firmware. A "queued" log line therefore proves nothing about the firmware, so the test script counts the firmware's own
  response lines instead.

**What could go wrong.** I never saw your `limine.conf` (`/boot` is root-only) and `ENABLE_ENROLL_LIMINE_CONFIG=yes` is set, so
editing it by hand may need a re-enroll. The README lists exactly what I could and could not verify.

### Follow-up: reading limine.conf

**What changed.** After you copied `limine.conf` into the project, I read it and made the install script print the finished
boot entry (both file hashes filled in). README step 3 now describes the entry as it relates to your actual file.

**Concept to understand: Limine verifies files by hash.** Every `path:` and `module_path:` in your generated entries ends with
`#<hash>`, a BLAKE2b-512 digest of the file Limine is about to load. With the config itself enrolled (its own hash stored in the
Limine binary), this forms a chain: enrolled config hash -> file hashes in the config -> kernel and initramfs. That is why a
hand-written entry needs correct hashes, and why editing `limine.conf` requires a re-enroll. I confirmed the algorithm by hashing
the 7.2.9 `vmlinuz` with `b2sum` and getting exactly the value in the file. Look up: `limine enroll-config`, `b2sum`.

**Also worth knowing.** `default_entry: 2` is a position in the menu, so inserting an entry *above* it would silently change which
kernel boots by default; the new entry goes below the CachyOS block. `remember_last_entry: yes` means whichever entry you boot
last becomes the next default.

## 2026-10-15 (evening): START_STREAM experiment, results

**What changed.** Nothing in the code. I ran the experiment on the 7.2.0-1.7 kernel and read the three logs; findings section 11
has the table and conclusions. Along the way I fixed a bug in `scripts/test-isp4-threshold.sh` (a `lsmod | grep -q` under
`pipefail` skipped the module unload).

**Why it matters.** The hypothesis "START_STREAM is never sent because only 3 buffers arrive" did not reproduce, and the firmware
went quiet after its very first answer. A theory that looked complete in the handoff turned out to depend on a measurement that
was not repeatable.

**Concept to understand: you cannot tell "no answer" from "answer not read" from the log alone.** The ISP firmware writes responses
into a ring buffer in shared memory and raises an interrupt; the driver's response thread reads the ring when woken. If the interrupt
stops arriving, responses pile up unread and the log looks exactly like a silent firmware. The two cases differ in the ring's write
pointer versus the read pointer, which is what the next diagnostic would print. Look up: ring buffers (producer/consumer pointers),
interrupt-driven versus polled completion.

**What could go wrong.** Reading intent into the single reply (`seq 0`) is easy to get wrong; I only claim that it matches the first
command the host sent.

### Follow-up: ring-pointer diagnostic patch

**What changed.** Added `scratch/isp4-threshold/0010-isp4-ring-pointer-diagnostic.patch` (a function that logs the command/response
ring read and write pointers and the interrupt registers) and rebuilt the module. The test script now also saves its console output.
Not run yet. Findings section 12 has the table for reading the output.

**Why.** To tell "the firmware is silent" from "the firmware answered but the host did not read it", which the existing logs cannot.

**Concept to understand: a ring buffer is two pointers.** The producer advances the write pointer, the consumer advances the read
pointer, and they are equal when the ring is empty. So comparing the two answers "was anything produced that was not consumed?"
without needing the data. The diagnostic reads them without moving them, so it cannot disturb the thing it measures. Look up:
producer/consumer rings, memory-mapped I/O registers (`readl`), why debug code should not modify state.

**Decision recorded:** the SET_SENSOR_PROP layout work is deferred. If the firmware is silent right after the first command, the
more useful reverse engineering is the order of Windows' bring-up commands, not that one payload.

### Follow-up: ring-pointer diagnostic, results

**What changed.** Ran the diagnostic and read the results; no code changed. Findings sections 13 and 14 record them. I also decompiled
Windows' `isp_init_stream`, which gave the order of the bring-up commands, and corrected an earlier claim (`FUN_14004d65c` only logs).

**What the run showed.** The firmware reads every command (the command ring's read pointer catches up with the write pointer each
time) but wrote only one response in total (the response ring stays at one 64-byte entry). Interrupts are armed and nothing is pending.
So the host is not losing answers: the firmware is not giving them.

**Concept to understand: consumed is not answered.** A ring's read pointer moving only proves the consumer *looked at* the entry. Whether
it then acted and replied is separate, and here the second part never happens. When a debugging step cannot tell two failure modes
apart, find a measurement that can, as the pointers did; do not extend the theory first.

**Concept: replay without understanding.** Windows builds the sensor-property payload by calling the sensor plugin's `get_caps`. If that
function is a pure function of constants and a few inputs, its output can be reproduced by porting the function faithfully, with no need
to know what each field means. That is a much smaller task than "reverse engineer the format" and is how the next experiment can be
built.

**What could go wrong.** The leading explanation (the Linux firmware cannot create a stream for an unknown sensor) fits the evidence
but is unproven; the Linux firmware may not implement the sensor commands at all.

### Follow-up: firmware-log drain patch

**What changed.** Added `scratch/isp4-threshold/0011-isp4-fw-log-drain.patch` (a function that reads the firmware log ring's pointers
and prints its text on demand) and rebuilt the module. The test script now ends each run with the first 150 firmware-log lines. Not run
yet. Findings section 15 says how to read the output and when the replay of the Windows sensor setup becomes the next step.

**Why.** The driver only reads the firmware log when a response arrives, so text written after the firmware's last response was never
seen. This reads it on demand.

**Concept to understand: lazily-drained logs lose the interesting part.** A log that is only emptied as a side effect of some other
event misses everything that happens after that event stops. For debugging a stall, drain on a timer or at the failure point instead.
Look up: ring-buffer logs (like `dmesg` or `printk`'s own buffer), and why the *last* messages before a hang matter most.

**Note on style.** I changed the log lines from `dev_dbg` to `dev_info` in this experimental copy so they are visible without enabling
dynamic debug. That is fine for an experiment but would be noise in a real driver.

## 2026-10-15 (night): replay of the Windows sensor setup (patch 0012), built, not yet run

**What changed.** The firmware log was empty (`rd 0 wr 0`), so I went ahead with the replay you allowed. New: `scratch/build_sensor_prop.py`
(a port of the Windows `get_caps_OV13B` that produces the 360-byte `SET_SENSOR_PROP` payload), `--c-header` output in
`scratch/assemble_ov13b.py`, and patch `0012` which adds a module parameter `replay_sensor_setup`. When on, the driver sends
`SET_DEVICE_SCRIPT` and `SET_SENSOR_PROP` before `SET_STREAM_CONFIG`, one at a time, and logs `EXP-REPLAY: ... answered / NO ANSWER`.
`scripts/test-isp4-threshold.sh` got a `--replay` flag. Findings section 16 says how to read the result.

**Why.** Windows sends these commands and Linux does not. If the firmware needs a sensor description before it will create a stream,
that would explain why it reads our commands but never replies.

**Concept to understand: direct versus indirect commands.** The six commands Linux sends carry their data inside the 64-byte command
(*direct*). The two new ones are too big for that, so the data sits in a buffer the firmware can read and the command carries only
`{address lo, address hi, size, checksum}` (*indirect*). The same idea exists in many hardware interfaces (command queues pointing to
descriptors in memory; look up "DMA descriptor" and "doorbell").

**Concept: a synchronous command as a probe.** `isp4if_send_command_sync` waits for the firmware's reply. Using it here turns each
command into a yes/no measurement ("did the firmware understand this?") instead of fire-and-forget. A timeout is only logged, so a
negative answer does not stop the later steps from being observed.

**What could go wrong.** Everything in the payloads is a port of decompiled code and was never checked against real firmware. A `NO ANSWER`
therefore has two possible meanings: the Linux firmware does not know the command, or my payload is wrong. Section 16 lists the
assumptions. A bad address/size could also upset the ISP, so I send only after the memory pool is set up and never fail the bring-up.

### Result of the replay run

The firmware answered both new commands: the script with status 0 (success), the sensor properties with status 1 (fail). Commands after
that still got no response. Details: findings section 17.

**Concept to understand: "a reply arrived" is not "it worked".** My own log line said `answered (0)`, but the 0 was a Linux return code
(the wait completed), while the firmware's verdict is `cmd_status` in the response, which my line did not show. I only noticed by
reading the driver's own debug line. When you add a probe, make it print the thing you actually want to know, and read the
struct definition (`isp4fw_resp_cmd_done`, with its `cmd_status` and `isp4fw_error_code`) before trusting a summary line.

## 2026-10-15 (late): print the firmware's error code (patch 0013), built, not yet run

**What changed.** Patch `0013` (`isp4_subdev.c` only) adds one `dev_info` line, `EXP-RESP`, to the command-done handler. It prints the
command's sequence number, ID, `cmd_status`, `isp4fw_error_code` and the 36-byte response payload. The test script now shows these
lines. Run: `./scripts/test-isp4-threshold.sh --values "4" --replay`.

**Why.** `SET_SENSOR_PROP` came back with status 1 (fail), and the response struct has an error-code field that was never printed.

**Concept to understand: `%36ph`.** The kernel's printk has a format specifier for hex-dumping a small buffer (`%*ph`, up to 64 bytes,
space separated), so no loop is needed. The argument is the buffer pointer and the width is part of the format string.

## 2026-10-15 (late, 2): SET_SENSOR_PROP payload variants (patch 0014), built, not yet run

**What changed.** Patch `0014` (`isp4_interface.c` only) adds the module parameter `sensor_prop_variant`: 0 = payload as built, 1 = without the
8-byte prefix (352 bytes), 2 = sensor id 1, 3 = all zeros. The test script gained `--variants "0 1 2 3"` and now runs one capture per variant
(log names end in `-varN`). Run: `./scripts/test-isp4-threshold.sh --values "4" --replay --variants "0 1 2 3"`.

**Why.** The firmware rejected the property payload with error code 0x1b and the code values are not documented. Changing one thing at a
time and watching whether the code changes tells us which check, if any, the change affected.

**Concept to understand: black-box probing with a controlled variable.** Vary exactly one input per run and compare the single output you
trust (the error code). Variant 3 (zeros) is the control: it shows what the firmware says to garbage, so a different code for the real
payload means the firmware got further into it. Look up "differential testing" and "oracle" in the testing sense.

**What could go wrong.** I used `kmemdup` for a scratch copy of the payload so the original const array is never modified; if the
parameter is changed between module loads only the new value applies. Each run reloads the module, so runs do not influence each other.

## 2026-10-15 (late, 3): bogus command ID (patch 0015), built, not yet run

**What changed.** Patch `0015` (`isp4_interface.c` only) adds the module parameter `bogus_cmd`. When non-zero, the driver sends one more
command with that (invalid) ID, four zero parameter words, right after `SET_SENSOR_PROP`, and logs it. The test script has
`--bogus-cmd`. Run: `./scripts/test-isp4-threshold.sh --values "4" --replay --bogus-cmd 0x0badbad`.

**Why.** All four payload variants gave error 0x1b, so it is not a payload error. If an impossible command also returns 0x1b, then 0x1b
simply means "unsupported command" and the Linux firmware does not implement `SET_SENSOR_PROP`. If the code differs, 0x1b is specific.

**Concept to understand: negative control.** To interpret a failure code you need to know what a failure of a known kind looks like. A
command that is guaranteed to be invalid gives that baseline. Look up "negative control" (science) and "fuzzing" (testing).

**What could go wrong.** The firmware might ignore the unknown command and send no response (the sync call then times out after 0.5 s,
which is also a result), or in a worst case misbehave. The bring-up carries on either way.

## 2026-10-15 (night): test firmware images from the Windows ISP firmware (built, not loaded)

**What changed.** New `scratch/build_winfw.py`. It reads the stock Linux `isp_4_1_1.bin.zst` and the two Windows `.ram` firmware files (read
only) and writes `scratch/winfw/isp_4_1_1_srx.bin` and `isp_4_1_1_srx_h.bin`: the stock 0x100-byte header with three fields recomputed
(`size_bytes`, `ucode_size_bytes`, `crc32`) followed by the unchanged Windows bytes. Findings sections 21 and 22 have the details.

**Why.** To test, without changing the driver, whether the firmware Windows uses understands the OV13B sensor commands that the Linux
firmware refuses.

**Concept to understand: a container format versus its payload.** The signature that the PSP checks protects the payload (`$PS1` blob);
the small `common_firmware_header` in front is only bookkeeping for the Linux kernel (sizes, checksum). Because the payload is byte-for-byte
the Windows one, we change nothing that is signed. Look up "firmware header" in `amdgpu_ucode.h`, and CRC32 (`zlib.crc32`).

**Concept: reproduce the rule before using it.** I first checked on the stock image that my crc32 definition gives exactly the stored value
(it does), and only then computed new values. Otherwise a wrong rule would silently produce plausible-looking numbers.

**What could go wrong.** The PSP may reject the image (signature, version or chip mismatch), then the ISP does not start; which of the two
Windows variants fits is a guess to be tested. Keep a boot entry with the stock firmware, and do not redistribute these files.

## 2026-10-15 (night, 2): deploy and restore scripts for the test firmware (written; /boot part not run)

**What changed.** `scripts/deploy-windows-isp-fw-test.sh` packs each test image into a tiny cpio archive and appends it to a *copy* of the
1.7 initramfs (`/boot/camera-test/initramfs-fw-<variant>.img`), then prints one Limine entry per variant. `--build-only` stops before
anything outside the project. `scripts/restore-stock-isp-fw.sh` verifies the stock firmware is intact and prints the removal commands
(it deletes nothing). Findings section 23 has the reasoning.

**Why I deviated from "option 2".** I checked `mkinitcpio`: it only scans `/usr/lib/firmware/updates` and `/usr/lib/firmware`, not a
per-kernel subdirectory, and the shared `updates/` would affect every later initramfs rebuild. The cpio gives the same result you
wanted (only the test entry sees the image) without touching the system tree.

**Concept to understand: concatenated initramfs archives.** The kernel's initramfs is "one or more cpio archives, compressed or not,
glued together", unpacked in order into the same in-memory root. This is how CPU microcode is delivered early. Look up
`Documentation/driver-api/early-userspace/buffer-format.rst`, and `firmware_class` search order (`/lib/firmware/updates` first).

**What could go wrong.** The loader might still use the stock copy (then the ISP version is unchanged, which the check commands in the
deploy output reveal), or the PSP may reject the image. Neither touches the filesystem. A wrong Limine hash only makes the entry fail to boot.

### Follow-up: the first firmware deployment did not take effect

**What happened.** The srx_h boot looked identical to stock, and the loader log (enabled with `dyndbg=`) showed the stock file and hash. The
boot log had "Initramfs unpacking failed: invalid magic at start of compressed archive": the kernel rejected the plain cpio I had appended
after the compressed initramfs. I changed `scripts/deploy-windows-isp-fw-test.sh` to put the firmware cpio first and to print entries
with the `dyndbg=` option (findings section 26).

**Concept to understand: order in a multi-archive initramfs.** Uncompressed cpio first, compressed archive after (that is how early CPU
microcode works); the reverse fails. My earlier claim that the kernel "handles mixed segments in any order" was wrong; I had marked it
unverified, which is why the boot-log check mattered.

**Concept: verify the intervention before reading the experiment.** The experiment result was real but meaningless, because the thing
we changed never reached the system. The loader's own log (path and sha256) is the check to do first every time.

## 2026-10-15 (late night): the Windows firmware accepts the sensor setup; START_STREAM now fails for missing tuning data

**What changed.** Nothing in the code; the boot entry now really loads the Windows `srx_h` firmware (verified by the loader's path and
sha256). Findings section 27 has the table and the evidence.

**Result.** With that firmware every command up to `START_STREAM` is answered with success, including the two sensor commands that the
Linux firmware refused. The firmware also prints a readable log. It says `START_STREAM` fails because the host never delivered
"setfile" (tuning) buffers: the pipeline cannot be configured without them.

**Concept to understand: a firmware's own log beats guessing from error codes.** Error 0x27 alone meant nothing; the log line next to it
names the missing resource. That is why getting the log working (it is empty on the Linux firmware) was worth the detour. Also:
tuning data / "setfile" in an ISP is the table of image-quality parameters (noise, shading, colour) for one specific sensor module;
without it the pipeline will not start.

**What I got wrong earlier.** For a long time I assumed the payload was the problem; the control experiments (a zero payload gives the
same error code) pointed the right way: the firmware, not my data. And a first "null result" from the wrong firmware nearly sent me
back to payload work. Check that the intervention reached the system before interpreting the experiment.

## 2026-10-16: decoding the tuning-data sender in amdcamera.sys (read-only analysis)

**What changed.** No code. Findings section 28 documents how Windows loads `OV13B_3001_ROG_SRX.atb` once (a 3 MB pool buffer, path built
from three plugin strings) and sends it with command 0x2050008 as a 12-word parameter block {buffer type 14, 0, 4, GPU address, size,
second blob address and size}, copying the data into a firmware-visible buffer first.

**Method worth remembering.** Start from the strings (function-name strings used for logging, such as `isp_set_calib_2_fw`), follow their
cross-references to the function, then read the stack variables of the command payload to get the word layout. The firmware log from the
last run gave the matching clue ("queue empty: type=14"), so two independent sources agree on the buffer type.

**Concept to understand: out-of-band data versus inline parameters.** A command can carry its data inside the 64-byte message (the
tuning command carries only an address and sizes) or point at a buffer in shared memory (the data itself). Both appear here; the sizes
and the address are the "descriptor", the 566 KB file is the "payload".

**What could go wrong.** Word 2 (value 4) and the buffer type are inferred from one decompile and one log line; if START_STREAM still
fails after the replay, they are the first suspects, along with the order relative to `SET_SENSOR_PROP`.

## 2026-10-16 (later): tuning-file replay patch 0016 (built, not yet run)

**What changed.** Patch `0016` (`isp4_interface.c` only) adds the module parameter `tuning_file`. With it set (and `replay_sensor_setup=1`)
the driver reads the file, copies it into a 3 MB GPU buffer and sends `SET_TUNING_DATA` with the 12-word block decoded from Windows.
`scripts/test-isp4-threshold.sh` gained `--tuning-file PATH`. Findings section 29 says how to read the result.

**Why a path instead of an embedded array.** The earlier payloads were generated headers. The tuning file is 566 KB of Windows data, so
the module reads it at load time from the Windows partition: no Windows data in the sources or patches.

**Concept to understand: `kernel_read_file_from_path`.** The kernel reads a file itself, for example firmware, without going through
userspace; the last argument says what kind of file it is so security modules can allow or refuse it (`READING_FIRMWARE`). Look up
`request_firmware()` for the normal route; this one skips the firmware search path, which is why a plain absolute path works.

**What could go wrong.** The buffer must outlive the command (the firmware may use it during `START_STREAM`), so it is kept in a static
pointer and freed with the other firmware buffers. If the Windows partition is not mounted when the module loads, the read fails and the
log says so.

## 2026-10-16 (night): tuning data accepted; the next blocker is the memory pool size

**What changed.** No code. Findings section 30. With `--tuning-file`, `SET_TUNING_DATA` returns success and the "setfile" errors vanish, so the
decode from the Windows driver was right. `START_STREAM` still fails, now because the firmware cannot allocate its internal raw/temporary
frame buffers: its log says "MEM|no buffer found". Windows hands the firmware a 200 MiB memory pool; Linux hands it 100 MiB.

**Concept to understand: each fix moves the failure one step later.** Read the first error line that changed, not the status code (which
stayed 0x27 across three different causes). The same error code is a bucket; the log text is the cause. This is why the firmware log was
the thing to get working.

**Concept: sizing a pool for the worst case.** A driver written for a 5 MP sensor sized the firmware's scratch memory for that; a 13 MP
RAW frame needs several times more per buffer. Allocating "twice as much" is a hypothesis, not a fix, until the log stops complaining.

**What could go wrong.** A 200 MiB GTT allocation is large; it is what Windows does, but it competes with graphics memory. And the pool may
not be the only missing buffer (Windows also allocates per-purpose work buffers).

## 2026-10-16 (night, 2): pool-size parameter (patch 0017) and which firmware image Windows picks

**What changed.** Patch `0017` (`isp4_interface.c`) adds `fw_mem_pool_mb`; the test script has `--pool-mb`. Default behaviour is unchanged
(100 MiB). Findings section 31.

**The srx question.** The Windows driver selects `srx_h_isp_firmware_signed.ram` when a hardware-variant byte equals 4 and
`srx_isp_firmware_signed.ram` otherwise. The "_h" most likely means Strix Halo, which this laptop has, so `srx_h` (the one we are
using) is the expected match; the `srx` entry is a fallback, not a likely improvement. I did not read the byte's real value; it is an
inference from the names.

**Concept to understand: module parameters as experiment knobs.** Each experiment so far added one parameter with a safe default
(`min_start_bufs`, `replay_sensor_setup`, `tuning_file`, `fw_mem_pool_mb`). That keeps every change reversible by reloading the module
and lets one script vary one thing per run, which is what made the failure chain readable.

**What could go wrong.** 200 MiB is a large allocation (it is what Windows does). If the allocation fails, the module prints an error
and the ISP does not start; reload without the option to recover.

## 2026-10-16 (late night): START_STREAM succeeds; the sensor itself is the last missing piece

**What changed.** No code. Findings section 32. With the Windows firmware, the replayed sensor setup, the tuning file and a 200 MiB memory pool,
every command up to and including `START_STREAM` succeeds. The firmware arms its MIPI/CSIS receiver and waits, then times out with
"frame done timeout" and counters at zero: no data arrives, because nothing starts the sensor.

**Concept to understand: the camera pipeline has two independent halves.** The ISP (receiver plus image pipeline, controlled by firmware)
and the sensor (a separate chip on the I2C bus, controlled by its own driver, here `ov13b10`). The Windows driver coordinates both; the
Linux ISP driver only knows the first half. Everything we have done so far configured the ISP half; the second half is now what is
missing. Look up "V4L2 async subdev", "media controller" and "CSI-2 receiver" for how the usual bridge-and-sensor pairing is wired.

**Why there is no /dev/v4l-subdev.** A sensor subdev only becomes usable from userspace when a bridge driver has registered it
into a media graph. Here no bridge does, so the next experiment has to start the sensor from inside the kernel.

**What could go wrong.** Starting the sensor with the upstream mode tables may not match the lane count and link rate the ISP receiver
expects; the Windows tables are a reference if the first attempt shows receiver errors instead of silence.

## 2026-10-16 (night, 3): start_sensor patch 0018 (built, not yet run)

**What changed.** Patch `0018` (`isp4_subdev.c` only) adds the module parameter `start_sensor`. The ISP driver now finds the `ov13b10` I2C client on the
ISP's own bus and calls the sensor driver's `s_stream` itself, right after (1) or before (2) `START_STREAM`, and stops it at teardown. The test
script has `--start-sensor N` and prints the sensor log lines and how many frame-start/done events the firmware saw. Findings section 33.

**Concept to understand: calling another driver through its ops table.** `v4l2_subdev_call(sd, video, s_stream, 1)` does not need to link against the sensor
module: it goes through `sd->ops->video->s_stream`, a function-pointer table the sensor driver filled in. The subdev pointer comes from the I2C client's
driver data (`i2c_get_clientdata`), which `v4l2_i2c_subdev_init` set. `bus_find_device_by_name` takes a device reference (balanced with `put_device`).

**Why two start orders.** A CSI-2 receiver is normally ready before the sensor sends; mode 1 (after) matches that. Mode 2 exists in case the firmware wants the
sensor already running when it arms the receiver. We learn which from the firmware's frame/timeout lines.

**What could go wrong.** The sensor may not be powered (dummy regulators at probe), or its mode tables may not match what the ISP expects (lanes, link rate).
The log of the sensor's chip-ID read in `s_stream` separates those two cases.

## 2026-10-16 (night, 4): the sensor start fails with EIO at its first register write

**What changed.** No code. Findings section 34. `start_sensor=1` found the sensor (client `21-0010`) and called its `s_stream`; the sensor driver
reported "failed to set powerup registers" and returned -5. So the experiment reached the right place; the sensor's I2C write failed.

**Concept to understand: error masking.** The driver turns any I2C failure into `-EIO`. The real reason (device not answering, bus timeout,
arbitration) is in the return value of `i2c_master_send`, which the driver throws away. When a layer hides the cause, add a probe one level
lower (here: do the raw transfer yourself and print its errno) rather than guessing.

**Concept: who owns the bus?** The sensor sits on an I2C controller inside the ISP block (bus 21). The ISP firmware also talks to the sensor over I2C
(its device script contains register-access instructions). Two masters on one bus, or a bus gated by the ISP's power state, are the first things to rule
out. A userspace read with `i2ctransfer` while the ISP is idle is a clean baseline.

**What could go wrong.** Writing to the sensor from userspace is not dangerous (a soft reset at most), but keep it to the chip-ID read first.

## 2026-10-16 (night, 5): raw I2C probe patch 0019 (built, not yet run)

**What changed.** Patch `0019` (`isp4_subdev.c` only): with `start_sensor` set, the driver now does a raw chip-ID read and a harmless write on the
sensor's I2C adapter before calling `s_stream`, and logs the real return values (`EXP-SENSOR: raw I2C ...`). Findings section 35.

**Why `i2ctransfer` said "busy".** An I2C address claimed by a kernel driver cannot be opened from userspace unless forced with `-f`. The error was
about ownership, not hardware; reading only is the safe way to use `-f`.

**Concept to understand: `i2c_transfer` return values.** It returns how many messages were processed, or a negative errno. A chip-ID read is two messages
(write the register address, read the bytes), so success is 2; a plain write is 1. `-ENXIO` means nothing acknowledged the address, `-ETIMEDOUT` the bus
hung. This is the information `ov13b10` hides behind `-EIO`.

**What could go wrong.** The write goes to register 0x0100 (standby); it cannot start streaming. If the sensor were powered off it would just fail.

## 2026-10-16 (night, 6): the sensor does not answer on I2C at all (not powered)

**What changed.** New `scripts/dump-acpi-tables.sh` (not run yet) to dump and decompile the machine's ACPI tables into `scratch/acpi/`. Findings section 36.

**Result.** The raw I2C probe from patch 0019 got `-121` (-EREMOTEIO, no acknowledge) for both the chip-ID read and the write, before and after `s_stream`,
in both start orders, and the userspace read with the ISP idle fails the same way. So the sensor is not powered or not enabled; neither the ISP firmware nor
the start order is the issue.

**Concept to understand: ACPI describes board wiring.** On x86 laptops, which GPIO pin switches a sensor's power rail, which pin resets it, and what clock it
needs is written in the firmware tables (DSDT/SSDT) as device methods (`_PS0`, `_ON`, `_DSM`), `GpioIo` resources and power resources. Linux drivers
normally get this through the ACPI core; here the sensor driver (`ov13b10`) asks for regulators/GPIOs that nobody provides. `iasl -d` turns the binary tables
into readable ASL.

**Concept: eliminate before you build.** The raw probe separated three possible causes (bus conflict, timing, no power) with one run. Only "no power" survived,
so the next work is about power, not about the ISP firmware.

**What could go wrong.** Driving GPIOs that control rails can matter electrically; the safest source of truth is the machine's own ACPI methods (which Windows also uses), not guesses.

## 2026-10-16 (night, 7): correction. The pins were found earlier; the sensor lost its power after probe

**What happened.** I concluded the sensor "has nothing powering it" without first checking the project's earlier work. You remembered correctly: patches 0003/0005 map the ISP's own GPIO 0 (`amdisp-pinctrl`) as
the sensor's reset/enable line, and the sensor identified and bound at boot. Findings section 37 documents the earlier work and corrects section 36.

**Lesson (mine).** Before building a theory on "X is missing", search the repo and its handoff notes for earlier work on X. Here that was one `grep` in `handoff.md`.

**Concept to understand: power-gated blocks forget their state.** The pin that enables the sensor lives inside the ISP block. When the block is power-gated and powered up again, its registers return to defaults.
A driver that tracks "I powered the device" with a software flag (runtime-PM `active`) cannot know that the hardware lost power underneath it. The classic fix is to make the state change visible to the driver
(a runtime suspend/resume cycle, or a notifier), not to assume. Look up "runtime PM", "generic PM domain (genpd)" and "state restore after power gating".

**What could go wrong.** The theory is unproven: the pin state could also be changed by the ISP firmware. The proposed test (a forced runtime-PM cycle of the sensor) separates the two.

## 2026-10-16 (night, 8): sensor runtime-PM cycle, patch 0020 (built, not yet run)

**What changed.** Patch `0020` (`isp4_subdev.c` only): `sensor_pm_cycle=1` forces the `ov13b10` through `pm_runtime_force_suspend()` and `pm_runtime_force_resume()` once the ISP is up, with a raw I2C
chip-ID probe before and after, then starts the sensor as before. Test script option `--sensor-pm-cycle`. Findings section 38.

**Why this API.** The sensor driver already knows how to power itself off and on (`ov13b10_power_off`/`power_on` drive the clock, regulators and the reset GPIO). Calling its runtime-PM callbacks from the
outside is the smallest way to make it re-drive the pin, without touching the pin controller from my own code.

**Concept to understand: `pm_runtime_force_suspend/resume`.** They run the driver's runtime callbacks regardless of the device's current usage state (they are meant for system sleep) and temporarily disable
runtime PM, so nothing else races with the cycle. Alternatives I rejected: toggling the GPIO myself (the pin belongs to the sensor driver, it would conflict); unbinding and rebinding the driver (a heavier change, and
it re-registers the subdev).

**What could go wrong.** If the pin loses its state for another reason (for example the ISP firmware resets it during boot), the cycle may help only partly. The before/after probe shows exactly which.

## 2026-10-16 (night, 9): the sensor starts after a power cycle; the CSI-2 receiver still sees nothing

**What changed.** No code. Findings section 39. The forced runtime-PM cycle worked in a way I did not expect: it left the sensor suspended, and the following `s_stream` then did a real
power-on and the chip finally answered, so `s_stream(1)` returned 0 for the first time. This confirms the theory that the sensor's enable pin was lost while the driver thought the sensor was on.

**Concept to understand: why my two "after" probes still failed.** `pm_runtime_force_resume()` does not always wake the device; devices flagged "smart suspend" stay suspended until something
asks for them. The probe I put between the cycle and `s_stream` therefore looked at a sleeping chip. The result was still conclusive because `s_stream` itself asks for power. Reading the
"runtime-active 0" in the same log line was what explained it.

**Next concept: the receiver PHY.** A MIPI CSI-2 link has a physical layer (D-PHY) on the receiving chip that must be configured for lane count and data rate and calibrated before it can lock onto the sensor's
signal. The Windows driver ships its own Synopsys PHY code, the Linux ISP4 driver ships none. If the PHY is not brought up, the sensor can stream happily and the receiver reports zero frame starts, which is exactly what the firmware counters show.

**What could go wrong.** The firmware may well initialise the PHY itself; the log does not say. The lead is a hypothesis built from names in the Windows binary.

## 2026-10-16 (night, 10): start order is not the issue; the PHY decode is next

**What changed.** No code. Findings section 40. Starting the sensor before `START_STREAM` (mode 2) gives the same result as after it (mode 1): the sensor starts, the receiver reports no frame start. So the missing piece is the
link between sensor and receiver, not the order of the two start-ups.

**Concept to understand: eliminate variables one at a time.** We have now ruled out, in order: firmware without sensor support, missing sensor/tuning data, too little scratch memory, sensor without power, and the start order. Each experiment
changed one thing and kept a log that shows exactly where the pipeline stops. What remains is the receiver PHY (or the sensor's actual output).

**Method for the next step.** The Windows driver names its PHY functions in log strings (`phx_start_internal_synopsys_phy`, `startup_seq_cdphy_rx`, `reset_sensor_phy`); following their cross-references gives two small clusters of code to decode.
The register layout of a Synopsys D-PHY is public in many Linux drivers, which helps in checking the decoded values for plausibility.

**What could go wrong.** The PHY may already be initialised by the firmware, in which case the problem is elsewhere (for example a sensor mode that the pipeline does not expect). The firmware log will keep saying "0 frame starts" in both cases.

## 2026-10-16 (night, 11): decoding the Windows MIPI D-PHY bring-up (read-only analysis)

**What changed.** No kernel code. New helper `scratch/decode_phy.py` (a throwaway parser that condenses a Ghidra dump of the PHY setup function into one line per register write). Findings section 41 has the whole decoded sequence.

**What I found.** For Strix variants, the Windows driver itself starts the CSI-2 receiver's D-PHY (controller registers at `0x66700`, indirect PHY registers through a port at +0x24/+0x28) before the stream starts: reset pulse, lane masks,
about 330 analog register fields (calibration, settle times, pin swap) that depend on the lane data rate, then enable and wait for "PHY ready" and lane stop-state. The inputs are exactly fields I had already ported into the sensor properties
(rate = 1120 Mbps, lanes = 4).

**Concept to understand: read-modify-write of a field.** Most PHY registers pack several unrelated fields; changing one means reading the register, clearing the field's mask, inserting the new value shifted to the field's position, and writing back.
The Windows helper does exactly that from a descriptor (register, mask, value). The same pattern appears in Linux as `FIELD_PREP`/`regmap_update_bits`.

**Concept: a hardware variant byte decides the path.** One driver binary supports several chips; branches on a variant byte (`dev+0x17f4`) pick the matching code (Phoenix `phx_` versus Strix). I first decoded the Phoenix function by name and only then checked its caller; the caller showed
that our chip takes the other path. Always check who calls a function and under which condition before porting it.

**What could go wrong.** Replaying a PHY configuration the firmware also programs could conflict with it. The PHY has no effect on the sensor and is unlikely to be harmful, but the plan is to run it only behind an opt-in module parameter.

## 2026-10-16 (night, 12): PHY generator and `phy_init` patch 0021 (built, not yet run)

**What changed.** New `scratch/build_phy_seq.py` (evaluates the Windows PHY analog setup for one case and writes `scratch/isp4-threshold/isp4_phy_seq.h`) and patch `0021`: module parameter `phy_init`, an `isp4if_phy_init()` function, and a call from the
sensor start helper. Test script option `--phy-init`. Findings section 42.

**Why a generator instead of porting by hand.** The Windows code computes about 330 register fields with floating-point maths and branches on the data rate. The kernel cannot use floating point, and transcribing 800 lines by hand invites typos. The script reads the
tables straight from the binary, evaluates the single branch path for our case (1120 Mbps, 4 lanes, phy 0) and emits plain numbers. The kernel code then only walks a list.

**Concept to understand: `ceil` and `floor` hidden behind unnamed functions.** The decompiler showed `FUN_140097ee0(x)` and `FUN_140098000(x)`. I read their assembly (clear the fraction bits, add or subtract 1.0 depending on the sign) to be sure they are `ceil` and
`floor` before relying on them. When a tool gives a generic name, check the behaviour once; a wrong guess here would shift every timing value silently.

**Concept: runtime-PM reference across a sequence.** The sensor must be powered while the receiver's PHY comes up and while the sensor is started. Taking a runtime-PM reference (`pm_runtime_resume_and_get`) before and releasing it (`pm_runtime_put`) after keeps the device on for exactly that window.

**What could go wrong.** The PHY registers might not respond in the ISP's current power state, or the firmware may reconfigure the receiver when `START_STREAM` runs and undo this. The log line "before" shows whether the registers read back sensible values.

## Task: PHY start froze the machine's capture run (unmapped MMIO offset)

**What changed:** `isp4if_phy_init()` in `scratch/isp4-threshold/isp4_interface.c` now maps its own register window (`ioremap` of ISP offsets 0x66000-0x67fff) instead of adding Windows' offsets to `ispif->mmio`. Patch 0021 was regenerated; findings section 43 records the incident.

**Why:** the first version did `readl(ispif->mmio + 0x66108)`. That mapping only spans the driver's platform resource (0x0-0x629a4), so the address was in unmapped kernel virtual space and the CPU took a page fault inside `isp4if_phy_init` (an Oops). The process died, v4l2-ctl hung, and the module stayed "in use" until reboot.

**Concept to understand: an MMIO pointer is only valid inside what you mapped.** `readl()`/`writel()` do no bounds check; they just access `base + offset`. A driver's `ioremap`/`devm_ioremap_resource` covers exactly one resource (see `platform_get_resource()` and `/proc/iomem`). Offsets that are valid in another driver's or OS's address scheme (here: Windows) must be checked against the resources THIS driver owns. Related things to look up: `ioremap` vs `devm_ioremap_resource` (the latter also claims the region and fails on overlap, which is why a second mapping of a range already claimed by a sibling device uses plain `ioremap`), and reading the Oops "RIP: function+offset" line to find the faulting spot.

## Task: reading the first run with a host-started MIPI D-PHY

**What changed:** nothing in code; findings section 44 records the result of the `--phy-init` run.

**Why it matters:** the PHY reported ready with lane stop-state, and the firmware's MIPI0 receiver started reporting `Error protocol` and `2-bit ecc error`, where earlier runs had only a frame-done timeout. So the lanes now carry high-speed data, and the problem moved from "no signal" to "signal that is not decoded correctly".

**Concept to understand: CSI-2 packet header ECC.** Every CSI-2 packet starts with a 4-byte header protected by a Hamming-style ECC. The receiver corrects 1-bit errors and flags 2-bit errors. A 2-bit ECC error usually means the receiver is sampling at the wrong moment or the wrong rate, or started listening in the middle of a packet. That is why the D-PHY lane rate / HS settle timing, and the order of "receiver enabled" versus "sensor starts streaming", are the first suspects.

## Task: patch 0022, read-only D-PHY snapshots

**What changed:** `isp4if_phy_diag()` (isp4_interface.c) reads the D-PHY controller registers and the lane stop-state; `isp4sd_exp_sensor_start()` (isp4_subdev.c) calls it right after the sensor starts, then 100 ms and 1 s later.

**Why:** the firmware log cannot distinguish a silent sensor from a receiver that mis-decodes. The lane state at the D-PHY can.

**Concept to understand: MIPI D-PHY lane states.** An idle D-PHY lane sits in the low-power "stop state" LP-11 (both wires high). A transmitter leaves it with a fixed LP sequence (LP-01, LP-00) and then drives high-speed (HS) differential data; at the end it returns to LP-11. So a lane status that leaves stop state and later returns tells you the sensor transmitted a burst, and one that never leaves tells you nothing was sent. Also: a status register can be "clear-on-read", so merely observing it can change what you see (an observer effect); that is why such reads are logged in a few fixed snapshots rather than polled.

## Task: reading the 0022 snapshots and the unexpected LED

**What changed:** nothing in code; findings section 47.

**Why it matters:** the lane state left LP-11 within 100 ms of the sensor starting and stayed out, so the sensor transmits and the receiver mis-decodes (repeating 2-bit ECC errors); the sensor is not simply off.

**Concept to understand: an inferred pin is a hypothesis, not a fact.** The GPIO lines my earlier patches drive were chosen by analogy with a reference platform. When hardware reacts unexpectedly (here: a front-camera LED/flash lighting up) the first thing to re-check is that mapping, using a primary source: the ACPI tables (`_CRS` GpioIo resources, `_DSM`, power resources) say which pin of which controller each device owns. Related terms: ACPI `GpioIo()` resource, `_PS0`/`_PS3`, `iasl` (the ACPI decompiler).

## Task: reading the ACPI tables for the camera pins

**What changed:** `scripts/decompile-dsdt-skip-ssdt6.sh` (new) decompiles the DSDT alone; findings section 48 records what ACPI says about `\_SB.CAMB`.

**Why:** the front-camera LED lighting during the tests raised the question whether the GPIO lines we drive are the right ones. ACPI is the platform's own description of device resources.

**Concept to understand: ACPI describes what the firmware chose to describe.** A device's `_CRS` lists its memory, interrupts, I2C connections and `GpioIo()` pins; `_PS0`/`_PS3` and power resources describe on/off sequences; `_DSM` returns vendor data by function number. Here `CAMB` has only `_PLD` (panel = BACK, so it is the rear camera) and a `_DSM`, so the sensor's power and reset wiring is not in ACPI; on this platform it lives in the ISP's own GPIO block, which only the Windows driver (and the ISP firmware) know. Also: `iasl -d` of a DSDT can fail when an SSDT redefines a name the DSDT has (`AE_ALREADY_EXISTS`); decompiling it alone avoids that at the cost of `External()` declarations.

## Task: Windows decode of the camera pin / LED code

**What changed:** nothing in code; findings section 49.

**Why:** to learn which GPIO lines Windows toggles for the OV13B, and whether the host driver drives an LED.

**Concept to understand: layered Windows driver stacks hide the hardware access.** `amdcamera.sys` (camera class driver) calls an interface table; `sensorOV13B.sys` is only a data/plugin table of sensor parameters; `amdisp.sys` is a thin bridge that forwards requests; the actual power/GPIO register access sits in the display driver. Following a name string to its `xrefs` shows where it is logged, not always where the work is done. A stub like `led_write` returning `STATUS_NOT_SUPPORTED` (0xC00000BB) is a useful negative result: that code path is not how the LED is driven. Related terms: WDF, `IofCallDriver`, device interface / function table, `xrefs` in Ghidra.

## Task: finding which code switches the front-camera LED

**What changed:** nothing in code; findings section 50 records the code review.

**Why:** the LED lit even without the PHY experiment, so the cause had to be older or in the stock path.

**Concept to understand: `gpiod` lookup tables bind a name to a physical pin.** The driver asks for the GPIO named `"enable_isp"` with `devm_gpiod_get()`; a `gpiod_lookup_table` registered by the platform code (here `GPIO_LOOKUP("AMDI0030:00", 85, "enable_isp", ...)`) says which chip and pin that name means. The driver then calls `gpiod_set_value()` on every open and close. If the lookup table is wrong for a board, correct-looking driver code toggles the wrong hardware. The fix is always on the table side (which pin), not in the consumer. Related terms: `gpiod_add_lookup_table`, `GPIOD_OUT_LOW`, active-high/active-low, `/sys/kernel/debug/gpio`.

## Task: patch 0023, a switch to stop driving the enable_isp GPIO

**What changed:** `skip_enable_gpio` module parameter in `isp4_subdev.c`, `--skip-enable-gpio` option in `scripts/test-isp4-threshold.sh`.

**Why:** to find out whether the front-camera LED follows the `enable_isp` pin and whether the ISP needs that pin at all.

**Concept to understand: make the experiment reversible with a module parameter.** `module_param(name, bool, 0444)` exposes a load-time switch (and a read-only entry under `/sys/module/<module>/parameters/`) so one binary can run both variants and results are comparable. `dev_info_once()` logs a message a single time even if the function runs many times. When a request returns early, the earlier setup (`devm_gpiod_get(..., GPIOD_OUT_LOW)`) still defines the line's resting state, here low.

## Task: patch 0024, reading the ISP's sensor-control pins

**What changed:** `isp4_interface.c` maps the three ISP sensor-control pin registers once in `isp4if_init()` and prints them in every `EXP-RING` snapshot.

**Why:** pin 85 was cleared as the LED source, and the ISP has three sensor-control outputs while Linux only drives the first. Reading their state while the light is on shows which one is high, without changing anything.

**Concept to understand: map once in a sleepable context, read anywhere.** `ioremap()`/`devm_ioremap()` may sleep, so it must not run in atomic context (spinlock held, IRQ handler). The pattern is to create the mapping during `probe`/`init` and store the pointer; later `readl()` is safe in any context. `devm_ioremap()` ties the unmap to the device's lifetime. It does not claim the memory region, which matters here because the pin controller already owns a resource over the same addresses. Also: a register that is "output-only" (as in `pinctrl-amdisp.c`) can still be read back to see the last driven value.

## Task: reading the ISP pin dump, and a power-only test

**What changed:** nothing in code; findings section 55.

**Why:** the three ISP sensor-control outputs stayed low while the light was on, so they are not the cause; the next thing to separate is the power-up itself from the firmware and the streaming path.

**Concept to understand: generic power domains (genpd) and runtime PM.** A driver that has no `runtime_suspend`/`runtime_resume` callbacks still takes part in power management: when a device is attached to a power domain, `pm_runtime_resume_and_get(dev)` makes the domain run its `power_on` hook (here `isp_poweron()`, an SMU message). `/sys/.../power/control` set to `on` forces the device active (resumes it and prevents autosuspend) and `auto` hands control back to the kernel; `runtime_status` shows `active`, `suspended` or `unsupported`. This lets you test "is the hardware power-up alone enough?" with no driver code at all.

## Task: correlating the LED with the teardown, and a passive watcher

**What changed:** new `scripts/watch-video-users.sh`; findings section 56.

**Why:** the light follows the close of the capture node and outlasts the ISP power-off, and the "front camera" is a separate USB device, so a user-space reaction is now a serious candidate.

**Concept to understand: observe before you instrument.** When two components (here the ISP driver and a USB webcam) seem related, first check whether anything outside your code links them. `v4l2-ctl --list-devices` shows which driver owns which node; `fuser`/`lsof` shows which process has a device open (they read `/proc`, they do not open the device); PipeWire/WirePlumber's V4L2 monitor opens video nodes on udev events. A polling log with millisecond timestamps (only printing when the state changes) can be lined up against what you see, and against the kernel journal, without changing the system under test.

## Task: comparing the Windows and Linux sensor tables, and the temporary sudo rule

**What changed:** `scratch/diff_ov13b_tables.py` (register-table diff), findings section 58; `scripts/sudoers-grant-camera-tests.sh` and `scripts/sudoers-revoke-camera-tests.sh` (narrow, temporary sudo rule for the test script, written for you to run), and two small changes in `scripts/test-isp4-threshold.sh` so it works with such a rule (`sudo -n -l` check, `tee` instead of `sh -c`).

**Why:** the receiver sees corrupt packet headers although the PHY is up, and the register table Windows writes differs from Linux's exactly in the PLL registers.

**Concept to understand: a sensor PLL turns the input clock into the CSI-2 lane rate.** lane rate = (input clock x multiplier) / divider, so the same register values mean different bit rates for a different input clock. The Linux driver assumes 19.2 MHz (`OV13B10_EXT_CLK`) and checks that the clock framework reports it; here the number came from a software node I wrote, so the check only verifies my own placeholder. A receiver configured for 1120 Mbps cannot decode a 1400 Mbps stream: the symptom is header ECC errors, not "no signal".
**And for the sudoers scripts:** a sudoers rule can name exact commands and arguments (`/usr/bin/insmod /path/file.ko *`); files in `/etc/sudoers.d` whose name contains a dot are ignored, which is used here so a half-written file can never be active; `visudo -cf FILE` validates a rule before it is installed. Even a narrow rule that allows `insmod` of a file you can rebuild is, in effect, root, which is why it is temporary.

## Task: the freeze after the PLL experiment

**What changed:** nothing in code; findings section 59 (result + incident).

**What happened:** with the Windows PLL values the CSI-2 link decoded for the first time, and the data reached the ISP's MIPI write DMA, which overflowed. The firmware could not stop the stream, the driver then asked the SMU to power the ISP off, and the SMU (the SoC's power-management firmware, shared by GPU, display, video engine and ISP) never answered again. Without it the display failed and the machine froze.

**Concept to understand: shared firmware is a single point of failure.** Many SoC blocks are powered through one management controller via a mailbox (message register, argument, response register). If one request never completes (here: power-gating a block that is still busy), the mailbox stays occupied and every other driver's requests time out (`SMU: No response`). That is why an ISP experiment can freeze the display: they share the SMU. Safe teardown order matters: stop the data source, let DMA drain, then power off.

## Task: finding why the ISP's write DMA overflows (memory stutter / MMHUB power gating)

**What changed:** nothing in code; findings section 60 (correction of 59 and the new lead). New local directory `scratch/disasm/` with a disassembly of the Windows `amdcamera.sys` (Windows-derived: keep it local).

**Why:** once the sensor's PLL was right, the data reached the ISP's MIPI write DMA, which overflowed its latency buffer, and the firmware hung. Windows has a step Linux lacks: before streaming large images it asks the SMU to switch the ISP's memory path out of its power-saving modes.

**Concept to understand: real-time DMA versus memory power saving.** SoCs save power by letting the memory path sleep between bursts ("stutter") and by power-gating hubs such as the MMHUB. A camera receiver cannot pause the sensor: every line must be written to memory within a fixed time, buffered only by a small "latency buffer". If waking the memory path takes longer than that buffer lasts, it overflows. The SMU interface even names the switch (`PPSMC_Message_IspStutterOn_MmhubPgDis`). Reading a stripped Windows driver works by following its log strings: each function logs its own name, so `llvm-objdump` plus the PE section table (virtual address -> file offset) is enough to name functions without a decompiler.

## Task: building a patched amdgpu.ko out of tree

**What changed:** `scratch/kernel-patches/0009-drm-amdgpu-isp-memory-stutter.patch`; `scripts/build-amdgpu-oot.sh`, `scripts/install-amdgpu-0009-test.sh`, `scripts/undo-amdgpu-0009-test.sh`; findings section 61.

**Why:** to send the two SMU messages Windows uses before streaming 13 MP images, without rebuilding the whole kernel package.

**Concepts to understand:** (1) an in-tree driver can be built as an external module (`make -C <kernel build dir> M=<driver dir>`) if it finds its headers relatively; tracepoint headers are the usual exception because they locate themselves relative to the kernel's `include/trace/`. (2) `srcversion` in `modinfo` is a hash of the module's source files as kbuild sees them; out-of-tree builds hash a different file set, so compare behaviour-relevant things instead (parameters, function names, distinctive strings). (3) `depmod` resolves module names by a search order (`/usr/lib/depmod.d/search.conf`: `updates` first), which is how one kernel version can get a replacement module without touching the original file. (4) A module listed in mkinitcpio's `MODULES=()` is loaded from the initramfs, so the initramfs must be rebuilt for a replacement to take effect.

## Task: Windows stutter decode (delegated) and what it taught us

**What changed:** nothing in code; findings sections 63 and 64. The decode was done by a separate agent working in `scratch/disasm/` (it was told to write only there, so it could not add this note).

**What happened:** the agent decoded when Windows switches the ISP memory path ("stutter") and I checked the central claim in the disassembly: the switch happens only for modes up to 12 MP, never for our 13 MP. My previous theory had the condition backwards, and my amdgpu patch did what Windows deliberately does NOT do for this mode.

**Concept to understand: verify the direction of a comparison, not only that it exists.** `cmova` ("move if above") after `cmp $0xb71b00` sets a flag when width x height is ABOVE 12,000,000; the state machine then uses it as `1 + flag`, and only the transitions into/out of state 1 call the transfer function. Reading "there is a 12 MP threshold" and guessing which side acts is exactly the mistake. Also: delegating a bounded read-only reverse-engineering question to a second agent worked well, but its report is a claim until you re-check the load-bearing step yourself; the other claims in it stay INFERENCE.

## Task: the missing META_DATA buffers (patch 0027)

**What changed:** `isp4_subdev.c` (new parameter `meta_data_bufs`, allocation, send, free), `scripts/test-isp4-threshold.sh` (`--meta-data-bufs`), `scratch/isp4-threshold/0027-isp4-meta-data-buffers.patch`, findings section 65.

**Why:** in every run the firmware logged the same warning four times, `PopFrontBuffer: queue empty: type=13`, and an error `LoadFrameMetaData: No meta data buffer is available`. Type 13 is the Windows driver's `BUFFER_TYPE_META_DATA`; the Linux driver never sent any.

**Concept to understand: a repeated, identical warning in every run is a lead, not noise.** It was visible in the logs for hours, but I only counted it across all runs after a different theory (memory stutter) collapsed. Method that worked: (1) compare a "baseline" run with a "changed" run by reducing each firmware log line to a signature (level, module, function, text with numbers masked) and diffing the two sets; (2) find the producer side in the other platform's driver (`isp_send_metadata_buf`), read the constants it uses (the type word in the SEND_BUFFER block), and copy its behaviour behind a module parameter; (3) test first in the configuration that cannot hurt (no sensor, no data) before the risky one.
**API note:** `isp_kernel_buffer_alloc(dev, size, &handle, &gpu_addr, &cpu_addr)` / `isp_kernel_buffer_free(&handle, &gpu_addr, &cpu_addr)` are exported by amdgpu (`<drm/amd/isp.h>`) and give the GPU virtual address the firmware needs plus a CPU pointer.

## Task: Windows memory for the ISP, and a standing rule for agents

**What changed:** findings sections 67 and 68; memory note "agents: Sonnet only" (user's instruction: all subagents on Sonnet, never Opus, so every Agent call passes `model: "sonnet"` explicitly).

**What we learned:** the Windows camera driver does not allocate buffers one by one; it carves them out of two big memory regions that the display driver reserves for the ISP, using a small free-list allocator. The buffers that looked unexplained are command/response-path buffers (their getter is only called from `get_cmd_resp_buffer`, `get_cmd_single_buffer`, `getfw/setfw_cmd_send_imp`, `isp_ipu_set_hostless_cfg`).

**Concept to understand: name unknown code by its callers.** When a function has no name, list its callers and read the log strings of those callers (the Windows driver logs its own function names): five callers with command-related names tell you what a buffer getter is for, without understanding its body. Also: a negative result ("no fault in the logs", "no extra frame buffer") is progress; it removes explanations and shows where the search must move next.

## Task: what "mode 1" is, and Windows-side captures

**What changed:** new `scripts/windows/` (three PowerShell scripts + README, untested), `scratch/disasm/sensorOV13B.txt` (local disassembly), findings section 69.

**What we learned:** the sensor plug-in's two modes both report 4208x3120 at 30 fps; they differ in lane rate (1120 vs 560 Mbps) and timing values. My earlier suggestion that mode 1 was a smaller, lighter image was wrong, and checking the decoded capability function (rather than the lane-rate field alone) showed it.

**Concept to understand: ETW / WPP tracing.** A Windows driver can write trace messages (WPP) tagged with a *control GUID*; `logman create trace NAME -p {GUID} flags level -ets` starts an in-memory session that listens to that GUID, and `tracerpt` converts the `.etl` file to CSV/XML. The driver only emits a message if the session's enabled-flags and level pass its own check (here: flag bit 0x8 and level >= 4). The GUID can be recovered from the driver binary by following its WPP init: a `lea` of a `.rdata` address stored into the control block's second field. Note on PowerShell: `-and` and `-or` have equal precedence, so always parenthesise mixed conditions.

## Task: Windows trace collected; front LED closed; PowerShell AsTask fix

**What changed:** `scripts/windows/01-camera-info.ps1` (`Await-Action` now calls `AsTask(IAsyncAction)` found by reflection), findings section 70.

**What we learned:** the front LED also lights in Windows with the rear camera open, so it is expected behaviour and no longer a bug to chase. The Windows trace has events but no readable text: WPP stores only a message GUID plus a line number, and the format string lives in a TMF/PDB file we do not have, so the arguments must be read from the raw `.etl` bytes.

**Concept to understand: .NET overload resolution through WinRT in PowerShell 5.1.** WinRT async types (`IAsyncAction`, `IAsyncOperation<T>`) become `Task` via extension methods `AsTask` in `System.WindowsRuntimeSystemExtensions`. PowerShell cannot always pick the right overload (several `AsTask` exist, some generic), so you fetch the exact `MethodInfo` by reflection (`GetMethods()` filtered on name, generic-ness and parameter type) and `Invoke` it.

## Task: decode the Windows trace and compare with the Linux command sequence

**What changed:** new `scratch/windows-trace/` (parser written by a Sonnet agent, plus my `timeline.py`, `dump_payload.py`, `decode_sendbuf.py` and their outputs), findings section 71.

**What we learned:** Windows' working preview start is now known step by step. Linux sends about 8 command kinds; Windows sends about 22. The ones Linux lacks (APPLY_TUNING_SCENARIO, SET_FPS_RANGE, SET_ITIME_RANGE, SET_SCENE_MODE, SET_3A_CONFIG, ...) are the likeliest reason no frames arrive. Also, Windows never starts the sensor from the host; the firmware does it. The "frame queue empty" firmware errors also appear in the working Windows run, so they are harmless.

**Concept to understand: WPP trace records.** A WPP message in an `.etl` file is a header (message GUID = source file, message number = source line, timestamp, thread) followed by the raw printf arguments. Without the format string (TMF/PDB) Windows tools cannot print it, but the arguments that are strings are stored as plain text, and integers as raw little-endian bytes, so you can read function names directly and decode numbers by their position.

## Task: payload layouts of the Windows-only commands, patch 0028

**What changed:** new patch `scratch/isp4-threshold/0028-isp4-windows-cmds.patch` (`isp4_subdev.c`, module parameter `win_cmds`), `--win-cmds` option in `scripts/test-isp4-threshold.sh`, README row, helper scripts `scratch/disasm/strva.py` and `readva.py`, `scratch/windows-trace/cmd_ids.py`, findings section 72.

**What we learned:** six more firmware commands now have known payloads (all tiny: one or two 32-bit words); the three that are big or special (`SET_3A_CONFIG` is 92 bytes sent "indirect", `ENABLE_PREFETCH` is a global command) do not fit the Linux send path and were left out on purpose. Part of the numbers (FPS range 15000..30000, integration time 40..66666 us) came straight from the Windows trace, because the driver logs them.

**Concept to understand: reverse-engineering a call by its send helper.** Every command goes through one function (`0x140028bb0`) with the same argument pattern, so you search for the place that loads the command ID into `edx`, then read what is loaded into the payload buffer and its size just before the call. Enum values come from the "to string" helper functions used for logging: their switch table gives the number for each name. Also note the Linux pattern `(const u32 []){ 15000, 30000 }`: a C99 *compound literal*, an unnamed array that lives until the end of the enclosing block, handy for passing a small constant payload.

## Task: read the first run of patch 0028

**What changed:** only notes (findings section 73).

**What we learned:** five of the six new commands are accepted by the firmware (status 0), so their payload layouts are valid; SET_SCENE_MODE with value 0 is rejected ("Invalid SceneMode 0"). Everything else in the firmware log is identical to the earlier baseline, so the new commands are harmless without a sensor.

**Concept to understand: "accepted" is not "correct".** A command-done status of 0 only means the firmware parsed and applied the payload; it says nothing about whether the values produce the behaviour you want. The firmware's own log lines (here `apply tuning scenario to mode:0`) are the better evidence. A failing command with a clear firmware message (`Invalid SceneMode 0`) is useful: it tells you the validation rule exists, so the host value or the state at that moment differs from Windows.

## Task: static investigation of scene mode and frame interval

**What changed:** only notes (findings section 74).

**What we learned:** (1) The "frame interval 655270" I worried about is the sensor's maximum exposure time; the firmware clamps the frame time to 33333 us (30 fps) itself, as on Windows, so my 15 fps guess was wrong. (2) The scene-mode payload is identical to what Windows sends (the driver translates a host enum to a firmware enum through a table, and both end up as 0), so the firmware rejection is about *state*, most likely the module calibration (`SET_M2M_CAL_DATA`) that Windows reads from the camera module and sends first.

**Concept to understand: fixing the wrong layer.** When a command fails with the same payload that works elsewhere, stop comparing the payload and compare what happened *before* it. Also, a guess you wrote down earlier (the 15 fps reading) should be checked against new evidence and openly corrected in the notes; the firmware's own log line (`max_itime ... force to 33333`) settled it.

## Task: freeze #4, sensor start in Windows, and the memory pool formula

**What changed:** only notes (findings section 75, correction in section 71), plus `scratch/disasm/mempool_size.py` (the Windows pool size formula).

**What we learned:** (1) Nothing survived freeze #4: journald only keeps recent messages in memory-mapped pages, so an instant freeze loses them. (2) The Windows sensor plug-in starts the sensor with an init table plus one final `0x0100 = 1` write, all inside `start_OV13B`; `stream_on` is an empty stub, and the device script is only for gain/exposure at run time. (3) The firmware memory pool size is *computed* from the sensor pixel count; for the 13.1 MP mode the formula gives exactly the 262.31 MiB that Windows logs, while all our data runs used 200 MiB.

**Concept to understand: sizes that look like constants are often formulas.** The first analysis found "200 MiB" because it only read the fallback path. The trace showed the real number, and re-deriving it from the code with the sensor resolution as input reproduced it to the byte; that is a stronger result than a coincidence-looking number. Also: a log that is not written to disk before a crash is not evidence; for crash-prone tests, write logs synchronously (fsync per line) or send them off the machine (netconsole).

## Task: no-sensor baseline with the Windows-sized memory pool

**What changed:** only notes (findings section 76).

**What we learned:** a 263 MiB pool is allocated, sent and accepted exactly like the 200 MiB one, and the firmware log shows no difference. That is the expected result of a baseline: the pool-size hypothesis can only be tested when raw frames are really written, so this run proves "no new side effects", not "the problem is fixed".

**Concept to understand: a negative control.** Before the risky run you change one variable (the pool size) in the safe configuration and check nothing else moves. If the firmware had refused the larger pool, you would learn that without risking a freeze. The price is that it can never confirm the fix; keep the two questions apart in your notes (here: "is the larger pool accepted?" yes; "does it stop the freeze?" unknown).

## Task: synchronous kernel-log logger

**What changed:** new `scripts/log-kernel-sync.py`, findings section 77.

**What we learned:** a log is only evidence if it reached the disk before the crash. The logger therefore writes each kernel line with `os.write` and then `os.fdatasync` before reading the next, and adds a one-per-second heartbeat so the last heartbeat marks the moment of a freeze.

**Concept to understand: durability vs. buffering.** `write()` only copies data into the page cache; `fsync`/`fdatasync` asks the storage to make it permanent and waits. Programs normally avoid this per line because it is slow (milliseconds each); for a crash log that is exactly the point. Related trap: after creating a file, the *directory entry* also needs an `fsync` on the directory, otherwise the file itself can vanish after a crash. Also note `select()` with a timeout: it lets one loop do two jobs (read data when it arrives, write a heartbeat when it does not).

## Task: first data run with the Windows-sized pool

**What changed:** only notes (findings section 78).

**What we learned:** with the pool sized like Windows' (263 MiB instead of 200) the machine did not freeze, the firmware saw real frame starts for the first time, and the write DMA moved 14 KB before failing with a latency-buffer error. Still no frames. The error then repeats for seconds after the sensor has stopped, so it is a firmware error loop, which is probably what froze the machine in earlier runs.

**Concept to understand: DMA write latency buffer.** A camera DMA engine writes pixels to memory through a small FIFO ("latency buffer") that hides memory delays. If memory accepts data slower than pixels arrive (slow address translation, page-table walks, contended memory), the FIFO fills and the hardware reports "latency buffer leaking/overflow". Fixes act on the memory side (prefetching page-table entries, contiguous or large pages, lower bandwidth), not on the sensor side. That is why `ENABLE_PREFETCH` and where the buffers live are the next suspects.

## Task: patch 0029, global command routing and ENABLE_PREFETCH

**What changed:** `isp4_interface.c` (`isp4if_get_fw_stream`), `isp4_subdev.c` (`win_cmds` bit 0x40), new `0029-isp4-global-prefetch.patch` and `base-0028/`, README row, usage comment in the test script, findings section 79.

**What we learned:** the Linux driver already had a global command ring; only the routing function sent everything to stream 1. A command id encodes its category in the top byte (0x01 global, 0x02 per-stream), so the routing is a one-line test on `cmd_id >> 24`. The new command is behind a bit of `win_cmds`, so the default behaviour is unchanged.

**Concept to understand: ring buffers per command class.** The host talks to the ISP firmware through pairs of ring buffers in shared memory: a command ring the host writes (write pointer) and the firmware reads (read pointer), and a response ring the other way. Having a separate *global* ring from the *per-stream* ring lets device-wide settings (prefetch, power gating, log level) be handled independently of a running stream. The payload `{1,1,1}` is an inference, so the command is a probe: the reply status and the firmware's log tell us whether it was understood.

## Task: baseline with the global ENABLE_PREFETCH command

**What changed:** only notes (findings section 80).

**What we learned:** the global command path works end to end (command ring, firmware reply on the global response ring, firmware log showing prefetch enabled). But with prefetch on, the firmware gets stuck during START_STREAM, in the function that sets up memory-hub prefetching for its first client; its log simply stops there. The summary line `fw-reply=0` was the first hint: a missing acknowledgement is a result, not noise.

**Concept to understand: finding where a firmware hung from its own log.** Read the log ring until read pointer == write pointer (nothing unread), then the last line is the last thing it did before blocking. Comparing the command ring's read pointer with the write pointer tells you which command it is stuck on (here the one at offset 1920 = START_STREAM). Also remember that "the command was accepted (status 0)" and "the feature works" are different: here the accepted command triggered the hang later, when its effect was first used.

## Task: patch 0030, one switch at a time

**What changed:** `isp4_subdev.c` (module parameter `prefetch_flags`), `--prefetch-flags` in the test script, new `0030-isp4-prefetch-flags.patch`, `base-0029/`, README row, findings section 81.

**What we learned:** nothing new yet; this is the tool for the next experiment. The default keeps the earlier behaviour so old command lines mean the same thing.

**Concept to understand: bisecting a combination.** When a set of switches together causes a failure, test them one by one (and all off) instead of guessing: with three switches that is at most four short runs. Turning a constant into a parameter, with the old value as default, is the cheapest way to make such a sweep without rebuilding between runs.

## Task: read the prefetch switch sweep

**What changed:** only notes (findings section 82).

**What we learned:** the three payload words are RT-pipe prefetch, soft-RT-pipe prefetch and the YUV gap. None of them hangs the firmware on its own; RT-pipe prefetch alone even sets up the same client the firmware hung on before, and makes a long-standing stop-time error disappear. So the earlier hang needs two switches together, or it was a one-off.

**Concept to understand: a single failing run is one data point.** Before treating `{1,1,1}` as "the hang", it needs a repeat. A sweep that turns each switch on alone, plus a repeat of the failing case and the pairwise combinations, separates "this switch is bad", "this combination is bad" and "this was random". Also useful: a fingerprint (here an md5 of the normalised error list) quickly shows which runs differ at all, and `diff` then shows how.

## Task: first frames, and a list race

**What changed:** only notes (findings section 83).

**What we learned:** with RT-pipe memory prefetch enabled (and the Windows-sized pool) the ISP processed 8 frames at 30 fps and handed 4 full 1920x1080 NV12 buffers back to the driver: the camera pipeline works. The run then crashed in our own code: the loop in `start_streaming` walked the buffer list while the frame-done path removed a buffer from it.

**Concept to understand: iterating a list that someone else modifies.** `list_for_each_entry` reads `pos->next` *after* the loop body; if the body (or another thread meanwhile) removes `pos` with `list_del`, `next` now holds the poison value `0xdead000000000100` and the next step faults at an address like `0xdead...b8`. Seeing `dead000000000` in a register is the kernel's way of saying "use after list_del". `list_for_each_entry_safe` reads the next element *before* the body, which protects against removing the current element; it does not protect against other threads removing the *next* element, which is why the reasoning "a buffer not yet sent cannot complete" matters here. Proper protection is a lock; the existing `buf_list_lock` cannot be held across the slow send, because the frame-done path needs it.

## Task: patch 0031, safe list iteration

**What changed:** `isp4_video.c` (`start_streaming` uses `list_for_each_entry_safe`), new `0031-isp4-start-streaming-safe-iter.patch`, `base-0030/`, README row, findings section 84.

**What we learned:** the smallest correct fix for "the current element is removed while I am working on it" is the `_safe` iterator, as long as nobody can remove the *next* element meanwhile; here the next buffer has not been sent to the firmware yet, so it cannot complete.

**Concept to understand: choosing between a lock and an ordering argument.** Holding `buf_list_lock` across the loop would block the frame-done path for over a second (the firmware would keep finishing frames that nobody processes). The `_safe` iterator plus the argument "unsent buffers cannot complete" avoids that. Write such arguments down in a comment next to the code, because they are easy to break later (for example if buffers were ever sent from somewhere else).

## Task: first image

**What changed:** only notes (findings section 85) and the converted frames in `scratch/isp4-threshold/results/frames-20261016-032025/`.

**What we learned:** with patch 0031 the run completed cleanly and v4l2-ctl saved 4 real 1920x1080 frames from the rear camera. The picture is very dark and purple-tinted because exposure and white balance control are not working yet (device-script errors, no 3A config), but the geometry is correct, so the whole data path (sensor -> D-PHY -> ISP -> memory -> V4L2) works.

**Concept to understand: check data before looking at it.** Simple statistics (mean, min, max, share of zero bytes, a coarse histogram) tell you whether a buffer contains a real image, garbage or zeros before you convert it. NV12 is a luma plane (W x H bytes) followed by an interleaved chroma plane (W x H/2 bytes); chroma 128 means "no colour", so U and V both above 128 means a magenta/purple cast. Brightening only the luma (as done here for viewing) changes the apparent saturation, so judge colour on the unmodified frame.

## Task: move the keepers out of scratch/

**What changed:** new folders `driver/` (module source, README, `patches/` with 0009-0031 and `patches/amdgpu/`), `tools/` (`disasm/`, `windows-trace/` helpers), `docs/findings.md`; paths updated in `scripts/build-isp4-threshold.sh`, `scripts/test-isp4-threshold.sh`, `scripts/sudoers-grant-camera-tests.sh` and the tools' usage text; path table at the top of `docs/findings.md`, layout note in `driver/README.md`; new `.gitignore` (all of `scratch/`, build output, `__pycache__`, the three Windows-derived generated headers, `limine.conf*`). No git command was run. Verified: the module builds from `driver/`, all moved Python tools compile, the three scripts pass `bash -n`.

**What we learned:** separating "source of truth" (driver, patches, tools, notes) from "work area" (trees, results, proprietary data) makes it obvious what may be published; once that split exists, the ignore rule is a single line (`scratch/`).

**Concept to understand: moving files that other things point to.** Before moving, grep for every hard-coded path (scripts, tool usage text, sudo rules); afterwards rebuild and syntax-check. Historical records (old patches, old notes) are better left unchanged and explained with a mapping table, because rewriting them would make them disagree with what was actually run.

## Task: firmware copies into the repo folder

**What changed:** `scratch/winfw/` moved to `firmware/` (the two built Windows ISP images, `SHA256SUMS`, the two initramfs `fw-*.cpio` archives and their `stage-*/` trees; checksums verified after the move); paths updated in `scripts/deploy-windows-isp-fw-test.sh`, `scripts/install-amdgpu-0009-test.sh`, `scripts/restore-stock-isp-fw.sh`; row added to the path table in `docs/findings.md`; `.gitignore` keeps the images, archives and stage trees out of git by default (only `SHA256SUMS` would be committed).

**Concept to understand: "in the repository folder" vs "in git".** A file can live inside the project tree (so scripts find it with a relative path) and still be excluded from version control by `.gitignore`. That is the right default for third-party binaries whose licence you have not checked: firmware from a Windows driver package is AMD's property, and pushing it to a hosting service (even a private repository) is distributing a copy.

## Task: deployment and upstream plan written down

**What changed:** new `docs/upstream-plan.md` (the six pieces the camera needs, how to set it up on a new machine, the upstream path and its blockers).

**Concept to understand: what "upstream" needs besides code.** Mainline Linux accepts drivers only if everything they depend on can be redistributed: firmware goes to `linux-firmware` under a licence from its owner, and data tables copied from another OS's driver cannot be carried in kernel code. That is why the firmware and the sensor setup blobs, not the C code, are the real blockers.

## Task: tuning step 1, the device script's I2C descriptor (patch 0032)

**What changed:** `driver/isp4_interface.c` (parameters `script_i2c`, `script_i2c_restart`, descriptor fill before the checksum), new `driver/patches/0032-isp4-script-i2c-descriptors.patch`, `scratch/isp4-threshold/base-0031/`, README row, `--script-i2c` in the test script, findings section 86.

**What we learned:** the exposure/gain errors are not caused by my instruction encoding: even a function without any I2C instruction fails, so the firmware sets up the I2C target before running the script, from a descriptor we send as zeros. The values to try come from the Windows sensor plug-in's I2C configuration (address 0x10, 7-bit address, 16-bit registers).

**Concept to understand: a control experiment inside the data.** Comparing which functions fail (one with I2C instructions, one without) separated two hypotheses ("instruction encoding wrong" vs "setup before running wrong") without any new test run. Also: when static analysis cannot find where a value comes from, put the best-supported guess behind a switch and let the hardware answer, as long as the test is safe.

## Task: DKMS package (written by a second agent, Opus)

**What changed:** new `dkms/` (`dkms.conf`, `Kbuild`, `Makefile`, `check-generated-headers.sh`, `install.sh` and `uninstall.sh` that only print commands, `README.md`), plus the agent's local test folders `dkms/test-build-6.18.55/` and `dkms/test-missing-headers/`; `.gitignore` now ignores the generated headers in any folder and both test folders. Verified by the agent: builds against the 7.2.0-1.7 headers (clang, `LLVM=1` added automatically) and against the installed 6.18.55 LTS kernel (gcc); nothing installed.

**Concept to understand: DKMS.** Dynamic Kernel Module Support keeps a module's source in `/usr/src/<name>-<version>/` and rebuilds it automatically for every installed kernel (`dkms.conf` says how). The built module goes to `/lib/modules/<kernel>/updates/dkms/`, which `depmod` prefers over the in-tree copy, so `dkms remove` is how you go back to the stock module.

## Task: read the step-1 run (patch 0032)

**What changed:** only notes (findings section 87).

**What we learned:** with the I2C descriptor filled in, the firmware's script errors are gone and auto-exposure writes the sensor each frame (exposure rises 952 -> 7884 us). The saved image is still dark only because the test captures the first four frames, before AE has acted, and stops the sensor after 300 ms.

**Concept to understand: closed-loop control needs time.** Auto-exposure measures a frame, computes a new exposure, writes it, and sees the result one or two frames later; it changes in steps (here about 1.5x per frame) to avoid oscillating, so it needs roughly 10 frames to settle. A test that only keeps the first frames cannot show whether the loop works; the log of the values it applied can.

## Task: read the 3 s burst run

**What changed:** only notes (findings section 88) and converted frames in `scratch/isp4-threshold/results/frames-20261016-042648/`.

**What we learned:** given enough frames, auto-exposure converges (25 ms exposure, 6.7x gain in a dim room) and the image is bright and sharp. The remaining problem is a strong magenta colour cast.

**Concept to understand: Bayer phase.** A colour sensor has a grid of red, green and blue filters (e.g. B G / G R repeating). The ISP must know which colour sits at the first pixel. If the readout window starts one row or column later (an odd offset), the pattern the ISP assumes is shifted: it then treats green pixels as red/blue, which produces a strong magenta (or green) cast over the whole image. The window offset registers of the sensor (here 0x3813) therefore matter for colour, not only for cropping.

## Task: patch 0033, Windows mode registers

**What changed:** `driver/isp4_subdev.c` (`sensor_pll=3`, longer register readback), new `driver/patches/0033-isp4-sensor-windows-mode-regs.patch`, `scratch/isp4-threshold/base-0032/`, README row, findings section 89.

**What we learned:** nothing new yet; this tests whether the one-row window offset difference (0x3813) explains the magenta cast. Knowing the true scene colour (dark grey) turns "is the colour wrong?" into a clear yes, which is the reference the test needs.

**Concept to understand: change one thing, but group what belongs together.** `sensor_pll=3` changes several registers at once because they are all "the Windows mode table differs here"; if the cast goes, the next step is to find which one mattered by removing them one at a time. A known-colour reference (a grey object) is the easiest way to judge colour; a colour checker or a white sheet of paper is even better.

## Task: read the sensor-pll 3 run

**What changed:** only notes (findings section 90) and converted frames in `scratch/isp4-threshold/results/frames-20261016-043158/`.

**What we learned:** writing the Windows mode registers (above all the window offset 0x3813 = 0x08) turns the magenta image into a neutral grey one: the colour error was a Bayer-phase shift in the sensor's readout window, not missing white balance.

**Concept to understand: measure colour with numbers, against a known reference.** With a grey object in view, neutral means U and V close to 128; the shift from ~200/~213 to ~126/~127 is a clear, objective result, independent of how the picture looks on a screen.

## Task: read the script-i2c 2 run, first good photo

**What changed:** only notes (findings section 91) and `scratch/isp4-threshold/results/frames-20261016-043621/`.

**What we learned:** with exposure control and the Windows sensor mode registers the rear camera now gives a natural-colour, sharp, well-exposed image. Autofocus is configured by the firmware but has no calibration data and did not move the lens; the rest position happens to be sharp at room distance.

**Concept to understand: a camera pipeline is many loops.** Getting pixels (sensor -> D-PHY -> ISP -> memory) was the first barrier; image quality then depends on several control loops in the ISP firmware (auto-exposure, auto white balance, autofocus) that each need their own inputs: a working path to the sensor (the I2C descriptor), statistics buffers (the META buffers), and calibration data (M2M/OTP). Each fix removed one missing input.

## Task: patch 0034, tuning steps 2 and 4

**What changed:** `driver/isp4_subdev.c` (parameters `meta_data_resend`, `phy_diag`; META_DATA re-send in the frame-done path), new `driver/patches/0034-isp4-meta-data-resend-phy-diag.patch`, `scratch/isp4-threshold/base-0033/`, README row, `--meta-data-resend` / `--no-phy-diag` in the test script, findings section 92.

**What we learned:** the firmware needs its per-frame buffers handed back, like a conveyor belt: META_INFO was already returned by Linux, META_DATA was not. The 1.1 s of diagnostics inside the send loop was a leftover of the PHY debugging and is now switchable.

**Concept to understand: buffer recycling (producer/consumer queues).** The host gives the firmware a set of empty buffers; the firmware fills one per frame and reports it done; the host must give it back (re-queue) or the firmware runs out. When the "done" message does not identify the buffer, returning them in the same order they were consumed (round-robin) works if the consumer is strictly FIFO; that is an assumption worth stating, as it is here.

## Task: read the continuous-streaming run

**What changed:** only notes (findings section 93) and `scratch/isp4-threshold/results/frames-20261016-180003/` (a PNG and a 30-frame MP4).

**What we learned:** with the META_DATA buffers recycled and the diagnostic sleeps removed, the camera streams continuously: every frame the firmware produced reached the application, with no buffer-starvation errors, and auto-exposure settles in under a second.

**Concept to understand: a steady state is the real test.** Single good frames proved the data path; a run where every produced frame is delivered (35 done, 35 returned) and the error counters stay at zero proves the buffer cycle is balanced, which is what a video app needs.

## Task: patch 0035, working defaults

**What changed:** `driver/isp4_interface.c` and `driver/isp4_subdev.c` (defaults of 12 parameters, pool size computed with Windows' formula), new `driver/patches/0035-isp4-working-defaults.patch`, `scratch/isp4-threshold/base-0034/`, README row, test-script defaults and `--module-defaults`, findings section 94.

**What we learned:** the camera's working setup is now what the module does by default, so an application can use it without anyone passing parameters. The parameters stay as switches for later experiments.

**Concept to understand: module parameters and their defaults.** `module_param(name, type, perm)` exposes a static variable that can be set at `insmod`/`modprobe` time (or in `/etc/modprobe.d/`); its initial value in the C code is the default. Changing defaults rather than deleting the switches keeps the change small and reversible; removing the experiment code is a separate clean-up step. Watch out for tools that always pass every parameter: their own defaults silently override the module's.

## Task: read the module-defaults run

**What changed:** only notes (findings section 95) and `scratch/isp4-threshold/results/frames-20261016-181013/`.

**What we learned:** loaded with no experiment parameters, the module now gives the same clean result as the hand-tuned command line, in three back-to-back runs with a module reload each time (also a small reliability test).

**Concept to understand: repeatability.** A result seen once can be luck (timing, a warm sensor, a leftover state from the previous run); the same counters in several runs, each starting from a fresh module load, show the configuration itself is right.

## Task: the camera in normal applications

**What changed:** only notes (findings section 96).

**What we learned:** the driver works with ordinary V4L2 programs (ffplay) and, through PipeWire, with desktop applications such as OBS. Two practical points: a module with the same name that is already loaded must be removed (`rmmod`) before `insmod` of another build, and PipeWire builds its camera list at start-up, so it needs a restart after the driver changes.

**Concept to understand: the camera stack on a Linux desktop.** The kernel driver exposes a V4L2 device (`/dev/video0`); simple tools open it directly, while desktop applications ask PipeWire, which enumerates V4L2 devices (via WirePlumber) and shares the stream between applications. A driver that works in `v4l2-ctl`/`ffplay` usually works everywhere once PipeWire has re-scanned.

## Task: fold the sensor fixes into ov13b10 (DMI quirk)

**What changed:** new `sensor/` (`ov13b10.c` with a GZ302 quirk, `Kbuild`, `README.md`, `patches/0001-media-ov13b10-gz302-dmi-quirk.patch`), new `scripts/build-ov13b10.sh`, `scratch/isp4-threshold/base-ov13b10/` and `base-0035/`, capture-driver patch 0036 (`sensor_pll` default 0), test-script default, README row, findings section 97.

**What we learned:** the register values that fixed the PLL and the colour belong in the sensor driver, written in the normal start sequence before streaming begins, not patched in from the ISP driver afterwards. A DMI quirk limits them to this laptop, so other OV13B10 users are unaffected.

**Concept to understand: DMI quirks.** DMI/SMBIOS tables describe the machine (vendor, product, board). Kernel drivers use `dmi_check_system()` with a `dmi_system_id` table (`DMI_MATCH` = substring match) to enable board-specific workarounds. It is the quick, contained fix; the cleaner long-term fix describes the real hardware (here: a 24 MHz clock) in the board data so the driver can choose the right settings itself.

## Task: test the ov13b10 quirk

**What changed:** only notes (findings section 98) and `scratch/isp4-threshold/results/frames-20261016-183747/`.

**What we learned:** with the new ov13b10 module the camera gives the same clean result, and the log proves which path did the work: the sensor driver printed that it applied the GZ302 values, and the capture driver logged no sensor register writes.

**Concept to understand: prove the code path, not only the result.** A good image alone would not show whether the new code or a leftover old path fixed it; checking the loaded module's `srcversion` against the built file and finding the new log line (and the absence of the old one) does.

## Task: Windows-derived data as firmware files (patch 0037)

**What changed:** new `tools/header_to_fw.py` and the three files it made in `firmware/`; `driver/isp4_interface.c` loads them with `request_firmware()` (patch 0037, base `scratch/isp4-threshold/base-0036/`); `dkms/check-generated-headers.sh`, `dkms/Kbuild`, `dkms/README.md` (base `scratch/isp4-threshold/base-dkms-0037/`); README row; findings section 99.

**What we learned:** the module source and the built module no longer contain any data copied from the Windows driver; it is all in files under `/lib/firmware/` that each user makes from their own Windows install. That is what makes the driver code shareable (and buildable from a fresh checkout).

**Concept to understand: `request_firmware()`.** A driver asks the kernel for a named blob (`amdgpu/gz302-ov13b-script.bin`); the kernel looks in `/lib/firmware/updates/`, `/lib/firmware/<kernel version>/`, `/lib/firmware/`, and returns its bytes in a `struct firmware`, which the driver must give back with `release_firmware()`. Separating code (GPL, in the kernel) from data (vendor-licensed, in linux-firmware or installed locally) is the standard Linux model. When a file has structure (here the D-PHY list), give it a header with a magic number and version, and check sizes, so a wrong or truncated file is rejected instead of misread.

## Task: test patch 0037

**What changed:** only notes (findings section 100).

**What we learned:** the three payloads load from `/lib/firmware/amdgpu/` and the camera works exactly as before; the D-PHY parameters (phy 0, 1120 Mbps, 4 lanes) now come from the file's header, and the firmware accepted the device script and sensor properties loaded from files.

**Concept to understand: equivalence testing after a refactor.** When moving data out of the code, check that the same bytes reach the hardware (identical files, same command replies, same register counts in the log) and that the end result is unchanged; then the refactor is proven not to have changed behaviour.

## Task: squash capture patches 0009-0037 into one patch for newer kernels

**What changed:** new `scripts/make-capture-squash.sh` (writes `scratch/series/0001-media-amd-isp4-gz302-capture.patch`, dry-runs it on fetched upstream trees) and `scripts/test-capture-squash-build.sh` (applies it to a copy of an upstream isp4 directory in `scratch/series/build-TAG/` and compiles it). No driver source changed.

**What we learned:** the single patch (29 hunks, 7 files) applies to v7.2.9 and v7.3-rc6 and both results compile. One hunk needs "fuzz 1": its last context line upstream became `refcount_dec_and_test` instead of `atomic_dec_and_test`; our change does not touch that line. After applying, the tree differs from `driver/` only by upstream's own fixes (refcount_t, new error-unwind labels in power-on), so nothing of ours was lost.

**Concept to understand: hunk context and fuzz.** A unified diff hunk carries ~3 unchanged lines before and after each change; `patch` uses them to find where the hunk goes (an "offset" means the spot moved, which is harmless). "Fuzz N" means patch ignored N context lines at the hunk edges that no longer match; usually fine, but always read a fuzzed hunk, because it is the one place a patch can land in the wrong spot. `-F0` (no fuzz) is how you detect drift; the long-term fix is to regenerate (rebase) the patch on the new tree so it applies cleanly.

## Task: assemble the full GZ302 kernel patch series

**What changed:** new `scripts/make-series.sh`. It writes the 7-patch series to `scratch/series/gz302/` (amdgpu 0001/0003/0005, amd_isp4 0002, ov13b10 0004 + DMI quirk 0006, capture squash 0007) and tests it on pristine 7.2.0, v7.2.9 and v7.3-rc6. Old kernel patches 0006-0008 are left out (superseded). No source file changed.

**What we learned:** three of the old board patches (0002, 0003, 0005) never matched 7.2.0 exactly; they only applied because makepkg's `patch -Np1` allows fuzz 2 (0003 had wrong hunk line counts, 0005 was written against the tree before 0003). After a refresh, everything applies with no fuzz on all three trees except one hunk of 0007 on the newer kernels, and the result on 7.2.0 is byte-identical to the `driver/` and `sensor/ov13b10.c` sources tested on hardware.

**Concept to understand: refreshing a patch (`quilt refresh`).** A patch is regenerated by applying it (fuzz allowed) and then diffing the file before and after; the change itself stays the same, but the hunk headers and context lines now describe the real tree exactly. Do it whenever a patch needed fuzz or an offset, and keep the patches of a series in order, because each one's context includes what the earlier ones changed in the same file.

## Task: PKGBUILD helper for new CachyOS kernels

**What changed:** new `kernel/patches/` (the 7-patch series; from now on the copy to use), `scripts/apply-series-to-pkgbuild.sh` (checks the series against a PKGBUILD's kernel tarball with no fuzz, then appends it to the PKGBUILD) and `scripts/refresh-patch.sh` (rebases one patch onto a tree). Patch 0007 in `kernel/patches/` was rebased onto CachyOS 7.2.11. Tested on a copy of the current CachyOS PKGBUILD (7.2.11-1) in `scratch/pkgbuild-test/work/`.

**What we learned:** all 7 patches apply exactly to CachyOS 7.2.11 after rebasing 0007 (the only drift was one context line, `atomic_dec_and_test` became `refcount_dec_and_test`), and the rebased 0007 also applies exactly to v7.2.9 and v7.3-rc6. CachyOS's stock config builds `AMD_ISP_PLATFORM` as a module, while the tested kernel had it built in; whether `=m` works is not tested yet.

**Concept to understand: how makepkg pairs `source` and checksums.** `b2sums[i]` belongs to `source[i]`, purely by position. Appending to both arrays at the very end of the PKGBUILD (`source+=()`, `b2sums+=()`) keeps them paired however CachyOS changes the lines above, which is why the helper does that instead of editing inside the arrays. Using real BLAKE2 sums instead of `SKIP` makes makepkg refuse a patch file that changed after it was added.

## Task: one-command camera kernel build (deckify, -camera) and notify hook

**What changed:** new `scripts/rebuild-camera-kernel.sh` (fetch CachyOS deckify PKGBUILD, verify sources, add the series, build, `pacman -U`; stops at the first failure), `kernel/hooks/gz302-camera-kernel-notify.hook` (prints a reminder when `linux-cachyos-deckify` updates), `scripts/show-srcinfo.sh` (prints makepkg's view of a PKGBUILD). `scripts/apply-series-to-pkgbuild.sh` now also renames the build to `-camera` and stops if a CachyOS patch touches the same files as ours. `.gitignore` ignores `kernel/build/`.

**What we learned:** deckify defaults to `_use_llvm_lto=none`, so it builds with GCC and no LTO. Appending `-camera` to `_pkgsuffix` before `pkgbase=` renames the packages (`linux-cachyos-deckify-camera`, `-headers`) and the kernel release, so it installs next to the official kernels. On 7.2.11 deckify all 7 patches apply cleanly, none of CachyOS's deckify patches touch our files, and the tarball signature is good. Not yet built or booted.

**Concept to understand: pacman (ALPM) hooks.** A `.hook` file in `/etc/pacman.d/hooks/` names a trigger (operation + package) and an action that pacman runs as root inside the transaction (`PreTransaction`/`PostTransaction`). That is why heavy work (a long build, as a normal user) doesn't belong in a hook, and ours only prints. Also `makepkg` refuses to run as root, and `pacman -U` installs a local package file with the same dependency and conflict checks as a repository install.

## Task: camera kernel as linux-cachyos-camera, built like linux-cachyos-gcc

**What changed:** `scripts/rebuild-camera-kernel.sh` now uses CachyOS's `linux-cachyos-eevdf` PKGBUILD with `_cpusched=cachyos` and `_use_llvm_lto=none` and names the result `linux-cachyos-camera`; `scripts/apply-series-to-pkgbuild.sh` sets `_pkgsuffix="cachyos-camera"`; the notify hook triggers on `linux-cachyos`; new `scripts/survey-cachyos-variants.sh` compares all CachyOS variants. The first real run had stopped because CachyOS's deckify `0001-handheld.patch` no longer matched its PKGBUILD checksum (their mistake; the script stopped correctly).

**What we learned:** CachyOS's tarball already contains its patch set, so variants differ only in a few extra patches and option defaults. `linux-cachyos-gcc` (an official package) is the default kernel built with GCC and no LTO: same tarball, same config, BORE. The eevdf PKGBUILD with `_cpusched=cachyos` gives the same kernel with no extra patches; the main PKGBUILD can't be used with LTO off because its fixed checksum list then has one entry too many.

**Concept to understand: `: "${var:=default}"`.** In bash, `${var:=default}` gives `var` the value `default` only if it is unset or empty, and `:` is the do-nothing command that lets the expansion run as a statement. CachyOS writes every build option this way, so `_use_llvm_lto=none makepkg` overrides the default from the environment without editing the PKGBUILD. `export` in our script makes the override reach every makepkg call it runs.

## Task: znver4 CPU tuning for the camera kernel

**What changed:** `scripts/rebuild-camera-kernel.sh` exports `_processor_opt=zen4`, so the camera kernel gets `CONFIG_MZEN4=y` like the official kernels from the `cachyos-znver4` repo (read from the installed `linux-cachyos-headers` 7.2.9-2 `.config`).

**What we learned:** in CachyOS PKGBUILDs an empty `_processor_opt` means `native`, not generic. The 7.2.11 tree has `MZEN4` (needs GCC >= 13) but no Zen 5 option; `native` would tune for the Zen 5 CPU doing the build.

**Concept to understand: `-march` and microarchitecture levels.** `-march=znver4` lets the compiler use every instruction Zen 4 has (AVX-512 among them) and tune for its pipeline; the result runs only on CPUs that have those instructions. `x86-64-v1..v4` are vendor-neutral feature levels; CachyOS picks a repo (`x86_64_v3`, `x86_64_v4`, `znver4`) per machine so packages match the CPU. It changes runtime speed, not build time.

## Task: AUR firmware package gz302-camera-firmware (step A)

**What changed:** new `aur/gz302-camera-firmware/PKGBUILD`, `data/` (phy-seq and sensor-prop, the two files we ship), `scripts/test-aur-firmware.sh`; `tools/build_winfw.py` got `--tag` (build only the srx_h image); `.gitignore` ignores debug output (`*.log`, `*.raw`, `*.yuv`, `*.y4m`).

**What we learned:** the package refuses to build without `~/cam-firm-gz302ea/` (any case) and its three files, and with them it rebuilds byte-identical copies of the ISP image and device script the camera uses today. The ISP image goes to `/usr/lib/firmware/updates/amdgpu/` (searched first by the kernel and by mkinitcpio, and no file clash with linux-firmware); the `.atb` must stay at `/usr/lib/firmware/amdgpu/` because the driver reads it by full path, not through `request_firmware()`. The git history was checked before going public: it contains the D-PHY table (which we decided to publish) but no device script, sensor-prop bytes or firmware images.

**Concept to understand: what a PKGBUILD's functions are for.** makepkg runs `prepare()` (checks and setup after the sources are unpacked), `build()` (make things, as your user), then `package()` inside `fakeroot` (copy results into `$pkgdir`, which becomes the package's `/`). Failing in `prepare()` with a clear message is the usual way to demand files a package cannot download, and because nothing reaches `$pkgdir`, nothing is installed.

## Task: AUR kernel package linux-cachyos-camera (step B)

**What changed:** new `scripts/make-aur-kernel.sh` (generates `aur/linux-cachyos-camera/`: PKGBUILD, `.SRCINFO`, config, the 7 patches) and `scripts/test-aur-kernel.sh`. The generated PKGBUILD is CachyOS's eevdf PKGBUILD with our defaults (`_cpusched=cachyos`, `_processor_opt=zen4`, LTO off), the `-camera` name, our patches, a `gz302-camera-firmware` dependency and you as maintainer (CachyOS's maintainers kept as contributors). The firmware PKGBUILD now has the same maintainer and `GPL-2.0-only`.

**What we learned:** a dependency set inside a package function (`_package()`) is only checked by pacman when installing; makepkg does not look at it before building. The first test "passed" only because other build tools were missing. With an extra top-level `depends`, makepkg names `gz302-camera-firmware` as missing and stops before downloading anything; the headers package sets its own `depends` and does not inherit it.

**Concept to understand: split packages and `.SRCINFO`.** One PKGBUILD can make several packages (`pkgname=(a a-headers)`, one `package_a()` function each). Top-level variables are defaults for all of them, and a variable set inside a package function overrides it for that package only. `.SRCINFO` is that information written out as plain text (`makepkg --printsrcinfo`); the AUR website and helpers like paru read it instead of running the PKGBUILD, which is why it must be regenerated and pushed with every PKGBUILD change.

## Task: publishing setup (step C)

**What changed:** `LICENSE` (GPL-2.0, from Arch's `licenses` package), `aur/README.md` (instructions for other GZ302 owners and for releases), the firmware `.SRCINFO`, `scripts/aur-firmware-checksum.sh` (real checksum of the tag tarball after the release tag is pushed) and `scripts/aur-sync.sh` (copies both packages into local AUR clones and prints the commit/push commands); `.gitignore` ignores makepkg leftovers in `aur/` and the `aur-git/` clones.

**What we learned:** the AUR is a set of small git repositories, one per package, holding only the PKGBUILD, `.SRCINFO` and local source files; the code itself comes from the URLs in `source=()`, here a tag tarball of the public GitHub repo. That is why the firmware checksum can only be filled in after the tag exists, and why each AUR push must carry a `.SRCINFO` that matches its PKGBUILD.

**Concept to understand: `git commit -- <paths>`.** Normally `git commit` records everything that is staged. With paths after `--` it records only those paths (their current content) and leaves the rest of the staged changes for the next commit. That is how one big staging area can still become several commits that each hold one logical change.

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

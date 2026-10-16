# GZ302 OV13B10: findings from the Windows driver store

> **Paths moved on 2026-10-16** (after section 85). The text below keeps the old paths as they were when written; read them through this table:
>
> | old path | new path |
> |---|---|
> | `scratch/findings.md` | `docs/findings.md` (this file) |
> | `scratch/isp4-threshold/*.c`, `*.h`, `Kbuild`, `README.md` | `driver/` |
> | `scratch/isp4-threshold/00NN-*.patch` | `driver/patches/` |
> | `scratch/kernel-patches/0009-drm-amdgpu-isp-memory-stutter.patch` | `driver/patches/amdgpu/` |
> | `scratch/*.py` (`assemble_ov13b`, `build_phy_seq`, `build_sensor_prop`, `build_winfw`, `decode_phy`, `diff_ov13b_tables`) | `tools/` |
> | `scratch/disasm/*.py` | `tools/disasm/` |
> | `scratch/windows-trace/*.py` | `tools/windows-trace/` |
> | `scratch/winfw/` (built Windows ISP firmware images, `SHA256SUMS`, `fw-*.cpio`, `stage-*/`) | `firmware/` (git-ignored by default) |
>
> Unchanged (local only, not for git): `scratch/isp4-threshold/results/`, `scratch/isp4-threshold/base-00NN/`, the Windows-derived data (`scratch/phy-src/`, `scratch/acpi/`, `scratch/disasm/*.txt` and `*.md`, `scratch/windows-trace/` outputs) and the kernel/amdgpu trees.

Source files (all read-only, in place under `/mnt/windows/Windows/System32/DriverStore/FileRepository/`):

- `amdcamera.inf_amd64_636e6e00d737b319/amdcamera.sys` (sha256 `2376fd79...4263`)
- `sensorov13b.inf_amd64_817a026ab537dd2a/sensorOV13B.sys` (sha256 `53403d7d...f5ef`)
- `.../asm_OV13B.asm`, `.../OV13B_3001_ROG_SRX.atb`
- Windows ISP firmware `srx_isp_firmware_signed.ram`, `srx_h_isp_firmware_signed.ram`

Decompiled with rea + Ghidra 12.1.2. Addresses are image addresses in the named `.sys`.
**OBSERVED** = backed by a decompiled address or dumped bytes. **INFERENCE** = my reading; check before relying on it.

## Headline

The handoff's conclusion ("the firmware ABI has no sensor-configuration surface; only AMD can fix it")
described the **Linux header**, not the firmware. The Windows host driver sends sensor configuration
to the firmware with commands that Linux's `isp4_fw_cmd_resp.h` does not define.

Whether the **Linux** firmware (`isp_4_1_1.bin`) accepts those commands is **UNKNOWN**. Nothing here proves it does.

## 1. Command IDs: Windows and Linux share one ID space (OBSERVED)

Name-to-ID function `FUN_14004dfa8` in `amdcamera.sys`.

| Command | ID | In Linux header? |
|---|---|---|
| SET_STREAM_CONFIG | 0x2010001 | yes, matches |
| SET_OUT_CHAN_PROP | 0x2010003 | yes, matches |
| ENABLE_OUT_CHAN | 0x2010005 | yes, matches |
| START_STREAM | 0x2010007 | yes, matches |
| STOP_STREAM | 0x2010008 | yes, matches |
| SEND_BUFFER | 0x2040001 | yes, matches |
| **SET_SENSOR_PROP** | **0x2090001** | no |
| **SET_DEVICE_SCRIPT** | **0x2090002** | no |
| **SEND_I2C_MSG** | **0x2090003** | no |
| SET_SENSOR_EMB_PROP | 0x1050002 | no (global, type 0x1) |
| SET_SENSOR_CALIBDB | 0x1050004 | no (global) |
| SET_TUNING_DATA | 0x2050008 | no |
| HOSTLESS_MODE_CFG | 0x2060001 | no |
| ACK_SENSOR_SET_AGAIN / ITIME / GROUP_HOLD / GROUP_RELEASE | 0x1080015 / 0x1080017 / 0x1080013 / 0x1080014 | no |
| ACK_LENS_SET_POS | 0x1080024 | no |

Encoding is `type<<24 | group<<16 | id`, as documented in the Linux header. The sensor commands are
type 0x2, group 9, so the existing stream command queue can carry them.

## 2. How Windows uploads the sensor script (OBSERVED)

`FUN_140019a5c` (`isp_set_script_to_fw`):

1. Ask the per-sensor module for the script size (vtable +0x10).
2. `ExAllocatePool2`, pool tag `0x41495350`.
3. Fetch the script text (vtable +0x18).
4. Run an assembler that lives in `amdcamera.sys` (`*(param_1 + 0x1090 + sensor*8)[0]`) over the text.
5. Hand the result to `FUN_1400271cc` (`isp_fw_set_script`).

`FUN_1400271cc` then calls `FUN_140028bb0(dev, 0x2090002, stream, 0, payload, 0x16EC)`.
**The SET_DEVICE_SCRIPT payload is a fixed 0x16EC (5868) byte structure.** Its field layout is not decoded yet.

The Windows firmware has a matching script VM: strings `Svm/svm_interpreter.cpp`, `RunInstrWi2c`, `RunInstrRi2c`,
`DevCtrlScript.cpp`, `script for sensor:%d not set`, and an `i2cSensor={deviceId,enRestart,deviceAddrType,regAddrType,deviceAddr}`
descriptor. The Linux `isp_4_1_1.bin` has the same `.function` names (`SensorSetAGain`, `SensorGroupHold`, ...)
but none of these strings. **INFERENCE:** it is a stripped build of the same VM. **Not verified.**

## 3. OV13B specifics from `sensorOV13B.sys` (OBSERVED unless marked)

- `get_i2c_config_OV13B` (`FUN_140003680`): fills a small struct with device address **0x10** (sensor) and **0x0c** (second device,
  **INFERENCE:** the autofocus VCM; `asm_OV13B.asm` has a `LensSetPos` function). Other fields 0x102 / 0x101 are probably
  address/register width codes (**INFERENCE**).
- `get_sensor_hw_parameter_OV13B` (`FUN_1400048f0`):
  - name `"OV13B"`, tuning variant `"3001"` (matches `OV13B_3001_ROG_SRX.atb`).
  - GUID `{F39FB658-6C43-4BB5-827E-2EFADB408052}`, the same as `FliterOV13B` in `amdcamera.INF`.
  - value `0xC85500` = 13,128,960 = **4208 x 3120**.
- `get_caps_OV13B` (`FUN_140002d70`), mode 0: width 0x1070 (4208), height 0xC30 (3120), 30 fps (30000 in x1000 units),
  0x2b at +0x10 (**INFERENCE:** MIPI CSI-2 data type 0x2B = RAW10), a u32 `4` at +0x1c, a byte `4` at +0x08, and
  0x460 (1120) at +0x1F0 for mode 0 vs 0x230 (560) for mode 1 (**INFERENCE:** per-lane Mbps; 1120 Mbps = 560 MHz link,
  which agrees with the repo's 560 MHz assumption).
  **Correction:** an earlier draft called the byte at +0x08 a lane count. The firmware's own log format
  (`version, intfType, cfaPattern, sensorShutterType, ...`) puts a CFA pattern in that slot, so it is more likely `cfaPattern`.
  The lane count is therefore **not yet identified**. Note +0x1F0 lies beyond the first 0x160 bytes that are sent in
  `SET_SENSOR_PROP` (section 7), so it is probably consumed by the host (D-PHY setup), not the firmware.
- `get_sensor_port_OV13B` returns `*(ctx+0x188)`; the value is set elsewhere and is **not yet determined**.
- Only two resolution modes exist (`res_0_config_OV13B`, `res_1_config_OV13B`).

### Mode 0 init sequence (131 register/value pairs, table at `0x140008030`)

`res_0_config_OV13B` (`FUN_140005144`) writes each pair through a callback at `ctx+0x3f0`.
**INFERENCE:** that callback is the host's ISP I2C write, so the host (not the firmware) writes the init table.
If flag `DAT_14000a57e` is set, two more pairs are written from `0x140008458` (raw bytes `00 50 fd 00 01 50 0d 00`),
which decode as reg `0x5000` = `0xFD` and reg `0x5001` = `0x0D` (they override the `0xFF` / `0x0F` in the main table).

Sanity checks that the decode is right: `0x3808/9` = 0x1070 (4208 wide), `0x380A/B` = 0x0C30 (3120 high),
`0x380C/D` = 0x0498 and `0x380E/F` = 0x0C94, matching the `get_caps` mode-0 numbers.

```
0x0103=01 0x0303=01 0x0305=46 0x0321=00 0x0323=04 0x0324=01 0x0325=55 0x0326=81 0x0327=04
0x3011=7C 0x3012=07 0x3013=32 0x3107=23 0x3501=00 0x3502=60 0x3504=08 0x3508=01 0x3509=00
0x3600=1A 0x3601=54 0x3612=4E 0x3620=00 0x3621=68 0x3622=66 0x3623=03 0x3662=92 0x3666=BB
0x3667=44 0x366E=FF 0x366F=F3 0x3675=44 0x3676=00 0x367F=E9 0x3681=32 0x3682=1F 0x3683=0B
0x3684=0B 0x3704=0F 0x3706=40 0x3708=3B 0x3709=72 0x370B=A2 0x3714=24 0x371A=3E 0x3725=42
0x3739=12 0x3767=00 0x3774=2D 0x377A=0D 0x3789=18 0x3790=40 0x3791=A2 0x37C2=04 0x37C3=F1
0x37D9=0C 0x37DA=02 0x37DC=02 0x37E1=04 0x37E2=0A 0x3800=00 0x3801=00 0x3802=00 0x3803=08
0x3804=10 0x3805=8F 0x3806=0C 0x3807=47 0x3808=10 0x3809=70 0x380A=0C 0x380B=30 0x380C=04
0x380D=98 0x380E=0C 0x380F=94 0x3811=0F 0x3813=08 0x3814=01 0x3815=01 0x3816=01 0x3817=01
0x381F=08 0x3820=88 0x3821=00 0x3822=14 0x3823=18 0x3827=01 0x382E=E6 0x3C80=00 0x3C87=01
0x3C8C=19 0x3C8D=1C 0x3CA0=00 0x3CA1=00 0x3CA2=00 0x3CA3=00 0x3CA4=50 0x3CA5=11 0x3CA6=01
0x3CA7=00 0x3CA8=00 0x4008=02 0x4009=0F 0x400A=01 0x400B=19 0x4011=21 0x4017=08 0x4019=04
0x401A=58 0x4032=1E 0x4050=02 0x4051=09 0x405E=00 0x4066=02 0x4501=00 0x4502=10 0x4505=00
0x4800=64 0x481B=3E 0x481F=30 0x4825=34 0x4837=0E 0x484B=01 0x4883=02 0x5000=FF 0x5001=0F
0x5045=20 0x5046=20 0x5047=A4 0x5048=20 0x5049=A4
```

**Note for the old experiment:** Windows programs PLL register `0x0305` = **0x46**. The abandoned patch 0007 forced it to 0x8c.
Compare this table against upstream `ov13b10.c` (PLL, `0x0303`, `0x0321`..`0x0327`) and the actual reference clock before re-trying anything.

## 4. Who drives sensor I2C? (partly answered)

- OBSERVED: the sensor module's init writes go through a host callback (`ctx+0x3f0`), and `amdcamera.sys` contains host I2C code
  (`dw_i2c_*`, `i2c_read_reg_imp`, `i2c_write_reg_imp`, `isp_i2c_write`, `AMDPropertyI2CAccessHandler`).
- OBSERVED: the firmware has its own `i2cSensor` descriptor and VM `WI2C`/`RI2C`, and Windows defines `SEND_I2C_MSG` plus `ACK_SENSOR_*` commands.
- INFERENCE: init and power-up are host-driven, and runtime exposure/gain are firmware-driven via the script. **Not proven.**

## 5. What is still unknown (needed before writing kernel code)

1. `SET_SENSOR_PROP` (0x2090001): sender and overall layout are known (section 7), and section 14 shows the payload can be replayed from
   `get_caps_OV13B`. Still missing: the meaning of each field in the 0x160-byte caps struct (only a few are identified). The
   `FUN_14004d65c` step is only a logger (corrected in section 14).
2. `SET_DEVICE_SCRIPT` (0x2090002): wire format is now decoded (section 8). Not yet checked: the memory-operand forms of MOV
   (unused by `asm_OV13B.asm`), and that my bit positions are right (needs a test vector or a firmware VM to confirm).
3. The `.atb` tuning blob delivery (`SET_TUNING_DATA` 0x2050008, 566 KB file) and whether it is required to get frames.
4. The ISP port value (`get_sensor_port_OV13B`), lane count, and clock setup on the Windows path (`reset_sensor_phy`, `isp_snr_enbale_ldo_power`).
5. Whether Linux `isp_4_1_1.bin` accepts any of the commands in section 1. The only way to know is to send one and read the firmware log.
6. `SET_SENSOR_EMB_PROP` (0x1050002) payload: 0x24 bytes (9 u32), first u32 = sensor id, filled by `FUN_140059c70`. Not decoded.

## 6. Do this before any new kernel build

The handoff's 2026-08-25 section shows `START_STREAM` was never sent because only 3 of the required 4 buffers reached the ISP
(`ISP4SD_MIN_BUF_CNT_BEF_START_STREAM = 4`; buffers are only forwarded after `stream_started` is set). That experiment was never run.
"The firmware rejects OV13B10" is therefore **untested**. Run the buffer-threshold experiment first.
**Update (2026-10-15): the experiment has been run; see section 11. The threshold was not the cause.**

Also: `/etc/modprobe.d/99-gz302-ov13b10-force-stream.conf` is still present and logs
`ov13b10: unknown parameter 'force_stream' ignored` at boot. It is harmless but stale.
The running kernel (7.2.9) has none of handoff patches 0001-0005 and the repo's `amd_isp4.ko` was built for 7.1.6.

## 7. Order in which Windows sets a sensor up (OBSERVED)

`FUN_140019fb0` = `isp_set_snr_info_2_fw(dev, sensor_idx, stream_idx)` in `amdcamera.sys`. On the first call per sensor:

1. `FUN_140059bdc`: fetch the sensor caps from the sensor plugin into a per-sensor cache (`dev + 0x1c70 + idx*0x3848`).
2. If the script-mode flag (`dev + 0x1848`) is set: `FUN_140019a5c` sends **SET_DEVICE_SCRIPT** (0x2090002), section 8.
3. Build a 0x24-byte structure (9 u32; first = sensor id from `FUN_140013608`, the rest from `FUN_140059c70`) and send
   **SET_SENSOR_EMB_PROP** (0x1050002) as an *indirect* command.
4. Build the **SET_SENSOR_PROP** payload and send it as command 0x2090001, also *indirect*:
   - payload size **0x168** = 8-byte header + the first **0x160** bytes of the caps cache;
   - header u32[0] = sensor id (`FUN_140013608`), u32[1] unset; the caps copy starts at payload+8 and its first u32 is forced to **3**
     (matches the firmware's "Sensor properties version %u" check, **INFERENCE:** the struct version);
   - `FUN_14004d65c` was first listed here as an undecoded "post-processing" step. **Correction (section 14): it only logs the
     fields and changes nothing.**
5. Mark the sensor as configured (`dev[idx + 0x184b] = 1`).

**Indirect command** (OBSERVED shape): the command's inline parameters are `{payload GPU address lo, hi, size, checksum}` (16 bytes),
the payload lives in a separate firmware-visible buffer, and the checksum comes from `FUN_1400236bc`. Windows keeps a pool of such
buffers (`isp_fw_indirect_cmd_pl_buf_init`, `isp_fw_get_nxt_indirect_cmd_pl`). The Linux header's `isp4fw_resp_param_package`
(`package_addr_lo/hi`, `package_size`, `package_check_sum`) has the same four fields, which suggests the same mechanism
(**INFERENCE**, not checked on the Linux side). Linux already allocates GPU-visible memory for the firmware pool.

`FUN_140028bb0(dev, cmd_id, stream, indirect_flag, params, params_len)` is the generic sender. The script upload calls it
with `indirect_flag = 0`, a 0x16EC-byte payload and the script command, so the sender appears to stage that payload into an
indirect buffer itself (**INFERENCE**).

## 8. SET_DEVICE_SCRIPT wire format (decoded from the assembler; verify before relying on it)

Pipeline in `amdcamera.sys`: `FUN_14005e6c0(text, len, out)` allocates a 0x14464-byte assembler context, runs the file assembler
`FUN_14005e2dc` (tokenise lines -> `FUN_14005d83c` per line -> link labels/functions in `FUN_14005d47c`), then serialises with
`FUN_14005dc28(ctx, out)`.

**Opcodes** (same value in the internal record and on the wire): ADD 1, SUB 2, MUL 3, DIV 4, SHL 5, SHR 6, AND 7, OR 8, XOR 9,
MOVB 10, MOVW 11, MOVDW 12, JNZ 13, JEZ 14, JLZ 15, JGZ 16, JGEZ 17, JLEZ 18, CALL 19, WI2C 20, RI2C 21.
Operand types in the assembler: 1 register, 2 memory, 3 immediate, 4 label, 5 function.

**Compiled script** (0x15E8 = 5608 bytes, little-endian):

| Offset | Size | Content |
|---|---|---|
| 0x0000 | 8 x N | instructions, N <= 500, two u32 words each |
| 0x0FA0 | 40 x F | function table, F <= 40: `char name[32]; u32 start_index; u32 end_index` |
| 0x15E0 | 4 | N (instruction count) |
| 0x15E4 | 4 | F (function count) |

**Instruction words** (low bit = bit 0):

- Arithmetic/logic (ADD..XOR; `OP dst, src1, src2`, dst and src1 registers, src2 register or immediate):
  `w0 = (((((op<<5 | dst)<<5 | src1)<<2) | f) << 15)` with `f = 1` if src2 is a register, `3` if immediate; `w1 = src2 value`.
- MOVB/MOVW/MOVDW with register destination (`MOVDW R0, $imm` / `MOVDW R31, R6`):
  `w0 = ((op<<2 | 1) << 25) | (dst << 20) | (src_type << 5) | src_reg`, `w1 = immediate` when `src_type = 3`.
  Memory-destination forms exist but `asm_OV13B.asm` does not use them; not decoded here.
- Jumps (JNZ/JEZ/JLZ/JGZ/JGEZ/JLEZ; `Jcc reg|imm, label`): `w0 = ((op<<2 | f) << 25) | target_instruction_index`
  with `f = 1` register, `3` immediate; `w1 = register number or immediate`.
- CALL: `w0 = (op << 27) | function_index`, `w1 = 0`.
- WI2C (`WI2C addr, value, len`): `w0 = (flags | op<<11 | len_value) << 16 | addr_value`, `w1 = value`.
  flags: `0x200` if addr is a register else `0x600`; `0x80` if value is a register else `0x180`; `0x20` if len is a register else `0x60`.
- RI2C (`RI2C dst, addr, len`): `w0 = (flags | op<<11 | len_value) << 16 | addr_value`, `w1 = dst_reg << 27`.
  flags: `0x200`/`0x600` for addr register/immediate; `0x20`/`0x60` for len register/immediate.

**Wire payload** for command 0x2090002 is 0x16EC bytes: `u32 sensor_id`, then the 0x15E8-byte compiled script, then 0x104 further bytes
that are zero except four u32 fields set to a small per-sensor index. **INFERENCE:** the `i2cSensor` descriptors the firmware prints
(`deviceId, enRestart, deviceAddrType, regAddrType, deviceAddr`) are carried here, with the device address itself coming from
`SET_SENSOR_PROP` (the I2C config 0x10 / 0x0c above). Unverified.

`asm_OV13B.asm` defines 10 functions (SensorGroupHold, SensorGroupRelease, SensorConvertAGain, SensorSetAGain, SensorGetAGain,
SensorSetItime, SensorGetItime, SensorSetDGain, SensorGetDGain, LensSetPos), well under the 40-function limit.

## 9. Suggested next steps (in order)

1. Run the `START_STREAM` buffer-threshold experiment (section 6). It needs no new reverse engineering.
2. ~~Write a small assembler prototype~~ Done: `scratch/assemble_ov13b.py`, results in section 10.
3. Decompile `FUN_14004d65c` and `FUN_140059c70` to finish the `SET_SENSOR_PROP` / `SET_SENSOR_EMB_PROP` field layouts.
4. Only then add the three commands to a test kernel and read the firmware log with `fw_log_enable=1` to see whether the
   Linux `isp_4_1_1.bin` accepts them. If it rejects them, the remaining route is firmware, as the handoff concluded.

## 10. Assembler prototype results (`scratch/assemble_ov13b.py`)

Run with `python3 -I scratch/assemble_ov13b.py <path to asm_OV13B.asm> --listing`.

- Front end re-implemented from the decompile: tokenizer (delimiters space/tab/comma, `;` comments, <= 4 words, <= 32 chars),
  operands (`R0`..`R31`, `$dec` / `$0xhex`, `@label`; no signs), per-function label scoping, `.function` / `.endfunction`,
  `CALL @func`, and the same limits (500 instructions, 100 labels, 40 functions).
- `asm_OV13B.asm` assembles to **96 instructions, 10 functions, 14 labels** (all limits respected).
  Compiled script = 5,608 bytes; payload = 5,868 bytes (0x16EC). These sizes are fixed constants taken from the Windows code,
  so they are not a check on anything; only the instruction and function counts are real outputs.
- The function table (name, start, end): SensorGroupHold 0..1, SensorGroupRelease 1..3, SensorConvertAGain 3..32,
  SensorSetAGain 32..38, SensorGetAGain 38..44, SensorSetItime 44..65, SensorGetItime 65..70, SensorSetDGain 70..70 (empty),
  SensorGetDGain 70..70 (empty), LensSetPos 70..96.
- Every instruction survives encode -> decode -> compare (96/96), so the bit packing has no overlapping fields for this input.
  Hand-computed vectors (WI2C, RI2C, MOVDW, DIV, JEZ, CALL, MOVB) and five error cases also pass (`--selftest`).

**What this does NOT show.** It does not show that the firmware decodes these words the same way. The vectors come from the same
reading of the decompiler output as the encoder, so they cannot catch a misreading. Open risks:

1. The MOV front-end checks (`FUN_14005cb80`) were not decompiled; they are inferred from the serialiser.
2. Memory operands (`M0[..]`, `M1[..]`) are not implemented; this asm does not use them.
3. The 0x104 trailing bytes in the payload are assumed to be zero except four u32 fields set to a per-sensor index
   (offsets 0x169C, 0x16B0, 0x16C4, 0x16D8). This comes from stack-variable analysis and is the least certain part.
4. A word of `WI2C` / `RI2C` whose length operand is 32 or more would corrupt its own flag bits in the Windows code. The prototype
   rejects that instead of copying the bug; no instruction in this file triggers it.

**Where to get independent confirmation:** the Windows firmware has a matching interpreter (`Svm/svm_interpreter.cpp`,
`RunInstrWi2c`, `RunInstrRi2c`). Decompiling its WI2C / RI2C handlers would confirm the word layout for those two instructions
without hardware, but first the firmware image's CPU architecture has to be identified (not yet attempted, so this may be hard).

## 11. START_STREAM buffer-threshold experiment: results (kernel 7.2.0-1.7-cachyos, 2026-10-15)

Setup: patched `amd_isp4_capture.ko` (`scratch/isp4-threshold/`, parameter `min_start_bufs`), 1080p NV12, 4 mmap buffers
(the driver itself asked for 8: `*nbuffers=8`), dynamic debug on. Logs: `scratch/isp4-threshold/results/20261015-180738-min{4,2,1}.log`.

| min_start_bufs | START_STREAM queued | "no send" lines | firmware reply to START_STREAM | frames (`poc:`) | capture bytes |
|---|---|---|---|---|---|
| 4 (stock) | yes, on the 4th buffer | 4 | none | 0 | 0 |
| 2 | yes, on the 2nd buffer | 2 | none | 0 | 0 |
| 1 | yes, on the 1st buffer | 1 | none | 0 | 0 |

**Observed (identical in all three runs):**
1. `ISP CCPU FW boot success`; the driver then sends the memory pool, stream config, output-channel properties, enables the channel,
   sends the meta buffer, and sends image buffers. `START_STREAM` is queued once the threshold is met.
2. The only firmware response in the whole log is `stream 1,cmd ISP4FW_CMD_ID_SEND_BUFFER(0x02040001)(0),seq 0`: success status,
   sequence 0, which is the **first command the host sent** (the memory-pool `SEND_BUFFER`). No response line appears for anything
   after it, including `SET_STREAM_CONFIG` and `START_STREAM`.
3. About 2 s later the two synchronous teardown commands time out (`fail to disable stream`, `fail to stop stream`; each waits
   `ISP4IF_FW_CMD_TIMEOUT` = HZ/2).
4. No firmware log lines appear. `isp_fw_log_print` is only called from the response thread and only if `fw_log_enable` is set;
   I do not know whether it was set (the script's console output was not captured).

**Conclusions.**
- **The handoff's explanation is not reproduced.** At the stock threshold of 4, four buffers were sent and `START_STREAM` was queued.
  So "START_STREAM is never sent" is not what happens in this run, and lowering the threshold changes nothing.
- **"The firmware rejects the OV13B10" is still unproven.** The firmware stops being visible after its first answer, including
  for commands unrelated to the sensor, so the silence cannot yet be attributed to missing sensor configuration.
- Two explanations remain open and the current logs cannot separate them:
  (a) the firmware does not answer anything after the first command (stalled or erroring), or
  (b) it does answer, but the host never reads the responses (the response thread is woken by an interrupt and re-arms it after each
  drain, see `isp4sd_fw_resp_func`; if the interrupt stops arriving, later responses sit unread in the ring).

**Next diagnostic (not done):** at teardown, log the read and write pointers of the response rings (and the interrupt state). If the
write pointer is ahead of the read pointer, the firmware did answer and the problem is on the host (interrupts / thread). If they are
equal, the firmware really is silent, and the sensor-configuration commands from sections 7-8 become the next thing to try.
Also capture the script's console output, and confirm `fw_log_enable` was set.

## 12. Ring-pointer diagnostic patch (written and built, not yet run)

`scratch/isp4-threshold/0010-isp4-ring-pointer-diagnostic.patch` (on top of 0009). It only reads registers and ring memory; it never
moves a pointer. New function `isp4if_dump_rings()` logs, for the global and stream-1 rings: command ring read/write pointers,
response ring read/write pointers, the ring size, `ISP_SYS_INT0_EN`, `ISP_SYS_INT0_STATUS` and `ISP_STATUS`, and decodes the first
unread response (sequence number, response id, command id, status) when the response ring's read and write pointers differ.
It is called after `START_STREAM` is queued, before each synchronous command (disable channel, stop stream), and when one of them
times out. Lines are tagged `EXP-RING[...]`.

How to read the result (pointers are byte offsets into the ring):

| Observation at the `TIMEOUT` snapshot | Meaning |
|---|---|
| response ring write != read, unread entries decode as normal responses | The firmware did answer; the host did not read the answers (interrupt or response-thread problem). Host-side fix. |
| response ring write == read, command ring read < write | The firmware stopped consuming commands: it is stalled or in an error state. |
| response ring write == read, command ring read == write | The firmware read every command but produced no response (not even for commands it should answer). |
| `INT0_EN` lacks the stream-1 bit (`0x00010000`) while responses are unread | The response interrupt was left disabled: pointer to the interrupt re-arm logic in `isp4sd_fw_resp_func`. |

**Is the SET_SENSOR_PROP reverse engineering needed yet? No.** Reasons:
- If the first row applies, the problem is on the host and the sensor-command layouts are irrelevant for now.
- If the second or third row applies, the firmware went quiet right after the very first command (the memory-pool buffer) and
  before any sensor-related command. The more useful reverse engineering then is the **order** of Windows' bring-up commands between
  firmware boot and `SET_STREAM_CONFIG` (look at `isp_fw_start` and `isp_setup_stream` in `amdcamera.sys`), not the layout of
  `SET_SENSOR_PROP`. Something Windows sends before or alongside the memory pool may be what the firmware needs to keep going.
- The layouts are only needed once the firmware is shown to respond but still produce no frames.
The partial layout is already in section 7 (0x168-byte payload; the first 0x160 bytes of the caps struct, version field forced to 3).

**Superseded by sections 13 and 14:** the diagnostic was run; the host-side explanation is ruled out, and Windows' bring-up order
(sensor data before `SET_STREAM_CONFIG`) makes the sensor commands relevant after all.

## 13. Ring-pointer diagnostic: results (kernel 7.2.0-1.7-cachyos, `fw_log_enable` = Y)

Run: `--values "4"`; log `results/20261015-181931-min4.log`, console `results/20261015-181931-console.txt`. Values are byte offsets,
ring size 2560 bytes, one command = 64 bytes.

| Moment | Command ring (stream 1) rd / wr | Response ring (stream 1) rd / wr | `INT0_EN` | `INT0_STATUS` |
|---|---|---|---|---|
| right after `START_STREAM` queued | 0 / 1088 | 0 / 0 | `0x00410000` | 0 |
| before the 1st synchronous command (~2 s later) | 1344 / 1344 | 64 / 64 | `0x00410000` | 0 |
| after it timed out (disable channel) | 1408 / 1408 | 64 / 64 | `0x00410000` | 0 |
| after stop stream timed out | 1472 / 1472 | 64 / 64 | `0x00410000` | 0 |

The global rings never moved (0 / 0), and `ISP_STATUS` stayed `0x00002402` throughout.

**What this establishes (observed):**
1. **The host-side explanation is ruled out.** The response ring's read and write pointers are equal (64 = one response of 64 bytes, the
   one logged earlier), and no interrupt is pending. The firmware never wrote a second response, so nothing sits unread.
2. **The firmware does consume commands.** The command ring's read pointer catches up with the write pointer every time (1088 -> 1344 ->
   1408 -> 1472), including the two synchronous commands, each within the 0.5 s timeout window. So the firmware CPU is alive and walks
   the ring.
3. **It answers only the first command.** Everything after the memory-pool `SEND_BUFFER` is read but produces no response, including the two
   commands the driver waits for (disable channel, stop stream). On a healthy system those must be answered, so this is abnormal.
4. Both response interrupts are armed (`0x00410000` = stream-1 bit `0x00010000` plus global bit `0x00400000`).
5. `fw_log_enable` was on, yet no firmware log text appeared. **Caveat:** the driver only drains the firmware log when its response
   thread processes a response (`isp_fw_log_print`, called from `isp4sd_fw_resp_func`). The single response arrived before the firmware
   handled the later commands, so any log text it wrote afterwards was never read. The log ring's own pointers were not dumped.

**Not established:** *why* the firmware stays quiet. The leading hypothesis (unproven) is in section 14.

## 14. Windows bring-up order, and what the sensor commands are made of (all OBSERVED unless marked)

**Order in `isp_init_stream` (`FUN_1400161b4`, `amdcamera.sys`):**
1. `FUN_140008820`, `FUN_14002703c`, `FUN_140005e38` (preparatory; not decoded).
2. `FUN_140019fb0` = sensor setup: `SET_DEVICE_SCRIPT` (0x2090002), then `SET_SENSOR_EMB_PROP` (0x1050002), then `SET_SENSOR_PROP` (0x2090001).
3. `FUN_14001c768` = `isp_setup_stream`, whose first act is `FUN_14001ad44` = `isp_set_stream_path`, which sends `SET_STREAM_CONFIG` (0x2010001).
4. State is marked as initialised.
So **Windows sends all sensor information before the stream configuration; Linux sends none of it.**

**`SET_STREAM_CONFIG` payload on Windows is 36 bytes (9 x u32)**, built in `FUN_14001ad44`:
`[0]` enable (1; 0 for one mode), `[1]` sensor id (`FUN_140013608`), `[2]` pipeline id (`FUN_140013e60`), `[3]` flag (0/1),
`[4]` value from the device context (`dev+0x17f8`), `[5..8]` four u32 from the sensor's per-mode table.
Linux sends only the first five words (its `struct isp4fw_isp_stream_cfg`: enable, sensor id, pipeline id, TNR, RTA frames), which
matches word for word in order (INFERENCE from field order). The four trailing words are not sent by Linux.

**SET_SENSOR_PROP payload source (resolves earlier open points):**
- `FUN_140059bdc` just calls the sensor plugin's function at vtable +0x40 with (sensor index, mode, output buffer). The "caps cache" is
  therefore the plugin's `get_caps_OV13B` output (`FUN_140002d70`, decompiled in section 3).
- `FUN_14004d65c` only logs fields; it does not modify the structure.
- `FUN_140059c70` calls the plugin's function at vtable +0xb8 (the embedded-property getter, `get_emb_prop_OV13B`) for `SET_SENSOR_EMB_PROP`.
- So the 0x168-byte payload = `{u32 sensor id, u32 (unset), caps[0..0x160) with caps[0] forced to 3}` can be **replayed** by porting
  `get_caps_OV13B` faithfully, without understanding each field. Inputs it needs from outside the plugin: mode index (`ctx+0x410`),
  interface type (`ctx+0x464`: 4 or 5 are the accepted values; **INFERENCE:** the V4L2 bus-type numbers, 4 = CSI-2 D-PHY, which is also what the
  repo's software-node graph uses), a flag bit (`ctx+0x455` bit 2), a global flag `DAT_14000a57d`, and two small tables in the plugin's data.
  Not yet done.

**Leading hypothesis (UNPROVEN):** the Linux firmware has the OV05C10 pipeline built in, so Linux can create a stream without sensor
commands. For an unknown sensor the pipeline cannot be created, and the firmware drops the stream commands without answering. Evidence
for: the Windows firmware strings `[Pipeline]sensor:%d script is not ready` and `script for sensor:%d not set`; Windows' ordering above;
observation 3 in section 13. Evidence against / untested: the Linux firmware is a different, stripped build and may not implement the
sensor commands at all; AMD has said new sensors need firmware changes.

**Cheapest next tests, in order:**
1. Drain and print the firmware log ring at teardown (it may state the reason) and dump the log ring's pointers. Small patch, same loop.
2. Replay the Windows sensor setup from the Linux driver: `SET_DEVICE_SCRIPT` + `SET_SENSOR_EMB_PROP` + `SET_SENSOR_PROP` before
   `SET_STREAM_CONFIG`, with the 36-byte stream config. Needs the payload builders above (script builder exists:
   `scratch/assemble_ov13b.py`) and an indirect-command sender in the Linux driver.

## 15. Firmware-log drain patch (written and built, not yet run)

`scratch/isp4-threshold/0011-isp4-fw-log-drain.patch` (on top of 0010). New `isp_fw_log_dump()` reports the firmware log ring's own
read/write pointers and drains it; `isp4if_dump_rings()` now calls it, so it runs after `START_STREAM` is queued, before each synchronous
command and when one times out. Log lines are printed at normal level as `EXP-FWLOG: <text>` (previously `dev_dbg`).

How to read the result:

| Observation | Meaning / next step |
|---|---|
| log ring `rd == wr == 0` at every dump | The firmware wrote no log at all. Log level may be low; Windows has `LOG_SET_LEVEL` / `LOG_ENABLE_MOD` / `SET_LOG_MODULE_LEVEL` commands (0x1020019 / 0x102001a / 0x1020009, payloads not decoded) that could be tried. Not informative about the cause. |
| `wr > rd`, text mentions a sensor, script, pipeline, or a missing configuration | Strongest evidence for the hypothesis in section 14: start the replay of the Windows sensor setup. |
| `wr > rd`, text is about something else (memory, clock, power, MIPI/PHY) | Follow what it says; the replay may not be the next step. |
| text is unreadable (binary or hashes only) | Release firmware logs are often terse; record the pattern and compare between runs. |

**Result (OBSERVED):** the log ring stayed at `rd 0 wr 0` at every dump (with `fw_log_enable` = 1). The firmware produced no log text, so
this round was uninformative, and the replay became the next step (see section 16).

## 16. Replay of the Windows sensor setup (patch 0012; written and built, not yet run)

**What is sent** (before `SET_STREAM_CONFIG`, after the memory pool, in `isp4sd_init_stream`):

| Command | ID | Payload | Source |
|---|---|---|---|
| `SET_DEVICE_SCRIPT` | 0x02090002 | 5868 bytes (`isp4_ov13b_script.h`) | `scratch/assemble_ov13b.py` assembling `asm_OV13B.asm` |
| `SET_SENSOR_PROP` | 0x02090001 | 360 bytes (`isp4_ov13b_sensor_prop.h`) | `scratch/build_sensor_prop.py`, a port of `get_caps_OV13B` |

`SET_SENSOR_EMB_PROP` is skipped, as Windows skips it for the OV13B (its getter reports "unsupported").

**How the sending works (OBSERVED in Windows; the checksum rule is identical to Linux's `isp4if_compute_check_sum`):** these are
*indirect* commands. The payload is copied into a GPU-visible buffer; the 64-byte command carries only `{address lo, address hi, size,
checksum}` in its parameter words. Linux's six existing commands are *direct* (the data sits inside the command). Commands are sent with
`isp4if_send_command_sync`, so the log shows per command whether the firmware answered inside the timeout. A timeout is only logged; the
bring-up carries on so the later steps can still be observed.

**Unverified assumptions (GUESSES, not facts):**
- The script encoding and the 0x104-byte tail after the compiled code (assumed zero except four index words) were never checked against firmware.
- The property payload assumes mode 0, variant "3001", bus type 4, and leaves the Windows `dev+0x1804` conditional (clears caps byte 0x12c) unreproduced.
- The Linux firmware may not implement these commands at all (then expect `NO ANSWER`, which would be informative too).
- Not done yet: the 36-byte `SET_STREAM_CONFIG` (Linux sends the first 20 bytes), and the host-side OV13B register init and stream-on
  (on Windows the host writes the 131-entry init table; here `ov13b10` `s_stream` is never called).

**How to read the result:**

| Observation (`EXP-REPLAY` lines and what follows) | Meaning / next step |
|---|---|
| both `NO ANSWER` and the rings look as in round 2 | The firmware ignores/does not know these commands (or rejects the payload silently). Try one of: different encoding assumption, `SET_TUNING_DATA`, log-level commands. |
| script `answered`, property `NO ANSWER` (or reverse) | That one command is understood; the other payload is suspect. |
| both `answered`, and `SET_STREAM_CONFIG` / `START_STREAM` are now answered too | Hypothesis in section 14 confirmed: the firmware needed the sensor description. Next: sensor stream-on from the host, check for frames. |
| both `answered` but the later commands are still not | The firmware accepts the sensor setup but something else is missing; compare `EXP-RING` pointers before/after. |
| a crash, hang or `FAILED` with an errno | Read the log; the payload address or size may be wrong. |

## 17. Replay results (kernel 7.2.0-1.7-cachyos, `replay_sensor_setup=1`, run 20261015-183840)

OBSERVED (`results/20261015-183840-min4.log`, lines 144-171):

| Command | seq | Response | `cmd_status` |
|---|---|---|---|
| `SEND_BUFFER` (memory pool) | 0 | yes | 0 (success) |
| `SET_DEVICE_SCRIPT` 0x02090002, 5868 bytes | 1 | yes | **0 (success)** |
| `SET_SENSOR_PROP` 0x02090001, 360 bytes | 2 | yes | **1 (FAIL)** |
| `SET_STREAM_CONFIG`, out-chan prop, enable chan, `START_STREAM` | 3.. | **none** | n/a |

- The response ring grew to 3 entries (wr 192) and then stayed there; the command ring is consumed to the end (rd = wr = 1472, later 1600).
  Still 0 frames, 0 bytes, no firmware log text (`rd 0 wr 0`).
- The "answered (0)" in the `EXP-REPLAY` line only says a response arrived, NOT that it succeeded. The status is in the debug line
  `stream 1,cmd unknown cmd(0x02090001)(1),seq 2`; the number in the second brackets is `cmd_status`.
- INFERENCE: the Linux firmware DOES implement both sensor commands (the earlier hypothesis that it might not know them is refuted), and it
  accepted my script payload (encoding assumption not contradicted, though acceptance is not proof of correctness). It rejected the
  sensor-property payload: either some field is wrong or it expects a different layout/size. The response carries `isp4fw_error_code`
  (u16) and a 36-byte payload that the driver does not print yet.
- The commands after the sensor setup still get no response at all. Whether that is because the property command failed (no sensor
  configured) is untested; it is the most likely explanation.

Next step (not done): print `isp4fw_error_code` and the 36-byte payload of every command-done response (a few lines in `isp4_subdev.c`),
then vary the `SET_SENSOR_PROP` payload (e.g. size 0x168 vs 0x160, version field, sensor id) while reading the error code.

## 18. Error code of the failed SET_SENSOR_PROP (run 20261015-184345, patch 0013)

OBSERVED (`results/20261015-184345-min4.log`, lines 145-154):

| seq | command | status | `isp4fw_error_code` | 36-byte payload |
|---|---|---|---|---|
| 0 | `SEND_BUFFER` (memory pool) | 0 | 0x0000 | all zero |
| 1 | `SET_DEVICE_SCRIPT` | 0 | 0x0000 | all zero |
| 2 | `SET_SENSOR_PROP` | **1 (fail)** | **0x001b (27)** | all zero |

- Same outcome as section 17, now with a code. The Linux headers (`isp4_fw_cmd_resp.h`) do not name the code values, so what 27 means
  is UNKNOWN. A command-done response with a zero payload carries no extra detail.
- The same payload is rejected consistently, so the failure is deterministic, not a timing effect.
- Candidate causes (GUESSES, ordered by how cheaply they can be tested): (1) a field value or the version word in the property
  payload; (2) the size (360 sent; Windows' wrapper builds 0x168 = 360, so this should match, but the firmware may expect the 0x160
  structure alone); (3) the sensor id; (4) the firmware wants `SET_SENSOR_EMB_PROP` first, or checks something set by a command Linux
  has not sent; (5) the property describes a sensor the Linux firmware does not know.
- To test without guessing: send the property command with variations and see whether the code changes (a different code = a different
  check failed, i.e. progress). The error code is the measurement. Possible variations: size 0x160 / 0x168; sensor id 0 vs 1;
  version word; all-zero payload (shows what the firmware says to garbage); a payload that mimics the OV05C10 values.

## 19. SET_SENSOR_PROP payload variants (run 20261015-184620, patch 0014)

OBSERVED: `results/20261015-184620-min4-var{0,1,2,3}.log`. In all four runs, seq 0 and seq 1 succeed (status 0, code 0x0000) and seq 2
(`SET_SENSOR_PROP`) fails with **status 1, fw_error_code 0x001b**, payload zero:

| variant | payload | seq 2 result |
|---|---|---|
| 0 | as built, 360 bytes | status 1, 0x001b |
| 1 | caps only, 352 bytes | status 1, 0x001b |
| 2 | sensor id 1 | status 1, 0x001b |
| 3 | 360 zero bytes | status 1, 0x001b |

INFERENCE: the firmware's verdict does not depend on the payload's content, size or sensor id (even all zeros gives the same code), so 0x1b is
NOT a payload-validation error. It looks like the command is refused before the payload is examined (state, capability or "not supported"
-type check). Payload tuning is therefore a dead end; the open question is what precondition fails. Seq 3.. still get no response.
Caveat: the script command succeeded, but it was never varied, so it is not shown that the firmware validates the script either.

Discriminating experiments (not done), cheapest first:
1. Send a command with an invalid ID (for example 0x0badbad) and read the code. If it is also 0x1b, then 0x1b means "unknown/unsupported command"
   and the Linux firmware simply does not implement `SET_SENSOR_PROP`. If it is a different code, 0x1b is specific to this command.
2. Send `SET_SENSOR_PROP` before `SET_DEVICE_SCRIPT`, and also with a zero-length script, to test an ordering/state precondition.
3. Send the other Windows commands (`SET_SENSOR_EMB_PROP` 0x1050002, log-level 0x1020019) and compare codes.

Context from the Reddit thread and chat the user pasted (SECONDHAND, not verified by me): an AMD developer said on the kernel mailing list that
the firmware `isp_4_1_1.bin` must also be changed for the Z13 rear camera; the mainline firmware has its sensor driver built in and
knows only its supported sensor(s); an older firmware used a "hybrid" design (host sensor driver, firmware only processes data).
Our result is consistent with that, but does not prove it. Candidate route: the Windows package contains `amdisp.sys` (separate from
`amdcamera.sys`) in `DriverStore/FileRepository/amdisp.inf_amd64_fb5111be9ab9d107/`; whether it embeds an ISP firmware image is
UNCHECKED. Do not redistribute extracted Windows files.

## 20. Bogus command ID (run 20261015-185327, patch 0015)

OBSERVED (`results/20261015-185327-min4-var0.log`, lines 189-207):

| seq | command | status | `isp4fw_error_code` |
|---|---|---|---|
| 1 | `SET_DEVICE_SCRIPT` 0x02090002 | 0 (ok) | 0x0000 |
| 2 | `SET_SENSOR_PROP` 0x02090001 | 1 (fail) | 0x001b |
| 3 | bogus 0x00badbad | **2 (skipped)** | **0x0015** |

- The firmware answers an invalid command promptly with a different verdict (status 2 "skipped", code 0x15) than for `SET_SENSOR_PROP`.
  So 0x1b is NOT the "unknown command" answer: the firmware recognises `SET_SENSOR_PROP` and refuses it for a reason of its own.
  This refutes the reading "the Linux firmware does not implement SET_SENSOR_PROP" (at least in the plain sense).
- Combined with section 19 (payload content, size and sensor id do not change the code): the refusal depends on something other than the payload.
- seq 4.. (`SET_STREAM_CONFIG`, ...) are still not answered.

**Lead found in the Windows sender (OBSERVED, `amdcamera.sys` `isp_set_snr_info_2_fw`, FUN_140019fb0):** the property command is sent with
`FUN_140028bb0(dev, 0x2090001, param_3, 1)`, where `param_3` is the caller's stream/sensor index (the function rejects values above 3);
the payload pointer/size are `{buffer address lo, hi, 0x168, checksum}` (16 bytes, indirect). `SET_SENSOR_EMB_PROP` is sent with stream 0.
Linux sends EVERY command on the stream-1 ring with stream id 1 (`isp4if_get_fw_stream()` always returns `ISP4IF_STREAM_ID_1`; the global
ring, stream 0, is never used). The stream Windows actually passes for the OV13B sensor commands is NOT yet determined (UNKNOWN: depends on
the caller's `param_3`); it may be 0 (global) for sensor setup.

Next experiment (not done): add a parameter to send the two sensor commands on the global ring (stream 0, `cmd_stream_id` invalid) and
compare the code. Also still untested: ordering (property before script), and finding where the Windows caller gets `param_3`.

## 21. The Windows ISP firmware images have the same container as the Linux one (OBSERVED, nothing run)

Windows `amdcamera.inf_amd64_636e6e00d737b319/` ships `srx_isp_firmware_signed.ram` (6022912 bytes) and `srx_h_isp_firmware_signed.ram`
(6027008 bytes), listed in `amdcamera.INF`. Linux uses `/usr/lib/firmware/amdgpu/isp_4_1_1.bin.zst` (3859408 bytes decompressed).

| | Linux `isp_4_1_1.bin` | Windows `.ram` |
|---|---|---|
| first 0x100 bytes | AMD common firmware header (size 0x3ae3d0, header size 0x20, ucode size 0x3ae2d0, ucode offset 0x100, crc32), zero padded | none |
| next 16 bytes | random-looking prefix | random-looking prefix |
| then | `$PS1` header, size field 0x3ae0d0 | `$PS1` header, size field 0x5be500 (srx) / 0x5bf500 (srx_h) |
| `$PS1` bytes 0x20..0x6f | `01 00 00 00 .. a0 5e ed d4 01 9e 48 55 a1 b0 38 07 6a 45 af 50 .. 02 00 00 00 .. 31 20 02 82 .. 00 05 09 03` | identical |
| payload | | |
| total after the header | $PS1 size + 0x200 = 3859152 | $PS1 size + 0x200 = 6022912 / 6027008 |

INFERENCE: the Windows `.ram` file is exactly the "ucode" part of the Linux image (without the 0x100-byte common header), i.e. the same
PSP-signed `$PS1` container with the same type GUID, only a different (bigger, newer: driver dated May 2026) build. The Linux image strings
show an ISP runtime ("IspPipe", "RtPipe", "SIRC-ISP-SDK-R2.02.00"), so the firmware is an ISP SDK build, not generic.
Linux loads it via the PSP (`isp_load_fw_by_psp` in `amdgpu_isp.c`: `amdgpu_ucode_request`, then registers `AMDGPU_UCODE_ID_ISP`).
So a loadable test image could be: Linux common header (size_bytes, ucode_size_bytes, crc32 recomputed) + Windows `.ram`.

UNKNOWN: which `.ram` (srx or srx_h) belongs to this chip; whether the PSP accepts it (signature, version/anti-rollback checks); whether the
header crc32 is verified; how the image gets into the early-boot environment (mkinitcpio embeds amdgpu firmware in the initramfs; the
`updates/<kernel release>` directory is searched first but only after root is mounted). What this would and would not show: if the Windows
firmware answers `SET_SENSOR_PROP` with status 0 it supports the Windows command set and the OV13B, and our Linux driver would then need
the rest of the Windows sequence; it does not make frames appear by itself. Do not redistribute Windows files.

## 22. Test images built (`scratch/build_winfw.py` -> `scratch/winfw/`, NOT yet deployed or loaded)

- `--check` on the stock image: size fields are consistent with the file, and the header `crc32` (0x8a39f1f6) is reproduced exactly by
  `zlib.crc32` over the ucode part (bytes 0x100..end). (The kernel only prints this value, `amdgpu_ucode.c:50`; it does not verify it.)
- Built `scratch/winfw/isp_4_1_1_srx.bin` (6023168 bytes, crc32 0xebeb606d) and `isp_4_1_1_srx_h.bin` (6027264 bytes, crc32 0x023a3a78) =
  stock 0x100-byte header with `size_bytes`, `ucode_size_bytes`, `crc32` replaced + the unchanged Windows `.ram` bytes. All other header
  fields (versions, `ucode_version` 0x00030000, `ucode_array_offset_bytes` 0x100) are copied from the stock header. Hashes: `scratch/winfw/SHA256SUMS`.
- Self-checks in the script: header parses back, sizes add up, the bytes after the header are identical to the `.ram` file.
- Whether the PSP accepts either image, and which one fits this chip, is UNKNOWN until one is loaded. Deployment is not done: it needs
  the file in the early-boot firmware lookup (see section 21), which is a boot-configuration step for the user to approve and run.

## 23. Deployment of the test firmware (scripts written; `--build-only` run, the /boot part NOT run)

- OBSERVED in `/usr/bin/mkinitcpio`: `_d_firmware=({/usr,}/lib/firmware/updates {/usr,}/lib/firmware)`. It searches `updates/` and the main
  directory, NOT `updates/<kernel release>/`. So the per-kernel directory ("option 2" as first worded) would not get into an initramfs, and
  a file in the shared `updates/` would leak into every initramfs regenerated later.
- Design used instead (`scripts/deploy-windows-isp-fw-test.sh`): a small uncompressed cpio (`usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin`)
  is appended to a COPY of the camera-test initramfs, written as `/boot/camera-test/initramfs-fw-<variant>.img`. The kernel unpacks
  concatenated archives one after the other and searches `/lib/firmware/updates` before `/lib/firmware`, so amdgpu gets the test image.
  Stock files, `initramfs.img`, `vmlinuz` and the other kernels are untouched. UNVERIFIED until booted: that the kernel accepts a cpio
  after a zstd archive in this setup (I believe so: the initramfs unpacker handles mixed segments), and that the loader prefers the
  `updates/` copy.
- `--build-only` (run): produced `scratch/winfw/fw-srx.cpio` (6024092 bytes) and `fw-srx_h.cpio` (6028188 bytes), each holding one root-owned
  file; the script first checks each image against `SHA256SUMS`.
- `scripts/restore-stock-isp-fw.sh` deletes nothing: it checks that no override exists in `/usr/lib/firmware/updates`, that `pacman -Qkk`
  reports the ISP firmware unchanged (checked by hand: `linux-firmware-amdgpu: 708 total files, 0 altered files`), lists the added files and
  prints the `rm` / Limine-entry steps for the user to run.

## 24. First run on the Windows-firmware boot entry (srx_h), run 20261015-190857: identical to stock, INCONCLUSIVE

OBSERVED (`results/20261015-190857-*`; kernel 7.2.0-1.7-cachyos, entry chosen by the user: `-fw-srx_h`):
- Boot is healthy: PSP, `isp_v4_1_1` block and display initialise as on the stock entry; `/dev/video0` is the ISP capture node;
  "ISP CCPU FW boot success" appears; no PSP/ucode failure in the kernel log.
- Command verdicts are the same as with the stock firmware: seq 0 ok, seq 1 (`SET_DEVICE_SCRIPT`) ok, seq 2 (`SET_SENSOR_PROP`)
  status 1 / 0x001b with a zero payload; seq 3.. unanswered; response ring stays at 192; command ring catches up (rd = wr = 1600);
  firmware log ring `rd 0 wr 0`; 0 frames.
- Nothing in the kernel log says which firmware image was used (no version line on either entry), and `/proc/cmdline` is the same on all
  entries. The `amdgpu_firmware_info` debugfs (root only) was not read, so it is UNKNOWN whether the test image was loaded at all.

Two readings, not distinguishable yet:
 (a) the Windows firmware really ran and refuses `SET_SENSOR_PROP` the same way -> the refusal is not about missing OV13B support in the
     image; look at preconditions on the host side (stream/ring choice, section 20; the Windows prep calls; sensor power/clock state);
 (b) the stock image was still used (the early cpio not unpacked after the zstd archive, or `updates/` not preferred) -> nothing learned.

Checks to separate them (user runs, need sudo):
 1. the file really is in the combined image:
    `sudo tail -c 6028188 /boot/camera-test/initramfs-fw-srx_h.img | cmp - scratch/winfw/fw-srx_h.cpio && echo same`
 2. the running ISP firmware: `sudo cat /sys/kernel/debug/dri/*/amdgpu_firmware_info | grep -i isp`, on this entry and on the stock entry, and compare
    (the version/feature fields should differ if the Windows image was used; the debugfs layout is an assumption).

## 25. Which ISP firmware did the srx_h boot use? (checks, 2026-10-15)

- OBSERVED (user): `tail -c 6028188 /boot/camera-test/initramfs-fw-srx_h.img | cmp - scratch/winfw/fw-srx_h.cpio` printed `same`, so the test
  image really is the last 6028188 bytes of the combined initramfs.
- OBSERVED (user): `amdgpu_firmware_info` has NO ISP line on this kernel. My earlier `grep -i isp` only matched "SECUREDISPLAY"
  ("DISPLAY" contains "isp"), so that debugfs cannot tell the images apart. (The zsh error before was the glob being expanded as the
  normal user; `sudo sh -c 'cat .../dri/*/amdgpu_firmware_info'` works. Files exist under dri/0000:c4:00.0, dri/1 and dri/128.)
- `amdgpu_ucode_print_common_hdr` is not called for the ISP image, so `drm.debug` would not show it either.
- Better observable (read in source, 7.2.0-1): the firmware loader (`drivers/base/firmware_loader/main.c`, built in) logs at debug level
  "Loading firmware from <path>" (line 569) and, with `CONFIG_FW_LOADER_DEBUG=y` (set in the 1.7 config), "Loaded FW: <name>, sha256: <hash>"
  (line 816). Enable at boot with the kernel option `dyndbg="file drivers/base/firmware_loader/main.c +p"` (`CONFIG_DYNAMIC_DEBUG=y`).
  Expected values: test image `isp_4_1_1_srx_h.bin` sha256 `1f0f826e...7e97`; stock image (decompressed) sha256 `f8ab7f5c...0932`;
  path `/lib/firmware/updates/amdgpu/isp_4_1_1.bin` for the test image, `/lib/firmware/amdgpu/isp_4_1_1.bin.zst` for stock.
  The same lines also show every failed lookup, so any rejected path is visible.

## 26. The srx_h boot used the STOCK firmware: the appended cpio was rejected (OBSERVED)

OBSERVED (user, boot with `dyndbg="file drivers/base/firmware_loader/main.c +p"`):
- `journalctl -k -b -g isp_4_1_1`: "Loading firmware from /lib/firmware/amdgpu/isp_4_1_1.bin.zst", "Loaded FW: amdgpu/isp_4_1_1.bin, sha256:
  f8ab7f5c...0932" = the stock image (size 3859408), not the srx_h image (sha256 1f0f826e...7e97). So section 24 was reading (b): no information
  about the Windows firmware yet; it should be treated as "never tested".
- Early boot log of the same boot: "Trying to unpack rootfs image as initramfs... Initramfs unpacking failed: invalid magic at start of
  compressed archive", then "Freeing initrd memory: 70684K". The main (compressed) archive was unpacked and the system booted from it, and
  the uncompressed cpio that `deploy-windows-isp-fw-test.sh` had appended AFTER it was rejected.
- Cause (kernel behaviour, from the error text and the known microcode case, not re-read in the source): the initramfs unpacker accepts an
  uncompressed cpio followed by a compressed archive, not the reverse.
- Fix applied to the script: the firmware cpio now goes BEFORE the existing initramfs (`cat fw.cpio initramfs.img > initramfs-fw-<v>.img`);
  the printed Limine entries now include the `dyndbg=` option so each test boot logs the path and sha256 it loaded; the post-boot hints now
  use `journalctl -k -b -g unpack` and `-g isp_4_1_1` (the `amdgpu_firmware_info` hint was wrong, there is no ISP line). The stock initramfs
  already starts with an uncompressed early cpio (`microcode` hook), so the new image is [fw cpio][microcode cpio][zstd]; cpio sizes are multiples of 4.
- UNVERIFIED until booted: that the kernel accepts this order here. Success criteria: no "unpacking failed", loader path
  `/lib/firmware/updates/amdgpu/isp_4_1_1.bin`, sha256 `1f0f826e...7e97`.

## 27. RESULT: with the Windows ISP firmware (srx_h) the sensor setup is accepted; START_STREAM fails for missing tuning data (run 20261015-201609)

Verified intervention (OBSERVED, user): boot has no "unpacking failed"; the loader log shows "Loading firmware from
/lib/firmware/updates/amdgpu/isp_4_1_1.bin", size 6027264, sha256 `1f0f826e...7e97` = `scratch/winfw/isp_4_1_1_srx_h.bin`.

Command verdicts (OBSERVED, `results/20261015-201609-min4-var0.log`; same driver, same payloads as the stock-firmware runs):

| seq | command | stock fw | Windows srx_h fw |
|---|---|---|---|
| 0 | SEND_BUFFER (memory pool) | ok | ok |
| 1 | SET_DEVICE_SCRIPT (0x2090002) | ok | ok |
| 2 | SET_SENSOR_PROP (0x2090001) | fail 0x1b | **ok** |
| 3 | SET_STREAM_CONFIG (0x2010001) | no answer | **ok** |
| 4 | SET_OUT_CHAN_PROP (0x2010003) | no answer | **ok** |
| 5 | ENABLE_OUT_CHAN (0x2010005) | no answer | **ok** |
| 6..17, 19..22 | SEND_BUFFER (meta + preview buffers) | no answer | **ok** |
| 18 | START_STREAM (0x2010007) | no answer | **fail, error 0x27** |
| 24 | STOP_STREAM (0x2010008) | timeout | fail 0x27 |

CONCLUSIONS (OBSERVED unless marked):
- The Linux firmware (`isp_4_1_1.bin`) does not support the OV13B sensor setup; the Windows firmware does. This confirms the thread's claim
  that the firmware has to change, and shows the Windows image loads on Linux through the normal amdgpu/PSP path (no rejection, display fine).
- My ports are right as far as the firmware checks: it parsed the replayed payloads. Its log: "Parsing indirect command 0x02090001",
  "SetPropertyParameterHandler:SensorID:0 [4208x3120] HDR:0", "sensor:0 script is ready", then "assign pipeline 'Mipi0CsisCstat0=>Lme=>Isp'
  to stream 1", "stream 1 is using RGB sensor", "SetOutChProp: output channel 0 width 1920 height 1080 ... image format 1".
- The firmware log now works (the stock image logged nothing): firmware "ISP Firmware Version: 51.0.8.0", build 2026/05/08, commit C14A4BA6,
  core config `isp4p1_lx7hifi5_PROD` = a Cadence/Tensilica Xtensa LX7 HiFi5 core, "LLFW version 4.1", "ISP Generation: 5", "Check Dual Boot
  mode timeout, boot as single mode" (error line, boot continues). The first 150 log lines are shown by the test script; the full text is in the `.log`.
- WHY START_STREAM FAILS (from the firmware log, lines 461-499 of the `.log`): the command is held ("Find delay response") while the pipeline
  is configured. Then: "LoadHostSetfileBufferAddresses: Host setfile buf queue empty" -> "failed to configure host setfile manager" (warning);
  about 2.5 s later "RtaTuneIfGetSetfileAddr: getTuneSetfileAddr failed!" -> "RTA setfile buf empty" -> "failed to configure RTA setfile manager"
  -> "Init: pipeline configuration failed for streamId:1!" -> START_STREAM `cmdStatus:1`, code 0x27; STOP_STREAM then fails too
  ("pipeline stop failed"). I.e. the firmware wants **setfile (tuning) buffers from the host** and the Linux driver sends none. The
  buffer manager's queue "type=14" is the host-setfile queue (INFERENCE: type numbers of SEND_BUFFER).
- Also logged, probably harmless but unverified: "PrepareIspParam: Video/Still channel is not enabled or no image property" (only the
  preview channel is configured); "CSIS Frame queue empty" (the sensor is not streaming: no host sensor init/stream-on yet); "Mem
  performance may not meet RT task schedule requirement" (warning).
- Tuning data on Windows: `OV13B_3001_ROG_SRX.atb` (566 KB, `sensorov13b.inf_amd64_817a026ab537dd2a/`), delivered with `SET_TUNING_DATA`
  (0x2050008) per section 5 item 3. How exactly it is sent (direct vs indirect, buffer type, one or several buffers, what the "RTA" and
  "host" setfiles are) is NOT decoded yet.

NEXT (not done): decode the Windows sender of `SET_TUNING_DATA` / the setfile SEND_BUFFER type in `amdcamera.sys` (rea is available), then
replay the `.atb` through a new experimental parameter; then see whether START_STREAM succeeds. After that the remaining missing piece
for frames is the host-side OV13B register init and stream-on (the firmware log shows "Frame queue empty").
The test boot entry stays in use; do not hibernate on it; pick a normal entry afterwards.

## 28. How Windows delivers the tuning data (`SET_TUNING_DATA`, decoded from `amdcamera.sys`)

All OBSERVED in the decompile (addresses are image addresses; function names are from the driver's own log strings):

1. **Load (once, when the sensor interface is added).** `CIspDevice::AddSensorInterface` (0x14005fd48) and `CIspDevice::InitalDevice`
   (0x1400653bc) call `CIspDevice::load_tuning_data` = `FUN_14006affc(dev, sensor index, &size)`. It allocates 0x300000 (3 MB) of pool,
   builds the path `\SystemRoot\system32\AMD\%S_%S_%S_SRX.atb` from three strings reported by the sensor plugin (here
   `OV13B` / `3001` / `ROG`), reads the file into the buffer and returns buffer and size. Fallbacks if the file is missing:
   `\SystemRoot\system32\AMD\calibdb_mem.bin`. A second loader `FUN_14006ada4` (`load_default_tuning_data`, `%S_%S_%S_default_SRX.atb`)
   fills a second blob; neither a `_default_` file nor `calibdb_mem.bin` exists on this machine, so the second blob is empty.
   The file used is `System32\AMD\OV13B_3001_ROG_SRX.atb` (565520 bytes, sha256 `6b5cc5f8...4b42`, identical to the DriverStore copy;
   header: magic `79 56 34 12`, then `08 06 00 00`, a version-like string "B076I", then zeros).
2. **Send (every stream init).** `isp_set_calib_2_fw` = `FUN_140018c90(dev, ?, stream)` is called from `isp_set_snr_info_2_fw` BEFORE
   `SET_SENSOR_PROP` (the `SET_SENSOR_EMB_PROP` step is skipped for the OV13B). It
   - takes a firmware-visible buffer object (`dev + stream*0xb0 + 0x358`; GPU address at `+0x18`, CPU address at `+0x20` of the object it points to),
   - copies the tuning blob (pointer/size from the `dev+0x1290+idx*0x50` record, +0x18 / +0x20; INFERENCE: the same bytes `load_tuning_data` read)
     to offset 0 of that buffer, and, only if a second blob exists, copies it to offset **0x300000**,
   - sends command **0x2050008** with `isp_send_fw_cmd(dev, 0x2050008, stream, 1, params, 0x30)`: a 12-word (0x30-byte) parameter block.
3. **The 12 parameter words** (little endian u32; layout read from the stack variables):

| word | value | meaning |
|---|---|---|
| 0 | `0x0000000e` (14) | BUFFER TYPE (INFERENCE): equals the firmware log's "BUF\|queue empty:type=14" for the host-setfile queue; the driver has a string `BUFFER_TYPE_SETFILE_DATA` |
| 1 | 0 | |
| 2 | 4 | unknown (count/flags); copied as is |
| 3, 4 | GPU address lo, hi of the buffer | tuning blob at offset 0 |
| 5 | size of the tuning blob (565520) | |
| 6, 7 | GPU address + 0x300000 | only when a second blob exists, else 0 |
| 8 | size of the second blob | else 0 |
| 9..11 | 0 | |

   No checksum word in the parameters (unlike `SET_SENSOR_PROP`'s `{addr lo, hi, size, checksum}`); the 64-byte command's own checksum is
   computed by the sender as for all commands (Linux's `isp4if_compute_check_sum` rule).
4. `isp_send_fw_cmd` (`FUN_140028bb0`) is a thin wrapper: `(dev, cmd id, stream index (must be < 4), flag, payload ptr, payload size)`.

Replay design (NOT written): a module parameter naming the `.atb` file; the driver reads it (so no Windows data goes into the source),
copies it into a new firmware-visible buffer (offset 0, buffer at least 0x300000 + nothing else), and sends the 12-word command between
`SET_DEVICE_SCRIPT` and `SET_SENSOR_PROP` (Windows order). Success criterion: the firmware log no longer says "Host setfile buf queue
empty" / "getTuneSetfileAddr failed" and `START_STREAM` (seq 18) returns status 0. UNKNOWN: word 2's meaning; whether firmware wants the
data before or after `SET_SENSOR_PROP`; whether a buffer type 14 is also expected through `SEND_BUFFER`.

## 29. Tuning-file replay patch (0016; written and built, not yet run)

`scratch/isp4-threshold/0016-isp4-tuning-file-replay.patch` (`isp4_interface.c` only, on top of 0015). New module parameter `tuning_file`
(path). With `replay_sensor_setup=1` and a path, `isp4if_replay_tuning()` reads the file with `kernel_read_file_from_path()` (cap 0x300000
bytes, as Windows' buffer), copies it to offset 0 of a new 0x300000-byte GPU buffer and sends `SET_TUNING_DATA` (0x02050008) synchronously
with the 12-word parameter block of section 28 (`{14, 0, 4, addr lo, addr hi, size, 0, 0, 0, 0, 0, 0}`), after `SET_DEVICE_SCRIPT` and before
`SET_SENSOR_PROP`. The buffer is kept (static pointer) until `isp4if_dealloc_fw_gpumem()` because the firmware may reference it later.
Log line: `EXP-REPLAY: SET_TUNING_DATA: <n> bytes from <path> at GPU 0x... -> answered/NO ANSWER`; the verdict is the `EXP-RESP` line with `cmd 0x02050008`.

How to read the result (needs the Windows-firmware boot entry; on the stock firmware nothing is expected to change):

| Observation | Meaning / next step |
|---|---|
| `EXP-RESP ... cmd 0x02050008 status 0`, no "setfile buf empty" lines, `START_STREAM` seq status 0 | Tuning data was the missing piece. Remaining for frames: host-side OV13B register init and stream-on. |
| tuning command status 1 with an error code | Layout/order is off: suspects are word 2 (4), the buffer type (14), the order relative to `SET_SENSOR_PROP`, or the buffer size. Read the firmware log lines right after it. |
| tuning command ok, but still "Host setfile buf queue empty" | The host setfile also needs a `SEND_BUFFER` of type 14 (UNKNOWN); compare with the Windows `isp_send_metadata_buf` path. |
| "cannot read <path>" | Wrong path or the Windows partition is not mounted when the module loads. |

## 30. RESULT: tuning data accepted; START_STREAM now fails for lack of internal buffers; Windows' memory pool is 200 MiB (run 20261015-203125)

OBSERVED (`results/20261015-203125-*`, Windows srx_h firmware, replay + `--tuning-file .../OV13B_3001_ROG_SRX.atb`):
- `SET_TUNING_DATA` (seq 2, 565520 bytes, 12-word block of section 28) -> **status 0**. Every command up to `START_STREAM` succeeds again;
  the "Host setfile buf queue empty" / "getTuneSetfileAddr failed" / "RTA setfile buf empty" errors are GONE. The decode in section 28 was right
  (buffer type 14, descriptor layout, order before `SET_SENSOR_PROP`).
- `START_STREAM` (seq 19) still fails, status 1 / error 0x27, but for a new reason, from the firmware log (`.log` lines 513-522):
  "BUF_MGR GetBuffer: MEM|no buffer found" -> "AllocInternalRawTmpBuf: stream:1 raw tmp internal buffer allocation failed" (twice) ->
  "intbufmgrbuffer 2 is not available" -> "Cstat lmeds01 buffer is not available" -> "ReserveTmpFrame: failed to allocate internal dma
  buffer for reserved tmp frame" -> "Init: pipeline failed to reserve tmp frame for streamId:1!". Then `ENABLE_OUT_CHAN` (seq 24) fails 0x1e
  (done-response timeout) and `STOP_STREAM` (seq 25) fails 0x27. Still 0 frames; the sensor is not started yet ("Frame queue empty").
- The firmware reports its pool: "SetMemPool: addr=0x7FFF03830000, size=104857600" = the Linux driver's `ISP4FW_MEMORY_POOL_SIZE` (100 MiB).
- OBSERVED in Windows (`FUN_140008820` = `IspSetupFwdMemPool`): the pool is allocated with `FUN_140006f2c(dev, 0xC800000, 3)` = **200 MiB**
  (209715200 bytes, not sensor-dependent in the code seen), and sent with `SEND_BUFFER` (0x2040001) as the 12-word block
  `{0xf (buffer type MEM_POOL), 0, 4, addr lo, addr hi, size, 0...}` (same shape as the tuning block). Linux sends the same layout with 100 MiB.
- INFERENCE: the 13 MP sensor mode (4208x3120 RAW, tens of MB per frame) needs more internal buffers than the OV05C10-sized 100 MiB pool holds;
  the firmware's allocator ("MEM|no buffer found") runs dry while building the pipeline. Cheapest test: send a 200 MiB pool.

NEXT (needs approval): module parameter for the pool size (default unchanged = 100 MiB), in `isp4if_alloc_fw_gpumem()` (`isp4_interface.c`), test with 200.
If it still fails: Windows allocates other work buffers (`ISP_WORK_BUF_TYPE_*`, `isp_get_work_buf`: LB_RAW_DATA, LB_RAW_INFO, STREAM_YUV_TMP,
STREAM_OFM_TMP, STAT, ...) and the firmware may expect some of them via `SEND_BUFFER`; decode those next.

## 31. Pool-size patch (0017, built, not yet run) and srx versus srx_h

**Patch 0017** (`scratch/isp4-threshold/0017-isp4-fw-mem-pool-param.patch`, `isp4_interface.c` only, on top of 0016): module parameter
`fw_mem_pool_mb` (0 = stock 100 MiB). `isp4if_alloc_fw_gpumem()` now allocates `fw_mem_pool_mb` MiB when set and logs
`EXP: firmware memory pool <bytes> (fw_mem_pool_mb|stock)`. The size sent to the firmware already comes from the allocation (`mem_size`),
so the `SEND_BUFFER` memory-pool command carries the new size automatically. Test script: `--pool-mb N`. Success criterion: the firmware's
"SetMemPool ... size=" line shows 209715200 and the "MEM|no buffer found" / "tmp frame" errors disappear (section 30).

**srx versus srx_h (OBSERVED).**
- The two Windows images are different builds with the same core config `isp4p1_lx7hifi5_PROD`: `srx_isp_firmware_signed.ram` reports
  "ISP Firmware Version: 41.5.9.0", `srx_h_isp_firmware_signed.ram` reports "51.0.8.0" (the version the log showed on the srx_h boot). Both
  contain "failed to match compatible setfile version to firmware version" checks, i.e. the tuning file has to match the firmware version.
- `CIspDevice::SetFWBinary` (`FUN_14006844c`, `amdcamera.sys`, read buffer cap 0xa00000 = 10 MiB) chooses the image from a byte in the hardware
  structure, `*(char *)(hw + 0x17f4)`: **`srx_h` when it is 4, otherwise `srx`**. The byte is logged next to `hw + 0x1736`. The value on this
  machine was not read. INFERENCE: "_h" stands for the Strix Halo variant (this laptop has a Strix Halo APU and the Windows driver on it works),
  so Windows would pick `srx_h` here. The Linux image `isp_4_1_1.bin` (firmware 41.x? not read) and its `$PS1` GUID equal both Windows images' GUID.
- Verdict: trying `srx` is cheap (the Limine entry `-camera-fw-srx` already exists) but not expected to help; its only use would be to see
  whether an older build (41.5.9.0) behaves differently with the same sensor setup. Do the pool test on `srx_h` first.

## 32. RESULT: with a 200 MiB pool `START_STREAM` SUCCEEDS; the pipeline is armed and waits for sensor data (run 20261015-203645)

OBSERVED (`results/20261015-203645-*`, Windows srx_h firmware, replay + tuning file + `--pool-mb 200`):
- Firmware log: "SetMemPool: addr=0x7FFF03830000, size=209715200" (was 104857600). The "MEM|no buffer found" / "raw tmp buffer" / "tmp frame"
  errors are GONE. `EXP-RESP`: **seq 19 `START_STREAM` (0x02010007) status 0**; every command from seq 0 to 23 succeeds.
  So the memory pool was the missing resource (section 30's inference confirmed): sensor setup, tuning data and a 200 MiB pool are
  sufficient for the firmware to configure the Mipi0 -> Csis -> Cstat -> Lme -> Isp pipeline for stream 1.
- What happens next in the firmware log (lines ~467-940 of the `.log`): "enable CSIS[0] otf output", "IspShotInternal ... IspHardwareShot :CSIS / MIPI0"
  (the hardware is armed to receive a frame), then ~1.3 s of nothing: the counters print `[CSIS]fs(0), cl(0), fe(0), dma(0)` (and MIPI0/1/2 the same,
  i.e. no frame start / line / frame end seen), "IspHardwareShotTimer: [S:0|MIPI0] false alarm timeout", "PipeFrmDoneTimerHandler: [Pipe][Mipi0CsisCstat0][stream 1][Fcount 0]
  frame done timeout". Then the stop path: "IspHwIpDisable: [S:0|MIPI0] Failed in waiting for V_VALID state", and `ENABLE_OUT_CHAN`
  (seq 24, the disable) and `STOP_STREAM` (seq 25) fail with 0x1e after "done response timeout".
- Therefore: **no data arrives on the MIPI CSI-2 receiver** because the sensor is not streaming (the Linux capture driver never starts the
  OV13B; `ov13b10` `s_stream` is never called, section 4/6). Also logged: "LoadFrameMetaData: No meta data buffer is available / PopFrontBuffer: BUF|queue empty:type=13"
  (4 times right after START_STREAM): per-frame metadata buffers (type 13) are consumed faster than the 2 the driver sends; probably harmless
  until frames flow, UNVERIFIED. Still 0 frames / 0 bytes from `v4l2-ctl`.
- Firmware identity (from the log): version 51.0.8.0, build 2026/05/08, "isp4p1_lx7hifi5_PROD", ISP generation 5.

REMAINING for a first frame (not done): (1) host-side sensor bring-up: power (ACPI already handles it with the kernel patch), the OV13B register
init for mode 0 (4208x3120, 4 lanes?, Windows table `res_0_config_OV13B` in `sensorOV13B.sys`, 131 register pairs; compare with upstream `ov13b10.c`)
and stream-on (reg 0x0100 = 1) at the right moment (after `START_STREAM`, probably, so the receiver is armed); (2) possibly more metadata buffers;
(3) then fix the stop path (probably fine once frames flow).
Cheap first experiment: start the sensor from the existing `ov13b10` driver while `START_STREAM` is armed and see whether `fs(...)` changes.

**State of the sensor side on this boot (OBSERVED, 2026-10-16):**
- `/sys/bus/i2c/devices/i2c-ov13b10` is an I2C client on **i2c-21**, the ISP's own bus (`amd_isp_i2c_designware.2.auto`), with the `ov13b10` driver bound
  ("supply dovdd/avdd/dvdd not found, using dummy regulator" at probe). There is no `/dev/v4l-subdev*` node: the subdev is registered with
  no bridge, so userspace cannot stream it; it can only be started from inside the kernel.
- The upstream `ov13b10_set_stream(sd, 1)` (7.2.0-1 source) does everything for the sensor in one call: runtime-PM resume (`power_on`: clock, regulators,
  reset GPIO), `ov13b10_identify_module` (reads the chip ID over I2C: a free test of the I2C link and power), software reset, PLL registers for the link
  frequency (560 MHz in the table, 4 or 2 data lanes taken from the firmware node), mode registers, controls, then `0x0100 = 1` (stream on).
  Mode 0 is the 4208x3120 mode the replayed sensor properties describe (to be confirmed by the log).
- The Linux ISP driver has no reference to the sensor subdev at all (it hard-codes `ISP4FW_SENSOR_ID_ON_MIPI0`).

**Proposed experiment (not done):** a module parameter `start_sensor=1` that, right after `START_STREAM` is queued and acknowledged, finds the sensor with
`bus_find_device_by_name(&i2c_bus_type, NULL, "i2c-ov13b10")`, takes the `struct v4l2_subdev` from the client data and calls
`v4l2_subdev_call(sd, video, s_stream, 1)` (and 0 at stop), logging the result. Success criterion: the firmware's `fs(..)/fe(..)` counters or
`FrameStart`/`FrameDone` lines for MIPI0/CSIS become non-zero, "frame done timeout" disappears, `v4l2-ctl` returns frames.
Likely failure modes to read from the log: identify-module I2C error (power/clock/reset), PHY/lane/rate mismatch between the sensor's 560 MHz link and
what the ISP expects (the receiver would see errors rather than silence), or timing (the firmware gives up after ~1.3 s).

## 33. Sensor start patch (0018; written and built, not yet run)

`scratch/isp4-threshold/0018-isp4-start-sensor.patch` (`isp4_subdev.c` only, on top of 0017). Module parameter `start_sensor`: 0 off (default), 1 start the
sensor right after `START_STREAM` has been queued, 2 right before. The helper finds the I2C client with
`bus_find_device_by_name(&i2c_bus_type, NULL, "i2c-ov13b10")`, takes the `struct v4l2_subdev` from its client data, calls
`v4l2_subdev_call(sd, video, s_stream, 1)` and logs `EXP-SENSOR: <subdev name> s_stream(1) after|before START_STREAM -> <ret>`. It keeps a device
reference while streaming and calls `s_stream(0)` from `isp4sd_uninit_stream()` (log line `EXP-SENSOR: ... s_stream(0) -> <ret>`). Both places that
send `START_STREAM` (kickoff and buffer queue) are covered. The test script now prints the `EXP-SENSOR`/`ov13b10` kernel lines and the number of
firmware `FrameStart`/`FrameDone` lines and frame-done timeouts for each run (`--start-sensor N`).

How to read the result:

| Observation | Meaning / next step |
|---|---|
| `EXP-SENSOR ... s_stream(1) -> 0`, firmware `FrameStart HWID:MIPI0/CSIS` lines for F:0, F:1.., no "frame done timeout", `frames>0`/bytes>0 | First frames. Then look at the image (format, colour: the tuning/script may need refinement) and the stop path. |
| `s_stream(1)` fails with an I2C error from `ov13b10` (chip-ID read, `-EREMOTEIO`, `-ETIMEDOUT`) | Sensor power/clock/reset is not up: ACPI power resources, the `img_clk`, the reset GPIO (dummy regulators at probe). Next: ACPI/`_PS0` for OMNI13B1 and the Windows power-up (`isp_snr_enbale_ldo_power`, `reset_sensor_phy`). |
| `s_stream(1) -> 0` but the firmware counters stay 0 / "frame done timeout" | The sensor runs but no CSI-2 data reaches the receiver: lanes, link rate (560 MHz upstream), PHY setup or mode mismatch. Compare with the Windows register table (`res_0_config_OV13B`) and the ISP PHY configuration. Try mode 2 (sensor first). |
| the firmware shows MIPI/CSIS error lines (CRC, ECC, lane errors) instead of silence | Data arrives but is malformed or at the wrong rate: wrong lane count or link frequency. |
| `no I2C device i2c-ov13b10` | The sensor client is not present on this boot (needs the patched amdgpu/ISP stack; same kernel entry as before). |

## 34. RESULT: the sensor start fails at its first register write (EIO) (run 20261015-204439, `start_sensor=1`)

OBSERVED (`results/20261015-204439-*`, Windows srx_h firmware, replay, tuning file, 200 MiB pool, `--start-sensor 1`):
- The commands behave as in section 32 (everything through `START_STREAM` seq 19 status 0; disable/stop fail 0x1e).
- `EXP-SENSOR: ov13b10 21-0010 s_stream(1) after START_STREAM -> -5` and the sensor driver's own line
  `ov13b10 i2c-ov13b10: ov13b10_start_streaming failed to set powerup registers`. So the sensor is client 21-0010 (I2C address 0x10 on the ISP's bus 21), the
  call reached the driver's `start_streaming`, and the failing step is the one that follows the chip-ID check: the write of `OV13B10_REG_SOFTWARE_RST` (0x0103 = 1) via
  `i2c_master_send()`; the driver converts any failure to `-EIO` (-5), so the real error (NACK, timeout, arbitration) is hidden. No I2C controller messages in the log.
- The firmware counters in this run: 2 "FrameStart/FrameDone" lines (the internal shots when the receiver is armed, as in section 32) and 1 "frame done timeout";
  0 frames from v4l2-ctl. The sensor never started, so this says nothing yet about lanes/link rate.
- At probe the driver identifies the chip only if ACPI reports the device in D0 (`acpi_dev_state_d0`); otherwise `identified` stays false and `s_stream`
  does it. Either way a chip-ID read passed (or was skipped as already done) before the failing write. `/sys/bus/i2c/devices/i2c-ov13b10/power/runtime_status` reads `active`.
- INFERENCE (unverified): candidates for a write failing where a read worked earlier: (1) the sensor lost power/reset between probe and now (dummy regulators, optional reset GPIO,
  ACPI power resource not driven by the ISP stack); (2) the I2C controller on bus 21 is owned/used by the ISP firmware while it runs (the firmware's `SET_DEVICE_SCRIPT`
  contains I2C instructions for the sensor), so host transfers fail or collide; (3) the bus/controller clock is gated while the ISP is idle.
- Not done / next: (a) a userspace baseline, with the ISP idle, using `i2ctransfer` on bus 21 address 0x10: chip-ID read `w2@0x10 0x30 0x0a r3` (expect `56 0d 42`) and a harmless write; (b) log the real errno
  and the state during the run by doing a raw `i2c_transfer()` read and write in `isp4sd_exp_sensor_start()` before calling `s_stream` (patch 0019).

## 35. Raw I2C probe patch (0019; written and built, not yet run) and the userspace baseline

- The userspace attempt `sudo i2ctransfer -y 21 w2@0x10 0x30 0x0a r3` printed "Could not set address to 0x10: Device or resource busy". That is NOT a hardware result: the
  kernel's `ov13b10` driver owns address 0x10, so the I2C character device refuses unless forced. Use `-f` (force) for a read: `sudo i2ctransfer -f -y 21 w2@0x10 0x30 0x0a r3` (expect `0x56 0x0d 0x42`).
  Needs `i2c-dev` loaded (`/dev/i2c-21`).
- Patch 0019 (`scratch/isp4-threshold/0019-isp4-sensor-i2c-probe.patch`, `isp4_subdev.c` only, on top of 0018): `isp4sd_exp_i2c_probe()` runs two raw `i2c_transfer()` calls on the sensor client's
  adapter: read 3 bytes at register 0x300a (chip ID) and write 0x00 to register 0x0100 (standby, harmless). Called before `s_stream(1)` and, if that fails, again afterwards. It logs
  `EXP-SENSOR: raw I2C (before s_stream|after failed s_stream) adapter <name> addr 0x10: chip-id read ret <n> (id xx xx xx, want 56 0d 42), write 0x0100=0 ret <n>, sensor runtime-active <0|1>`.
  `i2c_transfer()` returns the number of messages completed (2 for the read pair, 1 for the write) or a negative errno.

How to read the result (run with `--start-sensor 1`, and also `--start-sensor 2` to compare the bus state before the firmware's `START_STREAM`):

| Raw probe result | Meaning / next step |
|---|---|
| read ret 2, id `56 0d 42`, write ret 1, then `s_stream` still fails | The bus works; the failing write is in the driver's own sequence (maybe the software-reset register 0x0103) or a timing/power effect of `pm_runtime_resume_and_get`. Compare with the Windows power-up. |
| read `-ENXIO` (-6) | The sensor does not acknowledge: not powered, in reset, or the address/bus is wrong. Look at ACPI power resources / reset GPIO and the Windows `isp_snr_enbale_ldo_power`, `reset_sensor_phy`. |
| read `-ETIMEDOUT` (-110) or `-EAGAIN` (-11) | Bus trouble: controller clock gated, firmware master on the same bus, arbitration. |
| read ok but wrong id | Different chip or mode (e.g. powered but not the expected OV13B10); read other ID registers. |
| read ok, write fails | Write path specific: write-protect style behaviour, or a controller issue with longer messages. |

## 36. RESULT: the sensor never acknowledges on I2C: it is not powered/enabled (runs 20261015-205402 mode 1, 20261015-205458 mode 2, patch 0019)

> **CORRECTION (see section 37):** the bullet "Why nothing powers it" below is WRONG. The earlier sessions already found the sensor's power/enable pin (`amdisp-pinctrl`
> GPIO 0, mapped as the OV13B10 "reset" line, patch 0005) and the sensor identified and bound at probe. What is true: the sensor does not answer at CAPTURE time.
> The "NEXT" ACPI-dump step below is therefore not the first thing to do.

OBSERVED (`results/20261015-205402-console.txt`, `-205458-console.txt`; Windows srx_h firmware, replay, tuning file, 200 MiB pool):
- Raw probe on the sensor's adapter ("AMDISP DesignWare I2C adapter", bus 21, address 0x10): chip-ID read `ret -121` (id 00 00 00, want 56 0d 42), write of register 0x0100 `ret -121`, "sensor runtime-active 1".
  -121 = `-EREMOTEIO`: the controller got no acknowledge. Identical BEFORE `s_stream` and AFTER the failed `s_stream`, and identical whether the sensor start happens before (mode 2) or after
  (mode 1) `START_STREAM`. `s_stream(1)` -> -5 in both. A userspace read with the ISP idle (`sudo i2ctransfer -f -y 21 w2@0x10 0x30 0x0a r3`) also fails: "Remote I/O error".
- CONCLUSION: the OV13B at 0x10 does not answer on any of these occasions. It is unpowered, held in reset/shutdown, or lacks its clock; it is not a bus conflict with the firmware and not a timing issue
  of the stream start. (The earlier hypotheses (2) firmware owns the bus and (3) clock gated while idle in section 34 are not supported: the failure is the same with the ISP idle.)
- Why nothing powers it (OBSERVED): `ov13b10` uses dummy regulators and an optional "reset" GPIO that does not exist here (probe log), and an `img_clk` it only enables; `amd_isp4.c` has software nodes for OMNI5C10 only,
  with no GPIO/regulator/reset properties; for the reference sensor the ISP firmware drives everything (no host `ov05c10` driver in this tree). The Windows bridge driver `amdisp.sys` (51 KB) is a stub with no
  power strings (INF: `ACPI\AMDI0201`, `ACPI\AMDI1591`); `amdcamera.sys` calls power through an interface table (`isp_snr_enbale_ldo_power` -> function at table+0xf8, `FUN_140059a34`; `CIspSensor::EnableLDOPower`,
  `EnControlLdo`, `reset_sensor_phy`, command name `CMD_ID_SNR_ENABLE`). INFERENCE: the real sequence is in ACPI (power resources / `_PS0` / GPIO) and/or ISP-side GPIOs (this machine has `amdisp-pinctrl.3.auto`; kernel config
  `CONFIG_PINCTRL_AMDISP=m`).
- The sensor's ACPI device is `\_SB_.CAMB` (HID `OMNI13B1`, uid 0, status 15 = present/enabled), bound as platform device `OMNI13B1:00`. No ACPI table dump exists in the project yet.

NEXT: `scripts/dump-acpi-tables.sh` (written, not run) dumps DSDT+SSDTs into `scratch/acpi/` and decompiles them; then read `CAMB` (`_CRS`: I2cSerialBus address, GpioIo pins, `_PS0`/`_PS3`, `_ON`/`_OFF`, `_DSM`, power resources) and
the GPIO controller they refer to, to see what must be switched on (and whether the Linux ISP GPIO/pinctrl driver exposes those lines). Alternative: find the Windows implementation behind the interface table (`FUN_14005a174`).

## 37. Prior work found the pins and the sensor powered up at probe; today's NACK is a state problem between probe and capture (repo check, 2026-10-16)

OBSERVED in the repo / on the machine:
- `/home/termis/Projects/handoff.md` (2026-08-24/25) and the patches in `/mnt/windows/Users/Termis/linux-cachyos-camera/linux-cachyos/`:
  `0001` (amdgpu: recognize `OMNI13B1`), `0002` (`amd_isp4`: OV13B10 board info, I2C address 0x10, software-node graph, 4 CSI-2 lanes, 560 MHz link), `0003` (register the ISP enable GPIO
  lookup `enable_isp` = `AMDI0030:00` pin 85 for the GZ302), `0004` (`ov13b10` I2C device id), `0005` (map **`amdisp-pinctrl` GPIO 0 as OV13B10's "reset" line, `GPIO_ACTIVE_LOW`**: "the polarity that allowed
  the driver to identify and bind the sensor"; before it the probe's identification returned -EIO), `0006` (force_stream at probe, experiment), `0007` (PLL experiment), `0008` (capture-time `s_stream`, unbuilt).
  The pin: GPIO 0 of the ISP's own pin controller is the sensor enable (same line the OV05C10 reference platform uses as its sensor "enable").
- The running `7.2.0-1.7-cachyos` `amdgpu` really contains these lookups: its strings include `i2c-ov13b10`, `amdisp-pinctrl`, `OMNI13B1`, `enable_isp`. At boot the `ov13b10` probe printed only the three
  dummy-regulator notices and no "failed to find sensor", i.e. it identified the chip and bound. The old `force_stream` test (0006) called the sensor start callback successfully at probe time.
- The old handoff conclusion that the firmware layer "cannot be bypassed" and that the command ABI has six commands is SUPERSEDED by this session's results (the Windows-signed `srx_h` image loads through
  the normal PSP path and accepts the sensor commands, sections 18-32).

WHY this contradicts section 36's "nothing powers it": it is true that nothing powers the sensor at capture time, but the power pin exists and worked.

INFERENCE (unverified, consistent with everything above): the sensor's enable line is a GPIO of the ISP block, and the ISP block is power-gated through the SMU (`isp_poweroff`/`isp_poweron` in `isp_v4_1_1.c`, genpd).
At probe the ISP is up, the driver releases the sensor and identifies it. Afterwards the ISP is power-gated (idle) and the pin controller loses its output state (comes back at its default level). The `ov13b10` driver still
believes it is powered (runtime status `active`, so `s_stream` calls no `power_on`), and nobody re-asserts the pin when `amd_isp_capture` powers the ISP up again: the chip stays disabled and NACKs (-121), as observed.
Supporting facts: the NACK is the same before and after the ISP firmware boots and in both start orders; the sensor reports `runtime-active 1` all along; `/sys/bus/i2c/devices/i2c-ov13b10/power/runtime_status` reads `active`.

TEST (patch 0020, proposed): while the ISP is powered, force the sensor through a runtime-PM cycle (`pm_runtime_force_suspend` then `pm_runtime_force_resume` on the I2C client) so the driver runs its own `power_off`/`power_on`,
which re-drives the reset/enable GPIO; then repeat the raw chip-ID probe and `s_stream`. If the chip ID reads `56 0d 42` afterwards, the diagnosis is confirmed and the fix is to make sure the sensor is power-cycled (or the pin
re-asserted) every time the ISP is powered up (by the ISP driver, via the sensor's PM, or by keeping the ISP powered).

## 38. Sensor runtime-PM cycle patch (0020; written and built, not yet run)

`scratch/isp4-threshold/0020-isp4-sensor-pm-cycle.patch` (`isp4_subdev.c` only, on top of 0019). New module parameter `sensor_pm_cycle` (bool, needs `start_sensor`). In
`isp4sd_exp_sensor_start()`, before the usual raw I2C probe and `s_stream`, it does: raw I2C probe ("before pm cycle"), `pm_runtime_force_suspend(&client->dev)` then
`pm_runtime_force_resume(&client->dev)` (the ov13b10 driver wires `ov13b10_suspend`/`ov13b10_resume` through `DEFINE_RUNTIME_DEV_PM_OPS`, so this runs its `power_off` then `power_on`: reset GPIO asserted,
clock and regulators off/on, reset released, 5 ms wait), a log line `EXP-SENSOR: forced runtime PM cycle of the sensor: suspend <r>, resume <r>, runtime-active <0|1>`, then the raw probe again ("after pm cycle").
Test script: `--sensor-pm-cycle`.

How to read the result (run `--start-sensor 1 --sensor-pm-cycle`, optionally also with `--start-sensor 2`):

| Output | Meaning / next step |
|---|---|
| "before pm cycle" read -121, "after pm cycle" read ret 2 with id `56 0d 42` | Diagnosis CONFIRMED: the enable pin state is lost while the ISP is gated and the driver does not know. `s_stream` should then proceed; look at the firmware counters for frames. The fix is to power-cycle the sensor (or re-assert the pin) whenever the ISP powers up. |
| both reads still -121, suspend/resume returned 0 | The pin is not (only) the problem: wrong polarity at this moment, or another rail/clock, or the pin controller isn't writable now. Next: read the pin state (`/sys/kernel/debug/gpio`) while the ISP is on, then the ACPI dump (`scripts/dump-acpi-tables.sh`) and Windows `reset_sensor_phy`. |
| suspend or resume returns an error (e.g. -EBUSY, -ENOSYS) | The PM cycle did not run; the driver or core refused. Use the returned errno; alternative: unbind/bind the I2C client while the ISP is up. |
| read works after the cycle but `s_stream` fails later with a different error | Progress: power is fixed; the failure is now in the sensor's register programming (PLL/mode); compare with the Windows table (`res_0_config_OV13B`) and patch 0007's PLL change. |

## 39. RESULT: the forced power cycle brings the sensor up; `s_stream(1)` succeeds; still no CSI-2 data at the receiver (run 20261015-211312, `--start-sensor 1 --sensor-pm-cycle`)

OBSERVED (`results/20261015-211312-*`; Windows srx_h firmware, replay, tuning file, 200 MiB pool):
- Sequence of `EXP-SENSOR` lines: raw I2C "before pm cycle" read -121; "forced runtime PM cycle of the sensor: suspend 0, resume 0, runtime-active 0"; "after pm cycle" and "before s_stream" raw reads still -121 (sensor
  runtime-active 0); then **`ov13b10 21-0010 s_stream(1) after START_STREAM -> 0`** (first success; no "failed to set powerup registers") and `s_stream(0) -> 0` at teardown.
- Reading: `pm_runtime_force_resume()` left the sensor runtime-suspended (power off: reset asserted, clock off), which is why the two raw probes in between still failed; `s_stream`'s own
  `pm_runtime_resume_and_get()` then ran the driver's `power_on` (clock, reset released, 5 ms) and the chip answered: identify, soft reset, PLL, mode registers and stream-on all passed. This CONFIRMS the diagnosis of
  section 37: before the cycle the driver believed the sensor was powered ("active") while the pin state had been lost; one real suspend->resume re-drives the enable line. Stable fix (not yet written): make the sensor
  go through a real runtime suspend/resume (or re-assert its enable pin) every time the ISP is powered up, before `s_stream`.
- Firmware side unchanged: `START_STREAM` seq 19 status 0; "m_configureInputCstat ... physical sensor output ... 4208x3120"; the receiver is armed ("IspHardwareShot :CSIS / MIPI0"), the sensor starts right after,
  and then every counter stays 0 (`[CSIS]/[MIPI0..2]/[CSTAT..]/... fs(0), cl(0), fe(0), dma(0)`), "IspHardwareShotTimer false alarm timeout" about 1.3 s later, "PipeFrmDoneTimerHandler ... [Fcount 0] frame done timeout",
  stop path as before (0x1e). Still 0 frames/0 bytes. The line `SetFrameTime ... ConfigureInput() = 16391` is present in every run since section 32 (not new).
- So the sensor is configured and streaming (as far as its register writes say) but the ISP's CSI-2 receiver never reports a frame start.

NEW LEAD (OBSERVED, `amdcamera.sys`, strings): the Windows host driver contains its own Synopsys MIPI D-PHY/C-PHY receiver code: `phx_phy_reg_read`, `phx_phy_reg_write` (0x1400a0bf0 / 0x1400a0c10),
`phx_start_internal_synopsys_phy` (0x1400a0c40), `phx_shutdown_internal_synopsys_phy`, `reset_sensor_phy` (0x1400a0c90), `startup_seq_cdphy_rx` (0x1400a0cb0), `PHY_READY_addr`/`PHY_READY_DLY`, DDL calibration
(`DPHY_DDL_CAL_addr`, `CPHY_DDL_CAL_addr`, `DDLCAL_*`) and tables of PHY register names (`CORE_DIG_*` x197, `PPI_RW_*`, `OA_LANE0..4_*`, `IA_LANE*`). The firmware log shows no PHY initialisation. INFERENCE: the receiver PHY (lane
count / data rate / HS settle / calibration) may have to be brought up by the HOST on this chip, which Linux's ISP4 driver does not do (for the OV05C10 the firmware probably does it). Not verified.

NEXT, cheapest first:
1. no code: the other start order, `--start-sensor 2 --sensor-pm-cycle` (sensor streaming before `START_STREAM` arms the receiver);
2. decode the Windows PHY bring-up (`startup_seq_cdphy_rx`, `phx_start_internal_synopsys_phy`, `reset_sensor_phy` and their callers): register offsets, values, dependence on lane count / data rate; then replay it from the Linux
   module through the ISP MMIO window (as done for the sensor commands);
3. write the stable power-cycle fix for the sensor once frames flow.

## 40. RESULT: sensor started BEFORE `START_STREAM` gives the same outcome; where the Windows PHY code lives (run 20261015-211804, `--start-sensor 2 --sensor-pm-cycle`)

OBSERVED (`results/20261015-211804-*`):
- Same sequence of raw probes as section 39 (-121 before the cycle, sensor left runtime-suspended by the cycle, -121 in between), then **`ov13b10 21-0010 s_stream(1) before START_STREAM -> 0`** and `s_stream(0) -> 0` at teardown.
- `START_STREAM` seq 19 status 0 again; the receiver counters are all `fs(0), cl(0), fe(0), dma(0)` (46 lines in the log), "frame done timeout [Fcount 0]", stop path 0x1e as before; 0 frames. Both start orders (sensor before or after `START_STREAM`) behave
  the same, so the order is not the missing piece.
- CONCLUSION: with the sensor powered and streaming (per its register writes), the ISP's CSI-2 receiver never sees a frame start. The ISP-side pipeline is configured and armed; what is not shown to be right is the
  link between the sensor and the receiver: PHY bring-up (lane count, data rate, calibration), the sensor's output mode vs what the pipeline expects, or the sensor not really transmitting (register programming accepted but no HS output).

WHERE THE WINDOWS PHY CODE IS (`amdcamera.sys`, xrefs of the name strings; not decompiled yet):
- `phx_start_internal_synopsys_phy` (string 0x1400a0c40) is referenced from 14 places, all in `0x140051bb7`-`0x140051fa9`; `reset_sensor_phy` (0x1400a0c90) from `0x140052028`, `0x14005203e`;
  `startup_seq_cdphy_rx` (0x1400a0cb0) from 8 places in `0x1400523c9`-`0x1400527cb`. So the PHY driver is two compact function clusters around 0x140051b00-0x140052100 and 0x140052300-0x140052800: about 20 functions.
- Also present: `phx_phy_reg_read/write` (0x1400a0bf0/0x1400a0c10), `PHY_READY_addr`/`PHY_READY_DLY`, `DPHY_DDL_CAL_addr`/`CPHY_DDL_CAL_addr`, register-name tables (`CORE_DIG_*`, `PPI_RW_*`, `OA_LANE0..4_*`, `IA_LANE*`).

NEXT (needs approval): read-only decompile of these two clusters to learn (1) how a PHY register is addressed (`phx_phy_reg_write`: the MMIO window and indirection), (2) the startup sequence and its dependence on lane count and data rate,
(3) the values for 4 lanes at the sensor's rate, and (4) when it is called relative to `START_STREAM`; then replay that sequence from the Linux module through the ISP MMIO mapping, behind a new parameter.

## 41. Windows MIPI D-PHY receiver bring-up, decoded from `amdcamera.sys` (read-only; not yet replayed)

All OBSERVED in the decompile unless marked. Function names are the driver's own log strings.

**Which path this machine takes.** `isp_snr_open` (`FUN_14001d2f4`) powers the sensor LDO (`isp_snr_enbale_ldo_power`, `FUN_140059a34(dev, sensor, 1)`), gets the sensor caps (`FUN_140059bdc`, the same
`get_caps_OV13B` structure I ported; cached at `sensor + 0x3c8`), and then, if the global `DAT_1400d1838 == 0` and caps dword 1 (`caps+4`) is 0 (both true for our payload), starts the receiver PHY from the hardware-variant byte
`dev+0x17f4`: variant **2** (Phoenix, `phx_`) -> `phx_start_internal_synopsys_phy` (`FUN_140051b80`); variants **3 and 4** (Strix; 4 selects `srx_h`, section 31) -> `FUN_140052284(sensor, 3, 0, (float)rate, lanes)`.
Arguments (OBSERVED, they match my sensor-property port): **rate = caps+0x1f0** = 1120 (0x460) for the 4208x3120 mode, **lanes = caps+8** = 4. So the Strix path applies, not the `phx_` one.

**Register access.** `isp_hw_reg_write32/read32(byte_offset)` (`FUN_1400014b8`/`FUN_140001320`): offset must be 4-aligned; offsets in `0x60000-0x67fff` or above `0x1b7fff` are direct dword accesses (`offset >> 2`); others
use an index/data pair at dword `0x187c2` / `0x187c3` (= bytes `0x61f08` / `0x61f0c`, inside the direct window). The Linux ISP4 driver already uses the same byte-offset scheme (`ISP_SOFT_RESET = 0x62000`, `readl(mmio + reg)`),
so `ispif->mmio` + these offsets work from the module. **[WRONG for everything at 0x66xxx, corrected in section 43: `ispif->mmio` only covers 0x0-0x629a4.]** Delay: `FUN_1400512d4(us)` = busy wait (`KeStallExecutionProcessor`, 50 us chunks).

**PHY controller registers** (per PHY instance, base from the table at 0x1400c06a8, 8-byte entries): PHY0 `0x66700`, PHY1 `0x66780`, PHY2 `0x67400`.
| offset | use |
|---|---|
| +0x00 | control: 0 = off, 3 = enable |
| +0x04 | bit 0 = mode (0 D-PHY, 1 C-PHY) |
| +0x10 | lane enable mask = `(2 << lanes) - 1` (4 lanes: 0x1f) |
| +0x14 | lane reset: `((1 << lanes) - 1) \| 0x10` (4 lanes: 0x1f) while configuring, then `& ~0x1f` = 0 |
| +0x1c | status, bit 0 = PHY ready |
| +0x24 / +0x28 / +0x2c | indirect PHY-register port: address / data (16 bit) / status (bit 1 = error) |
Global PHY reset register `0x66108`: bit *phy* set, 1 ms, cleared. Lane stop-state status (indirect region) at `0x68008 + 0x8000*phy`: field bits 15:8 must contain the lane mask (1 lane 0x11, 2 lanes 0x13, 4 lanes 0x1f).

**Sequence = `startup_seq_cdphy_rx(phy, mode, rate, lanes)` (`FUN_140052390`), for phy 0, D-PHY, 4 lanes:**
1. `r = rd(0x66108); wr(0x66108, r | 1); delay 1 ms; wr(0x66108, rd(0x66108) & ~1)`.
2. `wr(base+0x00, 0)`; `wr(base+0x14, 0x1f)`; `wr(base+0x10, 0x1f)`; `wr(base+0x04, 0)` (D-PHY).
3. `FUN_14005356c(phy, rate, lanes)` = analog configuration, below.
4. `wr(base+0x00, 3)`; (debug read of PHY reg 0xe41); poll `rd(base+0x1c) & 1` with 1 ms steps (unbounded in Windows).
5. poll the lane status `(rd(0x68008) >> 8 & 0x1f) == 0x1f` up to 5 times with 1 ms delays (logs an error but continues on timeout).
6. `wr(base+0x14, 0x1f & ~0x1f)` = 0 (release the lane resets).

**Analog configuration `FUN_14005356c(phy, rate, lanes)` = six steps, all PHY-register read-modify-writes through the indirect port** (`FUN_14005131c(phy, descriptor)`: write address to +0x24, read +0x28, replace the bits
selected by `mask` with `value << lowest_set_bit(mask)`, write back; descriptor = {name, reg, field name, mask (u16), value (u16)}):
1. `FUN_1400513d4` computes timing values from `rate` into globals (`DAT_1400d3e48..ea0`: DDL counter reference, DLL feedback / coarse bank, HS settle `DAT_1400d3e7c`, ...) with floating-point maths and rate thresholds (1500, 2500, 4500, 160/320/640/1280/2560, ...). No register writes. Must be evaluated offline for rate 1120 (the kernel does not use floating point).
2. `FUN_14005528c`: 15 static entries (`PPI_STARTUP_RW_COMMON_DPHY_10`...), table at 0x1400ab5f0, 32-byte descriptors.
3. `FUN_14005280c`: 19 static entries (`PPI_STARTUP_RW_COMMON_DPHY_2`...), table at 0x1400ab7d0.
4. `FUN_1400535d8`: about 170 writes (condensed by `scratch/decode_phy.py`): lane word-clock gating (`0x1c47`), DDL calibration (`0xe20..0xe27`, `0xc07/0xc08`), HS RX clock divider (`0x1229`... ), clock-lane settle (`0x3880`, `0x3887`), per-lane HS settle (`0x3080,0x3280,0x3480,0x3680`, value from the computed table),
   deskew/SOT detection, lane config; most branch on `rate >= 1500.0` and on the PHY index (`phy < 2` -> four data lanes). Values marked `CONCAT22(DAT_1400d3exx, mask)` come from step 1.
5. `FUN_1400534f0`: 128 static (register, value) pairs, table at 0x1400acdd8 (stride 32 bytes: register u16 at +0, value u16 at +0x12), written as plain (not read-modify-write) PHY writes.
6. `FUN_140055510`: clears pin-swap bits (LP/HS) and the HS RX select-gated polarity bit on the clock and data lanes (phy < 2: four data lanes).
The firmware log never mentions PHY setup, and the OV05C10 path in Linux works without host PHY code, so whether the firmware repeats or overrides this on the Strix variants is UNKNOWN. The Windows driver runs it
from the host before the stream starts (sensor open), then the firmware only arms the receiver.

**Open items before a replay patch:** (a) evaluate step 1 and the full branch structure of step 4 for (phy 0, rate 1120, 4 lanes), preferably by a small script that reads the descriptor tables and the pseudo-code branches from the Windows binary
(output: a generated C header of `(register, mask, value)` triples, no Windows data in the sources beyond those numbers), (b) check which of the other `isp_snr_open` steps matter (`FUN_14005989c`, `FUN_140059d08`, `FUN_14005a560`), (c) the
exact moment to run it in the Linux flow (before `START_STREAM`, after the sensor is powered; Windows: in sensor open, before stream configuration), (d) mapping of the PHY index to our sensor (sensor index 0 -> PHY 0, MIPI0).

## 42. PHY generator and `phy_init` patch (0021; written and built, not yet run)

**Generator** `scratch/build_phy_seq.py` (reads `amdcamera.sys` read-only, sha256 `2376fd79...4263`; input pseudo code `scratch/phy-src/FUN_1400535d8.txt`, saved from the Ghidra dump, derived from the Windows binary: keep it local):
- ports `FUN_1400513d4` (floating-point timing values) for the rate; `FUN_140097ee0` = `ceil`, `FUN_140098000` = `floor` (read from their assembly); start values of the globals are 0 (`.data`: `0x1400c06f0` = 4, `+4` = 5000, `+8` = 1);
- evaluates the pseudo code of `FUN_1400535d8` (only two conditions: `phy < 2`, `rate >= 1500`; no gotos) with a small transpiler;
- reads the static tables (15 entries at 0x1400ab5f0, 19 at 0x1400ab7d0, the 128-entry write table at 0x1400acdd8), transcribes `FUN_140055510`;
- output for phy 0, 1120 Mbps, 4 lanes: **296 operations** = 15 + 19 + 119 + 128 + 15; timing values: counter ref 88, HS settle 13 (lanes and clock), 69, 9, 18, 23; DDL calibration bypassed (rate < 1500);
- writes `scratch/isp4-threshold/isp4_phy_seq.h` (`{reg, mask, val, kind}` triples; kind RMW = read-modify-write, WRITE = plain). `--print` lists every operation with its register name.
Not ported / assumptions: rates >= 1500 Mbps (the generator raises an error), the tail of `FUN_1400513d4` for rates above about 1.7 Gbps, C-PHY mode.

**Kernel patch** `0021-isp4-phy-init.patch` (`isp4_interface.c/.h`, `isp4_subdev.c`, new `isp4_phy_seq.h`; on top of 0020): module parameter `phy_init` (bool), `isp4if_phy_init()` does, with `readl/writel` on `ispif->mmio` **[first version; this oopsed, see section 43. The revised patch uses its own ioremap window for 0x66000-0x67fff]**:
1. pulse bit 0 of `0x66108` (1 ms); 2. `0x66700+0x00 = 0`, `+0x14 = 0x1f`, `+0x10 = 0x1f`, `+0x04 = 0`; 3. the 296 operations through the indirect port (`+0x24` address, `+0x28` data; RMW = read, replace the masked bits with `val << lowest_set_bit(mask)`, write);
4. `+0x00 = 3`, poll `+0x1c` bit 0 (PHY ready, at most about 100 ms); 5. lane stop-state: write `0x68008` to the index port `0x61f08`, read `0x61f0c`, bits 15:8 should contain 0x1f (at most 5 tries, then continue, like Windows); 6. `+0x14 = 0`.
Called from the sensor start helper (`start_sensor` != 0): the helper now holds a runtime-PM reference on the sensor across the PHY start and `s_stream(1)` so the sensor is powered (out of reset) while the receiver comes up. Log lines:
`EXP-PHY: starting ...`, `EXP-PHY: before: ...`, `EXP-PHY: done: PHY ready yes|NO (status ...), lane stop-state 0x... (want ...)`, `EXP-SENSOR: PHY start returned <0|-ETIMEDOUT>`.
Test script: `--phy-init` (use with `--start-sensor 2 --sensor-pm-cycle`; the summary prints the `EXP-PHY` lines).

How to read the result:

| Output | Meaning / next step |
|---|---|
| PHY ready yes, lane stop-state matches, then the firmware shows `fs(1..)` / `FrameStart` on MIPI0 and `frames > 0` | First light. Check the image next. |
| PHY ready yes, stop-state matches, but counters still 0 | The PHY is up and the lanes are idle (LP-11), yet no frame start arrives: the sensor's output (mode, lane count, link rate; compare the OV13B table in the Windows sensor plugin) or the firmware's own receiver configuration is the next suspect. |
| PHY ready NO (timeout) | The analog setup or the controller registers are wrong or the ISP domain is not clocked: check the "before" line (all-ones means the registers are not accessible), the order, and `isp_hw_reg` addressing. |
| PHY ready yes, stop-state NO | The sensor lanes are not in LP-11 when polled (sensor not powered or not yet out of reset): try the other sensor start order or check the sensor's state. |
| reads return 0xffffffff, or the machine hangs | The PHY registers are not reachable at these offsets while the ISP is in this power state. Revert to the module without `phy_init`. |

## 43. INCIDENT: the first `phy_init` run oopsed (unmapped register range); fixed in patch 0021 (revised, rebuilt, not yet run again)

OBSERVED (kernel log of the boot, runs at 21:35 and 21:37 journal time; `results/20261015-213554-console.txt` is truncated after "=== min_start_bufs=4 ...", `...213759-console.txt` says "cannot unload amd_isp4_capture (in use?)"):
- `EXP-SENSOR: powered the sensor for the PHY start: 0`, `EXP-PHY: starting the D-PHY receiver (phy 0, 1120 Mbps, 4 lanes), 296 register operations`, then
  `BUG: unable to handle page fault for address: ffffcfb7a6766108`, `Oops: 0000 [#1] SMP NOPTI`, `RIP: isp4if_phy_init+0x4c`. The faulting address is the module's register mapping base plus `0x66108`.
  The capture process died inside the kernel, v4l2-ctl hung, the module stayed "in use" (the second run could not unload it): the user saw a command that "froze".
- CAUSE (my error, section 41/42 claimed otherwise): `ispif->mmio` is the capture device's resource 0, `isp_4_1_1_reg`, which amdgpu defines as `isp_base .. isp_base + ISP_REGS_OFFSET_END` = **0x0-0x629a4**
  (`isp_v4_1_1.c`, `amdgpu_isp.h`). The PHY controller is a different resource, `isp_4_1_1_phy0_reg` = `0x66700 + 0xD30` (`ISP411_PHY0_OFFSET/SIZE`), which the upstream capture driver never maps, and the global PHY reset register
  `0x66108` is in no resource at all (the sensor GPIO window starts at `0x6613c`, the sensor I2C at `0x66400`). Only the index/data pair `0x61f08/0x61f0c` is inside `ispif->mmio`.
  Side fact: amdgpu already provides the PHY0 window to this device, so a host-side PHY driver is anticipated by the platform glue even though upstream does not use it.
- FIX (in `0021-isp4-phy-init.patch`, regenerated; the patch never ran successfully, so it was revised instead of adding 0022): `isp4if_phy_init()` maps `res0->start + 0x66000`, size `0x2000`, with `ioremap()` (no region request, so nothing conflicts with
  the resources already claimed by amdgpu's child devices), uses that window for every direct PHY access (`phy_rd32/phy_wr32`), keeps `ispif->mmio` only for the index/data pair, unmaps at the end, logs the physical address and
  offsets mapped, and stops without writing if the first reads are all-ones.
- Recovery: the module could not be unloaded after the oops; a reboot is needed before the next test. The oops tainted the kernel; nothing was written to disk.
- LESSON: a register offset that works in another driver's address scheme must be checked against THIS driver's mapped resources before use; `readl` on an unmapped offset is a kernel oops, not a failed read.

## 44. RESULT: host-side D-PHY start works and the firmware MIPI0 receiver now sees packets, but they are corrupt (run 20261015-214659, `--start-sensor 2 --sensor-pm-cycle --phy-init`)

OBSERVED (`results/20261015-214659-console.txt`, `...-min4-var0.log`):
- No oops. `EXP-PHY: mapped ISP offsets 0x66000-0x67fff (physical 0xa0366000)`, registers before: global reset / ctl / status all 0, so the window is reachable and the PHY was idle.
- After the 296-operation sequence: `PHY ready yes (status 0x1)`, lane stop-state `0x3f00` (bits 15:8 = 0x3f contain the wanted 0x1f), ctl `0x3`. Then the ov13b10 `s_stream(1)` returned 0.
- Firmware (51.0.8.0) accepted every command (all EXP-RESP status 0 except the usual STOP_STREAM 0x1e at the end). It now reports real receiver events that no earlier run had:
  - `MipiCsiInterruptsHandler: [S:0|MIPI0] [F0]Error protocol` then `2-bit ecc error occurred` (checked mipi error 5 and 4 from MIPI 0), `ISP_MIPI_MI_WR_DBG_CUR_PTR=0x3820`, `CSTAT HW Error`.
  - `FrameStart HWID:MIPI0 ... already in VValid`, `FrameDone HWID:MIPI0` at the stop, and CSIS shots F0-F3 (FrameStart/FrameDone ~30 us apart, i.e. empty shots, not real image data).
  - Per-block counters `fs/cl/fe/dma` are still 0 everywhere, `[Pipe][Fcount 2] frame done timeout`, "Failed to Shot a frame" (Fcount 3), driver `frames=0 bytes=0 select timeout`.
- Previous run (211804, no `phy_init`): no MIPI error lines at all, only `frame done timeout [Fcount 0]`.

INTERPRETATION (mine, not verified):
- A "2-bit ECC error" is a CSI-2 packet HEADER the receiver could not correct. That means the receiver is getting high-speed bits on the lanes now (before: silence). So lane/PHY power-up and the sensor output are alive; what is wrong is the bit-level framing or timing.
- Candidates, most likely first:
  1. ORDER: the sensor was already streaming when the receiver was enabled by the firmware at START_STREAM (mode 2 starts the sensor before). The receiver may lock onto the middle of a packet. Try `--start-sensor 1` (sensor after START_STREAM); note the PHY start currently runs inside the same helper, so in mode 1 it also moves after START_STREAM and the firmware's own MIPI enable may then override it. Needs a look at what the log shows.
  2. Link rate / sampling: PHY analog config is for 1120 Mbps (matches upstream ov13b10 560 MHz link, 4 lanes) but the sensor register mode set by the Linux ov13b10 driver for 4208x3120 may use a different lane rate than Windows' `res_0_config_OV13B` table. Also HS-settle/timing values in the sequence could be off for a different rate.
  3. Lane count / lane polarity-order in the receiver (the 0x1f stop-state mask is for 4 lanes + clock).
- NOT yet checked: the firmware's own MIPI0 configuration lines (lane count/rate it believes), the sensor register state while streaming (I2C is only reachable with the ISP powered; the raw read was -121 in this run too).

NEXT (proposed, not done): (a) run with `--start-sensor 1 --sensor-pm-cycle --phy-init` and compare the error lines; (b) grep the full log for the firmware's MIPI0 open/config text (lane/rate); (c) compare the ov13b10 mode registers with the Windows table.

## 45. RESULT: sensor started AFTER `START_STREAM` (with `phy_init`) gives the same MIPI errors, so start order is not the cause (run 20261015-214920, `--start-sensor 1 --sensor-pm-cycle --phy-init`)

OBSERVED (`results/20261015-214920-console.txt`, `...-min4-var0.log`):
- PHY start identical to section 44 (ready yes, stop-state 0x3f00, ctl 3). `s_stream(1) after START_STREAM -> 0`. Kernel warning from my ioremap: `mapping multiple BARs` (expected: the window overlaps the resources claimed by amdgpu's child devices; harmless here).
- Firmware: the same burst at sensor start: 8 pairs of `MipiCsiInterruptsHandler: [S:0|MIPI0] [F0]Error protocol` + `2-bit ecc error occurred` within ~0.4 ms, plus `CSTAT HW Error`, `HandleHwErrorEvt ExtraInfo=5 / 4`. After that burst there are NO further MIPI0 errors or frames: one MIPI0 FrameStart/FrameDone pair, CSIS shots F0-F3 empty, `[Fcount 2] frame done timeout`, `Failed to Shot a frame`. Counters 0, `frames=0 bytes=0`.
- The firmware log has no line that states its own MIPI lane count or rate (grep for lane/Mbps/settle/PHY found nothing from the firmware).

WHAT THIS RULES OUT / LEAVES:
- Hypothesis 1 of section 44 (sensor already streaming when the receiver is enabled) is not supported: mode 1 and mode 2 give the same burst.
- The nominal rate matches the Linux sensor driver: `ov13b10.c` comment "4208x3120 needs 1120Mbps/lane, 4 lanes", register `0x0305 = 0xaf`, link frequency 560 MHz, and the firmware property says 4208x3120. Unchanged suspects: PHY analog timing values (HS settle etc.), lane order/polarity, and whether the sensor really keeps streaming (the burst may be the sensor start-up and then nothing).
- Open question: the firmware also holds a Windows "device script" (5868 bytes) for the sensor, and the Linux driver writes its own mode registers in `s_stream`; I do not know which of the two actually starts the sensor output in the Windows flow.

NEXT (proposed, not done): a diagnostic patch that reads the PHY registers (0x66700 + 0x00..0x30, lane stop-state at 0x68008 via 0x61f08/0x61f0c) right after `s_stream(1)` and again after ~100 ms and ~1 s. If the data-lane stop-state bits drop (lanes leave LP-11), the sensor is transmitting high-speed data and the problem is timing/sampling; if they stay at stop-state, the sensor is not transmitting and the problem is on the sensor side.

## 46. Patch 0022: read-only D-PHY snapshots after the sensor starts (written and built, not yet run)

PURPOSE: sections 44/45 show the receiver reporting a burst of `Error protocol` / `2-bit ecc error` at sensor start and then nothing. The firmware log cannot tell "sensor stops transmitting" from "receiver mis-samples". The PHY's lane stop-state can.

`0022-isp4-phy-diag.patch` (on top of 0021; base files in `base-0021/`):
- `isp4if_phy_diag(ispif, label)` in `isp4_interface.c`: same separate ioremap window as `isp4if_phy_init()`; logs `EXP-PHYDIAG[label]: global reset, lane stop-state (bits 15:8)` and the 13 dwords `+0x00..+0x30` of the PHY controller at 0x66700. Only reads (index/data pair for the stop-state is one write of the index, as in 0021). Status registers might be clear-on-read (observer effect, noted in the code comment).
- `isp4sd_exp_sensor_start()` in `isp4_subdev.c` calls it after a successful `s_stream(1)`, then after `msleep(100)` and after another `msleep(900)`, still holding the pm reference. Process context (the helper already does sleeping I2C/pm calls), adds about 1 s.
- Active only with `phy_init=1`; no new module parameter; the test script already greps `EXP-PHY`.

HOW TO READ THE RESULT (for the run `... --start-sensor 1 --sensor-pm-cycle --phy-init`, or `--start-sensor 2`):
- Baseline from section 44: stop-state before the sensor starts was 0x3f00 (lanes in LP-11, bits 15:8 contain 0x1f).
- If the data-lane bits (low bits of 15:8 = 0x0f, bit 12 = clock?; I do not know the exact bit order, compare the three snapshots) CHANGE after `s_stream`, the lanes left stop state: the sensor transmits high-speed data, so the problem is sampling/timing/lane config.
- If the stop-state stays 0x3f00 in all three snapshots, the sensor never transmits (or the lanes stay in LP-11): the problem is on the sensor side (its mode/PLL/start-up, or the firmware's device script).
- A change that returns to 0x3f00 by +1s means the sensor transmitted only briefly: matches the single error burst.

## 47. RESULT of patch 0022: the sensor IS transmitting; plus an unexplained observation (front-camera flash/LED lights up) (runs 20261015-220053 `--start-sensor 1` and 20261015-220112 `--start-sensor 2`, both `--sensor-pm-cycle --phy-init`)

OBSERVED (`EXP-PHYDIAG`, direct PHY dwords identical in every snapshot: +0x00=3, +0x10=0x1f, +0x14=0, +0x18=0xf, +0x1c=1, +0x20=1, +0x24=0x1829, +0x28=0xaf0, +0x2c=1, +0x30=1; no error/latch register in this block changes):
- Lane stop-state (bits 15:8): start 0x3f00 (before the sensor). Run 220053 (sensor after START_STREAM): 0x3f00 right after `s_stream(1)`, 0x2000 at +100 ms and +1 s. Run 220112 (sensor before START_STREAM): 0x3f00, 0x2f00 at +100 ms, 0x2000 at +1 s.
- So within 100 ms of `s_stream(1)` the lanes leave the stop state (only bit 13 = 0x20 stays set) and they have NOT returned after 1 s. I do not know the meaning of each bit (bit 13 alone stays; 0x10 clears before the others in run 2), so this is read as "lanes left LP-11 and stay out", not per lane.
- Firmware, run 220053: unchanged from section 45 (single error burst, one MIPI0 frame event, `frame done timeout`, 6 FrameStart / 5 FrameDone lines).
- Firmware, run 220112 (sensor before START_STREAM): a retry loop about every 188 ms: `MIPI0 IspHwIpDisable: Failed in waiting for V_VALID state`, two `checked mipi error 4` (the 2-bit ECC error) per cycle, 472 lines with `Error protocol`/`ecc error` in total; FrameStart 39 x MIPI0 + 13 x CSIS + 1 x CSTAT0; FrameDone 26 x MIPI0 + 13 x CSIS; no `frame done timeout`. Driver side still `frames=0 bytes=0`.

INTERPRETATION (mine, not verified):
- The "sensor silent" and "brief start-up burst" explanations of section 45 are not supported: the lanes are active for at least a second and the receiver keeps getting headers it cannot correct, every attempt. That fits wrong sampling or framing at the receiver (HS settle/timing, lane rate, lane order/polarity, or the data the sensor sends not being what the firmware configured), not a sensor that stays off.
- `s_stream(1)` returning 0 means the Linux sensor driver's I2C accesses worked at that moment (its chip-ID read is part of start-up, see section 29/33 notes), even though the raw probes before it return -121. That suggests the sensor becomes reachable only after the driver's own power-on sequence in `s_stream`.

USER OBSERVATION (reported after these two runs): the FRONT camera's flash (LED) turned on instead of anything on the rear camera. Not in the logs.
- Facts: nothing in my patches names a flash or LED. The firmware says `no SIRC_ISP_IID_FLASH_DRIVER availble from sensor. Auto Flash algorithm is disabled`. The only lines my code drives are the ones inferred earlier: `AMDI0030:00` pin 85 (ISP enable, patch 0003) and `amdisp-pinctrl` GPIO 0 as the ov13b10 "reset/enable" (patch 0005). Section 36/38 already flagged that pin choice as an INFERENCE from the OV05C10 reference platform, never confirmed from the ACPI tables.
- Hypotheses (none verified): (a) the pin I drive is shared with, or really is, the front-camera LED/flash enable, so my pin mapping is wrong or incomplete; (b) it is the camera-in-use indicator, wired by the platform to the camera power rail and lit whenever the sensor is powered (harmless); (c) a GPIO operation inside the Windows device script (5868 bytes) that the firmware executes.
- Not yet known: at which step the LED comes on (module load / pm cycle / s_stream / START_STREAM), whether it goes off at `s_stream(0)` or module unload, and whether it also lit in the earlier runs.
- Decision: pause live hardware tests until the pin is identified. The way to identify it is the ACPI dump (`scripts/dump-acpi-tables.sh`, needs the user: the tables are root-only), reading `\_SB_.CAMB` and every device that mentions the GPIO controllers.

## 48. ACPI dump read (user ran `scripts/dump-acpi-tables.sh`); what ACPI says and does not say about the camera pins and the LED

USER REPORT: the LED/flash next to the FRONT camera came on only during the two `--phy-init` runs (220053, 220112): it started right before the `select timeout` line and went off right after it (i.e. while the capture/sensor stream was active, off when the device was closed). Earlier runs: not stated.

TOOLING NOTE: the script's DSDT decompile failed (`iasl -e` with all SSDTs: error on SSDT6 `CPMPMF`, `Failure resolving symbol [\_SB._]`; without SSDT6: `\_SB.PCI0.GPP4._PR0 AE_ALREADY_EXISTS`, the DSDT and an SSDT define the same name). Both runs left an EMPTY `scratch/acpi/DSDT.dsl` (and `SSDT6.dsl` is empty, same cause). New `scripts/decompile-dsdt-skip-ssdt6.sh` decompiles the DSDT alone to `scratch/acpi/DSDT-alone.dsl` (18899 lines; names from SSDTs appear as `External`). The empty `DSDT.dsl` and `SSDT6.dsl` can be removed by the user.

OBSERVED (ACPI):
- The sensor is `\_SB_.CAMB` in `SSDT23.dsl` (table "CAM12"): `_HID "OMNI13B1"`, `_DDN "OV13B-RGB"`, `_SUB "OV13B"`, `_UID "0"`, `_PLD` with `PLD_Panel = "BACK"` (rear camera, upper centre, user visible), `_STA` = 0x0F, and a `_DSM` (UUID f8fd3bff-21b7-4a99-bdc8-c414a3e9453c) that returns: fn1 = 0x07, fn2 = "3001" (matches the tuning file name `OV13B_3001_ROG_SRX.atb`), fn3 = 1, fn4 = 1, fn5 = 0x10, fn6 = 0x0C, fn7 = 0x50 (meaning not decoded; fn5/6/7 could be I2C-address/lane/port style values, not verified). There is NO `_CRS`, no I2cSerialBus, no GpioIo, no power resource, no `_PS0/_PS3` in `CAMB`. So ACPI describes no pin, regulator or reset line for the sensor.
- There is no other camera device and no flash/strobe/privacy/indicator device in the DSDT or any SSDT (searched for camera, flash, privacy, indicator, webcam; only the OMNI13B1 hit). The only LED fields are EC fields `MLED`, `CLED`, `CLE2`, `SLED` at EC offsets 0x0E-0x13 in the DSDT (mute/caps/sleep-style LEDs, by position and use; not verified as camera-related; `CLED` is not referenced anywhere else).
- `\_SB.GPIO` (`AMDI0030`, FCH GPIO controller, MMIO 0xFED81500) is consumed by BTNS (pin 0), BTH0 (4), HID0/HID2 (0xAB), NFC1 (0x5B/0x4A/0x90), TPM, EC0 (0x16), two I2C HID devices (9, 8), SPKR (0x0C/0x20/4). Pin 85 (0x55), the pin patch 0003 drives as "enable_isp", is claimed by NO ACPI device.
OBSERVED (kernel tree, `isp_v4_1_1.c:243-247`): mainline registers the two GPIO lookups (`AMDI0030:00` pin 85 "enable_isp"; `amdisp-pinctrl` GPIO 0 "enable") ONLY `if (!strcmp("OMNI5C10", acpi_device_hid(acpi_dev)))`, i.e. for the reference platform's OV05C10. Our patches 0003/0005 extend that to OMNI13B1 on the GZ302.

CONCLUSIONS:
- The two lines the host drives for the OV13B are INHERITED from the OV05C10 reference platform, not confirmed for this board by any primary source. ACPI cannot confirm them: the ISP's own GPIO block (`isp_gpio_reg`, 0xa036613c-0xa0366190) is not in ACPI at all.
- Nothing in ACPI links any pin to a front-camera LED. So the LED may be (a) the camera-in-use indicator lit by the platform (EC or hardware) whenever the camera/ISP/sensor is powered and streaming; (b) driven by one of the two inherited GPIOs because on this board that line does something else; or (c) driven by the firmware's device script. ACPI alone cannot tell these apart.
- The timing (lit while the sensor streams, off at teardown) is what (a) would also predict, and it matches the period where `s_stream(1)` is active and the lanes are out of stop state; it does not by itself prove which line caused it.

DISCRIMINATING TESTS (proposed):
1. In Windows, use the rear camera in the Camera app (switch to the rear camera) and see whether the same LED lights. If yes: it is the shared camera-in-use indicator, harmless and expected.
2. Windows driver decode (what I can do without the user): find what `isp_snr_enbale_ldo_power`, `reset_sensor_phy` and the sensor open path in `amdcamera.sys` write to the ISP GPIO registers (around 0x6613c-0x66190) and whether Windows toggles a different line or more lines than Linux (pin 85, pinctrl GPIO 0).
3. Read-only host check (needs the user, root-only): `/sys/kernel/debug/gpio` and the state of the `amdisp-pinctrl` lines while a capture is running.

## 49. Windows decode for the camera pins / LED (amdcamera.sys, sensorOV13B.sys, amdisp.sys): the GPIO/LDO logic is NOT in them; the host driver has no LED write

USER ANSWER (new fact): using the REAR camera in Windows does NOT light the front-camera LED. So in Linux something we cause reaches that LED; it is not the normal rear-camera behaviour.

OBSERVED (Ghidra, read-only):
- `isp_snr_enbale_ldo_power` = `FUN_140059a34` (amdcamera.sys): only a wrapper. It fetches an interface table with `FUN_14005a174(dev, idx)` = `*(dev + 0x1030 + idx*8)` (idx < 4, four tables) and calls its slot `+0xf8` with two arguments (enable value and a byte); it logs `isp_snr_enbale_ldo_power` on failure. No register or GPIO access here.
- `sensorOV13B.sys` (the sensor plugin): table of `*_OV13B` functions (`config`, `start`, `stop`, `stream_on`, `get_caps`, `get_i2c_config`, `get_fw_script_ctrl`, `get_sensor_hw_parameter`, `get_sensor_port`, `register_isp_callback`, `res_0_config`, `res_1_config`, ...); NO strings or calls for LDO, GPIO, power, reset, flash or LED. `get_sensor_hw_parameter_OV13B` (`FUN_1400048f0`) fills a struct: name "OV13B", module "3001", dword[2] = 0x1c, dword[3] = 0x19, dword[0x14] = 0x3ff, dword[0x15] = 400 (looks like an I2C speed in kHz), dword[0x12] = 0xc85500, dword[0x24] = 100, dword[0x25] = 0x60e, a 16-byte GUID-like value (0x4bb56c43f39fb658, 0x528040dbfa2e7e82). The meaning of 0x1c/0x19 is NOT known (could be many things; I do not claim they are GPIO numbers).
- `amdisp.sys` ("AMD ISP Bridge Driver", 11.4.2.1482): imports only generic kernel services (`MmMapIoSpaceEx`, `MmAllocateContiguousMemorySpecifyCache`, `IoBuildSynchronousFsdRequest`, `IofCallDriver`, `VslCreateSecureSection`, WDF); no GPIO, LDO or power strings. It forwards requests to another driver.
- The remaining owner of the sensor power/GPIO sequence is therefore the AMD display driver (`amdkmdag.sys`, 84 MB, `u0202643.inf_amd64_8835e06f359414be/B026283/`). A raw ASCII search for isp/gpio/ldo/led/privacy names found nothing useful (names are stripped). NOT analyzed: a full Ghidra analysis of 84 MB would be very long and may not give names.
- LED code in amdcamera.sys: `led_write` = `FUN_1400850b4` is a stub that logs and returns 0xC00000BB (STATUS_NOT_SUPPORTED); `update_ir_led_mode_imp` = `FUN_140049ea0` only stores a mode (0, 1 or 2; any other value logs and becomes 2) at `dev + 0x1704`. Registry-style parameters exist as strings: `IRLEDCurrLvl`, `IRLEDDelay`, `IRLEDDuration`, `IRLEDFramePeriod`, `IRStrobeShift`, `IRStrobeSpan` (read in the function containing 0x14008fae9), plus `CIspFilter::SetIRLEDMode/SetIRLEDCurrent`, `RearFlash`, `set_flash_*_imp` and firmware command names `CMD_ID_ACK_FLASH_SET_*`. So the Windows HOST driver does not toggle an LED pin; IR-LED/flash/strobe behaviour is parameters handed to the ISP firmware.
- ISP firmware log of the LED run (220112) contains one IR-related line: `HandlePipelineStoppedEvt: Re-enable DeepSleep after IR close for streamId[0]`; no strobe/flash/IR LED lines otherwise. FrameStart events per earlier run WITHOUT `phy_init`: 2 (CSIS shots only) in runs 211804 and 205458, 0 in 201609; WITH `phy_init`: 6 (220053) and 53 (220112).

HYPOTHESES for the LED (none verified):
- H1: the ISP FIRMWARE drives an IR-illuminator/strobe output that follows frame/exposure events of the pipeline; with the MIPI receiver now producing (corrupt) frame events, it fires, and the output is wired to the front camera's LED on this board. Fits: Windows host never writes an LED; the rear camera in Windows is not an IR session. Does not fit cleanly: 2 FrameStart events existed in earlier runs without `phy_init`.
- H2: one of the two inherited pins (AMDI0030 pin 85, amdisp-pinctrl GPIO 0) is shared with that LED, and only visible now because the sensor stays powered/enabled for the whole capture. Test: the same command without `--phy-init` (earlier runs did power the sensor the same way).
- H3: my PHY writes (global reset 0x66108 and the controller at 0x66700) touch something that also feeds the LED. Test: same.

TESTS (cheapest first; each is a normal run of `scripts/test-isp4-threshold.sh`, keep the capture short (--seconds 8) while the LED source is unknown, because an illuminator should not be driven continuously):
1. Same command as before but WITHOUT `--phy-init` (still `--start-sensor 2 --sensor-pm-cycle`): LED on or not? On -> H2 (or firmware), not the PHY. Off -> H1/H3.
2. If off in 1: with `--phy-init` but the ISP-side start only (no sensor start) is not possible (`phy_init` needs `start_sensor`); instead patch 0023 (read-only): dump the ISP GPIO register block 0x6613c-0x66190 and 0x66108 in the PHYDIAG snapshots to see which GPIO bits are set while the LED is on.
3. Analysis (long): Ghidra on `amdkmdag.sys` for the code behind interface slot +0xf8; or look for the ISP GPIO register writes by searching it for immediates 0x6613c.

## 50. Code review after "the light came on even without `--phy-init`": the LED timeline matches the driver's `enable_isp` GPIO (AMDI0030:00 pin 85), which patch 0003 assigned by assumption

USER RESULT: command of section 49 test 1 (`--start-sensor 2 --sensor-pm-cycle`, no `--phy-init`, `--seconds 8`): the front-camera light came on. So the PHY writes (H3) are ruled out as the cause.

CODE REVIEW (everything of mine that can reach a GPIO or LED; sources in `scratch/isp4-threshold/`):
- `isp4_subdev.c:192-199` `isp4sd_module_enable(sd, enable)` does `gpiod_set_value(enable_gpio, enable)`. `enable_gpio` is requested in probe as `devm_gpiod_get(dev, "enable_isp", GPIOD_OUT_LOW)` (`isp4_subdev.c:1199-1201`), i.e. low at module load. This is the upstream driver's own code, not one of my experiments.
- It is called with `true` at `isp4_subdev.c:863` in `isp4sd_pwron_and_init()` (camera node opened / power-on) and with `false` at `:837` (power-off, followed by `msleep(20)`) and at `:1236` (remove). So the line goes HIGH when the capture device is opened and LOW when it is closed.
- Which physical line that is: `isp_v4_1_1.c:55` `GPIO_LOOKUP("AMDI0030:00", 85, "enable_isp", GPIO_ACTIVE_HIGH)`. Mainline registers it only for `OMNI5C10`; MY patch 0003 (`0003-drm-amdgpu-enable-isp-gpio-on-gz302.patch`) registers it for `OMNI13B1` as well. Its own text says the GZ302 sensor "has no GPIO resources" and justifies pin 85 only by "the same AMDI0030 controller lookup used by the ISP4 reference platform": an ASSUMPTION, never confirmed. Section 48 shows no ACPI device on this machine owns pin 85.
- The only other pin my kernel changes drive is `amdisp-pinctrl` GPIO 0 as the ov13b10 "reset" line (patch 0005, also by analogy), toggled by the ov13b10 runtime-PM power on/off, including the forced suspend/resume of `--sensor-pm-cycle` (patch 0020) and `s_stream`.
- Nothing else I wrote touches GPIO/LED/flash: the replay commands (0012-0017) go to the firmware; the I2C probe (0019) writes register 0x0100 on bus address 0x10, which NACKs (-121); the PHY code (0021/0022) is ruled out by this result.

MATCH WITH THE OBSERVATION: "light on right before the `select timeout` message, off right after" = device opened ... device closed = pin 85 high ... pin 85 low. The sensor start (GPIO 0, s_stream) also lies inside that window, so the two candidates are not separated by timing alone.

CONFIDENCE: moderate. Direct evidence is the code timeline and that nothing owns pin 85 in ACPI; NOT proven that the LED hangs on pin 85. It is also unexplained why the light was not noticed in earlier runs (those also opened the device); the user said it was noticed only in the last tests, so earlier runs may simply not have been watched.

DISCRIMINATING TEST WITHOUT CODE CHANGE (proposed): same command but WITHOUT `--start-sensor` and `--sensor-pm-cycle` (so the sensor GPIO 0 is not toggled during the capture; pin 85 still toggles because the node is opened):
`./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 200 --seconds 8`
- LED on -> pin 85 (`enable_isp`) is the cause. Then the pin assignment of patch 0003 is wrong for this board.
- LED off -> the sensor GPIO 0 / the sensor start is the cause.
FOLLOW-UP if pin 85: patch 0023 adding a module parameter that skips the `gpiod_set_value()` on that line (it stays low) to see if the ISP still boots and the firmware still answers without it (it may not be needed on this board, since the ISP is also powered by the SMU/genpd), and stop driving a line that is wired to something else.

## 51. RESULT: the front-camera light comes on with NO sensor start (no `--start-sensor`, no `--sensor-pm-cycle`, no `--phy-init`)

USER RESULT: command of section 50 (`--replay --tuning-file ... --pool-mb 200 --seconds 8` only): light ON.

WHAT THIS RULES OUT: the sensor reset/enable GPIO 0 and the ov13b10 `s_stream` (not touched in this run), the PHY code, the forced runtime-PM cycle. The sensor was not started by the host in this run.

WHAT REMAINS (everything that happens when the capture node is opened and a stream is set up):
- H-A: `enable_isp` = `AMDI0030:00` pin 85 driven HIGH in `isp4sd_pwron_and_init()` (`isp4_subdev.c:863`), LOW at power-off. The code timeline matches the observation exactly (section 50). Most likely.
- H-B: ISP power-up through the SMU / genpd (`pm_runtime_resume_and_get`, performance state) or the firmware boot, whose firmware-side GPIO/strobe outputs are not under my control.
- H-C: the replayed Windows commands (device script, tuning data, sensor properties) make the firmware drive an output; weaker, because earlier opens without these may have lit it too (not observed).
Not separated yet: H-A against H-B/H-C.

TEST (needs patch 0023, proposed): module parameter `skip_enable_gpio` makes `isp4sd_module_enable()` do nothing, so the line stays low (it is requested `GPIOD_OUT_LOW` at probe). Run the same command with it. LED off -> pin 85 is the cause (H-A); the pin choice of patch 0003 is wrong for this board and the line must not be driven. LED on -> H-B/H-C, pin 85 cleared. Either way learn whether the ISP boots and the firmware answers without pin 85 high. Optional extra: the stock module with no experiment parameters (`sudo modprobe amd_isp4_capture`, then `v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1`) to see whether a plain open lights it.

## 52. Patch 0023: `skip_enable_gpio` (written and built, not yet run)

PURPOSE: separate H-A (pin 85 `enable_isp` lights the front-camera LED) from H-B/H-C (ISP power-up or firmware outputs), see section 51.

`0023-isp4-skip-enable-gpio.patch` (on top of 0022; base file in `base-0022/`, only `isp4_subdev.c` changed):
- new bool module parameter `skip_enable_gpio` (default 0, read-only in sysfs).
- `isp4sd_module_enable()`: with the parameter set it logs once (`EXP: skip_enable_gpio=1, enable_isp GPIO is not driven`, via `dev_info_once`) and returns before `gpiod_set_value()`. The line was requested `GPIOD_OUT_LOW` in probe, so it stays low. The parameter does not change the probe or the remove path (remove would only set a low line low).
- `scripts/test-isp4-threshold.sh`: new option `--skip-enable-gpio` (passes `skip_enable_gpio=1` to `insmod`), usage comment, and the console summary filter now also shows the `skip_enable_gpio` line.

TEST (the same command as section 50 plus the new option; keep it short):
`./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 200 --seconds 8 --skip-enable-gpio`

HOW TO READ THE RESULT:
- LED OFF, firmware answers as before (EXP-RESP status 0 lines, FW log "ISP Firmware Version: 51.0.8.0"): pin 85 is what lights the LED, and the ISP does not need it high on this board. Patch 0003's pin choice is wrong for the GZ302; do not drive that line.
- LED OFF, but the ISP/firmware does not come up (insmod/boot errors, no EXP-RESP): pin 85 lights the LED AND the ISP boot depends on it, or the same line does both; then the true ISP enable pin is a different one (next: Windows/amdkmdag decode or a scan of the FCH GPIO registers).
- LED ON: pin 85 is cleared (H-A false); remaining H-B (ISP power-up/firmware output) or H-C (replayed Windows commands). Next: run without `--replay` and `--tuning-file`, then the stock module alone.
- Risk: none for the hardware beyond an unpowered ISP; an unchanged-low pin cannot damage anything.

## 53. RESULT of patch 0023: with `enable_isp` (pin 85) never driven, the ISP still boots and the front-camera light STILL comes on (run 20261015-223649, `--skip-enable-gpio`, no sensor start)

OBSERVED (`results/20261015-223649-console.txt`, `...-min4-var0.log`):
- `EXP: skip_enable_gpio=1, enable_isp GPIO is not driven` is in the kernel log (once). So pin 85 stayed low (requested `GPIOD_OUT_LOW` in probe).
- Firmware 51.0.8.0 booted and answered exactly as before: 24 `EXP-RESP ... status 0` lines; STOP path fails 0x1e as before; `frames=0 bytes=0 select timeout`.
- User: the light was still on.

CONCLUSIONS:
- H-A is false: `AMDI0030:00` pin 85 does NOT light the front-camera LED, and the ISP does NOT need pin 85 high to boot or accept commands on this board. Patch 0003's pin assignment is therefore not needed for these experiments (the driver only needs the lookup so that `devm_gpiod_get("enable_isp")` succeeds at probe).
- Cleared so far as LED causes: PHY writes (0021/0022), sensor GPIO 0 and `s_stream` (section 51), pin 85 (this section).
- Still open: (B) something the ISP power-up does (SMU `amdgpu_dpm_set_powergating_by_smu(ISP)` in `isp_poweron()`; platform firmware PMFW rails/GPIOs), (C) outputs the ISP FIRMWARE drives itself, possibly following the replayed Windows commands, (D) the ISP's own three sensor-control pins.
- NEW FACT (`pinctrl-amdisp.h`): the ISP's own pin controller has THREE pins, `GPIO_0 "sensor0 control"`, `GPIO_1 "sensor1 control"`, `GPIO_2 "sensor2 control"`; registers at ISP offsets 0x6613C (GPIO0), 0x66140 (GPIO1), 0x6618C (GPIO2); the output value is bit 4 (`GPIO_CONTROL_PIN`), output-only (`pinctrl-amdisp.c`). Linux only knows sensor0 (OV13B). The ISP supports up to three sensors; a front camera may be sensor1 or sensor2 as far as the ISP hardware is concerned (ACPI lists only the OV13B `CAMB`, section 48), so one of the other control pins may drive that module's LED/power.
- NEXT (patch 0024, read-only): print the three pin registers in every `EXP-RING` snapshot to see which sensor-control output is high while the light is on.

## 54. Patch 0024: print the ISP's three sensor-control pins in every EXP-RING snapshot (written and built, not yet run)

`0024-isp4-ispgpio-dump.patch` (on top of 0023; base in `base-0023/`, only `isp4_interface.c`):
- `isp4if_init()` maps the 0x54-byte window at ISP offset 0x6613c once, with `devm_ioremap()` (process context; no region request, so no conflict with the `isp_gpio_reg` resource owned by the pin controller). If mapping fails it logs a warning and the dump is skipped.
- `isp4if_dump_rings()` adds one line per snapshot: `EXP-RING[<when>]: ISP sensor-control pins gpio0 0x.. gpio1 0x.. gpio2 0x.. (output bit 4: a b c)`. Only reads, at moments where the ISP is already being read (same call sites as before).
- No new parameter. The test script already prints every `EXP-RING` line in its "ring / interrupt state" section.

WHAT TO RUN: any run in which the light comes on, for example the section 50 command (`--replay --tuning-file ... --pool-mb 200 --seconds 8`), optionally with `--skip-enable-gpio`.

HOW TO READ THE RESULT (compare snapshots: `replay: before`, `before unknown cmd`, `replay: after`, `after START_STREAM queued`, `before ... STOP_STREAM`):
- gpio1 or gpio2 output bit 4 goes to 1 while the light is on -> the firmware (or something else) drives a sensor-control pin of a sensor Linux does not know about; that is the front-camera LED/power. Then: who sets it (firmware script vs. host) and how to keep it off.
- only gpio0 bit 4 is high (or none): these three pins do not light it; remaining: SMU/PMFW rail on ISP power-up, or an EC-controlled indicator. Next test: run without `--replay`/`--tuning-file`, and the stock module alone.
- A register value of 0xffffffff would mean an unpowered/unreachable block; then say so.

## 55. RESULT of patch 0024: none of the ISP's three sensor-control pins is driven high while the light is on (runs 20261015-224050 and 20261015-224146, identical; no `--start-sensor`, no `--skip-enable-gpio`)

OBSERVED (`EXP-RING[...]: ISP sensor-control pins` lines, 8 snapshots per run: `replay: before`, 3x `before unknown cmd`, `replay: after`, `after START_STREAM queued (img buf)`, `before ...ENABLE_OUT_CHAN`, `before ...STOP_STREAM`):
- `gpio0 0x00000001 gpio1 0x00000001 gpio2 0x00000001`, output bit 4 = 0 0 0 in EVERY snapshot of both runs. Never 0xffffffff, so the block was reachable. The value does not change through the whole capture.
- The user reports the light on in these runs.

CONCLUSIONS:
- ISP offsets 0x6613c / 0x66140 / 0x6618c (sensor0/1/2 control, output value = bit 4) do NOT light the front-camera LED, at least as plain GPIO outputs. If the firmware drives a strobe/flash function on a pin through another mux function, bit 4 would not show it; this is not excluded. Bit 0 reads 1 on all three (meaning not known; the Linux pin driver never touches it).
- Cleared as LED causes: PHY (0021/0022), sensor GPIO 0 and `s_stream` (section 51), `enable_isp` pin 85 (section 53), the ISP sensor-control pin values (this section).
- Remaining: (B) the SMU/PMFW power-up of the ISP tile (`isp_poweron()` -> `amdgpu_dpm_set_powergating_by_smu(ISP, false)`), possibly together with a board rail (the Windows driver has a separate "LDO power for the sensor" call, section 49); (C) firmware-side outputs (strobe/IR/flash function) after the Windows firmware boots or after the replayed commands; (D) something outside the ISP (EC), or a hardware-tied "camera in use" indicator.

NEW FACT: the capture driver (`isp4.c`) has no runtime-PM callbacks; runtime PM is only enabled at probe (`pm_runtime_enable`, line 169). So `pm_runtime_resume_and_get(dev)` (used by `isp4sd_pwron_and_init()`) does one thing: the generic power domain runs `isp_poweron()` (SMU power-up). Current state (read from sysfs): `amd_isp_capture.1.auto` runtime_status `suspended`, control `auto`; `amdisp-pinctrl.3.auto` `unsupported`; `amd_isp_i2c_designware.2.auto` `suspended`.

TEST (no code; needs root; separates B from C; reversible): power the ISP tile ONLY, with no firmware boot, no commands and no video node open, by forcing the capture device's runtime PM on, look at the light, then restore:
1. `sudo sh -c 'echo on > /sys/bus/platform/devices/amd_isp_capture.1.auto/power/control'`   (then `cat /sys/bus/platform/devices/amd_isp_capture.1.auto/power/runtime_status` should read `active`)
2. look at the front-camera light for ~10 s
3. `sudo sh -c 'echo auto > /sys/bus/platform/devices/amd_isp_capture.1.auto/power/control'`   (back to `suspended`)
- Light ON in step 2 -> it is the SMU power-up / a rail on the ISP tile (B). Then the cause is outside our driver; the way forward is how Windows avoids it (LDO selection, `isp_snr_enbale_ldo_power`, or the ISP power-up arguments).
- Light OFF -> it needs the firmware running or our commands (C) or the streaming path; next: run the capture without `--replay`/`--tuning-file`, and compare opening only.
Also useful (no tool needed): note whether the light comes on at the START of the capture or only seconds later, and whether it goes off when `select timeout` prints or when the script ends.

## 56. RESULT of the power-only test, and a re-reading of the LED timing: the light follows the teardown of the capture node, not the ISP running

USER RESULTS:
- `echo on > /sys/bus/platform/devices/amd_isp_capture.1.auto/power/control` (step 1 printed nothing, as expected) -> `runtime_status` `active` (step 2) -> NO light during step 2 (ISP tile powered, no firmware, no commands, no node open). Step 3 restored `auto`.
- Timing of the light in the capture runs: it comes on when `v4l2-ctl` prints `select timeout`, and goes off when the log line is printed by the script.

CLEARED by this: the SMU power-up of the ISP tile (H-B) is not the cause.

TIMELINE of run 20261015-224146 (journal, 1 s resolution):
- 22:41:48 ISP powered, firmware booted, replay commands, `START_STREAM queued`, firmware pipeline runs (no light).
- 22:41:50 teardown starts: `ENABLE_OUT_CHAN` (disable) sent synchronously, firmware answers status 1, code 0x1e. This is `isp4sd_stop_stream()` after `v4l2-ctl` times out waiting for a frame = "select timeout".
- 22:41:51 `STOP_STREAM` (0x1e), `wait stop stream suc`, response threads quit, `power off isp_subdev suc` (SMU power-off at `isp4sd_pwroff_and_deinit()`).
- then the script: `sleep 1`, `journalctl`, prints the `log:` line (about 1-2 s after the ISP is already off) = the moment the light goes off, per the user.
So the light is OFF while the firmware runs and streams, comes ON when the stream is torn down, and stays on for about a second or two AFTER the ISP tile was powered down.

NEW FACTS (this session, read-only):
- `v4l2-ctl --list-devices`: `amd_isp_capture` = `/dev/video0` + `/dev/media0` only. The "front camera" is a SEPARATE USB device, "ASUS 5M webcam" (`usb-0000:c4:00.4-1`), `/dev/video1-4` + `/dev/media1,2`. It has nothing to do with the ISP hardware path.
- Running user-space: `pipewire`, `wireplumber`, `pipewire-pulse`, Brave (many renderer processes), `plasma-browser-integration-host`. PipeWire's V4L2 monitor opens and probes `/dev/video*` nodes when they appear/change; a UVC webcam lights its LED when something STREAMS it.
- Nothing holds any `/dev/video*` open when idle (dry run of the new watcher at 22:50).

RE-RANKED HYPOTHESES (none verified):
- H-U (new, now top): a user-space process opens/streams the USB webcam when the ISP node is closed (udev change / PipeWire re-enumeration / browser camera permission check), so the webcam LED lights for the second or two that takes. This matches: light on exactly at the node close (not during the ISP run), staying on after the ISP is already powered off, going off about 1-2 s later without any kernel event; and it explains why nothing on the ISP side (PHY, GPIO 0, pin 85, sensor-control pins, SMU power-up) changes it.
- H-C (firmware outputs during the failed stop): still possible (the firmware logs `Re-enable DeepSleep after IR close for streamId[0]` and `IspHwIpDisable` during the stop), but it would not explain a light that outlasts the ISP power-off.
- H-D (EC / hardware-tied indicator): not excluded.
TEST (no code): the new script `scripts/watch-video-users.sh` (passive; polls `fuser` on `/dev/video0..4` every 0.1 s and logs every change of holder with a millisecond timestamp, to `results/<stamp>-video-users.txt`). Run it in a second terminal, then the test in the first one; if a process (expected names: `wireplumber`, `pipewire`, `brave`, `plasma-...`) appears on `/dev/video1-4` exactly when the light turns on, H-U is confirmed and the light has nothing to do with our driver work (the ISP side is then free to be debugged without it). If nobody appears, H-U is out and H-C/H-D remain; then the pause-per-teardown-stage experiment (a module parameter that sleeps between the teardown stages and logs each stage) is the next step.

## 57. RESULT of the user-space watcher: nobody holds any /dev/video* node during the light window; Brave probes the USB webcam node only at ISP-node hotplug (run 20261015-225451, watcher log `20261015-225440-video-users.txt`)

OBSERVED (watcher, 100 ms polling, 5 nodes; kernel journal of the run `20261015-225451-min4-var0.log`):
- 22:54:41.0 nobody.  22:54:51.386-.676 `/dev/video3` held by `brave` (pid 70085), 0.3 s. Script start = `rmmod`/`insmod` of the capture module, i.e. the ISP node disappears and reappears: Brave (or its camera enumeration) probes the USB webcam when video devices change. It happens ~2 s BEFORE the capture.
- 22:54:53.583-55.852 `/dev/video0` held by `v4l2-ctl`. Kernel: START_STREAM queued 22:54:53; teardown commands (disable channel, STOP_STREAM) 22:54:55; resp threads quit 22:54:55; `power off isp_subdev` logged 22:54:56 (1 s granularity).
- From 22:54:55.852 until the end of the watch (22:55:21): nobody holds any video node. No process touches the webcam nodes /dev/video1-4 in the teardown window (checked only the video nodes, not /dev/media* or raw USB access).
- The user's observation for THIS run was not reported (only the watcher output was pasted).

CONCLUSIONS:
- H-U (a user-space process opens/streams the webcam during the light window) is NOT supported: during the window 55.9 -> script log print nothing holds a video node. Brave's open (0.3 s at script start) is a probe, not the window in which the light was reported on (select timeout -> log print).
- Not excluded: a process using the webcam without a /dev/video fd (UVC extension-unit control over `/dev/bus/usb`, `/dev/media*`, `hidraw`), though no such tool is running (no howdy / linux-enable-ir-emitter in the process list).
- The window in which the light is reported on (~22:54:55 teardown start -> ~22:54:57-58 log print) contains the ISP teardown (55) and the ISP power-off (56) and ends about 1-2 s later. Whether the light follows the teardown stages or the power-off is still unknown at 1 s resolution.

NEXT (patch 0025, proposed): bisect the teardown by pausing between its stages (module parameter `teardown_pause_ms`, default 0) and logging a marker line at each stage, so the user can say between which two markers the light turns on and off.

## 58. ROOT-CAUSE CANDIDATE for "no frames": the sensor's PLL is programmed for a 19.2 MHz clock, but Windows' table (and the AMD reference platform) assume 24 MHz; the lane rate is then wrong and the receiver sees corrupt headers

Scope note: from here on the front-camera LED question is parked (user decision) until the rear camera delivers frames.

COMPARISON (script `scratch/diff_ov13b_tables.py`, run with `python3 -I`; inputs: the Windows table in section 3 above and the 4208x3120 lists of the on-disk `ov13b10.c`, `mipi_data_rate_1120mbps[]` then `mode_4208x3120_regs[]`): Windows 131 entries, Linux 129 effective entries.
- DIFFERENT VALUE (reg: windows / linux): `0x0303: 01 / 04`, `0x0305: 46 / af`, `0x0325: 55 / a4` (PLL); `0x3501: 00 / 0c`, `0x3502: 60 / 10`, `0x3508: 01 / 07`, `0x3509: 00 / c0` (exposure and gain defaults, overwritten by controls); `0x3600: 1a / 16`; `0x380f: 94 / 7c` (frame length 3220 vs 3196 lines); `0x3813: 08 / 09`.
- ONLY IN WINDOWS: `0x3011=7c`, `0x3774=2d`, `0x3823=18`, `0x3827=01`.  ONLY IN LINUX: `0x3810=00`, `0x3812=00` (reset defaults).
- Identical in both (so not the difference): `0x4800=64`, `0x4837=0e` (MIPI pclk period), `0x4825`, `0x481b`, `0x481f`, `0x3808..0x380d` (4208x3120), the other analog and timing registers.

CLOCK ARITHMETIC (INFERENCE: I use the usual OmniVision encoding of the pre-divider register `0x0303`: 0 -> /1, 1 -> /1.5, 2 -> /2, 3 -> /2.5, 4 -> /3; NOT checked against the OV13B datasheet, which I do not have):
- Linux registers (`0x0303=4`, `0x0305=0xaf`=175): Fin x 175 / 3. At 19.2 MHz = 1120 Mbps (what the driver comment says). At 24 MHz = 1400 Mbps.
- Windows registers (`0x0303=1`, `0x0305=0x46`=70): Fin x 70 / 1.5. At 24 MHz = 1120 Mbps. At 19.2 MHz = 896 Mbps.
- Old patch 0007 (`0x0305=0x8c`=140, divider left at /3): at 24 MHz = 1120 Mbps (but `0x0325` PLL2 stays 0xa4, effect unknown).
So the Windows table is self-consistent ONLY for a 24 MHz sensor clock, and gives exactly the 1120 Mbps that the ISP firmware property (`caps+0x1f0` = 1120), my D-PHY sequence and the Linux comment all assume.

WHERE LINUX GETS 19.2 MHz (OBSERVED): `ov13b10.c:576` `OV13B10_EXT_CLK 19200000`, probe fails unless `clk_get_rate() == 19200000`; the rate comes from the software node of MY patch 0002 (`PROPERTY_ENTRY_U32("clock-frequency", 19200000)`, `0002-platform-amd-isp4-add-gz302-ov13b10-graph.patch`), whose own commit text says: "The 19.2 MHz declaration satisfies the driver's required external clock property; real clock validation remains part of hardware bring-up." The AMD reference node for the OV05C10 in mainline `amd_isp4.c:120` declares `24 * HZ_PER_MHZ`; patch 0007's text says the ISP reference platform uses 24 MHz.
The kernel source tree on disk does NOT contain patch 0007 (no 0x8c, no "GZ302" PLL line in `ov13b10.c`); which patches are in the module that is actually running is not verified.

WHY THIS FITS EVERY SYMPTOM:
- The sensor transmits (data lanes leave stop state, section 47) but every packet header fails ECC (`Error protocol` / `2-bit ecc error`, sections 44-45): the receiver samples at 1120 Mbps data that arrives at a different rate (1400 Mbps if the real clock is 24 MHz).
- Start order, PHY registers, tuning, memory pool, replay commands do not change the picture (sections 39-45).
NOT PROVEN: that the ISP's sensor clock really is 24 MHz (only inferred from the Windows table, the reference node and my old patch text), and that `0x0325` has no other effect.

EXPERIMENT (patch 0025, proposed): read back the PLL registers from the live sensor right after `s_stream(1)` (proves what rate the sensor really got), then, in software standby (`0x0100=0`), write the WINDOWS PLL values (`0x0303=0x01`, `0x0305=0x46`, `0x0325=0x55`) over raw I2C and restart streaming (`0x0100=1`); read back again. Module parameter `sensor_pll` (default 0, off). Success criterion: the `2-bit ecc error` lines disappear and the firmware/driver count frames.

## 59. RESULT of patch 0025, and INCIDENT: the Windows PLL values make the CSI-2 link decode, but the run hung the SoC's SMU and froze the whole machine (runs 20261015-231857 `--sensor-pll 1`, 20261015-231925 `--sensor-pll 2`; both `--replay --tuning-file --pool-mb 200 --start-sensor 2 --sensor-pm-cycle --phy-init --seconds 8`; run by Claude via the temporary sudo rule)

OBSERVED, read-back (231857, `sensor_pll=1`): live sensor after `s_stream(1)`: `0x0100=01 0x0303=04 0x0305=8c 0x0321=00 0x0323=04 0x0324=01 0x0325=a4 0x0326=81 0x0327=04 0x3011=4c 0x4800=64 0x4837=0e`.
- So the RUNNING ov13b10 module contains the old patch 0007 (`0x0305=0x8c`), unlike the source tree on disk. With the /3 pre-divider that is 1120 Mbps at 24 MHz (896 at 19.2). CORRECTION of section 58: the "1400 Mbps" case does not apply to this machine; the remaining live differences from Windows were the pre-divider/multiplier split (`0x0303`/`0x0305`), PLL2 `0x0325` (`a4` vs `55`) and `0x3011` (`4c` vs `7c`).
- Firmware: 482 `Error protocol`/`2-bit ecc error` lines, FrameStart 53 / FrameDone 39 (as in section 47). `frames=0`.

OBSERVED, Windows PLL applied (231925, `sensor_pll=2`): read-back after the writes `0x0303=01 0x0305=46 0x0325=55` (writes took; `0x3011` still 4c); stream on -> 0.
- `Error protocol` / `2-bit ecc error`: **0** (was 482). The CSI-2 packet headers now decode: the link-level problem is gone.
- New error, 2358 times: `MipiWdmaInterruptsHandler: [S:0|MIPI0] mipi wdma error: INTR_LATENCY_BUFFER_LEAKING` with `ReportHwError: ISP_MIPI_MI_WR_DBG_CUR_PTR=0x00000000`, starting ~110 ms after START_STREAM was answered. The MIPI write DMA (the stage that stores the received raw data in memory) overflows its latency buffer; its write pointer stays 0. Firmware log ring overflowed (`rd 53415 wr 53393`), so part of the log is lost. Earlier in the same boot the firmware's own memory test warned: `MemLatencyTest: Mem performance may not meet RT task schedule requirement, current:351, baseline:260`, `Mem perf drop level:5`, clocks `FCLK 1600, SCLK 598.87, ICLK 792, XCLK 798.47`.
- Side fact: in this run the ISP sensor-control pin GPIO0 output bit went to 1 after START_STREAM (`gpio0 0x00000011`); it was 0 in all earlier dumps.
- `STOP_STREAM` was not answered (`EXP-RING[TIMEOUT ISP4FW_CMD_ID_STOP_STREAM]`, `fail to stop stream`), v4l2-ctl was killed by `timeout` (rc 124), `frames=0 bytes=0`.

INCIDENT (previous boot's kernel log, `journalctl -k -b -1`):
- 23:19:31.79 teardown: STOP_STREAM timeout, `s_stream(0)`, resp threads quit. The host then holds the ISP CPU in reset and asks the SMU to power-gate the ISP.
- 23:19:45.00 first `amdgpu: SMU: No response msg_reg: f resp_reg: 0` / `Failed to export SMU metrics table!`; 23:20:00 `Failed to power gate ISP!`. From then on EVERY SMU message timed out (one every ~15 s).
- 23:22:39 `DMCUB error` (display microcontroller), `WARNING ... dmub_psr_get_state`; 23:22:56 `ring vcn_unified_0 timeout` (video engine, plasmashell), ring reset; 23:23:23 `Failed to power ungate VCN instance 0!`, `psp ... LOAD_IP_FW failed`. Journal ends 23:23:38 (hard reset by the user).
- Mechanism (INFERENCE): the SMU is the SoC power-management firmware shared by GPU, display, video engine and ISP. Its ISP power-gate sequence waits for the ISP to go idle; the ISP's MIPI write DMA was stuck with outstanding memory traffic (latency-buffer overflow, firmware unable to answer STOP_STREAM), so the power-gate never completed and the SMU stopped answering anyone. Without the SMU the display and video engine failed, so the desktop froze. Only a power cycle resets the SMU.
- Damage check (current boot): `SMU is initialized successfully!` (fw 100.7.0), no SMU/BTRFS errors; btrfs did its normal tree-log replay after the unclean shutdown. No sign of lasting damage.

LESSONS / SAFETY RULES FROM NOW ON:
1. A stream that produces decodable data but cannot write it to memory can wedge the ISP so that its power-off hangs the SMU. Before the next live run: make the teardown safe when STOP_STREAM times out (do not power-gate an ISP whose DMA may still be running; e.g. stop the sensor output first so the data flood ends, wait, then stop).
2. Stop the sensor (`0x0100=0`) early in the teardown, before the stop commands, when `sensor_pll=2`.
3. Keep runs short; one run per change.

NEXT (frames): the data now reaches the write DMA. Questions: why the write pointer is 0 (no raw buffer programmed?), whether the bandwidth of 4208x3120 at full rate exceeds what the memory path gives at these clocks (Windows may request higher memory clocks), and whether a lower bandwidth (binned mode / lower frame rate) gets frames through.

## 60. CORRECTION to section 59, and the lead for the write-DMA overflow: Windows switches the ISP memory path ("memory stutter" + MMHUB power gating off) through the SMU, Linux never does

CORRECTION (timeline of the frozen run, previous boot, ms precision): START_STREAM answered 23:19:28.69; teardown started 23:19:30.67; the disable-channel command timed out at 31.19 and STOP_STREAM at 31.79. So the ISP FIRMWARE was already unresponsive ~2 s after START_STREAM, BEFORE the driver asked the SMU to power-gate the ISP (after 31.8). The first SMU timeout (23:19:45) is consistent with a request issued ~23:19:30. Section 59's mechanism "the power-off request hung the SMU" is therefore not supported; more likely the stream itself (decodable data that the write DMA could not store) wedged the ISP and, with it, the SMU. A safer teardown alone would not make the next run safe.

OBSERVED (Windows `amdcamera.sys`, disassembled locally with `llvm-objdump` into `scratch/disasm/amdcamera.txt`; strings resolved through the PE section table):
- `0x140010ca0` = `isp_disable_mmhub_power_gating(dev, x, on)`: checks the argument (`0x14002bcdc`), then `0x14004add8` = `isp_disable_mmhub_pg_by_smu(on)`, which fills a small request (dword 1, and bit 5 (or bit 7 if `dev+0x1760` is set) = on) and passes it through a function pointer of the display-driver interface (`*(ctx+0x10028+0x50)`).
- `0x140010fcc` = `isp_enable_memory_stutter(dev, x, on)`.
- `0x1400176f0` = `isp_memory_stutter_status_transfer(dev, x, state)`: state 1 -> `isp_disable_mmhub_power_gating(1)` THEN `isp_enable_memory_stutter(1)`; state 0 -> `isp_enable_memory_stutter(0)` THEN `isp_disable_mmhub_power_gating(0)`.
- Its only caller is in `isp_process_memory_stutter` (strings `0x14009a040`, `isp_memory_stutter_status_transition` 0x14009a010), which compares a value with `0xB71B00` = 12,000,000 (INFERENCE: a pixel-count threshold of 12 MP; our mode 4208x3120 = 13.1 MP is above it).
OBSERVED (Linux source, `drivers/gpu/drm/amd/pm/swsmu/inc/pmfw_if/smu_v14_0_0_ppsmc.h:100-101`):
  `#define PPSMC_Message_IspStutterOn_MmhubPgDis 0x2F ///< ISP StutterOn mmHub PgDis`
  `#define PPSMC_Message_IspStutterOff_MmhubPgEn 0x30 ///< ISP StufferOff mmHub PgEn`
  (same IDs in `smu_v13_0_4_ppsmc.h`, Phoenix). These are NOT in the SMU v14.0.0 message map (`smu_v14_0_0_ppt.c`), and nothing in amdgpu sends them. Linux powers the ISP with `PowerUpIspByTile(ISP_ALL_TILES_MASK)` only (`smu_v14_0_0_set_isp_enable`). No public source found that uses them.

WHY IT FITS: the firmware's own start-up test reports memory latency above its real-time baseline (`current:351, baseline:260`, `Mem perf drop level:5`), and the write DMA fails with `INTR_LATENCY_BUFFER_LEAKING`: a real-time writer whose memory path has power-gating/stutter wake-up latency overflows its latency buffer. Windows switches exactly this off for streams above ~12 MP; Linux never does. (The Linux reference sensor is a 5 MP OV05C10, below the threshold, which would explain why upstream never needed it.)

NOT KNOWN: the SMU message argument (the Windows request carries an on/off bit; the display driver's translation to the PMFW message is not visible; 0 is the usual argument for parameterless messages, NOT verified); whether ISP stutter must be set before or after `PowerUpIspByTile` (Windows: stutter/MMHUB switch is done per stream state, after the ISP is powered).

NEXT (needs the user: an amdgpu change is a kernel-module change): add `IspStutterOn_MmhubPgDis` / `IspStutterOff_MmhubPgEn` to the SMU v14.0.0 message map and send them from the ISP power path (on after power-up, off before power-down), rebuild amdgpu for 7.2.0-1.7, install, reboot, then one short run.

## 61. amdgpu patch 0009 (ISP memory stutter / MMHUB power gating) written and built out of tree; install prepared, not yet installed

PATCH: `scratch/kernel-patches/0009-drm-amdgpu-isp-memory-stutter.patch` (work copies `scratch/kernel-patches/0009/{a,b}/`):
- `drivers/gpu/drm/amd/pm/swsmu/inc/smu_types.h`: two new SMU message names at the end of the list, `IspStutterOn_MmhubPgDis`, `IspStutterOff_MmhubPgEn`.
- `drivers/gpu/drm/amd/pm/swsmu/smu14/smu_v14_0_0_ppt.c`: `MSG_MAP` entries to `PPSMC_Message_IspStutterOn_MmhubPgDis` (0x2F) / `..._IspStutterOff_MmhubPgEn` (0x30); `smu_v14_0_0_set_isp_enable()` sends stutter-off before `PowerDownIspByTile` and stutter-on after `PowerUpIspByTile`, argument 0, failures only logged (`dev_warn`), success logs `ISP stutter on / MMHUB PG disabled`. This GPU registers `smu_v14_0_0` (boot log), whose `set_ppt_funcs` covers MP1 14.0.0/1/4/5.

OUT-OF-TREE BUILD (`scripts/build-amdgpu-oot.sh`, sources `scratch/amdgpu-oot/cachyos-7.2.0-1/drivers/gpu/drm/amd`, extracted from the user's `cachyos-7.2.0-1.tar.gz` + 0001/0003/0005 applied with offsets/fuzz as makepkg would):
- Tracepoint headers name themselves `../../drivers/gpu/drm/amd/...` relative to `include/trace/`; fixed with an empty extra include dir `$tree/include/trace` (KCFLAGS), no source edit.
- Baseline (without 0009) vs the installed module: srcversion differs (`337B046F2C1C6273B9BE4FE` vs `19A5444E3497C974A12325B`; out-of-tree builds hash a different file set), but module parameters identical, the set of function names identical (LTO suffixes stripped), and the GZ302 strings (`OMNI13B1` x2, `i2c-ov13b10`, `enable_isp`) present in both. Conclusion: same sources (strong evidence, not a byte-level proof). Copies kept: `scratch/amdgpu-oot/installed-amdgpu.ko`, `amdgpu-baseline.ko`.
- With 0009: builds; same 5 warnings as the baseline (toolchain version notes; stack-frame warnings in DCN 3.0/3.1/3.14 display code, not this GPU); module contains both message names and the new log lines. vermagic `7.2.0-1.7-cachyos`. Built with clang 23 while the kernel used clang 22 (same as the capture module, which loads fine).

INSTALL (user, touches /usr/lib/modules and /boot): `scripts/install-amdgpu-0009-test.sh` installs `updates/amdgpu.ko.zst` for kernel 7.2.0-1.7 only (depmod order `updates extramodules built-in`), rebuilds a NEW initramfs (amdgpu is in `MODULES=(amdgpu)`), combines it with the srx_h firmware cpio into a NEW file and prints a new Limine entry; overwrites nothing. Undo: `scripts/undo-amdgpu-0009-test.sh` (prints the commands).

RISKS (honest): (1) the message argument 0 is a guess; if the PMFW rejects it, only a warning is logged; if it hangs the SMU, the hang happens when the ISP powers up (possibly already at boot when ISP child devices probe) -> black screen or freeze, recover by power-cycling into another entry. (2) If the stutter change is not the cause, the next `--sensor-pll 2` run can freeze the machine again as in section 59.

TEST PLAN after booting the new entry: check `modinfo -n amdgpu` and the boot log (no SMU errors, ISP firmware srx_h), then ONE short run `--replay --tuning-file ... --pool-mb 200 --start-sensor 2 --sensor-pm-cycle --phy-init --sensor-pll 2 --seconds 8`, with unsaved work closed. Look for `ISP stutter on / MMHUB PG disabled`, the absence of `INTR_LATENCY_BUFFER_LEAKING`, a STOP_STREAM answer, and frames.

## 62. RESULT: the amdgpu 0009 entry froze the machine WITHOUT any camera test (boot b54204f1, 2026-10-15 23:58:57 -> 00:00:43)

OBSERVED (previous boot, kernel and system journal):
- `modinfo -n amdgpu` = `updates/amdgpu.ko.zst`, loaded srcversion `9F29528D070F43C6532261F` (the 0009 build); Windows srx_h ISP firmware loaded (sha256 1f0f826e...); `SMU is initialized successfully!`.
- 23:59:03 `ISP stutter on / MMHUB PG disabled` (the ISP is powered up once during boot for its child devices; no warning for the matching stutter-off when it is powered down again, i.e. that message was answered or not sent).
- No capture test, no amd_isp4_capture activity, no camera process. Last kernel message 23:59:15; system journal continues normally (network, services, my read-only `journalctl` at 00:00:21) and stops at 00:00:43 with no error: a hard freeze that left no log.
- The same entry was booted again afterwards (current boot): srcversion 9F29..., one `ISP stutter on` at boot.
INTERPRETATION (not proven, but the only new element): the 0009 change is the most likely cause. Unpatched boots of the same kernel ran for hours; this one froze ~100 s after boot while idle. Candidates: the guessed argument 0 makes the PMFW apply a wrong memory/MMHUB setting; or the stutter-on / -off pair at an ISP power-up that has no stream (Windows only switches it while streaming > 12 MP) leaves the memory hub in a state the display path does not survive.
DECISION: stop using the 0009 entry; the change is not safe as written. Next steps need more information about the message argument and timing (Windows sends it per stream, after the stream is configured, not at every ISP power-up).

## 63. Step 2 prepared (not yet run): burst-limited capture, and the GPU performance-level test

STATE: normal camera entry (`initramfs-fw-srx_h`), loaded amdgpu = stock (`/sys/module/amdgpu/srcversion` 19A5444E3497C974A12325B; `modinfo -n` names the updates/ file because it resolves on disk, but this entry's initramfs carries the original), no `ISP stutter on` at boot, ISP firmware = Windows srx_h (sha256 1f0f826e...).
PATCH FILES: `0025-isp4-sensor-pll.patch` (generated now, it had been built and run in section 59 without a patch file) and `0026-isp4-sensor-burst-limit.patch` (`sensor_burst_ms`, `--sensor-burst-ms N`), both on `isp4_subdev.c`; bases `base-0024/`, `base-0025/`.
GPU clocks: `/sys/class/drm/card1/device` = 0000:c4:00.0, `power_dpm_force_performance_level` = `auto`; `pp_dpm_fclk` 400..2000 MHz (the firmware reported FCLK 1600 during the frozen stream), `pp_dpm_socclk` 600..1472 MHz. `high` pins them at maximum; the setting is not persistent (reset at boot). Writing it needs root and is NOT in the temporary sudo rule.
PLAN (one change per run, each with `--start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --seconds 6` plus `--replay --tuning-file ... --pool-mb 200`):
- A: performance level `auto` (reference: count of `INTR_LATENCY_BUFFER_LEAKING`, firmware `MemLatencyTest current:` value, FrameStart/FrameDone, STOP_STREAM answered?).
- B: performance level `high` (set by the user before the run, `auto` after). If the write-DMA errors disappear or drop sharply and the latency value falls below the firmware's baseline (260 / 280), memory latency is confirmed as the cause.
Risk: each run still streams decodable data for ~300 ms; the freeze in section 59 came ~2 s after START_STREAM. Not guaranteed safe.

## 64. CORRECTION of sections 60/61: for the full-resolution OV13B (13.1 MP) Windows does NOT switch memory stutter or MMHUB power gating at all; my 0009 patch did the opposite of Windows. New lead: the firmware asks the host for a buffer of type 13 in every run, and the host never sends one

SOURCE: decode by a delegated agent (report `scratch/disasm/stutter-decode.md`, also helper scripts and `kmd-*.txt` range disassemblies of `amdkmdag.sys` in `scratch/disasm/`); the central claim re-verified by me in `scratch/disasm/amdcamera.txt` (OBSERVED below). Everything else from that report is the agent's reading (INFERENCE unless noted).

OBSERVED (amdcamera.sys, `isp_process_memory_stutter` at 0x140017da8..; lines 22066-22182 of the disassembly):
- For each active stream the function multiplies width x height of the stream's mode (`imull` 0x140017f4e) and compares with 12,000,000 (`cmpl $0xb71b00` 0x140017f58); `cmova` sets the "big" flag r14 = 1 when ABOVE the limit.
- New state = number of active streams: 0 -> 0; exactly 1 -> `1 + (big != 0)` (the `negb/sbbl/negl/addl` sequence at 0x140018045-0x14001804c); 2 or more -> 3. Old state is `dev+0x11a38`.
- The transfer function `isp_memory_stutter_status_transfer` (0x1400176f0, via the call at 0x14001811c) is called only for the transitions 0->1 and 3->1 (ON) and 1->0 and 1->3 (OFF) (compare chain 0x1400180ef-0x140018113). State 2 (one stream > 12 MP) is never entered or left through that call.
- => With the 4208x3120 mode (13,128,960 px > 12,000,000) Windows never sends the stutter/MMHUB request. It does it for small modes (<= 12 MP), where it ENABLES memory stutter (a power-saving mode) and disables MMHUB power gating.
Agent, not re-checked by me: the three callers (isp_kickoff_stream 0x140016997; stop_stream_imp 0x140046ced; stop_take_one_pic_imp 0x14004728a), the display driver's SMU code sending 0x2F/0x30 (amdkmdag.sys 0x141535087 / 0x1415354cc), the no-argument SMU helper (argument register not written), and an additional ISP firmware command 0x01030004 (CMD_ID_ENABLE_STUTTER, payload 1/0) sent by `isp_enable_memory_stutter`.

CONSEQUENCES:
- Section 60's hypothesis (missing stutter switch for large images) is WRONG. Linux's default (no stutter) already matches Windows for this mode. The amdgpu 0009 patch enabled stutter and disabled MMHUB PG at every ISP power-up, i.e. it did the opposite for a 13 MP stream; that, not "the argument", is the better explanation of the idle freeze (section 62), though this is still INFERENCE. Do not use the 0009 entry; no further work on stutter.
- The firmware's `MemLatencyTest ... may not meet RT task schedule requirement` warning is printed by the firmware at every start-up and is not shown to be related to the DMA overflow.

NEW LEAD (OBSERVED, from the 22 logs in `results/`; counts by a small python script): `BUF_MGR PopFrontBuffer: BUF|queue empty:type=13` appears exactly 4 times in EVERY run since START_STREAM was first accepted (20261015-203645) up to the last one, independent of PLL, PHY, GPIO, start order; `type=14` (host setfile) only in the first Windows-firmware run (before SET_TUNING_DATA existed). `INTR_LATENCY_BUFFER_LEAKING`: 0 in runs without decodable CSI-2 data, 13 in the three runs with the mismatched PLL (which also had ECC errors), 2358 in the run with the Windows PLL (ECC errors 0) with `ISP_MIPI_MI_WR_DBG_CUR_PTR=0x00000000`.
INFERENCE: the firmware needs 4 buffers of a type the Linux driver never sends (type 13: still unidentified; the firmware name table suggests candidates around 'Frame info' / 'Tnr ref' / 'Set file data'). The MIPI write DMA then has no destination and its latency buffer overflows once real data arrives. Bandwidth is not the issue: 4 lanes x 1120 Mbps = 560 MB/s raw.
NEXT: the delegated agent identifies type 13 and the Windows SEND_BUFFER sequence (what is sent before START_STREAM, sizes); then the driver sends the same.

## 65. FOUND: the missing buffer is type 13 = META_DATA; sending 6 x 128 KiB of it (patch 0027) removes the firmware's "queue empty:type=13" and "No meta data buffer is available" (run 20261016-003750, no sensor start, safe)

SOURCE: delegated read-only decode (report `scratch/disasm/buffer-types.md`) + my own checks.
OBSERVED by me (amdcamera.sys disassembly, `isp_send_metadata_buf` at 0x1400188a0): it builds SEND_BUFFER (`movl $0x2040001`) payloads whose type word is `movl $0xd` (13) taken from the buffer array at stream block +0x3b0, then `movl $0xa` (10) from the array at +0x380; both with dword `$0x4` (vmid_space = 4, i.e. Linux `ISP4FW_ADDR_SPACE_TYPE_GPU_VA`); at most 6 slots each (`cmpl $0x6`).
Agent report, not re-checked: value-to-name enum (1 RAW, 2 MIPI_RAW, 3 RAW_TEMP, 4 MIPI_RAW_SHORT_EXPO, 5 EMB_DATA, 6 PD_DATA, 7 STILL, 8 PREVIEW, 9 VIDEO, 10 META_INFO, 11 FRAME_INFO, 12 TNR_REF, 13 META_DATA, 14 SETFILE_DATA, 15 MEM_POOL, 16 CSTAT_DS, 17-22 LME_*, 23 BYRP_TAPOUT, 24 RGBP_TAPOUT, 26 YUVP_TAPOUT, 32 EMUL_DATA); `IspAllocFwDrvSharedBuff` (0x140005e38) allocates 6 x 0x20000 bytes for each array at isp_init_stream, type-13 ones not cleared (type-10 ones are zeroed); the buffers are re-sent after each frame-done (`ResendMetaInFrameDone` 0x140009690); other shared allocations not understood (4 x 128 KiB at +0x360, 6 MiB at +0x358, 192 KiB at +0x3e0, 4 KiB at +0x3e8). Windows sends no raw/MIPI_RAW buffer from the host (the raw destination is probably carved from the 200 MiB memory pool).
PATCH 0027 (`isp4_subdev.c`, parameter `meta_data_bufs`, script `--meta-data-bufs N`): allocates N (max 6) buffers of 0x20000 bytes with `isp_kernel_buffer_alloc` (kept until module unload, freed in `isp4sd_deinit()`), sends each as SEND_BUFFER {type 13, GPU_VA, addr, 0x20000} right before the type-10 buffers, logs `EXP: sent N type-13 META_DATA buffers of 0x20000 bytes`.
TEST (my run, sudo rule, normal camera entry with the Windows srx_h firmware, `--replay --tuning-file ... --pool-mb 200 --meta-data-bufs 6 --seconds 6`, NO sensor start, i.e. the kind of run that was always safe):
- gone: `BUF_MGR PopFrontBuffer: BUF|queue empty:type=13` (was 4 in every run since 20261015-203645, now 0), and the ERROR `ISP_PIPE_MGR LoadFrameMetaData: [Pipeline]No meta data buffer is available` (4 -> 0; I had not called this one out before).
- new: `STREAM_MGR HandleCmdSendBuffer: Push 'Meta data buffer' to buffer mgr` x 6 (the firmware's own name for type 13), all six commands answered status 0.
- unchanged: START_STREAM accepted; disable-channel and STOP_STREAM still answered with status 1 / code 0x1e (no real stream is running without a sensor); FrameStart 2 (empty CSIS shots). `MemLatencyTest ... drop level` varies between runs (3 / 5), not related.
MEANING (INFERENCE): the per-frame metadata could not be loaded before, so the pipeline was not fully prepared; with the metadata buffers present the capture path may now be valid, which could also remove the write-DMA overflow (`CUR_PTR=0`). NOT YET TESTED with real data.
NEXT TEST (risky, needs the user's OK and closed work): `--start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --meta-data-bufs 6` (Windows PLL = decodable data; burst limit ends the stream after 300 ms). Success: no `INTR_LATENCY_BUFFER_LEAKING`, FrameStart/FrameDone events on MIPI0/CSTAT, `poc:` frames in the driver log, `frames > 0`; and STOP_STREAM answered with status 0.

## 66. INCIDENT 3: the machine froze during a capture run that started at 00:41:46 (boot 74d0ef92); this run was NOT started by Claude

FACTS (OBSERVED, boot -1 journal and results directory):
- Claude's last module commands in that boot (sudo audit lines, no TTY field, i.e. non-interactive): 00:37:50 `modprobe -a ...`, `rmmod amd_isp4_capture`, `insmod ... start_sensor=0 sensor_pm_cycle=0 phy_init=0 skip_enable_gpio=0 sensor_pll=... meta_data_bufs=6` and 00:37:55 `rmmod`, `modprobe amd_isp4_capture` = the safe no-sensor type-13 test of section 65 (log `20261016-003750-min4-var0.log`, no problems). After that Claude made NO tool call that touches hardware; the last message asked the user for "go" and none had been given.
- A second run of `scripts/test-isp4-threshold.sh` DID start at 00:41:46 (result files `20261016-004146-console.txt` and `20261016-004146-min4-var0.nv12`, both 0 bytes on disk). The empty `.nv12` is created by `v4l2-ctl` at the start of the capture, so the run reached the capture step; the `-min4-var0.log` (written after the capture ends) does not exist, so the machine froze DURING the capture. The sudo audit lines of that run, and everything else after 00:41:43 (last persisted journal line), were lost in the freeze, so its options are UNKNOWN.
- No pstore crash record (`/var/lib/systemd/pstore/` empty). Current boot (00:44:32): module `amd_isp4_capture` not loaded; stock amdgpu.
INTERPRETATION: someone started the data-flow capture from a terminal (the exact command was printed in my previous message). It is not shown which options were used; if it was the data test (`--sensor-pll 2 ...`) this is the third freeze that follows decodable data reaching the ISP, now even with the 300 ms burst limit and the type-13 buffers (if those options were included - unknown).
DECISION: no more live runs by Claude with sensor start until the cause of the freeze is understood offline or a way to avoid it is found; ask the user which command was run.

ADDENDUM to section 66 (checked against the session transcript `59d4418d-....jsonl`, timestamps UTC = local - 3 h):
- Claude's test-script launches recorded in the transcript: 20:18:48Z (`--sensor-pll 1`), 20:19:25Z (`--sensor-pll 2`, the first freeze), 21:37:49Z (`--meta-data-bufs 6`, no sensor, safe). NO launch at 21:41:46Z (= 00:41:46 local, the run that froze the machine).
- User messages after 21:26Z in the transcript: 21:44:24Z "system crashed entirely after you ran the risky test", 21:47:09Z "i gave you the go and you launched the test yourself ...". No message containing "go" exists between Claude's question ("say go if I should run the data test now") and the crash at 21:41:46Z; the first user message after the question arrived 2.5 minutes AFTER the crash.
- Not determined: which command line produced the 00:41:46 run and from where (the shell history of the user's terminal would show it). If a "go" was typed, it did not reach this conversation.
RULE FROM NOW ON: a live test that starts the sensor is launched only after an explicit user message in this conversation that says to run it, and Claude quotes the exact command line in the message right before.

ADDENDUM 2 to section 66 (user's reply): the user states the run was intentional, that approval was given, and that the prompt history is often cleared during freezes (so a local record can be missing the last minutes). Claude cannot verify either side: no "go" and no launch in the transcript, but the transcript tail could be incomplete; the run's sudo audit lines were lost too. Not argued further. WORKING ASSUMPTION for the analysis: the 00:41:46 run was the data test as printed in the previous message (`--start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --meta-data-bufs 6` with `--replay --tuning-file ... --pool-mb 200`).
If so: (a) the freeze was much faster than the first one (user: ~1 s after launch; the first run's SMU died within seconds but the CPU kept logging for 3 minutes), so it is a different failure; (b) neither the burst limit nor the type-13 buffers prevented it; (c) with the type-13 buffers present the pipeline may for the first time have been complete enough to WRITE real data to memory, i.e. a DMA to a wrong/unmapped destination could hang the data fabric (INFERENCE; the earlier slow freeze was the ISP firmware wedging).
CHECKED: Linux `ISP4FW_ADDR_SPACE_TYPE_GPU_VA` = 4 = the Windows vmid_space code for types 10/13/15 (isp4_fw_cmd_resp.h:97), so the address-space code of the type-13 send is not the difference.

## 67. Offline check 3 (memory-fault messages) done, offline check 2 (Windows side) delegated; Linux side of the ISP memory allocation

CHECK 3 (OBSERVED, `journalctl -k` of the boots of freeze 1 `10339cec`, the patched-amdgpu idle freeze `b54204f1`, freeze 3 `74d0ef92`, and the CPU-oops boot `88e00ea7`): searched for `page fault`, `GCVM`, `mmhub ... fault`, `VM_L2`, `faulty address`, `IO_PAGE_FAULT`, `AMD-Vi ... fault/event`, `iommu ... fault`, `unhandled`, `machine check`, `hardware error`. The only matches are boot-time notes (`MCE: In-kernel MCE decoding enabled.`, `iommu: Default domain type: Translated`) and the earlier CPU oops of my PHY mistake. So there is NO logged GPU-VM fault, IOMMU fault or machine-check before any of the freezes. That does not exclude a bad DMA (a hang that fast can leave nothing in the log) but there is no direct evidence of one either; the IOMMU runs in translated mode.
LINUX SIDE of check 2 (OBSERVED, `amdgpu_isp.c:250-299`, `amdgpu_object.c:253-261`): `isp_kernel_buffer_alloc()` = `amdgpu_bo_create_kernel(adev, size, ISP_MC_ADDR_ALIGN, AMDGPU_GEM_DOMAIN_GTT, ...)`: a pinned GTT buffer object (system RAM pages mapped into the GART), flags `CPU_ACCESS_REQUIRED | VRAM_CONTIGUOUS` (the contiguous flag only matters for VRAM), the returned `gpu_addr` is the GART address; no special cache/secure/VMID attributes are set by the driver. Every host-provided ISP buffer (pool, command/response rings, log ring, meta buffers, type-13 buffers) is allocated this way.
CHECK 2 (Windows side: what IspAllocFwDrvSharedBuff's other allocations are for, how Windows allocates them and whether it programs memory registers) is delegated to the decode agent; result goes into `scratch/disasm/buffer-types.md`.

## 68. Offline check 2 (Windows memory for the ISP), done by Claude directly after the user stopped the delegated agent: the "unexplained" shared buffers are command-path buffers, not frame destinations

NOTE: the decode agent was stopped by the user before reporting; its partial files are `scratch/disasm/kmd-isp-mem-ifaces.txt` (raw display-driver disassembly), `regtrace.py`, `rangegrep.py` (not analysed). User decision recorded: agents are to run on Sonnet only (saved as a memory file).
OBSERVED (amdcamera.sys disassembly):
- `IspAllocFwDrvSharedBuff` (0x140005e38) allocates, in order: 0x8000, 0x2db0, 3 x 0x1000, 4 x 0x20000 stored from `+0x360` (a 4-slot array), 6 x 0x20000 at `+0x380` (type 10), 6 x 0x20000 at `+0x3b0` (type 13), 0x600000 (6 MiB) at `+0x358`, 0x30000 (192 KiB) at `+0x3e0`, 0x1000 at `+0x3e8` (the first five targets are not identified).
- All of them go through ONE helper, `0x140006f2c(dev, size, kind)`: it allocates a small tracking object (pool tag `'PSIA'`, 0x40 bytes) and then sub-allocates from one of TWO pre-reserved heaps (`dev+0x11a40`, `dev+0x11a48`, selected by `kind` 0..3) with `0x14004f988(heap, size, alignment 0x8000)`, a free-range-list allocator that returns an offset or -1. So Windows does not allocate each buffer from the OS; it carves them out of big regions.
- The two heaps are created in the device-init code (stores at 0x14002009b / 0x1400200bf) from `(base, size)` pairs at `dev+0x2e8..0x2f8` and `dev+0x320..0x330`, filled by a callback into the display driver (`call *0x1400aa3f0` with the device handle and a struct at `dev+0x310`): the display driver reserves memory regions for the ISP and hands them over. Sizes/attributes of these regions: NOT determined (display-driver side not analysed).
- The per-stream work-buffer getter at 0x140014e6c (switch on a type, stride 0xb0 per stream, `lfence` after the bounds checks) is called from exactly five places: `isp_ipu_set_hostless_cfg`, `get_cmd_resp_buffer`, `get_cmd_single_buffer`, `getfw_cmd_send_imp`, `setfw_cmd_send_imp` (names from log strings via `scratch/disasm/funcinfo.py`). None is a frame/stream data path.
INFERENCE: the 6 MiB / 192 KiB / 4 KiB / 4x128 KiB / ... buffers are Windows' command and response buffers (ring buffers, indirect "single" command buffers, get/set-FW command buffers). Linux has its own equivalents (`fw_cmd_resp_buf`, `fw_log_buf`, the replay buffers), so nothing here shows a missing destination for frame data. The raw frame destination is still believed to be carved from the 200 MiB pool (Windows sends no host RAW/MIPI_RAW buffer).
STATE OF THE FREEZE QUESTION after checks 2 and 3: no cause identified. No GPU-VM/IOMMU/MCE message before any freeze (section 67). The Windows side shows no extra frame-data buffer that Linux lacks beyond the type-13 buffers now sent. Open: attributes/placement of the display-driver-reserved ISP heaps (carve-out vs. GTT) and what the firmware does with real frames.

## 69. What "mode 1" really is (decoded from sensorOV13B.sys), the driver's WPP GUID, and the Windows-side scripts

LOCAL DISASSEMBLY: `scratch/disasm/sensorOV13B.txt` (llvm-objdump of the Windows sensor plug-in; Windows-derived, keep local).
OBSERVED, `get_caps_OV13B` (0x140002d70), selector `mode` (r12d; -1 = use ctx+0x410):
| field | mode 0 | mode 1 |
|---|---|---|
| width x height (+0x1c8/+0x1cc) | 4208 x 3120 | 4208 x 3120 (same) |
| frame rate (+0x1d0) | 0x7530 = 30000 (30 fps) | 0x7530 (same) |
| lane rate (+0x1f0) | 0x460 = 1120 | 0x230 = 560 |
| value at +0xa8 (INFERENCE: line length) | 0x498 = 1176 | 0x920 = 2336 |
| value at +0xa4 (INFERENCE: frame length) | 0xc94 = 3220 | 0xc7c = 3196 |
| +0xa0 / +0x140 | 0x286a / 0x7e17 | 0x5172 / 0xa |
`get_res_fps_OV13B` (0x14000460a): both mode indices return 4208 x 3120 at 0x1e = 30 fps. So mode 1 is NOT a binned/smaller mode (my suggestion "mode 1 = half the data" in the previous answer was wrong in the part about image size). Data-rate check: 4208 x 3120 x 10 bit x 30 fps = 3.94 Gbps; 4 lanes x 560 Mbps = 2.24 Gbps cannot carry it, so mode 1 is a lower-frame-rate (about half) or special variant; nominal 30 fps in the caps may be a static label. Which mode Windows uses for the rear-camera preview: NOT determined (index set by the host in ctx+0x410 / global 0x14000a4e4).
Resolution lists exposed by the plug-in (`get_resolution_list_OV13B`, 0x140004770; tables at 0x140007230 / 0x140007260 / 0x1400072b0):
- A (6): 2560x1440, 2112x1584, 2112x1568, 1920x1080, 1280x720, 640x480  (preview-sized)
- B (9): 4208x3120, 3264x2448, 3840x2160, 2592x1944, 2560x1440, 2112x1568, 1920x1080, 1280x720, 640x480  (stills)
- C (8): 3264x2448, 3840x2160, 2592x1944, 2560x1440, 2112x1568, 1920x1080, 1280x720, 640x480  (video)
So Windows too downscales a full-sensor (4208x3120) read-out to the preview size inside the ISP, as the Linux runs do.
WPP CONTROL GUID OF amdcamera.sys (OBSERVED): the WPP init stores `leaq 0x1400aaa20` into the control block at 0x1400d4658 (`0x14006b3cd`/`0x14006b3db`); the 16 bytes at 0x1400aaa20 = {0FBF5BB9-E551-475A-A9C0-B98F2EA1A4AD}. The driver gates its trace calls on flags bit 0x8 and level >= 4 (`0x2c(cb) & 8`, `0x29(cb) >= 4`), so "all flags, level 5" is right. The driver uses classic WPP over ETW (`WmiTraceMessage`, resolved at run time) plus WPP Recorder (`WppAutoLogStart/Trace`).
SCRIPTS (UNTESTED, PowerShell not available on Linux): `scripts/windows/01-camera-info.ps1` (device/driver inventory + WinRT list of stream formats of the video-capture devices), `02-trace-start.ps1` / `02-trace-stop.ps1` (logman session `amdcam` on that GUID, tracerpt exports, driver hash), `README.md`. Item 3 (MMIO register dump) deliberately not written.
STATE OF THE USER'S REQUEST "test mode 1 first": NOT implemented. Needed for a real mode-1 test: the mode-1 sensor register table (`res_1_config_OV13B`, not yet extracted), the mode-1 capability block for SET_SENSOR_PROP, and a D-PHY sequence for 560 Mbps (the generator `scratch/build_phy_seq.py` is parameterised by rate, input still in `scratch/phy-src/`). Given the corrected meaning of mode 1 (same frame size, probably lower frame rate, unknown whether Windows previews with it), whether it is worth the live-test risk is for the user to decide; Windows trace first is the cheaper way to learn which mode a working preview uses.

## 70. Windows run (user-collected) and front-LED conclusion

FRONT LED (user-confirmed, 2026-10-16): the front-camera LED also lights in Windows while the REAR camera is open. So it is intended behaviour (shared privacy indicator), NOT a Linux bug. The LED investigation (sections on PHY writes, GPIO, pin 85, sensor-control pin registers) is CLOSED; nothing to fix there.

WINDOWS CAPTURE (folder `/mnt/windows/Users/Termis/Documents/camera-bringup-windows/`, read-only use; PowerShell 5.1.26100, Windows 10.0.26200):
- `amdcamera.sys` 11.4.2.1482, SHA256 2376FD79...4263 = the binary already analysed. Sensor driver "Camera RGB Sensor OV13B" 11.4.2.1443. Rear device "ASUS 13M AF webcam", panel=Back; front cameras are USB (ASUS 5M webcam, ASUS IR camera).
- `01-camera-info.ps1` format listing FAILED with `Cannot find an overload for "AsTask" and the argument count: "1"` (PS 5.1 cannot resolve `AsTask(IAsyncAction)` on its own). FIXED in the script (reflection lookup, `scripts/windows/01-camera-info.ps1:62-65`); parse check with pwsh: 0 errors; NOT re-run on Windows (the user would have to).
- Trace: 221,235 events, 0 lost, 136 s. Windows' tracerpt gives no payload (no TMF): each event is only (file GUID, message number = source line). Decoding needs the raw `.etl` payload bytes; a Sonnet agent was started to parse the ETL (output goes to `scratch/windows-trace/`). Result not yet known when this section was written.

## 71. Windows ETL decoded: real start-up sequence of a WORKING rear-camera preview

DECODER (Sonnet agent, files in `scratch/windows-trace/`; I re-checked the validation myself): the `.etl` holds WPP records `u16 size | u16 0x9000 | u16 msg_line | u16 0x00AA | GUID | u64 ts (10 MHz QPC) | u32 tid | u32 pid | payload`. All 221,231 driver events parse; per-GUID counts equal tracerpt's summary (20 GUIDs, all OK). The payload holds the printf arguments: function names, command names, the firmware log text (`[FW][I|W|E][MOD_ID_..],Lnnn,Func:text`) and integer arguments as raw bytes. Command BODIES (sensor prop, stream config, ...) are NOT logged, only ids, stream, seq numbers; SEND_BUFFER IS logged with addresses and sizes. Tools: `parse_etl.py`, `timeline.py`, `dump_payload.py` (raw bytes for events matching a regex), `decode_sendbuf.py`. Outputs: `events.tsv` (one line per event), `timeline-preview-start.txt`, `send-buffer-payloads.txt`.

WINDOWS PREVIEW START (OBSERVED, trace seconds; real start at 17.78 s; preview = 1920x1080 NV12, first frame-done 0.128 s after START_STREAM, then every ~32 ms = 30 fps):
1. SMU power on ISP (`isp_ip_pwr_on`), clocks (`stxh_isp_clk_calculate`), `isp_WE2_pwr_on`, then **`startup_seq_cdphy_rx` (host D-PHY RX start) BEFORE firmware boot**, then `isp_fw_start`/`strix_isp_fw_boot` (ring buffers, enable CCPU, wait ready).
2. Async thread `isp_snr_start`: only I2C READS (sensor probe), no host sensor writes visible; the sensor is NOT started by the host. (The host does no `s_stream`; sensor stream-on must come from the firmware via the device script / START_STREAM.)
3. Global commands: SET_LOG_MODULE_LEVEL, GET_FW_VERSION, ENABLE_POWER_GATING, ENABLE_CLOCK_GATING.
4. Per stream (STREAM1): SEND_BUFFER **MEM_POOL first**, ENABLE_RTA, SET_DEVICE_SCRIPT, SET_TUNING_DATA, SET_SENSOR_PROP, SET_STREAM_CONFIG, SET_M2M_CAL_DATA, **APPLY_TUNING_SCENARIO (SCENARIO_MODE_PREVIEW)**, SET_OUT_CHAN_PROP, **SET_OUT_CHAN_FRAME_RATE_RATIO**, ENABLE_OUT_CHAN, **SET_SCENE_MODE (DEFAULT)**, SEND_BUFFER META_DATA x6, META_INFO x6, **SET_3A_CONFIG**, **ENABLE_PREFETCH** (STREAM_GLOBAL), **SET_FPS_RANGE**, **SET_ITIME_RANGE**, SEND_BUFFER PREVIEW x4, **START_STREAM (after only 4 preview buffers; more are added afterwards, 10 in all)**, SET_ADAPTIVE_RTA.
5. After each frame-done the driver re-sends the META_INFO and META_DATA buffer pair (`ResendMetaInFrameDone`), and the PREVIEW buffer is re-queued when the app returns it.
SEND_BUFFER DETAIL (OBSERVED from raw payload words: addr lo, addr hi, addr2 lo, addr2 hi, 0, 0, size): MEM_POOL addr 0xfd_ccc08000, **size 0x10650000 (= 275,054,592 B = 262.31 MiB; CORRECTED in section 75, the first arithmetic here was wrong)** (same value in both sends in the trace); META_DATA and META_INFO 0x20000 B each (6+6, 128 KiB steps, addresses 0xfd_dd6f8000..0xfd_dd858000); PREVIEW = plane Y at 0xfd_ddeb0000 and plane UV at +0x1fa400 (1920x1080), size 0x2f7600 = 1920*1080*1.5. All GPU VAs are 0xfd_xxxxxxxx (VMID-space prefix 0xfd), buffers contiguous 128 KiB apart. (Static analysis had suggested a 0xC800000 = 200 MiB pool; the RUN-TIME value is 0x10650000. Our Linux runs use 200 MiB. Unknown if the firmware needs the larger one; its size probably depends on the stream configuration.)

WINDOWS FIRMWARE LOG (OBSERVED, log level info): the working firmware ALSO prints at the start `PrepareIspParam: Video/Still channel is not enabled or no image property` and `IspGetFrame: [S:0|CSIS] Frame queue empty!! return last Shot`, later `OnVCFrameEnd: vc[0] wdma not configured when frame end, frame might be corrupted!` and `EnablePrefetch: potential TLSi stream overlap` (once, at the first frame), and then steady `CstatNotifyTask: RtaTask still active at FrameStart` warnings every ~32 ms (= it is receiving frame-starts at 30 fps). So these errors are not what stops our frames. (The Linux error we fixed, "No meta data buffer", does not occur in Windows because META_DATA is sent.)

DIFFERENCE LIST Linux (`scratch/isp4-threshold`, patch 0027) vs Windows. Linux sends: SET_DEVICE_SCRIPT, SET_TUNING_DATA, SET_SENSOR_PROP, (SET_STREAM_CONFIG), SEND_BUFFER, SET_OUT_CHAN_PROP, ENABLE_OUT_CHAN, START_STREAM. NOT sent by Linux: SET_LOG_MODULE_LEVEL, GET_FW_VERSION, ENABLE_POWER_GATING, ENABLE_CLOCK_GATING, ENABLE_RTA, SET_M2M_CAL_DATA, **APPLY_TUNING_SCENARIO**, SET_OUT_CHAN_FRAME_RATE_RATIO, **SET_SCENE_MODE**, **SET_3A_CONFIG**, ENABLE_PREFETCH, **SET_FPS_RANGE**, **SET_ITIME_RANGE**, SET_ADAPTIVE_RTA. Also: Linux starts the sensor from the HOST (s_stream, raw I2C PLL writes, forced PM cycle) before/around START_STREAM, Windows does not; order differences (Windows: pool and RTA first, ENABLE_OUT_CHAN before buffers, START_STREAM after the preview buffers); Windows resends META buffers per frame, Linux does not; pool size 261.8 MiB vs 200 MiB; no raw/MIPI buffer is sent by Windows either (only META_*, MEM_POOL, PREVIEW).
MY RANKING (INFERENCE, not proven): APPLY_TUNING_SCENARIO (selects which tuning set the pipe runs; without it the ISP pipeline may be unconfigured), SET_FPS_RANGE / SET_ITIME_RANGE / SET_SCENE_MODE / SET_3A_CONFIG (exposure/frame timing controller; a firmware with no frame rate range may not start the stream timing), then ENABLE_RTA, then the pool size. Their payload layouts are NOT in the trace; they must come from the static analysis of `amdcamera.sys` (`scratch/disasm/amdcamera.txt`).
NEXT STEP PROPOSAL (needs your OK, no live test): extract the payload structs of APPLY_TUNING_SCENARIO, SET_FPS_RANGE, SET_ITIME_RANGE, SET_SCENE_MODE, SET_OUT_CHAN_FRAME_RATE_RATIO from the Windows binary (callers named in the trace: `isp_set_scenario_mode`, `enable_dynamic_frame_rate_imp`, `isp_setup_ae_scene_mode`, `isp_setup_output`), then add them to the Linux sequence as a patch for review.

## 72. Payload layouts of the Windows-only commands, and patch 0028

METHOD: the trace names the command and the function that sends it; the function's code was found by locating its name string in `amdcamera.sys` (`scratch/disasm/strva.py`), then the code referencing it (`xref.py`), then reading the arguments loaded before `call 0x140028bb0` (= the common "send command" helper: rcx=device, edx=cmd id, r8d=firmware stream id, r9d=1 direct / 0 indirect, stack = payload pointer and size). Enum values were read from the to-string functions (`readva.py`). Numbers below that the trace itself logged are marked TRACE.
COMMAND IDS (TRACE, `cmd_ids.py`): GET_FW_VERSION 0x01010001, ENABLE_CLOCK_GATING 0x01020006, ENABLE_POWER_GATING 0x01020007, SET_LOG_MODULE_LEVEL 0x01020009, ENABLE_PREFETCH 0x01030003, SET_STREAM_CONFIG 0x02010001, SET_OUT_CHAN_PROP 0x02010003, SET_OUT_CHAN_FRAME_RATE_RATIO 0x02010004, ENABLE_OUT_CHAN 0x02010005, CAPTURE_FRAME 0x02010006, START_STREAM 0x02010007, STOP_STREAM 0x02010008, SET_ADAPTIVE_RTA 0x0201000c, SET_3A_CONFIG 0x02020001, SET_SCENE_MODE 0x02020007, SET_FPS_RANGE 0x02020008, SET_ITIME_RANGE 0x02020009, SEND_BUFFER 0x02040001, SET_TUNING_DATA 0x02050008, APPLY_TUNING_SCENARIO 0x02050009, SET_SENSOR_PROP 0x02090001, SET_DEVICE_SCRIPT 0x02090002, SET_M2M_CAL_DATA 0x02090005, ENABLE_RTA 0x02090008. (Linux names for the first six already match.)
PAYLOADS (OBSERVED in the disassembly unless marked):
- APPLY_TUNING_SCENARIO (`isp_set_scenario_mode`, 0x14001965c): 4 bytes `{u32 scenario}`; enum 0 PREVIEW, 1 VIDEO_DOLHDR, 2 VIDEO, 3 VIDEO_WINHELLO, 4 STILL, 5 STILL_DOLHDR, 6 STILL_BINNING, 7 VIDEO_SHDR, 8 STILL_SHDR (valid 0..8). Preview start sends 0.
- SET_SCENE_MODE (`isp_setup_ae_scene_mode`, 0x14001b7b8): 4 bytes `{u32 scene}`; -1 INVALID, 0 DEFAULT, 1 DISABLED, 2 PORTRAIT, ... Preview start: DEFAULT = 0.
- SET_FPS_RANGE / SET_ITIME_RANGE (`enable_dynamic_frame_rate_imp`, 0x140033970): 8 bytes each `{min,max}`. Values TRACE (the function logs them): FPS `{15000, 30000}` (units: frames/s x 1000), ITIME `{40, 66666}` (units: microseconds; 66666 = 1e6/15).
- SET_OUT_CHAN_FRAME_RATE_RATIO (`isp_setup_output`, 0x14001b9d8): 8 bytes `{u32 channel, u32 ratio}`; TRACE: channel "prev" (= 0, same as Linux ISP4FW_ISP_PIPE_OUT_CH_PREVIEW), ratio 1.
- ENABLE_RTA (0x140027100 area): 4 bytes `{u32 enable}`; trace says "Enable" -> 1.
- ENABLE_PREFETCH (`isp_kickoff_stream`, 0x140016d47): GLOBAL command (stream field 0), 12 bytes `{a,b,c}`, all 1 if device flag +0x1732 is set (flag not found being written, set in a bulk copy), else all 0. INFERENCE: {1,1,1}, because the Windows firmware log shows MMHUB prefetch programming ("MMhubPrefetchSingleStream: Overlap Detected ... to prevent hang").
- SET_3A_CONFIG (`isp_setup_3a`, 0x14001b080): 92 bytes (0x5c), sent INDIRECT (payload in a separate command-payload buffer, `isp_fw_get_nxt_indirect_cmd_pl`), flags word at +0 selects which fields are valid; at kickoff the default is flags = 0x23 (|0x800 depending on two device caps), +4 = 2 (AE auto), +0x1c = 1 (AWB auto), +8 = a stream value I could not resolve. Too big for Linux's 48-byte command slot.
- ENABLE_POWER_GATING (12 bytes) / ENABLE_CLOCK_GATING (16 bytes): global, power saving, arguments not resolved. SET_ADAPTIVE_RTA: built from device fields +0x1808..+0x1818, not resolved. SET_M2M_CAL_DATA: sensor calibration data, not resolved. Not needed to get frames in my judgement (INFERENCE).
PATCH 0028 (`scratch/isp4-threshold/0028-isp4-windows-cmds.patch`, on top of 0027; base copy `base-0027/`): module parameter `win_cmds` (0 = nothing changes). Bits: 0x01 ENABLE_RTA (after the pool), 0x02 APPLY_TUNING_SCENARIO (after SET_STREAM_CONFIG), 0x04 SET_OUT_CHAN_FRAME_RATE_RATIO (between PROP and ENABLE), 0x08 SET_SCENE_MODE (after ENABLE_OUT_CHAN), 0x10 SET_FPS_RANGE and 0x20 SET_ITIME_RANGE (after the META buffers). Each send logs `EXP-WINCMD: <name> (<id>) ... ret N`; failures never abort the bring-up; the firmware's verdict shows up in the existing `EXP-RESP:` line (status 0 ok / 1 fail / 2 skipped). Built OK against the 7.2.0-1.7 headers (`./scripts/build-isp4-threshold.sh`), `modinfo` lists `win_cmds`. NOT loaded or run.
SAFE FIRST TEST PROPOSAL (needs your go, per my rule no live sensor start without it): the no-sensor baseline `--replay --tuning-file ... --pool-mb 200 --meta-data-bufs 6 --win-cmds 0x3f --seconds 6` (no `--start-sensor`, no PHY, no PLL): only checks that the firmware ANSWERS each new command with status 0 (the EXP-RESP lines). Then, if clean, the data run is a separate decision.

## 73. First run of patch 0028 (no sensor): `scratch/isp4-threshold/results/20261016-022801-*`

COMMAND: baseline (no sensor, no PHY, no PLL) with `--win-cmds 0x3f` (user-launched). Result line: queued=1 failed=0 frames=0 (frames are not expected without the sensor).
OBSERVED:
- Five of the six new commands were sent (`EXP-WINCMD ... ret 0`) and the firmware answered each with status 0, fw_error_code 0: ENABLE_RTA (0x02090008), APPLY_TUNING_SCENARIO (0x02050009; firmware log: `HandleCmdApplyTuningScenario: Stream:1 apply tuning scenario to mode:0`, then `IspHardwareApplySetfile: apply_setfile: hw_map (0x4011)`), SET_OUT_CHAN_FRAME_RATE_RATIO (0x02010004), SET_FPS_RANGE (0x02020008), SET_ITIME_RANGE (0x02020009). So these payload layouts are accepted (acceptance does not prove the values are what the firmware wants).
- SET_SCENE_MODE (0x02020007) with payload {0} FAILED: status 1, fw_error_code 0x0018, firmware log `SetSceneMode: Invalid SceneMode 0` / `HandleCmdSetSceneMode: stream:1 set Scene mode failed`. The Windows host sends the same value 0 (the Windows driver's to-string maps 0 to SCENE_MODE_DEFAULT and logs it after the send), and no scene-mode error shows in the Windows firmware log (errors are logged there). So either the firmware rejects 0 only in our state (e.g. a scene table that Windows has loaded through something we do not send: M2M calibration data, or 3A config) or Windows' value is not 0 and my reading of the enum is off. UNRESOLVED; it did not break anything else.
- Apart from that one error the firmware warnings/errors are IDENTICAL to the earlier safe baseline `20261016-003750` (same list, same counts): the new commands change nothing else in the no-sensor case. The known stop-time messages (ENABLE_OUT_CHAN / STOP_STREAM response timeouts, MMHUB "Invalid input param", "Failed in waiting for V_VALID") are in both.
- `UpdateFrameInterval: set expected frame interval to 655270` appears in both Linux runs, unchanged by SET_FPS_RANGE. INFERENCE: this value comes from the replayed SET_SENSOR_PROP (about 65.5 ms if the unit is 0.1 us, i.e. roughly 15 fps), while the Windows firmware log shows a 33333 us frame time (30 fps): `getXTileDeepSleepDuration: ... > Frame=33333`. Worth checking whether the sensor properties we replay describe the same mode and frame length as the ones Windows sends for the preview (we do not have the Windows SET_SENSOR_PROP body, only its code path).
NEXT (not done): (a) decide about a data run with `--win-cmds 0x37` (all but the failing scene mode) together with the other data-run options, which is the risky step and needs the user's explicit go; (b) investigate scene-mode and the frame interval statically.

## 74. Static investigation: scene mode value, frame interval, and the missing M2M calibration

A) FRAME INTERVAL (resolved, benign). Firmware log of both Linux runs (also the run WITHOUT win_cmds): `SetITimeRange: max_itime 655270 exceed the fps_range limitation, force to 33333` (during SET_STREAM_CONFIG) and then `UpdateFrameInterval: set expected frame interval to 655270`. So 655270 is the MAX INTEGRATION TIME (microseconds) taken from the replayed SET_SENSOR_PROP, not a frame time; the firmware clamps it to its default fps range (33333 us = 30 fps), the same frame time the Windows firmware reports (`Frame=33333`). My earlier guess in §73 (about 15 fps) was WRONG; nothing to fix there. (The line is present with and without win_cmds, i.e. SET_FPS_RANGE/SET_ITIME_RANGE are accepted but change no logged value at info level.)
B) SCENE MODE (value checked, cause unresolved). `set_scene_mode_imp` (0x1400427a0, called from `isp_kickoff_stream` with mode 0) translates the host value through a 12-entry table at 0x1400c0640 (pairs host -> firmware): 0->0, 1->0x11, 2->4, 3->0xe, 4->0xa, 5->6, 6->9, 7->0xb, 8->0x10, 9->5, 10->7, 11->1; unmapped = -1. `isp_setup_ae_scene_mode` (0x14001b7b8) then sends the TRANSLATED value as a 4-byte payload. Windows kickoff uses host 0, so Windows sends firmware value 0 too (and logs "SCENE_MODE_DEFAULT"); our payload {0} is identical. Windows' firmware logged no scene-mode error in its trace, ours says `SetSceneMode: Invalid SceneMode 0` (ISP_PLATFORM L995). So the payload is right and the difference must be firmware STATE. Steps Windows performs before SET_SCENE_MODE that Linux does not: SET_M2M_CAL_DATA and the global commands (SET_LOG_MODULE_LEVEL, GET_FW_VERSION, ENABLE_POWER_GATING, ENABLE_CLOCK_GATING). INFERENCE (not tested): the scene table needs the module calibration, i.e. SET_M2M_CAL_DATA.
C) SET_M2M_CAL_DATA (what it would take). Sender `0x140018fbc` (`isp_set_m2m_calib_2_fw`): asks the sensor plug-in (`get_m2m_data_strix_OV13B`, function 0x1400039c0 in sensorOV13B.sys, plug-in table slot +0xe8) to fill a 0x1b8c-byte structure, copies parts of it into a ~0x2180-byte command payload (sent INDIRECT, `r9=0`), flags selected by bytes 0x22/0x23/0x24 of the structure. In the plug-in the data is READ FROM THE CAMERA MODULE (calls through an ISP-driver callback at 0x140007088 with block sizes 0x20/0x28, each block verified with a checksum, `Driver` registry flag gating it): i.e. module OTP/EEPROM calibration (lens shading, AWB golden sample, ...), not a constant table. Linux would have to read the same memory over the sensor's I2C bus (address/offsets not yet extracted) and reproduce the payload format, and it needs the indirect-command mechanism (payload > 48 bytes). That is a sizeable job; worth it only if the scene mode / calibration turns out to gate frame output.
D) Other observations from the Linux firmware log: `HandleCmdSendBuffer: Push 'Unknown buffer type'` is the MEM_POOL (type 15) buffer, also expected on Windows; `HandleCmdSetStreamCfg: assign pipeline 'Mipi0CsisCstat0=>Lme=>Isp' to stream 1 ... using RGB sensor ... RtaFramesPerProc(1)`.
CONCLUSION: nothing found here that explains the lack of frames. The remaining known differences are: host-started sensor vs firmware-started (Windows), M2M calibration/global commands, ENABLE_PREFETCH/3A (indirect) commands, pool size 262 MiB vs 200 MiB, the META buffer resend per frame, and the data path itself.

## 75. Freeze #4 (no logs survived) and the memory-pool size formula

FREEZE #4: user-authorised data run, command line quoted before launch: `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 200 --meta-data-bufs 6 --win-cmds 0x37 --start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --seconds 8`. The machine froze right after the launch (user report). WHAT SURVIVED: result files `results/20261016-023540-console.txt` and `-min4-var0.nv12`, both 0 bytes. The previous boot's journal (`journalctl -b -1`) has 2999 kernel lines, but the last kernel line is from the earlier no-sensor run (02:28:07); the last journal entry of any kind is a user-space line at 02:35:26 (the clock in that boot jumped, so absolute times need care). No pstore entries visible (directory listing was permission denied). So the failure of this run is NOT observable from logs: journald keeps recent entries only in memory pages and loses them on an instant freeze. Run with the same family of options froze 3 of 3 times (freeze 1, 3, 4). To see anything, the log has to be written synchronously during the run (idea, not built: a logger that follows `journalctl -k -f` and does an fsync per line into the results folder) or sent over the network (netconsole), which needs another machine.
NEW STATIC FACTS ABOUT THE SENSOR START (Windows, from the plug-in `sensorOV13B.sys`):
- `stream_on_OV13B` (0x1400056b0) and `stop_OV13B` (0x140005650) are EMPTY stubs (log + return). `start_OV13B` (0x140005550) does the work: chip check (reads), then `res_0_config` (mode 0, `0x140005144`) or `res_1_config` (`0x1400052d8`): writes the 131-entry register table (`0x140008030`, 4-byte entries {u16 reg, u16 value}), optionally 2 more entries (table `0x140008458`, if a driver-config flag byte at `0x14000a57e` is set), and then ONE final entry at `0x14000823c` = {reg 0x0100, value 1} = STREAM ON, all through the ISP-driver I2C write callback (plug-in slot `0x140007088`). So the device-script ("asm_OV13B.asm", only gain/exposure/lens functions) is NOT used for init or stream-on.
- Windows trace: the host writes are not logged (`isp_i2c_write` never appears); the trace shows 3 chip-ID reads at 17.7914-17.7920 and `isp_snr_start` returning at 17.8092, a 17 ms gap that fits ~130 unlogged I2C writes. START_STREAM is queued at 17.8099. So Windows' sensor goes to stream-on about 0.7 ms before START_STREAM (the two run in different threads), after PHY start (17.7864) and after the SET_* commands. In Linux: `--start-sensor 2` = before START_STREAM, `1` = after; neither matches Windows exactly (Windows: concurrent, ~simultaneous).
MEMORY POOL SIZE (the important new finding). The Windows pool is not a constant: `allocate_fw_mempool_imp` (0x1400320f0) computes it from the sensor pixel count W (third argument) and a flag (fifth argument), 32-bit arithmetic: `A=(2W+0x7ffe)&0xffff8000; h=W>>1; k=5 (+5 if flag); B=((h+0x7fff)&0xffff8000)+0x798000; C=(6W+0x1fffc)&0xfffe0000; D=(h+0x1fffc)&0xfffe0000; size = k*A + 4*B + C + D` (script `scratch/disasm/mempool_size.py`). OBSERVED: with W = 4208 x 3120 = 13,128,960 and flag 0 this gives EXACTLY 0x10650000, the size Windows logged for the MEM_POOL buffer (trace section 71). So the firmware needs a pool of 275,054,592 bytes = **262.31 MiB** for the 13.1 MP mode; the `0xC800000` (200 MiB) found earlier is only the fallback in the lazy-allocation path (`IspSetupFwdMemPool`), used when no pool was allocated before. For the upstream 5 MP OV05C10 (2592x1944) the same formula gives 119.5 MiB, consistent with upstream's fixed 100 MiB being "about enough" for a smaller sensor.
  - Every Linux data run so far used 200 MiB (or the stock 100 MiB): about 62 MiB (24%) LESS than the firmware computes it needs. INFERENCE (not proven, now the leading hypothesis): the raw frame buffers are carved from this pool; with the pool too small the firmware's allocation for the raw write DMA fails or overruns, which would fit "wdma not configured", `INTR_LATENCY_BUFFER_LEAKING`, `CUR_PTR=0`, and an instant freeze when real data arrives. In the no-sensor baselines nothing is written, so nothing breaks.
  - Not known: what the flag is (flag 0 reproduced the Windows value); and whether the firmware checks the size against what it needs and reports the failure (no such message seen so far).
NEXT STEP: run with `--pool-mb 263` (smallest whole MiB at or above 262.31). First a no-sensor baseline to see that the allocation and SEND_BUFFER are accepted (safe), then, only with the user's explicit go, a data run with the same options as freeze #4 but the larger pool.

## 76. No-sensor baseline with the Windows-sized pool (`--pool-mb 263`): `results/20261016-024525-*`

Command (user-authorised, quoted before launch): `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x3f --seconds 6`. The machine stayed up; summary line queued=1 failed=0 frames=0 (no sensor, none expected).
OBSERVED:
- Linux allocated and sent a pool of 275,775,488 bytes (263 MiB): `send fw mem pool 0x7fff03830000(275775488) suc`. The firmware accepted it and logged `BUF_MGR SetMemPool: MEM|memPool:addr=0x7FFF03830000,size=275775488,age=1`. The MEM_POOL SEND_BUFFER got status 0 (no failed reply on it).
- Firmware warnings and errors are IDENTICAL (same list, same counts) to the baseline with the 200 MiB pool (`20261016-022801`), including the known `SetSceneMode: Invalid SceneMode 0`. The two stop-time replies with status 1 / error 0x1e (ENABLE_OUT_CHAN, STOP_STREAM) are in both runs. So the larger pool changes nothing visible without data; as expected, the difference could only show once raw frames are written.
- NOT visible: any firmware message that says whether the pool is big enough. So this run cannot confirm or refute the pool-size hypothesis of section 75; only a data run can.
SIDE OBSERVATION (no conclusion): the pool address seen by the firmware is `0x7FFF03830000` on Linux (47-bit, the amdgpu GART aperture) while the Windows pool and buffers sit at `0xfd_xxxxxxxx` (below 2^40). The same firmware works with the upstream driver on other laptops using Linux addresses, so this is probably fine, but I have not checked the ISP's address width; note it in case the pool-size change does not help.
NEXT (needs the user's explicit go and the exact command line): the freeze-#4 data run with only the pool changed (`--pool-mb 263`), preferably with a synchronous kernel-log logger running (not built yet; the user has not answered whether to build it).

## 77. Synchronous kernel-log logger (`scripts/log-kernel-sync.py`)

PURPOSE: after freeze #4 nothing of the run was on disk (section 75). The logger follows `sudo -n journalctl -k -f -n 0 -o short-precise --no-pager` (allowed by the temporary sudoers rule; `/dev/kmsg` cannot be read directly because `kernel.dmesg_restrict = 1`) and does `os.write` + `os.fdatasync` for EVERY line, plus a `# alive <time> lines=N` heartbeat line once a second (also synced). Output defaults to `scratch/isp4-threshold/results/kernel-sync-<stamp>.log`, must stay inside the project, append-only. Usage: start it in a second terminal before a risky run, Ctrl-C after.
TESTED (6 s self-test, `results/kernel-sync-selftest.log`): sudo accepted, 5 heartbeats written one per second with fdatasync, clean stop line, no leftover journalctl process. NOT yet tested: capture of real kernel messages (none occurred during the self-test); the first real use (any module load) will show it.
LIMITS: journald sits between the kernel and the logger (normally milliseconds; if the machine dies inside that window the last messages are still lost); `fdatasync` returns when the SSD reports the data durable, so a freeze that corrupts the file system journal could still lose the tail; the heartbeat proves when the logger last ran, not what the kernel printed afterwards.

## 78. First data run with the Windows-sized pool: NO freeze, DMA starts, still 0 frames (`results/20261016-024957-*`, `kernel-sync-20261016-024934.log`)

COMMAND (user-authorised; the user ran it, with `scripts/log-kernel-sync.py` running in a second terminal): `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x37 --start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --seconds 8`. Identical to freeze #4 except `--pool-mb 263` instead of 200. RESULT: machine did NOT freeze; summary `frames=0 bytes=0`. Three earlier runs of this option family froze the machine (freeze 1, 3, 4); one run is not statistics, but it is the first with the Windows pool size.
LOGGER: `kernel-sync-20261016-024934.log` has 5205 kernel lines and heartbeats until the user stopped it, so capture of real kernel messages works (the open point of section 77 is closed). It was not needed this time.
OBSERVED (firmware clock in us from its log):
- All five `win_cmds` commands sent and accepted (no failed `EXP-RESP`). Sensor sequence as before: PM cycle, PHY ready (lane stop-state 0x3f00), START_STREAM queued (815.026 s), `s_stream(1)` -> 0, Windows PLL values applied (readback 0x0303=01 0x0305=46 0x0325=55), burst limit armed.
- Lanes: stop-state 0x2000 at +100 ms (data lanes 0-4 active = the sensor transmits), back to 0x3f00 after the standby at +300 ms (0x0100=0 written, `burst limit ... -> 0`).
- FIRST TIME the firmware logs frame events for this sensor: `FrameStart HWID:CSIS` (815.028), `FrameStart HWID:MIPI0 S:0 F:0` (815.129, about 100 ms after START_STREAM), `FrameStart HWID:CSTAT0` (815.129), and `IspHardwareShot ... Done` for CSIS/MIPI0/CSTAT0. (In the Windows trace the first frame-done came 0.128 s after START_STREAM, i.e. the same delay.)
- Then, 0.6 ms after the MIPI0 frame start: `mipi wdma error: INTR_LATENCY_BUFFER_LEAKING` with `ISP_MIPI_MI_WR_DBG_CUR_PTR=0x00003820`, and CSTAT0 `INTR_LIC_OVERFLOW 0x1000000` (`DBG_CIN in 33376x95 ... err 0x01`). After that `CUR_PTR=0x00000000` is reported repeatedly (2172 times) together with 2152 more wdma errors until 818.94 s, i.e. for 3.8 s, although the sensor stopped sending at +0.3 s: it is a firmware-side error loop, not a data flood. Frame done never came, no frame was queued to the host.
- COMPARISON with the four earlier runs that logged this error (pool 200 MiB, runs 20261015-220112, -220551, -231857, -231925): their FIRST `CUR_PTR` was 0x00000000 in all four (13, 13, 13 and 2358 errors). This run's first value, 0x3820 (14,368 bytes), means the MIPI write DMA moved some data before failing. WEAK evidence (one run) that the larger pool changed the behaviour of the raw write path; it did not fix it.
INFERENCE (not proven): the DMA now has a valid destination but the write path cannot keep up or stalls: `INTR_LATENCY_BUFFER_LEAKING` is a write-latency overrun. Candidates, none tested:
  (a) MMHUB prefetch/translation: Windows sends the global command ENABLE_PREFETCH (0x01030003, payload most likely {1,1,1}, section 72) before START_STREAM; Linux never does. Without it every DMA page needs an on-demand page-table walk; Linux buffers are scattered 4 KiB GTT pages, so latency is high. The firmware even logs a prefetch-related overlap warning on Windows (second stream, 31.7 s) "to prevent hang".
  (b) Memory placement: Windows allocates the pool from a heap the display driver reserved for the ISP (addresses 0xfd_xxxxxxxx, probably physically contiguous / large pages); Linux uses a pinned GTT BO at 0x7FFF_xxxxxxxx.
  (c) Sensor timing: CSTAT saw an input of width 33376 (not 4208) for 95 lines before overflowing, which hints the pixel stream the ISP receives does not match the configured mode (e.g. wrong link/pixel timing, or the firmware counting something else). Not understood.
  (d) The remaining Windows-only items (M2M calibration, global commands, scene mode state).
NEXT (static or safe first): (a) is the cheapest to test and the best-supported: route global commands in `isp4_interface.c` (cmd type 0x01 -> global ring, `cmd_stream_id = -1`), send ENABLE_PREFETCH {1,1,1}; baseline test first (check the firmware accepts and logs MMHUB prefetch setup), then the data run with the logger.

## 79. Patch 0029: global-command routing and ENABLE_PREFETCH

WHAT: `scratch/isp4-threshold/0029-isp4-global-prefetch.patch` (on top of 0028; base copies of both files in `base-0028/`).
1. `isp4_interface.c`: `isp4if_get_fw_stream()` returned stream 1 for every command. Now command ids with bits 31:24 == 0x01 (Windows "STREAM_GLOBAL" commands) go to `ISP4IF_STREAM_ID_GLOBAL` (ring `CMD_RB_GBL0`, firmware stream id -1, the case already present in `isp4if_send_fw_cmd`). All commands used so far are type 0x02, so existing behaviour is unchanged. The global ring, its registers and the response thread for index 0 already existed in the driver (log shows `CMD_RB_GBL0 rd 0 wr 0 | ring size 2560`), no new infrastructure.
2. `isp4_subdev.c`: `win_cmds` bit 0x40 sends `ENABLE_PREFETCH` (0x01030003) with payload `{1,1,1}` after the META buffers and before SET_FPS_RANGE (Windows order: META buffers, 3A, PREFETCH, FPS, ITIME, preview buffers).
STATUS: built (`./scripts/build-isp4-threshold.sh`, parameter text lists 0x40); NOT loaded or run. Open risks, all unknown until a baseline run: (a) the firmware may not read the global ring in this state (then no reply, harmless), (b) it may reject `{1,1,1}` (Windows' real payload is `{1,1,1}` only if device flag +0x1732 was set, inferred from the MMHUB prefetch activity on Windows), (c) a reply for a global command is read by the global response thread, which has never carried a reply before.
HOW TO TEST (user decides): safe baseline first, no sensor: `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x77 --seconds 6` (0x77 = 0x37 + 0x40; scene mode 0x08 left out because it is known to be rejected). Look for: `EXP-WINCMD: ENABLE_PREFETCH ... ret 0`; an `EXP-RESP` for 0x01030003 with status 0; firmware lines mentioning MMHUB/prefetch; no new errors compared with `results/20261016-024525-*`. Only then the data run (with `scripts/log-kernel-sync.py` running).

## 80. Baseline with patch 0029 (`--win-cmds 0x77`): the global command works, but the firmware HANGS in MMHUB prefetch setup (`results/20261016-025546-*`)

COMMAND (user-authorised, quoted before launch): `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x77 --seconds 6` (no sensor, PHY or PLL). The machine stayed up; summary `queued=1 failed=0 fw-reply=0 frames=0`.
GOOD (OBSERVED):
- The global routing works: `ENABLE_PREFETCH (0x01030003) 3 payload words 01..01..01.. -> ret 0`, the command went through `CMD_RB_GBL0` (ring pointers rd 0 wr 64 after it was queued, later rd 64 wr 64) and the firmware answered on the GLOBAL response ring: `EXP-RESP: seq 24 cmd 0x01030003 status 0 ... fw_error_code 0x0000`. First time the global ring and its response thread carried traffic. The other five win_cmds commands were accepted as before.
- The firmware understood the payload: `CMD_DISPATCH GlbCmdConfigMmhubPrefetch: RTPipe MMHub Prefetch:enable`, `SoftRTPipe MMHub Prefetch:enable`, `Add YUV GAP for 32K alignment? yes`. So the three payload words are three switches (very likely RT pipe prefetch, soft-RT pipe prefetch, YUV gap) and `{1,1,1}` turned all on.
BAD (OBSERVED):
- START_STREAM is never acknowledged. Stream-1 command ring at the end: `rd 1920 wr 2240` (firmware consumed everything up to offset 1920, which is where START_STREAM sits, and nothing after it; in the previous baseline `rd 2304 = wr 2304`, all consumed, `fw-reply=1`). Response ring `RES_RB_STR1 rd = wr = 1920`.
- Firmware log: after `StartTimer: Start stream:1 cmdId=0x02010007` it builds the BYRP/RGBP/MCFP chains and the CSTAT config (`IspHwCstatInitConfig ... OTF_IN size 4208x3120`) and its LAST line is `MMHUB MMhubPrefetchSingleStream: Client Id:3 pChansBuffer =0x62da9780, chanIdx =0` at 1164.1975 s. The driver drained the log ring afterwards (read pointer = write pointer = 41686): the firmware wrote NOTHING after that line, in particular none of the usual "frame done timeout", error or reset messages of the previous baseline. CONCLUSION: the firmware is stuck inside `MMhubPrefetchSingleStream` (start of the first client's prefetch configuration) during START_STREAM handling. (The ENABLE_OUT_CHAN and STOP_STREAM timeouts at the end are consequences.)
- The machine and the module reload were unaffected.
INTERPRETATION (INFERENCE): enabling prefetch the way Windows does makes the firmware program the memory hub (MMHUB) for the ISP clients, and that access never completes on Linux, while Windows (same firmware, same command) works. A hang in a register access to an unready block would match the earlier clues that the MMHUB side is touched by the display driver on Windows (stutter / power-gating handling, section 60-62 in these notes: Windows only does nothing for modes above 12 MP; the Linux amdgpu may leave the MMHUB in a state where the prefetch registers do not respond, or the ISP's VMID/translation setup that the Windows KMD does is missing). It also explains why prefetch could not be the cause of the earlier DMA errors on its own: without it the firmware runs on.
CONSEQUENCE: `win_cmds` bit 0x40 (`{1,1,1}`) must NOT be used together with START_STREAM until the hang is understood; it is a firmware-level stall (safe for the machine here, but no frames can follow).
NEXT, cheap and safe (baseline runs only): find which of the three switches provokes the hang with a small patch 0030: a module parameter `prefetch_flags` (3 bits, replacing the fixed `{1,1,1}`), then baseline runs for `{0,0,0}` (is the command itself harmless?), `{0,0,1}` (only the YUV gap), `{1,0,0}`, `{0,1,0}`. If only the gap switch is harmless it may still matter for the output buffers. Static work in parallel: how Windows' display side prepares MMHUB for the ISP (KMD interface notes in `scratch/disasm/kmd-*.txt`).

## 81. Patch 0030: `prefetch_flags` to isolate the hanging prefetch switch

`scratch/isp4-threshold/0030-isp4-prefetch-flags.patch` (on top of 0029; base copy `base-0029/isp4_subdev.c`): module parameter `prefetch_flags` (default 7 = `{1,1,1}`, the 0029 behaviour); bit N -> ENABLE_PREFETCH payload word N. Test script option `--prefetch-flags N`. Built; NOT run.
PLAN (all no-sensor baselines, like section 80, each needs the user's go): `--win-cmds 0x77 --prefetch-flags 0` first (`{0,0,0}`: is the command itself harmless? firmware should log "disable"), then 4 (`{0,0,1}`), 1 (`{1,0,0}`), 2 (`{0,1,0}`). For each: the three `GlbCmdConfigMmhubPrefetch` lines (which word maps to which switch), whether START_STREAM is acknowledged (`fw-reply=1`, stream-1 ring rd = wr at the end), and the last firmware line.

## 82. Prefetch switch sweep (patch 0030, 4 no-sensor baselines run by the user): no single switch hangs; RT-pipe prefetch alone works

Runs (user-launched; `--pool-mb 263 --meta-data-bufs 6 --win-cmds 0x77 --seconds 6` plus `--prefetch-flags N`): `results/20261016-030613` (0), `-030642` (4), `-030704` (1), `-030724` (2). The machine stayed up in all four.
PAYLOAD MAPPING (OBSERVED from the firmware's `GlbCmdConfigMmhubPrefetch` lines): word 0 = `RTPipe MMHub Prefetch`, word 1 = `SoftRTPipe MMHub Prefetch`, word 2 = `Add YUV GAP for 32K alignment`.
| flags | payload | START_STREAM ack | stream-1 ring at stop | `MMhubPrefetchSingleStream` | difference in E/W list vs flags 0 |
|---|---|---|---|---|---|
| 0 | {0,0,0} | yes | rd = wr = 2240 | not called | (reference) |
| 4 | {0,0,1} | yes | rd = wr = 2240 | not called | none |
| 1 | {1,0,0} | yes | rd = wr = 2240 | 3 calls: client 3 chan 0 and 1, client 0 chan 0 | the known stop-time error `MMhubPrefetchDisableStreams: Invalid input param` is GONE (stop now logs "Disable prefetch for client id:0 chanNum 1" and "client id:3 chanNum 2") |
| 2 | {0,1,0} | yes | rd = wr = 2240 | not called | none |
| 7 (section 80) | {1,1,1} | NO, hung | rd 1920 / wr 2240 | hung at the first call (client 3 chan 0) | firmware silent after that |
CONCLUSIONS:
- The `{1,1,1}` hang is not caused by any single switch. RT-pipe prefetch alone sets up exactly the client that hung with `{1,1,1}` (client 3 chan 0) and continues. So either a COMBINATION hangs (RT + soft-RT, or RT + YUV gap), or the hang in section 80 was not deterministic (only one run). Not yet distinguished.
- The soft-RT switch and the YUV-gap switch have no visible effect without a sensor (no client set up). The RT-pipe switch is the one that concerns the MIPI raw write DMA (real-time pipe), i.e. the path that fails with `INTR_LATENCY_BUFFER_LEAKING` in the data run (section 78). That makes `--prefetch-flags 1` the candidate for the next data run.
- INFERENCE: the stop-time error "Invalid input param" that every earlier run showed came from the firmware trying to disable prefetch that was never set up; with RT prefetch enabled the stop is clean, which suggests the firmware expects prefetch to be on (as on Windows).
NEXT OPTIONS: (a) two more baselines to explain the hang: `--prefetch-flags 3` ({1,1,0}) and `5` ({1,0,1}), plus `7` again to see whether it is reproducible; (b) the data run of section 78 with `--win-cmds 0x77 --prefetch-flags 1` (and the logger), to see whether RT prefetch changes the DMA error.

## 83. FIRST FRAMES: the ISP produces NV12 preview frames with RT-pipe prefetch; then a race in start_streaming oopses (`results/20261016-031125-*`, `kernel-sync-20261016-031116.log`)

COMMAND (user-launched, logger running): `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x77 --prefetch-flags 1 --start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --seconds 8`. Only change vs section 78: `--win-cmds 0x77 --prefetch-flags 1` (= ENABLE_PREFETCH {1,0,0}, RT-pipe prefetch on).
OBSERVED (synchronous log; the machine stayed responsive, heartbeats continued):
- The full pipeline ran for the first time: per frame `FrameDone` for MIPI0, CSTAT0, CSIS, LME, BYRP, RGBP, MCFP, YUVP, MCSC, then `HandleFrameDoneEvt: [stream 1] normal frame N done will trigger a frame done building`, then the driver's `call vb2_buffer_done(size=3110400)` (= 1920x1080x1.5, a full NV12 preview buffer). 8 frames processed by the firmware (frame 0 at 03:11:27.428, frame 7 at 03:11:27.657, ~33 ms apart = 30 fps); 4 buffers returned to vb2 (03:11:27.428, .460, .496, .523), i.e. every buffer the host had queued; then `LoadFrameMcscDmaBuffers: Preview buffer is not available` x8 (no re-queued buffers).
- ZERO `INTR_LATENCY_BUFFER_LEAKING` (section 78: 2152) and only one `CUR_PTR` report. CONCLUSION: the raw write DMA failure was caused by missing MMHUB RT-pipe prefetch (together with the 263 MiB pool, which was already present in section 78). Windows enables it with the global ENABLE_PREFETCH command; we did not.
- Remaining firmware errors (not fatal): the device script's runtime functions all fail (`SvmSetINc: Set iNc addr mode not 8bit nor 16bit` x40, `SvmRun: set INC arg fail`, `Run SensorSetItime/SensorSetAGain/SensorGroupHold/... fail`, `ApplyExpoGainNormal: ... error`) = my assembled SET_DEVICE_SCRIPT has an encoding error in an INC/address-mode operand, so auto-exposure cannot write the sensor (frames will have the sensor's default exposure/gain); `LoadFrameMetaData: No meta data buffer is available` x6 (Windows re-sends META_DATA/META_INFO after every frame, `ResendMetaInFrameDone`; we do not); one `InForm V Size Error` + `Received frame error event from the sub IP MIPI` (probably the frame cut by the burst-limit standby at +300 ms).
THE OOPS (03:11:28.366, ~1.1 s after START_STREAM, in v4l2-ctl's VIDIOC_STREAMON): `general protection fault ... RIP isp4if_alloc_buffer_node+0x37`, call trace `isp4sd_ioc_send_img_buf <- isp4vid_qops_start_streaming <- vb2_start_streaming <- vb2_core_streamon`, RBX/RSI = 0xdead0000000000b8 (= LIST_POISON1 0xdead...100 minus the list offset). CAUSE (from the code, `isp4_video.c:570`): `start_streaming` walks `buf_list` with `list_for_each_entry` WITHOUT `buf_list_lock` and calls `isp4sd_ioc_send_img_buf` per buffer; the 4th call sends START_STREAM and, with `--start-sensor 1`, runs the experimental sensor start incl. PHY diagnostics that sleep ~1.1 s (+100 ms, +1 s dumps) INSIDE the loop. Meanwhile the firmware completed that very buffer and the frame-done path (`isp4_video.c:55-69`, under the lock) did `list_del` on it; when the loop advanced it followed the poisoned `next` pointer. The race exists in the original code too, but only our long sleeps inside the loop make it likely. The oopsing task died holding locks: v4l2-ctl is stuck in `D` state in `vb2_fop_release`, the test script cannot finish, the module cannot be unloaded -> a REBOOT is needed to recover (the system itself is fine).
FIX PROPOSAL (patch 0031, not written, needs the user's OK): use `list_for_each_entry_safe` in `isp4vid_qops_start_streaming` (the next entry is read before sending the current one; an entry not yet sent to the firmware cannot be completed, so it cannot be removed meanwhile). Secondary, later: move the experimental sensor start/diagnostics out of the send path.
The capture file is 0 bytes because v4l2-ctl never returned from STREAMON; the frame CONTENT is therefore still unseen.

## 84. Patch 0031: safe iteration in start_streaming

`scratch/isp4-threshold/0031-isp4-start-streaming-safe-iter.patch` (on top of 0030; base copy `base-0030/isp4_video.c`): `isp4_video.c:578` now `list_for_each_entry_safe(isp4vid_buf, next_buf, &isp_vdev->buf_list, list)` (new local `next_buf`, line 535; comment lines 570-577). Built; NOT run. LIMITS: it protects against removal of the CURRENT entry, which is what happened (section 83); it relies on the fact that an entry not yet sent to the firmware cannot be completed. The loop still runs without `buf_list_lock` and still contains the ~1.1 s of experimental sensor start + PHY diagnostics, so v4l2-ctl gets control back (and re-queues buffers) only after that; frames in between are dropped ("Preview buffer is not available"). If that matters, the next step is to move the experimental sensor start out of the send path (deferred work).
NEXT (user decides, user runs): the same data run as section 83, with the logger:
`./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x77 --prefetch-flags 1 --start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --seconds 8`
Expected if the fix works: no oops, v4l2-ctl returns, some frames in `results/<stamp>-min4-var0.nv12` (each 3,110,400 bytes). With `--sensor-burst-ms 300` the sensor stops after 300 ms, so only the first few frames (about 9) can contain image data.

## 85. FIRST IMAGE from the rear camera on Linux (`results/20261016-032025-*`, `frames-20261016-032025/`)

COMMAND (user-launched, logger running, patches up to 0031): `./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb --pool-mb 263 --meta-data-bufs 6 --win-cmds 0x77 --prefetch-flags 1 --start-sensor 1 --sensor-pm-cycle --phy-init --sensor-pll 2 --sensor-burst-ms 300 --seconds 8`.
RESULT: `variant=0 min=4 queued=1 failed=0 no-send=4 fw-reply=1 frames=8 bytes=12441600 v4l2-ctl-rc=0`. No oops (0 in `kernel-sync-20261016-032015.log`), no `INTR_LATENCY_BUFFER_LEAKING`, 8 frames done by the firmware, 5 `vb2_buffer_done`, 4 frames (4 x 3,110,400 bytes, 1920x1080 NV12) written by v4l2-ctl. Patch 0031 fixed the oops of section 83.
IMAGE (OBSERVED): `frames-20261016-032025/frame-1..4.png` (ffmpeg, NV12 -> PNG) and `frame-1-bright-x6.png` (luma x6, half size). Statistics (sampled): Y mean 12.8-14.7, max 33-47 of 255 (very dark), U and V means ~146 (neutral would be 128). The brightened frame shows a coherent scene (fabric folds of a cushion/sofa, a dark object at the right edge), geometrically correct: resolution, pitch and plane layout are right. Colour cast purple/magenta (AWB not working; brightening only luma exaggerates it); heavy noise (dark scene at fixed default exposure).
WHY DARK / TINTED (known causes, from the firmware log, same as section 83): the device script's runtime functions all fail (`SvmSetINc: Set iNc addr mode not 8bit nor 16bit`, `Run SensorSetItime/SensorSetAGain/... fail`), so the firmware's AE cannot write exposure/gain to the sensor; SET_3A_CONFIG is not sent (92-byte indirect command) and META buffers are not re-sent per frame (`No meta data buffer is available` in section 83).
WHAT MADE FRAMES POSSIBLE (cumulative, as established in sections 64-84): Windows ISP firmware (srx_h) + replayed Windows sensor setup (device script, tuning data, sensor properties); forced sensor PM cycle; host D-PHY start; Windows PLL values for a 24 MHz clock; 6 META_DATA buffers; memory pool sized like Windows (263 MiB for 13.1 MP, formula of section 75); RT-pipe MMHUB prefetch via the global ENABLE_PREFETCH {1,0,0} (section 82/83); safe buffer-list iteration (0031). Each was tested in isolation only partly; the freeze that ended earlier data runs did not occur in the last three data runs (all with the larger pool).
OPEN, in my order of value: (1) device-script encoding error in the INC/address-mode operand (exposure/gain control), (2) per-frame re-send of META_DATA/META_INFO like `ResendMetaInFrameDone`, (3) SET_3A_CONFIG via the indirect command path (AWB/AE configuration), (4) remove the 300 ms burst limit and the in-loop experimental sleeps to stream continuously, (5) then clean patches for upstream style.

## 86. Why exposure/gain fail: the device script's I2C descriptor, and patch 0032

EXACT ERROR (the `N`-normalised text in sections 83/85 was mangled): `DEVICE_SCRIPT L23 SvmSetI2c: Set i2c addr mode not 7bit nor 10bit`, then `L55 SvmRun: set I2C arg fail`, then `DeviceScriptCallSvm: Run <function> fail`, 8 times for each of SensorConvertAGain, SensorSetAGain, SensorSetItime, SensorGroupHold, SensorGroupRelease. The firmware's AE is working (`GetStaticMem: long expo & gain(E(960 ... 5210), ...)`); only the writes to the sensor fail.
KEY OBSERVATION: `SensorConvertAGain` contains NO I2C instruction (`asm_OV13B.asm`), yet fails with "set I2C arg fail". So `SvmRun` configures the I2C target from a per-sensor descriptor BEFORE running any function; my instruction encoding is not the cause. The firmware image has the matching print `DevCtrlScript.cpp ... i2cSensor={deviceId=%d,enRestart=%d,deviceAddrType=%d,regAddrType=%d,deviceAddr=0x%X}` and strings `7BIT` / `10BIT` near `SvmWi2c`.
WHERE THE DESCRIPTOR LIVES (OBSERVED in `isp_set_script_to_fw`, 0x140019a5c): the last 0x50 bytes of the 0x16EC-byte SET_DEVICE_SCRIPT payload are four 20-byte (5 x u32) records at 0x169c, 0x16b0, 0x16c4, 0x16d8 whose first word is set from a switch on the sensor index (0/1/2/0); the rest of the 0x104-byte tail is copied (reordered) from a stack block that the function zeroes at entry. Our payload sends all of it as zero (`tools/assemble_ov13b.py` PAYLOAD_INDEX_FIELDS). 5 words per record = exactly the 5 fields of the firmware's i2cSensor print, so INFERENCE: these are the I2C descriptors, and deviceAddrType = 0 is what the firmware rejects.
UNRESOLVED: I did not find what fills that stack block in Windows. Checked and excluded: op slot 0x10 (`0x140092dc0` -> `0x14005e844`, returns only the script file size), op slot 0x18 (`0x140092d80` -> `CIspSensor::GetFwScriptCtrl` 0x1400926d4 -> file reader `0x14005ecc8`, which writes only the size, then plug-in slot 0xb0 = `get_emb_prop_OV13B` 0x140003360, which clears one byte), the `.asm` file itself (no I2C directives). Either one of these writes more than I read, or the descriptor reaches the firmware another way on Windows.
SOURCE OF THE VALUES (OBSERVED in `sensorOV13B.sys` `get_i2c_config_OV13B`, 0x140003680, plug-in slot 0xd0): u16 1 at +0, device 0x10 at +4 with code 0x102 at +0xc, device 0x0c at +0x10 with code 0x101 at +0x18. INFERENCE: code = deviceAddrType << 8 | regAddrType, 1 = 7-bit address, 2 = 16-bit register (the OV13B has 16-bit registers, the DW9714-class focus motor 8-bit). In Windows this function is called from `isp_setup_stream` (0x14001c8a9) and `get_camera_dev_info_imp`; where its result goes was not traced.
PATCH 0032 (`driver/patches/0032-isp4-script-i2c-descriptors.patch`, on top of 0031; base copy `scratch/isp4-threshold/base-0031/isp4_interface.c`): `script_i2c` (0 off, 1 sensor, 2 sensor + focus motor, 3 all four = sensor) and `script_i2c_restart` (default 1) fill the records {deviceId kept, enRestart, 1, 2, 0x10} (and {.., 1, 1, 0x0c}) in the GPU copy of the payload before the checksum, and log `EXP-SCRIPT-I2C: mode N, descriptors ...`. Built OK; NOT run. Test script option `--script-i2c N`.
HOW TO TEST: the script only runs when AE is active, i.e. in a DATA run. Run section 85's command plus `--script-i2c 1` with the logger. Success = no `SvmSetI2c` errors, and the frames get brighter over the first frames (exposure 960 -> 5210 us gets applied). If the error stays, try `--script-i2c 3`, then other codes (would need a code change: `0x101`, or types 0).

## 87. Patch 0032 works: the device script runs, AE now writes exposure to the sensor (`results/20261016-042328-*`, `kernel-sync-20261016-042325.log`)

COMMAND (user-launched, logger running): section 85's data run plus `--script-i2c 1`. Result line: `frames=8 bytes=12441600 v4l2-ctl-rc=0`, no oops.
OBSERVED:
- Descriptor sent: `EXP-SCRIPT-I2C: mode 1, descriptors 00000000 01000000 01000000 02000000 10000000 + zeros` = {deviceId 0, enRestart 1, deviceAddrType 1, regAddrType 2, deviceAddr 0x10}.
- `SvmSetI2c`, `SvmRun`, `DeviceScriptCallSvm` errors: 40/40/40 in section 85 -> **0/0/0**. The 8 `ApplyExpoGainNormal` lines are now INFO lines that report the applied setting, e.g. `ApplySensorSetting applyExpoGainNormal tgain(1000 1000) expo(7884 5205), expo line 762, duration line 3221`. So the inferred codes (deviceAddrType 1 = 7-bit, regAddrType 2 = 16-bit register) are accepted and the script's I2C writes reach the sensor (the descending "expo line" values are written per frame).
- AE behaviour (per frame, ~33 ms apart): exposure 952 us (frames 0-2) -> 1883 -> 2949 -> 3373 -> 5205 -> 7884 us (frame 7, after the burst-limit standby at +300 ms); gain stays 1000 (1.0x). The AE is still ramping up when the sensor is stopped; it never converged.
- The 4 saved frames are frames 0-3, all at ~952 us exposure: Y means 19.2, 18.2, 17.5 (frame 3: 2.8, the sensor went to standby), U/V means ~150/~156 (still the colour cast). They cannot show the AE effect because the host had no free buffers after frame 3 (v4l2-ctl only re-queues after STREAMON returns, ~1.1 s later because of the experimental sleeps in the send path), and the 300 ms burst limit stopped the sensor.
- Other errors unchanged vs section 85 (same counts): `No meta data buffer is available` x6, `Preview buffer is not available` x8, and at stop (3 s after standby) `shot too early` / `SetWdmaAddress: failed to shot raw channel` / `frame done timeout` x2 each (also present in `kernel-sync-20261016-032015.log`; I had not listed them in section 85).
CONCLUSION: tuning step 1 (device-script I2C) is done; `--script-i2c 1` should become the default when the experiment parameters are cleaned up. To SEE the effect, the camera must stream longer than 300 ms with buffers being re-queued: that is tuning step 4, or, without code changes, a data run with a much longer burst limit (e.g. `--sensor-burst-ms 3000`), so frames arriving after STREAMON returns are captured.

## 88. 3 s burst: AE converges, bright sharp image, strong magenta cast (`results/20261016-042648-*`, `frames-20261016-042648/`)

COMMAND (user-launched, logger running): section 87's command with `--sensor-burst-ms 3000`. Result: `frames=64 bytes=93312000 v4l2-ctl-rc=0` (30 frames saved), no oops, 0 `INTR_LATENCY_BUFFER_LEAKING`, 0 `SvmSetI2c`, 64 frames done by the firmware, 35 buffers returned.
AE (OBSERVED, `applyExpoGainNormal` per frame, exposure us : gain x1000): 952:1000 (x3) -> 1883 -> 2949 -> 3373 -> 5205 -> 7884 -> 8329:1199 -> 8329:1668 -> 16658:1195 -> 24986:1063 -> 24986 with gain rising to 6848 -> settles at **24986 us (about 3/4 of the 33.3 ms frame) and gain 6.67x**, i.e. a dim room; converged after ~30 frames.
FRAMES: frames 0-2 Y ~18 (first exposure), frame 3 black (sensor not yet re-queued / the earlier standby path), frames 4-29 stable: **Y mean ~53.5, max ~100-170, U ~199.5, V ~212.5**. Converted: `frames-20261016-042648/frame-20-half.png` (colour) and `frame-20-gray-half.png` (chroma set to 128): the scene (a sofa: backrest channels, seat cushion, piping) is sharp, well exposed for a dim room, low noise for 6.7x gain; the colour version is saturated magenta everywhere.
INTERPRETATION (INFERENCE, to be tested): U and V both far above 128 means a strong magenta cast. Missing white balance alone would give a mild (usually greenish) cast; a uniform saturated magenta is the typical result of the ISP demosaicing with the WRONG Bayer phase (green treated as red/blue and vice versa). Candidate cause, from section 59's register comparison: the Windows mode table sets `0x3813 = 0x08`, the Linux ov13b10 driver `0x09`; on OmniVision sensors 0x3812/0x3813 is the vertical window offset, so an odd/even difference moves the Bayer pattern by one row. Other registers that differ and could matter: `0x3600` (1a/16), `0x380f` (frame length 94/7c), and Windows-only `0x3011=7c`, `0x3774=2d`, `0x3823=18`, `0x3827=01`. Alternative causes not excluded: missing AWB/3A configuration (SET_3A_CONFIG not sent), the colour channels of the scene itself (the user can say what colour the sofa really is).
NEXT (proposed): extend the raw-I2C register write of `sensor_pll=2` (written in software standby before stream-on) with the remaining Windows mode values, at least `0x3813=0x08`, as a new `sensor_pll=3`; one data run with `--sensor-burst-ms 3000` then shows whether the cast goes.

## 89. Patch 0033: Windows mode registers (`sensor_pll=3`)

User: the sofa in section 88 is DARK GREY, so the magenta cast is entirely an error.
`driver/patches/0033-isp4-sensor-windows-mode-regs.patch` (on top of 0032; base copy `scratch/isp4-threshold/base-0032/isp4_subdev.c`): `sensor_pll=3` writes, after the Windows PLL values and still in software standby, `0x3813=0x08` (vertical window offset; Linux 0x09), `0x3600=0x1a`, `0x380f=0x94` (frame length 3220 lines; the firmware's AE already reports "duration line 3221"), and the Windows-only `0x3011=0x7c`, `0x3774=0x2d`, `0x3823=0x18`, `0x3827=0x01`; then stream on. Exposure/gain registers are left to the AE. The PLL readback list (`EXP-SENSOR: PLL regs`) now includes 0x3600, 0x380f, 0x3813, 0x3774, 0x3823, 0x3827. Built OK; NOT run.
TEST: section 88's command with `--sensor-pll 3`. Success = U and V means near 128 for a grey scene (now ~200 / ~213) and the readback showing 0x3813=08. If the cast changes but stays, it is the white balance (tuning step 3); if it does not change at all, the Bayer phase hypothesis is wrong for 0x3813 and the flip/mirror bits (0x3820/0x3821, same in both tables per section 59) or the firmware's Bayer setting in SET_SENSOR_PROP are the next suspects.

## 90. Patch 0033 fixes the colour: neutral grey (`results/20261016-043158-*`, `frames-20261016-043158/`)

COMMAND (user-launched, logger running): section 88's command with `--sensor-pll 3`. Result: `frames=65 bytes=93312000 v4l2-ctl-rc=0`, no oops, 0 latency errors, 0 script-I2C errors.
OBSERVED: `EXP-SENSOR: applied the Windows mode registers (0x3813=08 0x3600=1a 0x380f=94 0x3011=7c 0x3774=2d 0x3823=18 0x3827=01)`; readback after stream-on confirms all of them (`0x3813=08` etc.).
- Chroma: frames 4-29 **U ~126, V ~127** (neutral = 128); section 88 had U ~200, V ~213 for the same dark grey sofa. Even the first, dark frames are neutral (U 129-131, V 124-128). The magenta cast is gone.
- AE: same ramp as section 88, settling at 24986 us and gain ~10.7x (dimmer scene than section 88's 6.7x); Y mean ~149-151 (AE target), max ~195-203.
- Image `frames-20261016-043158/frame-20-half.png` / `frame-20-full.png`: neutral grey, soft, low-contrast surface with a darker strip at the top: consistent with the camera very close to / facing the sofa fabric (scene not the same as section 88); sharpness/focus cannot be judged from it. Focus motor: not driven (`--script-i2c 1` fills only the sensor descriptor; the focus motor at 0x0c would need `--script-i2c 2`).
CONCLUSION: the colour cast was caused by the Linux ov13b10 mode table, most likely `0x3813` (vertical window offset 0x09 vs Windows 0x08 = one-row Bayer shift); which of the seven registers really mattered is not isolated yet (0x3813 is the only one with a known link to the Bayer phase). For a clean driver, the ov13b10 mode for this board should use the Windows values (or the driver must report the Bayer order that matches its offset).

## 91. First natural-colour photo; autofocus initialises but does not move the lens (`results/20261016-043621-*`, `frames-20261016-043621/`)

COMMAND (user-launched): section 90's command with `--script-i2c 2` (sensor + focus-motor descriptors). Result: `frames=54 bytes=93312000 v4l2-ctl-rc=0`, no oops, 0 latency / script errors.
OBSERVED:
- Descriptors sent: {0, 1, 1, 2, 0x10} and {0, 1, 1, 1, 0x0c}.
- Frames 4-29: Y ~133, U ~125, V ~128. `frames-20261016-043621/frame-20-half.png`: a room scene (dark grey sofa, blue/beige patterned rug on light tiles, a bottle, plastic bags) in natural colour, well exposed, the rug pattern sharp at ~1-2 m. FIRST GOOD PHOTO from the rear camera on Linux.
- AF (firmware RTA log): `SetAfLibraryConfig: SIRC AF is selected`, module info pan focus 10.00 m / macro 0.07 m, AF range 0-4095, initial/low-confidence positions 300 (inf) / 4095 (macro), `No valid AF calibration data. JIG param is used`, `CheckAfCalibrationValid: calibrationValid 0` (the module's AF calibration comes from M2M/OTP data we do not send, section 74). No `LensSetPos` call appears, i.e. the focus motor was never driven in this run; the lens sits at its rest position, which is sharp at this distance.
- Errors: `No meta data buffer is available` x52 (one per frame in the long run: tuning step 2), `Preview buffer is not available` x19 (host buffer starvation during the in-loop sleeps, step 4); the stop-time shot/wdma errors of sections 85-90 did not appear this time.
STATUS of the tuning plan: step 1 (exposure/gain via the device script) DONE (patch 0032, `script_i2c`); colour cast DONE (patch 0033, `sensor_pll=3`); step 2 (META re-send) open; step 3 (SET_3A_CONFIG) less urgent, colour already neutral under this light; step 4 (continuous streaming without burst limit / in-loop sleeps) open; autofocus: needs the AF calibration (M2M data) and/or a trigger, open.

## 92. Patch 0034: tuning steps 2 (META_DATA re-send) and 4 (no in-loop sleeps)

`driver/patches/0034-isp4-meta-data-resend-phy-diag.patch` (on top of 0033; base copy `scratch/isp4-threshold/base-0033/isp4_subdev.c`):
- STEP 2, `meta_data_resend` (default off): Linux already re-sends the META_INFO buffer the frame-done names (`isp4sd_send_meta_info`), but never the type-13 META_DATA buffers, so after the first 6 frames the firmware logs `LoadFrameMetaData: No meta data buffer is available` once per frame (x52 in section 91). The frame-done meta info (`struct isp4fw_meta_info`: poc, fc_id, timestamp, preview status) does not say which META_DATA buffer was used, so the patch re-sends them ROUND-ROBIN in submission order, one per frame-done, restarting at buffer 0 whenever the 6 buffers are sent at stream start. Windows pairs META_INFO k with META_DATA k in its resend (trace section 71: INFO ...6f8000 with DATA ...7b8000, then ...718000 with ...7d8000). INFERENCE: the firmware consumes META_DATA in order, one per frame; if not, a buffer still in use could be queued twice (would show as wrong/duplicated metadata, not as a memory fault: all buffers are ours).
- STEP 4, `phy_diag` (default on = as before): 0 skips the D-PHY state dumps of patch 0022 (`after s_stream`, `+100ms`, `+1s`) that run INSIDE `start_streaming`'s buffer-send loop and keep v4l2-ctl from re-queuing buffers for 1.1 s (`Preview buffer is not available` x19 in section 91). Continuous streaming needs no code: `sensor_burst_ms=0` (default) leaves the sensor streaming until the normal stop path.
Built OK; NOT run. Test script options `--meta-data-resend`, `--no-phy-diag`.
TEST: section 91's command with `--meta-data-resend --no-phy-diag --sensor-burst-ms 0` (logger running; this is the first run with the sensor streaming for the whole capture since the freezes of sections 60-75, which were caused by the DMA problem fixed in section 83). Expect: no `No meta data buffer` errors, no `Preview buffer is not available`, 30 consecutive good frames.

## 93. Steps 2 and 4 work: continuous streaming, every frame delivered (`results/20261016-180003-*`, `frames-20261016-180003/`)

COMMAND (user-launched, logger running): section 91's command with `--sensor-burst-ms 0 --meta-data-resend --no-phy-diag`. Result: `frames=35 bytes=93312000 v4l2-ctl-rc=0`; machine stayed up; sensor streamed for the whole capture (first time since sections 60-75).
OBSERVED: 35 frames done by the firmware, 35 `vb2_buffer_done` (every frame delivered); 0 oops, 0 `INTR_LATENCY_BUFFER_LEAKING`, 0 `SvmSetI2c`, 0 PHYDIAG dumps, 0 failed META_DATA re-sends; **0 `No meta data buffer is available`** (52 in section 91) and **0 `Preview buffer is not available`** (19). Remaining firmware errors are only the start-up messages that the Windows firmware prints too (`Frame queue empty` per IP at stream start, `Video/Still channel is not enabled`, one `wdma not configured` + `potential TLSi stream overlap` at the first frame, `Check Dual Boot mode timeout`).
FRAMES: 30 consecutive frames. Frames 0-2 Y ~21 (initial exposure), frames 3-25 show the AE converging (Y 3 -> 127; the sensor's first frames after stream start are dark), frames 25-29 stable at Y ~127; U 123-129, V 127-130 throughout (neutral). `frames-20261016-180003/frame-29-half.png`: natural-colour, well-exposed close-up scene on the grey sofa; slightly soft at that short distance (focus motor not driven). `all-30-frames.mp4` (960 px wide, 30 fps) shows the sequence.
CONCLUSION: the round-robin META_DATA re-send is accepted (the FIFO assumption holds as far as visible) and with the in-loop sleeps gone the host keeps up with the stream. Tuning steps 1, 2, 4 and the colour fix are done; open: step 3 (SET_3A_CONFIG / AWB tuning, only needed if colour fails under other light), autofocus (needs AF calibration / M2M data and the lens actually driven), and turning the experiment parameters into fixed behaviour.

## 94. Patch 0035: the working configuration becomes the module default

`driver/patches/0035-isp4-working-defaults.patch` (on top of 0034; base copies `scratch/isp4-threshold/base-0034/`). Parameters are kept (for experiments) but default to the values of section 93:
- `isp4_interface.c`: `replay_sensor_setup=1`, `phy_init=1`, `script_i2c=2`, `tuning_file="/lib/firmware/amdgpu/OV13B_3001_ROG_SRX.atb"` (the user copied it there; sha256 6b5cc5f8...4b42 = the Windows file; it is Windows-derived and stays local), `fw_mem_pool_mb=0` now means "computed like Windows" (`isp4if_exp_pool_size()`, the section 75 formula with flag 0, 275,054,592 bytes for 4208x3120) instead of the stock 100 MiB.
- `isp4_subdev.c`: `start_sensor=1`, `sensor_pm_cycle=1`, `sensor_pll=3`, `win_cmds=0x77`, `prefetch_flags=1`, `meta_data_bufs=6`, `meta_data_resend=1`, `phy_diag=0` (`min_start_bufs=4`, `sensor_burst_ms=0` already were).
- `scripts/test-isp4-threshold.sh`: its own defaults are the same values (it passes every parameter explicitly, so its old zero defaults would have overridden the module), and `--module-defaults` loads the module with only `dyndbg=+p`.
Built OK; NOT run. `dkms/` builds from `driver/`, so a DKMS build now gets the same defaults.
TEST: `./scripts/test-isp4-threshold.sh --module-defaults --seconds 8` (logger running). Expected: the same result as section 93. After that: an ordinary application (e.g. `ffplay /dev/video0`) with the module loaded without parameters.

## 95. Module defaults work: three clean runs with no experiment parameters (`results/20261016-181013-*`)

COMMAND (user-launched, logger running): `./scripts/test-isp4-threshold.sh --module-defaults --seconds 8`. The script's default `--values "4 2 1"` made it run three passes; with `--module-defaults` all three load the module the same way (`insmod amd_isp4_capture.ko dyndbg=+p`, no `min_start_bufs=` or other parameter in the logs), so they are three repeats of the same configuration.
OBSERVED, identical in all three passes: `frames=35 bytes=93312000 v4l2-ctl-rc=0`, 35 frames done / 35 `vb2_buffer_done`, 0 oops, 0 `No meta data buffer`, 0 `Preview buffer is not available`, 0 `SvmSetI2c`, 0 `INTR_LATENCY_BUFFER_LEAKING`; `firmware memory pool 275054592 bytes (computed like Windows)` and the firmware's `SetMemPool ... size=275054592`; `SET_TUNING_DATA: 565520 bytes from /lib/firmware/amdgpu/OV13B_3001_ROG_SRX.atb`. Frames: f0 Y23, f10 Y10, f20 Y104, f29 Y~129, U/V 123-129 (neutral) in each pass; `frames-20261016-181013/frame-29-half.png` = same natural-colour scene as section 93.
CONCLUSION: the module's defaults alone reproduce the working camera, three times in a row with reloads in between; the experiment flags are no longer needed for normal use. NEXT: an ordinary application with the module loaded without parameters (e.g. `ffplay -f v4l2 /dev/video0`), then the DKMS install and the code clean-up for upstream.

## 96. Works in ordinary applications (ffplay, OBS via PipeWire); 0009 amdgpu removed

USER REPORT (2026-10-16, on 7.2.0-1.7-cachyos): with the stock module unloaded (`sudo rmmod amd_isp4_capture`; the test script reloads the stock one at its end, which is why a plain `insmod` first failed with "File exists") and ours loaded without parameters (`sudo insmod driver/amd_isp4_capture.ko`), `ffplay -f v4l2 -video_size 1920x1080 -input_format nv12 /dev/video0` shows live video, and after `systemctl --user restart wireplumber pipewire pipewire-pulse` the camera appears and works in OBS. `/dev/video0` is the ISP node (name "Preview"); video1-4 are the USB front/IR cameras.
CLEAN-UP (user): the patched amdgpu of patch 0009 (`/lib/modules/7.2.0-1.7-cachyos/updates/amdgpu.ko.zst`) and its Limine boot entry are removed; `updates/` of 1.7 no longer exists. This removes the risk that a `depmod`/`mkinitcpio` (e.g. from a DKMS install) would put the freezing amdgpu into the boot image.
CURRENT BOOT is the stock `7.2.9-2-cachyos`: its in-tree amdgpu has no `OMNI13B1` (checked: 0 occurrences), so the camera only works on the patched 7.2.0-1.7 kernel (amdgpu patches 0001/0003, see the answer on DKMS limits). Not persistent yet: `insmod` lasts until reboot or the next test-script run; persistent = the DKMS install of `dkms/` on the patched kernel.

## 97. Sensor fixes folded into ov13b10 (GZ302 DMI quirk) and patch 0036

NEW `sensor/` (built by `scripts/build-ov13b10.sh` against the 7.2.0-1.7 headers, clang/LLVM=1): `ov13b10.c` = upstream 7.2.0 + camera kernel patch 0004 (I2C id; verified byte-identical to the `.orig` in `/mnt/windows/Users/Termis/linux-cachyos-camera/linux-cachyos/src/cachyos-7.2.0-1/drivers/media/i2c/`; the current camera PKGBUILD applies 0001-0005 and 0008, not 0006/0007) + `sensor/patches/0001-media-ov13b10-gz302-dmi-quirk.patch`:
- DMI match `DMI_SYS_VENDOR "ASUSTeK COMPUTER INC."` + `DMI_BOARD_NAME "GZ302"` (this machine: product "ROG Flow Z13 GZ302EA_GZ302EA", board "GZ302EA"); parameter `gz302_fixups` (-1 auto default, 0 off, 1 force; 0644 so it can be flipped between streams).
- In `ov13b10_start_streaming()`, for the 4208x3120 mode, AFTER the PLL list, mode table and `__v4l2_ctrl_handler_setup()` (which writes the frame length 0x380e/0x380f) and BEFORE `MODE_SELECT=streaming`: 0x0303=01, 0x0305=46, 0x0325=55, 0x3813=08, 0x3600=1a, 0x380f=94, 0x3011=7c, 0x3774=2d, 0x3823=18, 0x3827=01; logs `applied GZ302 register fix-ups`. Difference to the old path (patch 0033): the sensor now never streams with the 19.2 MHz PLL, and no standby/stream-on cycle is needed.
- Built OK (vermagic 7.2.0-1.7-cachyos, aliases acpi OVTIDB10/OVTI13B1/OMNI13B1 and i2c:ov13b10).
PATCH 0036 (`driver/patches/0036-isp4-sensor-pll-default-off.patch`; base `scratch/isp4-threshold/base-0035/`): capture driver `sensor_pll` default 3 -> 0 (test script default too). Built OK.
NOT run. TEST (user): `sudo rmmod amd_isp4_capture`, `sudo rmmod ov13b10`, `sudo insmod sensor/ov13b10.ko`, then `./scripts/test-isp4-threshold.sh --module-defaults --values 4 --seconds 8` with the logger. Expect the kernel log line `ov13b10 ...: applied GZ302 register fix-ups`, no `EXP-SENSOR: PLL regs` lines (sensor_pll=0), and the same clean, neutral-colour result as section 95.
NOT done (as agreed): the clock-based variant (board data 24 MHz) for upstream; `sensor_pm_cycle` stays in the capture driver.

## 98. The ov13b10 quirk works: same clean result without raw-I2C sensor writes (`results/20261016-183747-*`)

USER ran (on 7.2.0-1.7-cachyos): `rmmod amd_isp4_capture`, `rmmod ov13b10`, `insmod sensor/ov13b10.ko`, then `./scripts/test-isp4-threshold.sh --module-defaults --values 4 --seconds 8`.
OBSERVED: loaded ov13b10 srcversion 11519CD58289802BC8BBE60 = `sensor/ov13b10.ko`, `gz302_fixups=-1`; kernel log `ov13b10 i2c-ov13b10: applied GZ302 register fix-ups (24 MHz PLL, 0x3813=0x08, ...)` (DMI matched); 0 `EXP-SENSOR: PLL regs` lines (capture driver `sensor_pll=0`); `frames=35 bytes=93312000 v4l2-ctl-rc=0`, 35 done / 35 delivered, 0 oops / no-meta / no-preview / SvmSetI2c / latency errors; frames f20 Y115, f29 Y138, U/V 123-130 (neutral); `frames-20261016-183747/frame-29-half.png` natural colour (grey sofa).
CONCLUSION: the sensor-side fixes now live in the sensor driver; the capture driver no longer writes sensor registers. Kernel patch series for the camera now: amdgpu 0001 + 0003, amd_isp4 board data 0002, ov13b10 0004 + `sensor/patches/0001` (GZ302 quirk), capture driver 0009-0036 (to be squashed). Next steps from the "newer kernels" plan: move the Windows-derived data (device script, sensor properties, D-PHY sequence) to run-time files, then squash and rebase the series.

## 99. Patch 0037: Windows-derived data loaded as firmware files

- NEW `tools/header_to_fw.py`: converts the three generated headers into `firmware/gz302-ov13b-script.bin` (5868 B, sha256 a7c5cf5b...2566), `gz302-ov13b-sensor-prop.bin` (360 B, 26707bf5...5c05), `gz302-ov13b-phy-seq.bin` (2392 B = 24-byte header `GZPH` v1 {phy 0, 1120 Mbps, 4 lanes, 296 ops} + 296 x {reg, mask, val, kind} u16 LE; 0653ab7a...e3f3). Same bytes the driver compiled in, so tested data is unchanged. Refuses to overwrite. `firmware/*.bin` is git-ignored.
- PATCH 0037 (`driver/patches/0037-isp4-load-gz302-data-as-firmware.patch`, base `scratch/isp4-threshold/base-0036/`): `isp4_interface.c` no longer includes the three headers; `isp4if_exp_get_fw()` (request_firmware + size check, logs `EXP-FW: loaded <name>`), used for SET_DEVICE_SCRIPT (in `isp4if_replay_sensor_setup`), SET_SENSOR_PROP (variants still work on a copy), and the D-PHY start (`isp4if_phy_init`: header validated, phy/rate/lanes taken from the file, released after the register loop and on every error path). Missing file = logged, step skipped (`phy_init` returns -ENOENT).
- VERIFIED (build only): builds against the 1.7 headers without warnings; `driver/.isp4_interface.o.cmd` no longer lists the three headers; the `.ko` contains the three file names; 0 of 69 sampled 32-byte chunks of the three data files occur in the `.ko` (the data is gone from the module). Also built through `dkms/` (vermagic 7.2.0-1.7-cachyos).
- DKMS: `dkms/check-generated-headers.sh` now only WARNS about missing run-time files in `/lib/firmware/amdgpu/` (the three .bin + the .atb); the `Kbuild` header backstop is removed; `dkms/README.md` updated (base copies `scratch/isp4-threshold/base-dkms-0037/`).
NOT run on hardware. TEST (user): `sudo cp firmware/gz302-ov13b-*.bin /lib/firmware/amdgpu/`, then (new ov13b10 loaded as in section 98) `./scripts/test-isp4-threshold.sh --module-defaults --values 4 --seconds 8`. Expect three `EXP-FW: loaded amdgpu/gz302-ov13b-...` lines and the same clean result as section 98.

## 100. Patch 0037 works on hardware: payloads from /lib/firmware (`results/20261016-184723-*`)

USER copied `firmware/gz302-ov13b-*.bin` to `/lib/firmware/amdgpu/` and ran `./scripts/test-isp4-threshold.sh --module-defaults --values 4 --seconds 8` (new ov13b10 loaded).
OBSERVED: `EXP-FW: loaded amdgpu/gz302-ov13b-script.bin (5868 bytes)`, `... sensor-prop.bin (360 bytes)`, `... phy-seq.bin (2392 bytes)`; `EXP-PHY: starting the D-PHY receiver (phy 0, 1120 Mbps, 4 lanes), 296 register operations` (values from the file header) and `PHY ready yes, lane stop-state 0x3f00`; SET_DEVICE_SCRIPT (0x02090002) and SET_SENSOR_PROP (0x02090001) answered status 0; `ov13b10: applied GZ302 register fix-ups`; `frames=35`, 35 done / 35 delivered, 0 oops / no-meta / no-preview / SvmSetI2c / latency errors; frames f20 Y92, f29 Y119, U/V 124-129 (neutral).
CONCLUSION: the module now contains no Windows-derived data and works the same with the data loaded at run time. Remaining steps of the "newer kernels" plan: squash and rebase the patch series against current mainline, then a PKGBUILD helper.

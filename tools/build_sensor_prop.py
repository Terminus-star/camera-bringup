#!/usr/bin/env python3
"""Rebuild the SET_SENSOR_PROP (command 0x2090001) payload for the GZ302 OV13B, mode 0.

This is a faithful port of the Windows sensor plugin function get_caps_OV13B
(sensorOV13B.sys, FUN_140002d70, decompiled with Ghidra) plus the wrapper in
amdcamera.sys isp_set_snr_info_2_fw (FUN_140019fb0) that builds the 0x168-byte payload:

    payload[0:4]   = sensor id (0 for the first sensor)           FUN_140013608
    payload[4:8]   = never written by Windows (stack garbage); zero here
    payload[8:]    = first 0x160 bytes of the caps structure, with caps[0:4] (version) = 3

See docs/findings.md sections 7 and 14.  The field MEANINGS are not known; the point is to replay
exactly what Windows would send.  Nothing here has been checked against real firmware.

Inputs that come from outside the plugin's code (all assumptions, defaults shown):
    mode            ctx+0x410   0 = the 4208x3120 30 fps mode whose register table is res_0_config_OV13B
    variant         ctx+0x1a4   "3001": entry 1 of the plugin's variant table (get_sensor_hw_parameter_OV13B)
    bus_type        ctx+0x464   4 (accepted values are 4 and 5; 4 is CSI-2 D-PHY in V4L2's numbering, INFERENCE)
    flag_57d        DAT_14000a57d, byte 0x3bd of the host-supplied driver-config block; 0 (unset)
Data read from sensorOV13B.sys: per-mode table at 0x140008460 (u32 factor, u32 value) and the variant
table at 0x140008470 (stride 0x44; entry 1 has the string "3001" at +0x44 and a u32 at +0x40+0x44 = 0xb4).

One conditional in Windows is NOT reproduced: if device flag dev+0x1804 is set, byte 0x12c of the caps is cleared.
Its default is unknown.  Here the value is left as the plugin set it (1 for variant 3001).

Usage (pass paths as arguments; run isolated):
    python3 -I tools/build_sensor_prop.py [--mode 0|1] [--dump] [--out-bin FILE] [--c-header FILE]
"""

import argparse
import struct
import sys

PAYLOAD_SIZE = 0x168
CAPS_COPIED = 0x160
CAPS_BUF = 0x200          # the plugin writes up to offset 0x1f4; only the first 0x160 bytes are sent

# per-mode tables read from sensorOV13B.sys (0x140008460 / 0x140008464, stride 8)
MODE_TABLE_FACTOR = {0: 0x60, 1: 0x60}
MODE_TABLE_VALUE = {0: 0x100, 1: 0x100}
# variant table: u32 at (0x1400084b0 + idx*0x44); idx 1 is the "3001" entry
VARIANT_VALUE = {0: 0xC81, 1: 0xB4}
VARIANT_3001 = 1

# per-mode constants in get_caps_OV13B: (uVar6, uVar3, uVar9, uVar12, uVar10)
MODE_CONSTANTS = {
    0: dict(u6=0x498, u3=0x7E17, u9=0xC94, u12=0x286A, u10=0x460),
    1: dict(u6=0x920, u3=0x0A, u9=0xC7C, u12=0x5172, u10=0x230),
}


class Caps:
    def __init__(self):
        self.b = bytearray(CAPS_BUF)

    def u8(self, off, v):
        self.b[off] = v & 0xFF

    def u32(self, off, v):
        struct.pack_into("<I", self.b, off, v & 0xFFFFFFFF)

    def u64(self, off, v):
        struct.pack_into("<Q", self.b, off, v & 0xFFFFFFFFFFFFFFFF)


def build_caps(mode, variant, bus_type, flag_57d):
    c = Caps()
    k = MODE_CONSTANTS[mode]
    u3, u6, u9, u10, u12 = k["u3"], k["u6"], k["u9"], k["u10"], k["u12"]

    # memset(caps, 0, 0x160) is implicit (zeroed buffer)
    c.u32(0x1C0, 0)
    c.u32(0x1C4, 0)
    c.u32(0x1D0, 0)
    c.u32(0x120, 0)
    c.u32(0x124, 0x10)
    is_3001 = variant == VARIANT_3001

    c.u32(0x1C8, 0x1070)            # width 4208
    c.u32(0x1CC, 0xC30)             # height 3120
    c.u32(0x1D0, 30000)             # 30 fps x 1000
    c.u8(0x08, 4)
    c.u32(0x1F0, u10)
    c.u32(0xA0, u12)
    c.u32(0xA4, u9)
    c.u32(0xA8, u6)
    c.u32(0xF8, 0x1070)
    c.u32(0xFC, 0xC30)
    c.u32(0xEC, 0)
    c.u32(0xF0, 0x1070)
    c.u32(0xF4, 0xC30)
    c.u32(0x140, u3)
    c.u64(0x00, 3)                  # *param_2 = 3: version 3, next u32 = 0
    c.u32(0x54, 3)
    c.u32(0x70, 1000)
    c.u32(0x78, 1000)
    c.u32(0x0C, 0)
    c.u32(0x48, 2)
    c.u32(0x4C, 2)
    c.u32(0x60, 2)
    c.u32(0x18, 0)
    c.u64(0x34, 0)
    c.u64(0x3C, 0)
    c.u32(0x44, 0)
    c.u64(0x10, 0x2B)
    c.u32(0x1C, 4)
    c.u64(0x20, 1)
    c.u32(0x28, 0x10)
    c.u64(0x2C, 0x38)
    c.u32(0x50, 1)
    c.u32(0x58, 200)
    c.u32(0x5C, 0x4B0)
    c.u32(0x64, 4)
    c.u32(0x68, 0xFFF7)
    c.u32(0x6C, 8)
    c.u32(0x74, 0x3C8C)
    c.u32(0x7C, 0xF3C)
    c.u32(0xE4, 1 if flag_57d else 0)
    c.u32(0x88, 0x100)
    c.u64(0x8C, 0x100)
    c.u32(0x98, 0x100)
    c.u64(0xB0, u12 * 0xC2F)
    c.u64(0x80, 0)
    c.u32(0x94, 0)
    c.u32(0xAC, 0)
    c.u32(0x9C, 0xF80)
    c.u32(0xB8, 100)
    t1 = MODE_TABLE_VALUE[mode]
    t0 = MODE_TABLE_FACTOR[mode]
    c.u32(0xC8, (t1 >> 8) * 1000)
    c.u32(0xCC, (t1 >> 8) * 1000)
    c.u32(0xD4, 1000)
    c.u32(0xD8, 1000)
    c.u32(0xDC, 1000)
    c.u32(0xD0, (t1 >> 8) * 1000)
    iv7 = (1 if (u12 % 1000) > 499 else 0) + u12 // 1000
    c.u32(0xBC, iv7 * t0)
    c.u32(0xC0, iv7 * t0)
    c.u32(0xC4, iv7 * t0)
    c.u32(0xE8, 30000)              # (int) param_2[0x3a] = the value stored at 0x1d0
    c.u64(0x100, 0)
    c.u32(0x108, 0)
    c.u32(0x10C, VARIANT_VALUE[variant])
    c.u32(0x110, 0)
    c.u32(0x114, 1 if bus_type == 4 else 0)
    c.u64(0x118, 0)
    c.u32(0x128, 0)
    c.u8(0x144, 1)
    c.u32(0x14C, 0)
    c.u32(0x150, 0x3FF)
    c.u64(0x154, 1)
    c.u32(0x148, 10)
    c.u32(0x15C, 400)
    if is_3001:
        c.u32(0x12C, 1)
        c.u32(0x130, 0x1070)
        c.u64(0x134, 0xC30)
        c.u32(0x13C, 0)
    return c


def build_payload(sensor_id, caps):
    p = bytearray(PAYLOAD_SIZE)
    struct.pack_into("<I", p, 0, sensor_id)
    p[8:8 + CAPS_COPIED] = caps.b[:CAPS_COPIED]
    struct.pack_into("<I", p, 8, 3)     # version forced to 3 (auStack_1b0[0] = 3 in FUN_140019fb0)
    return bytes(p)


def write_c_header(path, data, comment):
    lines = []
    for i in range(0, len(data), 12):
        lines.append("\t" + ", ".join("0x%02x" % b for b in data[i:i + 12]) + ",")
    with open(path, "w") as f:
        f.write("/* SPDX-License-Identifier: GPL-2.0+ */\n")
        f.write("/* Generated by tools/build_sensor_prop.py; do not edit by hand.\n * %s\n */\n" % comment)
        f.write("#define ISP4_OV13B_SENSOR_PROP_SIZE %d\n" % len(data))
        f.write("static const unsigned char isp4_ov13b_sensor_prop[ISP4_OV13B_SENSOR_PROP_SIZE] = {\n")
        f.write("\n".join(lines) + "\n};\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mode", type=int, default=0, choices=(0, 1))
    ap.add_argument("--sensor-id", type=int, default=0)
    ap.add_argument("--bus-type", type=int, default=4)
    ap.add_argument("--flag-57d", type=int, default=0)
    ap.add_argument("--dump", action="store_true", help="print a hex dump with offsets")
    ap.add_argument("--out-bin", metavar="FILE")
    ap.add_argument("--c-header", metavar="FILE")
    a = ap.parse_args()

    caps = build_caps(a.mode, VARIANT_3001, a.bus_type, a.flag_57d)
    payload = build_payload(a.sensor_id, caps)
    assert len(payload) == PAYLOAD_SIZE

    # Consistency checks against facts established independently from the sensor register table
    # (res_0_config_OV13B): HTS = 0x380c/0x380d = 0x0498 and VTS = 0x380e/0x380f = 0x0C94 for mode 0.
    if a.mode == 0:
        hts = struct.unpack_from("<I", caps.b, 0xA8)[0]
        vts = struct.unpack_from("<I", caps.b, 0xA4)[0]
        assert (hts, vts) == (0x498, 0xC94), (hts, vts)
        w, h = struct.unpack_from("<II", caps.b, 0x1C8)
        assert (w, h) == (4208, 3120), (w, h)

    print("payload: %d bytes, sensor id %d, mode %d" % (len(payload), a.sensor_id, a.mode))
    print("  version (payload+8) = %d, width x height at caps+0xf8 = %dx%d, fps*1000 at caps+0x1d0 = %d" % (
        struct.unpack_from("<I", payload, 8)[0],
        struct.unpack_from("<I", caps.b, 0xF8)[0], struct.unpack_from("<I", caps.b, 0xFC)[0],
        struct.unpack_from("<I", caps.b, 0x1D0)[0]))
    nonzero = sum(1 for x in payload if x)
    print("  non-zero bytes: %d of %d" % (nonzero, len(payload)))
    if a.dump:
        for off in range(0, len(payload), 16):
            row = payload[off:off + 16]
            print("  %04x  %s" % (off, row.hex(" ")))
    if a.out_bin:
        with open(a.out_bin, "wb") as f:
            f.write(payload)
        print("wrote", a.out_bin)
    if a.c_header:
        write_c_header(a.c_header, payload,
                       "SET_SENSOR_PROP payload, OV13B mode %d, sensor id %d (UNVERIFIED port of get_caps_OV13B)" % (
                           a.mode, a.sensor_id))
        print("wrote", a.c_header)
    return 0


if __name__ == "__main__":
    sys.exit(main())

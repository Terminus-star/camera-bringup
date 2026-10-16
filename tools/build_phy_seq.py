#!/usr/bin/env python3
"""Evaluate the Windows MIPI D-PHY receiver setup for one concrete case and emit it as a C header.

Source of truth: the Windows camera driver amdcamera.sys (read only) plus the Ghidra pseudo code of one function
(saved by hand in scratch/phy-src/).  See docs/findings.md section 41.  The Windows function chain is

    startup_seq_cdphy_rx(phy, mode, rate, lanes)                     (FUN_140052390, the control sequence: hand-written in the kernel)
      -> FUN_14005356c(phy, rate, lanes)    "analog configuration":
           1. FUN_1400513d4      timing values from the rate (floating point)    -> ported here (timing_globals)
           2. FUN_14005528c      15 static read-modify-write entries (table at 0x1400ab5f0)  -> read from the exe
           3. FUN_14005280c      19 static read-modify-write entries (table at 0x1400ab7d0)  -> read from the exe
           4. FUN_1400535d8      about 170 read-modify-writes, branching on rate and phy       -> pseudo code evaluated here
           5. FUN_1400534f0      128 plain writes (table at 0x1400acdd8)                       -> read from the exe
           6. FUN_140055510      pin-swap / polarity clears (static)                           -> transcribed here

Every register write is one of two kinds, both through the PHY's indirect port (address +0x24, data +0x28):
    RMW   (FUN_14005131c): old = read(reg); new = (old & ~mask) | ((value << lowest_set_bit(mask)) & mask)
    WRITE (FUN_1400534f0): write(reg, value)

The output is a list of (register, mask, value, kind) in execution order.  The floating-point timing computation is done
here because the kernel must not use floating point.

Usage (paths as arguments; run isolated):
    python3 -I tools/build_phy_seq.py --exe AMDCAMERA.SYS --pseudo scratch/phy-src/FUN_1400535d8.txt \
        [--rate 1120] [--phy 0] [--print] [--c-header OUT.h]
"""

import argparse
import hashlib
import math
import re
import struct
import sys


# ---------------------------------------------------------------- PE helpers

class Pe:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        e_lfanew = struct.unpack_from("<I", d, 0x3C)[0]
        assert d[e_lfanew:e_lfanew + 4] == b"PE\0\0"
        nsec = struct.unpack_from("<H", d, e_lfanew + 6)[0]
        opt_size = struct.unpack_from("<H", d, e_lfanew + 20)[0]
        opt = e_lfanew + 24
        assert struct.unpack_from("<H", d, opt)[0] == 0x20B, "PE32+ expected"
        self.image_base = struct.unpack_from("<Q", d, opt + 24)[0]
        self.sections = []
        sec = opt + opt_size
        for i in range(nsec):
            name, vsize, va, rawsize, rawptr = struct.unpack_from("<8sIIII", d, sec + 40 * i)
            self.sections.append((va, max(vsize, rawsize), rawptr, rawsize))

    def off(self, va):
        rva = va - self.image_base
        for sva, ssize, rawptr, rawsize in self.sections:
            if sva <= rva < sva + ssize:
                assert rva - sva < rawsize, "address 0x%x is in uninitialised data" % va
                return rawptr + (rva - sva)
        raise ValueError("address 0x%x not in any section" % va)

    def u16(self, va):
        return struct.unpack_from("<H", self.data, self.off(va))[0]

    def u32(self, va):
        return struct.unpack_from("<I", self.data, self.off(va))[0]

    def u64(self, va):
        return struct.unpack_from("<Q", self.data, self.off(va))[0]

    def cstr(self, va):
        o = self.off(va)
        e = self.data.index(b"\0", o)
        return self.data[o:e].decode("ascii", "replace")


# ---------------------------------------------------------------- the pieces

def ctz16(mask):
    """Index of the lowest set bit of a 16-bit mask, 0 if none (as FUN_14005131c does)."""
    for i in range(16):
        if (mask >> i) & 1:
            return i
    return 0


def read_desc_table(pe, va, count):
    """32-byte descriptors: name ptr @0, register u16 @8, field-name ptr @0x10, mask u16 @0x18, value u16 @0x1a."""
    ops = []
    for i in range(count):
        b = va + 32 * i
        reg, mask, val = pe.u16(b + 8), pe.u16(b + 0x18), pe.u16(b + 0x1A)
        ops.append(dict(reg=reg, mask=mask, val=val, kind="RMW",
                        name=pe.cstr(pe.u64(b)), field=pe.cstr(pe.u64(b + 0x10))))
    return ops


def read_write_table(pe, va, count):
    """FUN_1400534f0: 32-byte entries, register u16 @0, value u16 @0x12; plain writes."""
    ops = []
    for i in range(count):
        b = va + 32 * i
        ops.append(dict(reg=pe.u16(b), mask=0xFFFF, val=pe.u16(b + 0x12), kind="WRITE", name="", field=""))
    return ops


def timing_globals(rate_mbps, pe):
    """Port of FUN_1400513d4 (floating point) for one rate.  Returns the DAT_1400d3exx globals it sets.

    Globals that this call does not set for the given rate keep their start value (0 in the binary's .data).
    """
    g = {a: 0 for a in range(0x1400D3E48, 0x1400D3EA8, 4)}
    rate = float(rate_mbps)
    u3 = pe.u32(0x1400C06F4)     # 5000
    u4 = pe.u32(0x1400C06F0)     # 4
    c6f8 = pe.u32(0x1400C06F8)   # 1
    ceil, floor = math.ceil, math.floor

    def s16(x):                  # (undefined2)(int)x
        return int(x) & 0xFFFF

    d1 = rate * 1000.0 * 0.5
    d7 = u3 * d1
    d7 = ceil(((d7 + d7) / 1000000.0) * 0.5 * 0.0625 * 0.5)
    g[0x1400D3E48] = s16(d7)
    if 2500.0 < rate:
        if rate <= 4500.0:
            g[0x1400D3E70] = 0
    else:
        g[0x1400D3E70] = 1
    if 1500.0 <= rate:
        raise NotImplementedError("rate >= 1500 Mbps: the first block of FUN_1400513d4 is not ported (not needed for the OV13B)")
    # (for rate < 1500 the e4c/e50/e54/e58 block is skipped)
    u2 = g[0x1400D3E50]
    if 1500.0 < rate:
        raise NotImplementedError
    g[0x1400D3E5C] = 1
    g[0x1400D3E60] = 1
    g[0x1400D3E68] = 1
    g[0x1400D3E74] = 0
    g[0x1400D3E6C] = 1
    g[0x1400D3E64] = 0
    if rate >= 160.0:
        if rate >= 320.0:
            if rate >= 640.0:
                if rate >= 1280.0:
                    g[0x1400D3E78] = 5
                    if rate >= 2560.0:
                        g[0x1400D3E78] = 6
                else:
                    g[0x1400D3E78] = 4
            else:
                g[0x1400D3E78] = 3
        else:
            g[0x1400D3E78] = 2
    else:
        g[0x1400D3E78] = 1
    d7 = floor((5000000.0 / d1) * 0.5 + 112.5)
    d7 = ceil(float(int(d7) & 0xFFFFFFFF) / 5.0)
    g[0x1400D3E7C] = s16((d7 - u4) - 7.0)
    d7 = floor((6000000.0 / d1) * 0.5 + 115.0)
    d7 = ceil(float(int(d7) & 0xFFFFFFFF) / 5.0)
    g[0x1400D3E80] = s16((d7 - u4) - 7.0)
    g[0x1400D3E84] = s16(ceil(u2 * 0.025))
    g[0x1400D3E88] = s16(ceil(u2 * 0.2))
    g[0x1400D3E8C] = s16(ceil(23.0))
    d7 = u3 / 5.0
    if d1 + d1 < 900000.0:
        d7 = d7 * 900000.0
    else:
        d7 = d7 * d1
        d7 = d7 + d7
    d7 = ceil(((d7 + d7) * 0.03125) / 1000000.0)
    g[0x1400D3E90] = s16(d7 - 1.0)
    d7 = ceil(((42000000.0 / d1) * 0.5) / 5.0 + float(c6f8))
    g[0x1400D3E94] = s16(d7)
    d7 = floor(((140000000.0 / d1) * 0.5) / 5.0 - 7.0)
    i5 = int(d7)
    if float(i5) < 1.0:
        i5 = 1
    g[0x1400D3E98] = i5 & 0xFFFF
    t = int(((d1 * 10.0 + d1 * 10.0) / 7.0) / 1000000.0 - 1.0)
    if 0.0 < float(t):
        raise NotImplementedError("FUN_1400513d4 tail with a positive term: argument of the ceil call is not known")
    g[0x1400D3EA0] = 1
    return g


def concat22(a, b):
    return ((a & 0xFFFF) << 16) | (b & 0xFFFF)


def eval_step4(path, phy, rate_mbps, glob):
    """Evaluate the pseudo code of FUN_1400535d8 for (phy, rate); returns its list of RMW ops in order."""
    ops = []
    env = {"param_1": phy, "param_2": float(rate_mbps), "CONCAT22": concat22}
    for addr, val in glob.items():
        env["DAT_%x" % addr] = val
    env["emit_ops"] = ops

    def emit():
        reg = env["local_50"] & 0xFFFF
        mv = env["local_40"] & 0xFFFFFFFF
        ops.append(dict(reg=reg, mask=mv & 0xFFFF, val=(mv >> 16) & 0xFFFF, kind="RMW",
                        name=env["local_58"], field=env["local_48"]))
    env["emit"] = emit

    src = open(path).read().splitlines()
    py = []
    depth = 0
    started = False
    decl = re.compile(r"^\s*(undefined\d*|ulonglong|uint|int|char|ushort|longlong|float|double|short)\b[^=(]*;\s*$")
    for line in src:
        s = line.strip()
        if not started:
            if s == "{":
                started = True
            continue
        if not s or decl.match(line) or s.startswith("/*"):
            continue
        ind = "    " * depth
        if s.endswith("{") and (s.startswith("if") or s.startswith("else")):
            if s.startswith("else"):
                py.append("    " * depth + "else:")
            else:
                cond = s[:-1].strip()
                cond = re.sub(r"^if\s*\((.*)\)$", r"if \1:", cond)
                py.append(ind + cond)
            depth += 1
            py.append("    " * depth + "pass")
            continue
        if s == "}":
            depth -= 1
            if depth < 0:
                break           # closing brace of the function
            continue
        if s.startswith("else"):
            raise ValueError("unexpected line: " + s)
        if s.startswith("return"):
            continue
        if s.startswith("FUN_14005131c("):
            py.append(ind + "emit()")
            continue
        stmt = s.rstrip(";")
        stmt = re.sub(r"\(int\)(\w+)", r"int(\1)", stmt)
        py.append(ind + stmt)
    code = "\n".join(py)
    exec(compile(code, "<FUN_1400535d8>", "exec"), env)
    return ops


# Step 6 (FUN_140055510), transcribed: clears of pin swap and gated polarity.  phy < 2: four data lanes (lanes 0..3 + clock).
def step6_ops(phy):
    four = phy < 2
    ops = []

    def add(reg, mask, name, field):
        ops.append(dict(reg=reg, mask=mask, val=0, kind="RMW", name=name, field=field))

    add(0x3800, 1, "CORE_DIG_DLANE_CLK_RW_CFG_0", "CFG_0_LP_PIN_SWAP_REG")
    add(0x3800, 2, "CORE_DIG_DLANE_CLK_RW_CFG_0", "CFG_0_HS_PIN_SWAP_REG")
    for sw, mask in (("LP", 1), ("HS", 2)):
        regs = [0x3000, 0x3200] + ([0x3400, 0x3600] if four else [])
        for n, reg in enumerate(regs):
            add(reg, mask, "CORE_DIG_DLANE_%d_RW_CFG_0" % n, "CFG_0_%s_PIN_SWAP_REG" % sw)
    regs = [0x1029, 0x1229, 0x1429] + ([0x1629, 0x1829] if four else [])
    for n, reg in enumerate(regs):
        add(reg, 0x100, "CORE_DIG_IOCTRL_RW_AFE_LANE%d_CTRL_2_9" % n, "OA_LANE%d_HSRX_SEL_GATED_POLARITY" % n)
    return ops


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--exe", required=True, help="amdcamera.sys (read only)")
    ap.add_argument("--pseudo", required=True, help="saved pseudo code of FUN_1400535d8")
    ap.add_argument("--rate", type=int, default=1120, help="lane data rate in Mbps (caps+0x1f0)")
    ap.add_argument("--phy", type=int, default=0)
    ap.add_argument("--lanes", type=int, default=4)
    ap.add_argument("--print", action="store_true", dest="do_print")
    ap.add_argument("--c-header", metavar="FILE")
    a = ap.parse_args()

    pe = Pe(a.exe)
    glob = timing_globals(a.rate, pe)
    steps = [
        ("FUN_14005528c static table (15)", read_desc_table(pe, 0x1400AB5F0, 15)),
        ("FUN_14005280c static table (19)", read_desc_table(pe, 0x1400AB7D0, 19)),
        ("FUN_1400535d8 rate/phy dependent", eval_step4(a.pseudo, a.phy, a.rate, glob)),
        ("FUN_1400534f0 plain writes (128)", read_write_table(pe, 0x1400ACDD8, 128)),
        ("FUN_140055510 pin swap clears", step6_ops(a.phy)),
    ]
    allops = [op for _, ops in steps for op in ops]

    print("exe sha256 %s" % hashlib.sha256(pe.data).hexdigest())
    print("phy %d, rate %d Mbps, lanes %d" % (a.phy, a.rate, a.lanes))
    print("timing globals:", ", ".join("%04x=%d" % (k & 0xFFFF, v) for k, v in sorted(glob.items()) if v))
    for title, ops in steps:
        print("  %-36s %3d ops" % (title, len(ops)))
    print("  total %d ops" % len(allops))
    assert len(steps[0][1]) == 15 and len(steps[1][1]) == 19 and len(steps[3][1]) == 128
    assert all(0 <= op["reg"] <= 0xFFFF for op in allops)

    if a.do_print:
        for title, ops in steps:
            print("\n# " + title)
            for op in ops:
                if op["kind"] == "RMW":
                    print("  RMW   0x%04x mask 0x%04x val 0x%04x  %s / %s" % (op["reg"], op["mask"], op["val"], op["name"], op["field"]))
                else:
                    print("  WRITE 0x%04x val 0x%04x" % (op["reg"], op["val"]))

    if a.c_header:
        with open(a.c_header, "w") as f:
            f.write("/* SPDX-License-Identifier: GPL-2.0+ */\n")
            f.write("/*\n * Generated by tools/build_phy_seq.py; do not edit by hand.  EXPERIMENT (GZ302): MIPI D-PHY receiver analog\n")
            f.write(" * configuration for phy %d, lane data rate %d Mbps, %d lanes, evaluated from the Windows driver (findings section 41).\n" % (a.phy, a.rate, a.lanes))
            f.write(" * Steps in order: %s.\n */\n" % "; ".join(t for t, _ in steps))
            f.write("#define ISP4_PHY_SEQ_PHY\t%d\n#define ISP4_PHY_SEQ_RATE_MBPS\t%d\n#define ISP4_PHY_SEQ_LANES\t%d\n" % (a.phy, a.rate, a.lanes))
            f.write("#define ISP4_PHY_OP_RMW\t\t0\n#define ISP4_PHY_OP_WRITE\t1\n\n")
            f.write("struct isp4_phy_op {\n\tu16 reg;\n\tu16 mask;\n\tu16 val;\n\tu16 kind;\n};\n\n")
            f.write("static const struct isp4_phy_op isp4_phy_seq[] = {\n")
            for op in allops:
                f.write("\t{ 0x%04x, 0x%04x, 0x%04x, %s },\n" % (
                    op["reg"], op["mask"], op["val"], "ISP4_PHY_OP_RMW" if op["kind"] == "RMW" else "ISP4_PHY_OP_WRITE"))
            f.write("};\n")
        print("wrote", a.c_header)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Prototype assembler for the AMD ISP "sensor device script" (asm_OV13B.asm).

Re-implements, from the decompiled Windows driver (amdcamera.sys), the pipeline that builds the
SET_DEVICE_SCRIPT (command 0x2090002) payload.  See docs/findings.md sections 2 and 8.

    amdcamera.sys FUN_14005e6c0  top-level: assemble, then serialise
    amdcamera.sys FUN_14005e5b0  line tokeniser
    amdcamera.sys FUN_14005d18c  operand parser
    amdcamera.sys FUN_14005d83c  per-line mnemonic dispatch
    amdcamera.sys FUN_14005d47c  label / function linker
    amdcamera.sys FUN_14005dc28  serialiser (instruction words, function table)

THIS IS UNVERIFIED AGAINST REAL HARDWARE OR REAL FIRMWARE.  The bit layout is a reading of
Ghidra pseudocode.  The built-in checks prove only that the encoding is lossless (every
instruction round-trips through the decoder) and that it matches hand-computed vectors derived
from the same reading; neither proves that the firmware agrees.

Not implemented: memory operands (M0[..] / M1[..]); asm_OV13B.asm does not use them.

Usage (run it isolated, pass the .asm as an argument; it is only parsed, never executed):

    python3 -I tools/assemble_ov13b.py ASM_FILE [--sensor-id N] [--listing] [--payload OUT.bin]
    python3 -I tools/assemble_ov13b.py --selftest
"""

import argparse
import struct
import sys

OPCODES = {
    "ADD": 1, "SUB": 2, "MUL": 3, "DIV": 4, "SHL": 5, "SHR": 6, "AND": 7, "OR": 8, "XOR": 9,
    "MOVB": 10, "MOVW": 11, "MOVDW": 12,
    "JNZ": 13, "JEZ": 14, "JLZ": 15, "JGZ": 16, "JGEZ": 17, "JLEZ": 18,
    "CALL": 19, "WI2C": 20, "RI2C": 21,
}
NAMES = {v: k for k, v in OPCODES.items()}
ARITH = range(1, 10)
MOVES = (10, 11, 12)
JUMPS = range(13, 19)

MAX_INSTRUCTIONS = 500      # FUN_14005e2b4 -> FUN_14005d128(ctx, 500, 100)
MAX_LABELS = 100            # second argument above (INFERENCE: it is the label limit)
MAX_FUNCTIONS = 40          # derived from the table layout: (0x15E0 - 4000) / 0x28
MAX_WORDS = 4               # FUN_14005e5b0 is called with 4 words, 0x20 bytes each
MAX_WORD_LEN = 32
MAX_NAME_LEN = 31           # strcpy_s(dst, 0x20, name) needs the terminator

COMPILED_SIZE = 0x15E8
FUNC_TABLE_OFFSET = 4000
FUNC_ENTRY_SIZE = 0x28
COUNT_INSN_OFFSET = 0x15E0
COUNT_FUNC_OFFSET = 0x15E4
PAYLOAD_SIZE = 0x16EC
# Offsets in the payload of the four u32 fields isp_set_script_to_fw sets to the sensor index
# (piVar3[0x5a7], [0x5ac], [0x5b1], [0x5b6] in FUN_140019a5c).
PAYLOAD_INDEX_FIELDS = (0x169C, 0x16B0, 0x16C4, 0x16D8)

MASK32 = 0xFFFFFFFF


class AsmError(Exception):
    pass


# ---------------------------------------------------------------- front end

def split_words(line):
    """FUN_14005e5b0: delimiters are space, tab and comma; ';' starts a comment."""
    words, cur = [], []
    for ch in line[:1023]:
        if ch == "\r":
            continue
        if ch in " \t,":
            if cur:
                words.append("".join(cur))
                cur = []
            continue
        if ch == ";":
            break
        if len(words) >= MAX_WORDS:
            raise AsmError("Too many words in one line, max:%d" % MAX_WORDS)
        if len(cur) >= MAX_WORD_LEN:
            raise AsmError("Word len too long, max:%d" % MAX_WORD_LEN)
        cur.append(ch)
    if cur:
        words.append("".join(cur))
    return words


def parse_number(text, allow_hex):
    """FUN_14005e514 + strtoul: decimal digits, or 0x/0X plus hex digits.  No sign."""
    if allow_hex and len(text) >= 3 and text[0] == "0" and text[1] in "xX":
        digits = text[2:]
        if all(c in "0123456789abcdefABCDEF" for c in digits):
            return min(int(digits, 16), MASK32)
        return None
    if len(text) >= 1 and all(c in "0123456789" for c in text):
        return min(int(text, 10), MASK32)
    return None


def parse_operand(tok):
    """FUN_14005d18c.  Returns (kind, value) with kind r=register, i=immediate, l=label."""
    if len(tok) < 2:
        raise AsmError("Arg length at least 2 characters start with R, $, @")
    head, rest = tok[0], tok[1:]
    if head == "R":
        n = parse_number(rest, False)
        if n is None:
            raise AsmError("Arg after with R is not a digital string, from 0 to 31")
        if n >= 32:
            raise AsmError("Register %s is not supported, range R0~R31" % tok)
        return ("r", n)
    if head == "$":
        n = parse_number(rest, True)
        if n is None:
            raise AsmError("Arg after with $ is not a digital string, a dec value or hex value start with 0x/0X")
        return ("i", n)
    if head == "@":
        if len(rest) >= 32:
            raise AsmError("Unsupported label characters large than:32")
        return ("l", rest)
    if head == "M":
        raise AsmError("memory operands are not supported by this prototype: %s" % tok)
    raise AsmError("The arg is not start with R, $, @")


class Assembler:
    def __init__(self):
        self.insns = []     # dicts: op, args, func, line
        self.labels = []    # (name, insn_index, func_index)
        self.funcs = []     # [name, start, end]
        self.cur_func = None

    # -- helpers
    def _need_func(self):
        if self.cur_func is None:
            raise AsmError("The instruction is not in a function")

    def _emit(self, op, args, line):
        self._need_func()
        if len(self.insns) >= MAX_INSTRUCTIONS:
            raise AsmError("Too many instruction, max:%d" % MAX_INSTRUCTIONS)
        self.insns.append({"op": op, "args": args, "func": self.cur_func, "line": line})

    # -- directives
    def start_function(self, args):
        if len(args) != 1:
            raise AsmError(".function should with one function name")
        name = args[0]
        if self.cur_func is not None:
            raise AsmError("Function nested is not supported:%s" % name)
        if len(self.funcs) >= MAX_FUNCTIONS:
            raise AsmError("Too many functions, max:%d" % MAX_FUNCTIONS)
        if len(name) > MAX_NAME_LEN:
            raise AsmError("function name too long: %s" % name)
        self.funcs.append([name, len(self.insns), 0])
        self.cur_func = len(self.funcs) - 1

    def end_function(self, args):
        if args:
            raise AsmError(".endfunction syntax error")
        if self.cur_func is None:
            raise AsmError("The endfunc is not in a function")
        self.funcs[self.cur_func][2] = len(self.insns)
        self.cur_func = None

    def add_label(self, word):
        self._need_func()
        if len(self.labels) >= MAX_LABELS:
            raise AsmError("Too many labels, max:%d" % MAX_LABELS)
        name = word[:-1]
        if len(name) > MAX_NAME_LEN:
            raise AsmError("label too long: %s" % name)
        self.labels.append((name, len(self.insns), self.cur_func))

    # -- one source line
    def feed(self, raw, lineno):
        words = split_words(raw)
        if not words:
            return
        mnem, rest = words[0], words[1:]
        if mnem in OPCODES:
            op = OPCODES[mnem]
            if op == 19:                       # CALL @func
                if len(rest) != 1:
                    raise AsmError("CALL takes one argument")
                if len(rest[0]) < 2 or rest[0][0] != "@":
                    raise AsmError("The arg for Call instruction is not start with @")
                if len(rest[0]) - 1 >= 32:
                    raise AsmError("Unsupported function characters large than:32")
                args = [("f", rest[0][1:])]
            elif op in JUMPS:                  # Jcc reg|imm, @label
                if len(rest) != 2:
                    raise AsmError("The args number is not 2")
                args = [parse_operand(t) for t in rest]
                if args[0][0] not in "ri":
                    raise AsmError("The first arg is not a register or an imm")
                if args[1][0] != "l":
                    raise AsmError("The second arg must be a label")
            elif op in MOVES:                  # front-end checks inferred from the serialiser
                if len(rest) != 2:
                    raise AsmError("The args number is not 2")
                args = [parse_operand(t) for t in rest]
            else:                              # ADD..XOR, WI2C, RI2C
                if len(rest) != 3:
                    raise AsmError("The args number is not 3")
                args = [parse_operand(t) for t in rest]
                if op in ARITH:
                    if args[0][0] != "r":
                        raise AsmError("The first arg is not a register")
                    if args[1][0] not in "ri":
                        raise AsmError("The second arg must be a reg or an imm")
                    if args[2][0] not in "ri":
                        raise AsmError("The third arg must be a reg or an imm")
                elif op == 20:
                    if args[0][0] not in "ri":
                        raise AsmError("The first arg is not a register , or a immediate value for WI2C instruction")
                    if args[2][0] not in "ri":
                        raise AsmError("The length arg of WI2C must be a reg or a immediate value")
                elif op == 21:
                    if args[0][0] != "r":
                        raise AsmError("The first arg is not a register or a memory for RI2C instruction")
            self._emit(op, args, lineno)
        elif mnem == ".function":
            self.start_function(rest)
        elif mnem == ".endfunction":
            self.end_function(rest)
        elif not rest:
            if not mnem.endswith(":") or len(mnem) < 2:
                raise AsmError('Label should end with ":"')
            self.add_label(mnem)
        else:
            raise AsmError("Not an instruction nor a label")

    # -- FUN_14005d47c
    def link(self):
        if self.cur_func is not None:
            raise AsmError("function '%s' has no .endfunction" % self.funcs[self.cur_func][0])
        func_index = {}
        for i, f in enumerate(self.funcs):
            func_index.setdefault(f[0], i)
        label_index = {}
        for name, idx, fn in self.labels:
            label_index.setdefault((fn, name), idx)
        for ins in self.insns:
            linked = []
            for kind, val in ins["args"]:
                if kind == "l":
                    key = (ins["func"], val)
                    if key not in label_index:
                        raise AsmError("line %d: Can't find label:%s" % (ins["line"], val))
                    linked.append(("L", label_index[key]))
                elif kind == "f":
                    if val not in func_index:
                        raise AsmError("line %d: Can't find func:%s" % (ins["line"], val))
                    linked.append(("F", func_index[val]))
                else:
                    linked.append((kind, val))
            ins["linked"] = linked


# ---------------------------------------------------------------- back end (FUN_14005dc28)

def encode(op, a):
    """Return the two u32 words for one linked instruction."""
    def bad():
        raise AsmError("Internal Instr Check Fail (op %s, operands %r)" % (NAMES[op], a))

    if op in ARITH:
        if len(a) != 3 or a[0][0] != "r" or a[1][0] != "r" or a[2][0] not in "ri":
            bad()
        flag = 1 if a[2][0] == "r" else 3
        w0 = (((((op << 5) | a[0][1]) << 5 | a[1][1]) << 2) | flag) << 15
        return w0 & MASK32, a[2][1]
    if op in MOVES:
        if len(a) != 2 or a[0][0] != "r" or a[1][0] not in "ri":
            bad()
        stype = 1 if a[1][0] == "r" else 3
        w0 = (((op << 2) | 1) << 25) | (a[0][1] << 20) | (stype << 5)
        if a[1][0] == "r":
            return w0 | a[1][1], 0
        return w0, a[1][1]
    if op in JUMPS:
        if len(a) != 2 or a[0][0] not in "ri" or a[1][0] != "L":
            bad()
        flag = 1 if a[0][0] == "r" else 3
        return (((flag | (op << 2)) << 25) | a[1][1]) & MASK32, a[0][1]
    if op == 19:
        if len(a) != 1 or a[0][0] != "F":
            bad()
        return ((op << 27) | a[0][1]) & MASK32, 0
    if op == 20:
        if len(a) != 3 or any(x[0] not in "ri" for x in a):
            bad()
        if a[2][1] >= 32:
            raise AsmError("WI2C length value %d would overlap the flag bits" % a[2][1])
        if a[0][1] > 0xFFFF:
            raise AsmError("WI2C address %#x does not fit in 16 bits" % a[0][1])
        flags = (0x200 if a[0][0] == "r" else 0x600) | (0x80 if a[1][0] == "r" else 0x180) \
            | (0x20 if a[2][0] == "r" else 0x60)
        return (((flags | a[2][1] | (op << 11)) << 16) | a[0][1]) & MASK32, a[1][1]
    if op == 21:
        if len(a) != 3 or a[0][0] != "r" or a[1][0] not in "ri" or a[2][0] not in "ri":
            bad()
        if a[2][1] >= 32:
            raise AsmError("RI2C length value %d would overlap the flag bits" % a[2][1])
        if a[1][1] > 0xFFFF:
            raise AsmError("RI2C address %#x does not fit in 16 bits" % a[1][1])
        flags = (0x200 if a[1][0] == "r" else 0x600) | (0x20 if a[2][0] == "r" else 0x60)
        return (((flags | a[2][1] | (op << 11)) << 16) | a[1][1]) & MASK32, (a[0][1] << 27) & MASK32
    bad()


def decode(w0, w1):
    """Inverse of encode().  Returns (op, operands) in the same form as linked operands."""
    op = w0 >> 27
    if op in ARITH:
        flag = (w0 >> 15) & 3
        return op, [("r", (w0 >> 22) & 31), ("r", (w0 >> 17) & 31),
                    ("r" if flag == 1 else "i", w1)]
    if op in MOVES:
        stype = (w0 >> 5) & 3
        dst = ("r", (w0 >> 20) & 31)
        return op, [dst, ("r", w0 & 31) if stype == 1 else ("i", w1)]
    if op in JUMPS:
        flag = (w0 >> 25) & 3
        return op, [("r" if flag == 1 else "i", w1), ("L", w0 & 0x1FFFFFF)]
    if op == 19:
        return op, [("F", w0 & 0x7FFFFFF)]
    if op in (20, 21):
        hi = (w0 >> 16) & 0x7FF
        addr = w0 & 0xFFFF
        lenv = hi & 31
        len_op = ("r" if not hi & 0x40 else "i", lenv)
        if op == 20:
            return op, [("r" if not hi & 0x400 else "i", addr),
                        ("r" if not hi & 0x100 else "i", w1), len_op]
        return op, [("r", w1 >> 27), ("r" if not hi & 0x400 else "i", addr), len_op]
    raise AsmError("Invalid opcode %d" % op)


def fmt_operand(o):
    kind, val = o
    return {"r": "R%d", "i": "$%#x", "L": "@L%d", "F": "@F%d"}[kind] % val


def fmt_insn(op, a):
    return "%-5s %s" % (NAMES[op], ", ".join(fmt_operand(x) for x in a))


# ---------------------------------------------------------------- driver

def build(text):
    asm = Assembler()
    for n, raw in enumerate(text.split("\n"), 1):
        try:
            asm.feed(raw, n)
        except AsmError as e:
            raise AsmError("line %d: %s" % (n, e))
    asm.link()
    words = [encode(i["op"], i["linked"]) for i in asm.insns]

    compiled = bytearray(COMPILED_SIZE)
    for i, (w0, w1) in enumerate(words):
        struct.pack_into("<II", compiled, i * 8, w0, w1)
    for i, (name, start, end) in enumerate(asm.funcs):
        struct.pack_into("<32sII", compiled, FUNC_TABLE_OFFSET + i * FUNC_ENTRY_SIZE,
                         name.encode("ascii"), start, end)
    struct.pack_into("<II", compiled, COUNT_INSN_OFFSET, len(words), len(asm.funcs))
    return asm, words, bytes(compiled)


def make_payload(compiled, sensor_id):
    payload = bytearray(PAYLOAD_SIZE)
    struct.pack_into("<I", payload, 0, sensor_id)
    payload[4:4 + COMPILED_SIZE] = compiled
    mapped = {0: 0, 1: 1, 2: 2, 3: 0}.get(sensor_id, 0)   # FUN_140019a5c switch on the sensor id
    for off in PAYLOAD_INDEX_FIELDS:
        struct.pack_into("<I", payload, off, mapped)
    return bytes(payload)


def write_c_header(path, data, comment):
    """Emit the payload as a C array for the kernel experiment (driver/)."""
    lines = []
    for i in range(0, len(data), 12):
        lines.append("\t" + ", ".join("0x%02x" % b for b in data[i:i + 12]) + ",")
    with open(path, "w") as f:
        f.write("/* SPDX-License-Identifier: GPL-2.0+ */\n")
        f.write("/* Generated by tools/assemble_ov13b.py; do not edit by hand.\n * %s\n */\n" % comment)
        f.write("#define ISP4_OV13B_SCRIPT_SIZE %d\n" % len(data))
        f.write("static const unsigned char isp4_ov13b_script[ISP4_OV13B_SCRIPT_SIZE] = {\n")
        f.write("\n".join(lines) + "\n};\n")


def roundtrip(asm, words):
    problems = 0
    for ins, (w0, w1) in zip(asm.insns, words):
        want = (ins["op"], ins["linked"])
        got = decode(w0, w1)
        if got != want:
            problems += 1
            print("ROUND-TRIP MISMATCH line %d: want %r got %r" % (ins["line"], want, got))
    return problems


VECTORS = [
    # (source, expected (w0, w1)); computed by hand from the decompiled serialiser, so they
    # guard against regressions in this file but are not independent ground truth.
    (".function t\nWI2C $0x3208, $0x00, $1\n.endfunction", [(0xA7E13208, 0)]),
    (".function t\nMOVDW R0, $15500\n.endfunction", [(0x62000060, 15500)]),
    (".function t\nDIV R8, R0, $1000\n.endfunction", [(0x22018000, 1000)]),
    (".function t\nRI2C R8, $0x3508, $1\n.endfunction", [(0xAE613508, 0x40000000)]),
    (".function t\nx:\nJEZ $0, @x\n.endfunction", [(0x76000000, 0)]),
    (".function a\nCALL @b\n.endfunction\n.function b\nMOVB R1, R2\n.endfunction",
     [(0x98000001, 0), (0x5200_0000 | (1 << 20) | (1 << 5) | 2, 0)]),
]


def selftest():
    failed = 0
    for src, want in VECTORS:
        _, words, _ = build(src)
        if words != want:
            failed += 1
            print("FAIL %r\n  want %s\n  got  %s" % (src.splitlines()[1], want, words))
    for bad_src, why in [
        (".function t\nWI2C $0x3208, $0, $40\n.endfunction", "length >= 32"),
        (".function t\nADD $1, R2, R3\n.endfunction", "first arg not a register"),
        ("MOVB R1, R2", "outside a function"),
        (".function t\nJEZ $0, @nowhere\n.endfunction", "undefined label"),
        (".function t\nMOVB R1, M0[R2]\n.endfunction", "memory operand unsupported"),
    ]:
        try:
            build(bad_src)
            failed += 1
            print("FAIL: expected an error for: %s" % why)
        except AsmError:
            pass
    print("selftest: %s" % ("FAILED (%d)" % failed if failed else "ok (%d vectors, 5 error cases)" % len(VECTORS)))
    return failed


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("asm", nargs="?", help="path to an asm_*.asm file")
    p.add_argument("--sensor-id", type=int, default=0)
    p.add_argument("--listing", action="store_true", help="print every instruction word")
    p.add_argument("--payload", metavar="OUT", help="write the 0x16EC-byte payload here")
    p.add_argument("--c-header", metavar="OUT.h", help="write the payload as a C array (for the kernel experiment)")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args()

    if args.selftest:
        return 1 if selftest() else 0
    if not args.asm:
        p.error("an .asm file is required unless --selftest is given")

    with open(args.asm, "r", encoding="ascii", errors="strict") as f:
        text = f.read()
    try:
        asm, words, compiled = build(text)
    except AsmError as e:
        print("assembly failed: %s" % e, file=sys.stderr)
        return 2

    payload = make_payload(compiled, args.sensor_id)
    print("instructions : %d (limit %d)" % (len(words), MAX_INSTRUCTIONS))
    print("functions    : %d (limit %d)" % (len(asm.funcs), MAX_FUNCTIONS))
    print("labels       : %d (limit %d)" % (len(asm.labels), MAX_LABELS))
    for i, (name, start, end) in enumerate(asm.funcs):
        print("  [%2d] %-22s insns %3d..%3d" % (i, name, start, end))
    print("compiled     : %d bytes (0x%X)" % (len(compiled), len(compiled)))
    print("payload      : %d bytes (0x%X), sensor id %d" % (len(payload), len(payload), args.sensor_id))

    if args.listing:
        for i, ((w0, w1), ins) in enumerate(zip(words, asm.insns)):
            print("%3d: %08X %08X  %s" % (i, w0, w1, fmt_insn(ins["op"], ins["linked"])))

    problems = roundtrip(asm, words)
    print("round-trip   : %s" % ("OK, all %d instructions decode back to themselves" % len(words)
                                 if not problems else "%d MISMATCHES" % problems))
    if args.payload:
        with open(args.payload, "wb") as f:
            f.write(payload)
        print("wrote %s" % args.payload)
    if args.c_header:
        if problems:
            print("refusing to write a header: round-trip failed", file=sys.stderr)
            return 1
        write_c_header(args.c_header, payload,
                       "SET_DEVICE_SCRIPT payload for asm_OV13B.asm, sensor id %d (UNVERIFIED encoding)" % args.sensor_id)
        print("wrote %s" % args.c_header)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

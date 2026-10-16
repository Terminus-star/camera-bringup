#!/usr/bin/env python3
"""Condense a Ghidra pseudo-code dump of a Windows PHY-setup function into one line per register write.

Input: the JSON file written by the rea tool (field raw_result.value holds the pseudo code).
The function builds a small descriptor on the stack before each call of FUN_14005131c (a read-modify-write
of one field of a PHY register):

    local_58 = "REGISTER_NAME";   local_50 = 0xREG;   local_48 = "FIELD_NAME";   local_40 = 0xVVMM;   FUN_14005131c(phy,&local_58);

with local_40 = (value << 16) | mask.  This script prints every call as  REG mask value  plus the names, and keeps the
if/else lines around them so the branches (data-rate dependent) stay visible.

Usage (paths as arguments, run isolated):
    python3 -I tools/decode_phy.py DUMP.json
"""

import json
import re
import sys

NAME_RE = re.compile(r'^\s*(local_\w+) = "([^"]+)";')
NUM_RE = re.compile(r'^\s*(local_\w+) = (0x[0-9a-fA-F]+|\d+);')
EXPR_RE = re.compile(r'^\s*(local_\w+) = (.+);')


def main(path):
    code = json.load(open(path))["raw_result"]["value"].splitlines()
    names = {}
    nums = {}
    exprs = {}
    out = []
    for line in code:
        s = line.strip()
        if s.startswith(("if ", "if(", "else", "} else", "}", "{")) and "FUN_14005131c" not in s:
            if s.startswith(("if", "else", "} else")):
                out.append("   " + s)
            continue
        m = NAME_RE.match(line)
        if m:
            names[m.group(1)] = m.group(2)
            continue
        m = NUM_RE.match(line)
        if m:
            nums[m.group(1)] = int(m.group(2), 0)
            exprs.pop(m.group(1), None)
            continue
        m = EXPR_RE.match(line)
        if m and m.group(1).startswith("local_"):
            exprs[m.group(1)] = m.group(2)
            nums.pop(m.group(1), None)
            continue
        if "FUN_14005131c" in s:
            arg = re.search(r'&(local_\w+)', s)
            base = arg.group(1) if arg else "local_58"
            # descriptor layout on the stack: name @ base, reg @ base+8 (local_50), field @ +0x10 (local_48), mask/value @ +0x18 (local_40)
            nm = names.get("local_58", "?")
            fl = names.get("local_48", "?")
            reg = nums.get("local_50")
            mv = nums.get("local_40")
            if mv is None and "local_40" in exprs:
                mv_s = exprs["local_40"]
            else:
                mv_s = None
            if reg is None:
                reg_s = "?"
            else:
                reg_s = "0x%04x" % reg
            if mv is not None:
                out.append("%s  %-44s %-34s mask=0x%04x value=0x%04x" % (reg_s, nm, fl, mv & 0xFFFF, (mv >> 16) & 0xFFFF))
            else:
                out.append("%s  %-44s %-34s mask/value = %s" % (reg_s, nm, fl, mv_s))
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])

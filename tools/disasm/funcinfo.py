# Usage: python3 -I funcinfo.py <pe file> <disasm.txt> <hexaddr> [<hexaddr> ...]
# For each address: find the enclosing function (bounded by int3 padding / ret),
# print start/end and every RIP-relative string it references (ASCII or UTF-16).
import re
import struct
import sys

pe_path, dis_path = sys.argv[1], sys.argv[2]
targets = [int(a, 16) for a in sys.argv[3:]]

data = open(pe_path, 'rb').read()
pe = struct.unpack_from('<I', data, 0x3c)[0]
nsec = struct.unpack_from('<H', data, pe + 6)[0]
optsz = struct.unpack_from('<H', data, pe + 20)[0]
base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
secs = []
off = pe + 24 + optsz
for i in range(nsec):
    vsz, va, rsz, rptr = struct.unpack_from('<IIII', data, off + i * 40 + 8)
    secs.append((va, max(vsz, rsz), rptr))


def va2off(v):
    r = v - base
    for va, sz, rp in secs:
        if va <= r < va + sz:
            return rp + (r - va)
    return None


def readstr(v):
    o = va2off(v)
    if o is None:
        return None
    s = data[o:o + 200]
    a = s.split(b'\0')[0]
    if len(a) >= 3 and all(32 <= c < 127 for c in a):
        return a.decode()
    if len(s) > 6 and s[1] == 0 and s[3] == 0:
        u = s.decode('utf-16le', 'ignore').split('\0')[0]
        if len(u) >= 3 and u.isprintable():
            return 'L"' + u + '"'
    return None


lines = []
line_re = re.compile(r'^([0-9a-f]+):\s+(.*)$')
for ln in open(dis_path, errors='replace'):
    m = line_re.match(ln)
    if m:
        lines.append((int(m.group(1), 16), m.group(2)))
addrs = [a for a, _ in lines]

import bisect
for t in targets:
    i = bisect.bisect_right(addrs, t) - 1
    s = i
    while s > 0 and 'int3' not in lines[s - 1][1]:
        s -= 1
    e = i
    while e + 1 < len(lines) and 'int3' not in lines[e + 1][1]:
        e += 1
    print('== target 0x%x: function 0x%x .. 0x%x' % (t, lines[s][0], lines[e][0]))
    seen = set()
    for a, txt in lines[s:e + 1]:
        for m in re.finditer(r'# 0x([0-9a-f]+)', txt):
            v = int(m.group(1), 16)
            if v in seen:
                continue
            seen.add(v)
            st = readstr(v)
            if st:
                print('   0x%x refs 0x%x: %s' % (a, v, st))

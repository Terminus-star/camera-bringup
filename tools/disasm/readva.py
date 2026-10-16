# Usage: python3 -I readva.py <pe file> s <hex VA> [...]       print the NUL-terminated ASCII string at each VA
#        python3 -I readva.py <pe file> x <nbytes> <hex VA> [...]  hex dump nbytes at each VA
#        python3 -I readva.py <pe file> q <count> <hex VA>        print count little-endian u32 words from VA
import struct
import sys

data = open(sys.argv[1], 'rb').read()
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
    raise SystemExit(f"VA {v:#x} not in any section")


mode = sys.argv[2]
if mode == 's':
    for a in sys.argv[3:]:
        o = va2off(int(a, 16))
        print(f"{a}: {data[o:data.index(b'\0', o)].decode(errors='replace')}")
elif mode == 'x':
    n = int(sys.argv[3])
    for a in sys.argv[4:]:
        o = va2off(int(a, 16))
        print(f"{a}: {data[o:o + n].hex()}")
elif mode == 'q':
    n, a = int(sys.argv[3]), sys.argv[4]
    o = va2off(int(a, 16))
    print(' '.join(f"{w:#x}" for w in struct.unpack_from(f'<{n}I', data, o)))

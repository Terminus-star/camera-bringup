# Usage: python3 -I off2va.py <pe file> <hex file offset> [...]
# Prints the virtual address for each raw file offset (via the PE section table).
import struct
import sys

data = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', data, 0x3c)[0]
nsec = struct.unpack_from('<H', data, pe + 6)[0]
optsz = struct.unpack_from('<H', data, pe + 20)[0]
base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
off = pe + 24 + optsz
for a in sys.argv[2:]:
    o = int(a, 16)
    for i in range(nsec):
        name = data[off + i * 40:off + i * 40 + 8].rstrip(b'\0').decode()
        vsz, va, rsz, rptr = struct.unpack_from('<IIII', data, off + i * 40 + 8)
        if rptr <= o < rptr + rsz:
            print('%s -> 0x%x (%s)' % (a, base + va + o - rptr, name))

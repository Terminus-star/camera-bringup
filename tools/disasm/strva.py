# Usage: python3 -I strva.py <pe file> <name> [<name> ...]
# Print the virtual address of every NUL-terminated ASCII occurrence of each name
# (exact string match, so "isp_set_scenario_mode" does not match "isp_set_scenario_mode_x").
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
    secs.append((va, rsz, rptr))

for name in sys.argv[2:]:
    # strings start after a NUL or 0xcc padding byte; they may be longer than NAME (e.g. NAME + "_wrapper")
    needle = name.encode()
    pos = data.find(needle)
    while pos >= 0:
        if pos == 0 or data[pos - 1] in (0, 0xcc):
            end = data.index(b'\0', pos)
            for va, rsz, rptr in secs:
                if rptr <= pos < rptr + rsz:
                    print(f"{name}: VA {base + va + pos - rptr:#x} full string '{data[pos:end].decode()}'")
        pos = data.find(needle, pos + 1)

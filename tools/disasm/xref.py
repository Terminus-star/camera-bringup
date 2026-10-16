# Usage: python3 -I xref.py <pe file> <hex VA> [...]
# Brute-force scan of executable sections for RIP-relative references
# (any 32-bit displacement that, taken as [rip+disp] at instruction end,
#  hits the target). Checks common encodings: lea/mov with REX (7 bytes:
#  REX 8d|8b modrm(mod=00,rm=101) disp32), plus call/jmp rel32 (e8/e9).
# Prints candidate instruction VAs; verify each with llvm-objdump.
import struct
import sys

data = open(sys.argv[1], 'rb').read()
targets = set(int(a, 16) for a in sys.argv[2:])
pe = struct.unpack_from('<I', data, 0x3c)[0]
nsec = struct.unpack_from('<H', data, pe + 6)[0]
optsz = struct.unpack_from('<H', data, pe + 20)[0]
base = struct.unpack_from('<Q', data, pe + 24 + 24)[0]
off = pe + 24 + optsz
for i in range(nsec):
    name = data[off + i * 40:off + i * 40 + 8].rstrip(b'\0').decode()
    vsz, va, rsz, rptr = struct.unpack_from('<IIII', data, off + i * 40 + 8)
    chars = struct.unpack_from('<I', data, off + i * 40 + 36)[0]
    if not chars & 0x20000000:  # IMAGE_SCN_MEM_EXECUTE
        continue
    sec = data[rptr:rptr + rsz]
    sva = base + va
    n = len(sec)
    for p in range(n - 7):
        b0, b1, b2 = sec[p], sec[p + 1], sec[p + 2]
        # REX.W lea/mov reg, [rip+disp32]
        if b0 in (0x48, 0x4c) and b1 in (0x8d, 0x8b, 0x89) and (b2 & 0xc7) == 0x05:
            disp = struct.unpack_from('<i', sec, p + 3)[0]
            t = sva + p + 7 + disp
            if t in targets:
                print('%s 0x%x -> 0x%x (lea/mov)' % (name, sva + p, t))
        # call/jmp rel32
        if b0 in (0xe8, 0xe9):
            disp = struct.unpack_from('<i', sec, p + 1)[0]
            t = sva + p + 5 + disp
            if t in targets:
                print('%s 0x%x -> 0x%x (%s)' % (name, sva + p, t,
                                               'call' if b0 == 0xe8 else 'jmp'))

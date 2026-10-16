"""Evaluate the firmware memory-pool size formula of amdcamera.sys allocate_fw_mempool_imp (0x1400320f0).

usage: python3 -I mempool_size.py [W ...]       (no argument: try a list of candidate values for W)
Transcribed from the disassembly (32-bit arithmetic, W = third argument r8d, flag = fifth argument r9b):
    A = (2*W + 0x7ffe) & 0xffff8000
    h = W >> 1
    k = 5 + (5 if flag else 0)
    B = ((h + 0x7fff) & 0xffff8000) + 0x798000
    C = (6*W + 0x1fffc) & 0xfffe0000
    D = (h + 0x1fffc) & 0xfffe0000
    T = k*A + 4*B + C + D
"""
import sys

M = 0xffffffff


def size(w, flag):
    a = (2 * w + 0x7ffe) & 0xffff8000 & M
    h = w >> 1
    k = 5 + (5 if flag else 0)
    b = (((h + 0x7fff) & 0xffff8000) + 0x798000) & M
    c = (6 * w + 0x1fffc) & 0xfffe0000 & M
    d = (h + 0x1fffc) & 0xfffe0000 & M
    return (k * a + 4 * b + c + d) & M


if len(sys.argv) > 1:
    cands = [int(x, 0) for x in sys.argv[1:]]
else:
    cands = {
        "4208x3120 pixels": 4208 * 3120,
        "4208 x 3120 / 2": 4208 * 3120 // 2,
        "3264x2448": 3264 * 2448,
        "1920x1080": 1920 * 1080,
        "2560x1440": 2560 * 1440,
        "4208": 4208, "3120": 3120, "1920": 1920, "1080": 1080,
        "RAW10 line bytes 4208*10/8": 4208 * 10 // 8,
    }
for name, w in (cands.items() if isinstance(cands, dict) else [(hex(c), c) for c in cands]):
    print(f"W={name:30} ({w:>10})  flag0 -> {size(w, 0):#012x} ({size(w, 0)/2**20:8.2f} MiB)   flag1 -> {size(w, 1):#012x} ({size(w, 1)/2**20:8.2f} MiB)")

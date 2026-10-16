"""Print the raw payload bytes of ETL events whose text matches a regex.

usage: python3 -I dump_payload.py ETL REGEX [MAX_EVENTS] [START_CLOCK]
Uses the record layout found in README.md (same as parse_etl.py): 0x48-byte buffer header,
records  u16 size | u16 marker | u16 msg_line | u16 aux | GUID(16) | u64 ts | u32 tid | u32 pid | payload.
Prints: seconds since the first event, tid, msg_line, payload length, hex of the payload.
"""
import re
import struct
import sys

BS = 262144
etl, rx = sys.argv[1], re.compile(sys.argv[2].encode())
maxn = int(sys.argv[3]) if len(sys.argv) > 3 else 50
start = int(sys.argv[4]) if len(sys.argv) > 4 else 0

d = open(etl, "rb").read()
hdr = 0x48 + 0x20
offset = struct.unpack_from("<Q", d, hdr + 0x108)[0] - struct.unpack_from("<Q", d, 0x48 + 0x10)[0]

ev = []
for b in range(1, len(d) // BS):
    base = b * BS
    saved = struct.unpack_from("<I", d, base + 4)[0]
    p, end = base + 0x48, base + min(saved, BS)
    while p + 0x28 <= end:
        size, _, mn, _ = struct.unpack_from("<HHHH", d, p)
        ts, tid, _ = struct.unpack_from("<QII", d, p + 0x18)
        ev.append((ts + offset, tid, mn, d[p + 0x28:p + size]))
        p += (size + 7) & ~7
ev.sort(key=lambda e: e[0])

t0 = ev[0][0]
n = 0
for clock, tid, mn, pl in ev:
    if clock < start or not rx.search(pl):
        continue
    print(f"{(clock - t0) / 1e7:9.4f} tid={tid} line={mn} len={len(pl)} {pl.hex()}")
    n += 1
    if n >= maxn:
        break

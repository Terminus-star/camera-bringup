"""Build a table  command name -> numeric command id  from cmd-payloads.txt (dump_payload.py output).

usage: python3 -I cmd_ids.py cmd-payloads.txt
Events with msg line 73 hold  u32 cmd_id | "CMD_ID_xxx\\0"  (OBSERVED in START_STREAM: 07000102 = 0x02010007).
"""
import re
import struct
import sys

ids = {}
for line in open(sys.argv[1]):
    m = re.match(r"\s*[\d.]+ tid=\d+ line=73 len=\d+ ([0-9a-f]+)", line)
    if not m:
        continue
    raw = bytes.fromhex(m.group(1))
    cid = struct.unpack_from("<I", raw, 0)[0]
    name = raw[4:raw.index(b"\0", 4)].decode()
    ids.setdefault(name, set()).add(cid)
for name, s in sorted(ids.items(), key=lambda kv: min(kv[1])):
    print(f"{name:42} " + " ".join(f"{c:#010x}" for c in sorted(s)))

"""Decode the SEND_BUFFER log events saved by dump_payload.py.

usage: python3 -I decode_sendbuf.py send-buffer-payloads.txt
For each line: the text after the BUFFER_TYPE_xxx string is printed as 32-bit words so the
address / size fields can be read (the exact meaning of each word is an INFERENCE).
"""
import re
import struct
import sys

for line in open(sys.argv[1]):
    m = re.match(r"\s*([\d.]+) tid=(\d+) line=(\d+) len=(\d+) ([0-9a-f]+)", line)
    if not m:
        continue
    raw = bytes.fromhex(m.group(5))
    k = raw.find(b"BUFFER_TYPE_")
    if k < 0:
        continue
    e = raw.index(b"\0", k)
    name = raw[k:e].decode()
    tail = raw[e + 1:]
    # the head holds: func name, cmd name, 4-byte cmd id?, stream, "direct"/"indirect", then u32 seq/timeout
    head = raw[:k]
    words = [f"{w:08x}" for w in struct.unpack_from("<%dI" % (len(tail) // 4), tail)]
    print(f"{m.group(1):>9} tid={m.group(2)} {name:28} tail_len={len(tail)} words={' '.join(words)}  rest={tail[len(tail)//4*4:].hex()}")

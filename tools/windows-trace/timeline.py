"""Condense events.tsv into a readable timeline of the first stream start.

usage: python3 -I timeline.py EVENTS_TSV START_CLOCK END_CLOCK [SKIP_REGEX]
Prints: seconds since START, tid, first string of the event; consecutive identical
lines are collapsed with a count.  Lines whose text matches SKIP_REGEX are dropped.
"""
import re
import sys

path, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
skip = re.compile(sys.argv[4]) if len(sys.argv) > 4 else None

prev, count = None, 0


def flush():
    if prev is not None:
        print(f"{prev[0]:9.4f} {prev[1]:>6} {prev[2]}" + (f"   x{count}" if count > 1 else ""))


with open(path) as f:
    next(f)
    for line in f:
        p = line.rstrip("\n").split("\t")
        clock = int(p[0])
        if clock < start or clock > end:
            continue
        text = p[7] if len(p) > 7 else ""
        if skip and skip.search(text):
            continue
        key = (p[1], text)
        if prev is not None and (prev[1], prev[2]) == key:
            count += 1
            continue
        flush()
        prev, count = ((clock - start) / 1e7, p[1], text[:230]), 1
flush()

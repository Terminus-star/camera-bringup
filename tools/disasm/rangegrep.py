# Usage: python3 -I rangegrep.py <disasm.txt> <start hex> <end hex> <regex>
# Prints disassembly lines in [start,end] matching regex.
import re, sys
p, s, e, rg = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), re.compile(sys.argv[4])
rx = re.compile(r'^([0-9a-f]+):')
for ln in open(p, errors='replace'):
    m = rx.match(ln)
    if not m:
        continue
    a = int(m.group(1), 16)
    if a < s:
        continue
    if a > e:
        break
    if rg.search(ln):
        print(ln.rstrip()[:115])

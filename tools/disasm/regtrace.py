# Usage: python3 -I regtrace.py <disasm.txt> <start hex> <end hex>
# Lists ISP register accesses (calls to 0x140001320 = read, 0x1400014b8 = write)
# inside [start,end] with the most recent immediates loaded into ecx/edx/edi/esi/ebx
# (heuristic: shows the instruction text that set rcx and rdx last).
import re
import sys

path, s, e = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
rx = re.compile(r'^([0-9a-f]+):\s+(.*)$')
last = {}
for ln in open(path, errors='replace'):
    m = rx.match(ln)
    if not m:
        continue
    a = int(m.group(1), 16)
    if a < s:
        continue
    if a > e:
        break
    t = m.group(2).strip()
    mm = re.match(r'(movl|movq|movabsq|leaq|leal|xorl|movzbl|movzwl|orl|andl|shll|addl|subl|movslq)\s+(.*)', t)
    if mm:
        ops = mm.group(2).split('#')[0].strip()
        dst = ops.split(',')[-1].strip()
        last[dst] = '%x: %s' % (a, t[:70])
    if 'callq' in t and ('0x140001320' in t or '0x1400014b8' in t):
        kind = 'READ ' if '0x140001320' in t else 'WRITE'
        print('%x %s rcx<=[%s] | rdx<=[%s]' % (a, kind,
              last.get('%ecx') or last.get('%rcx'), last.get('%edx') or last.get('%rdx')))

#!/usr/bin/env python3
"""Parse WPP message-trace events from an ETL file (stdlib only).
usage: python3 -I parse_etl.py <in.etl> <summary.txt> <outdir>
"""
import struct, sys, uuid, re, collections, os

BS = 262144
CLOCK_OFFSET = None  # derived below from the Header event (StartTime - StartPerfClock)

def esc(s):
    return s.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')

def strings_of(pl):
    out = []
    mask = bytearray(pl)
    # UTF-16LE runs (printable char + 00), both alignments, >=3 chars
    for m in re.finditer(rb'(?:[\x20-\x7e]\x00){3,}', pl):
        out.append((m.start(), m.group().decode('utf-16le')))
        for i in range(m.start(), m.end()):
            mask[i] = 0
    for m in re.finditer(rb'[\x20-\x7e]{3,}', bytes(mask)):
        out.append((m.start(), m.group().decode('ascii')))
    out.sort()
    return [s for _, s in out]

def main(etl, summary, outdir):
    d = open(etl, 'rb').read()
    nbuf = len(d) // BS
    # Header event in buffer 0: record at 0x48; payload (TRACE_LOGFILE_HEADER) at +0x20
    hdr = 0x48 + 0x20
    start_time = struct.unpack_from('<Q', d, hdr + 0x108)[0]  # StartTime (FILETIME)
    # event timestamp of the Header event itself is its StartPerfClock-equivalent
    hts = struct.unpack_from('<Q', d, 0x48 + 0x10)[0]
    offset = start_time - hts
    ev = []
    for b in range(1, nbuf):
        base = b * BS
        bsz, saved, cur = struct.unpack_from('<III', d, base)
        cpu, logger = struct.unpack_from('<HH', d, base + 0x28)
        p = base + 0x48
        end = base + min(saved, BS)
        while p + 0x28 <= end:
            size, marker, mn, aux = struct.unpack_from('<HHHH', d, p)
            if size < 0x28:
                raise SystemExit('bad record size %d at buf %d off %#x' % (size, b, p - base))
            guid = str(uuid.UUID(bytes_le=d[p+8:p+24]))
            ts, tid, pid = struct.unpack_from('<QII', d, p + 0x18)
            pl = d[p+0x28:p+size]
            ev.append((ts, b, p, mn, guid, tid, pid, cpu, pl, marker, aux))
            p += (size + 7) & ~7
    ev.sort(key=lambda e: (e[0], e[1], e[2]))
    os.makedirs(outdir, exist_ok=True)
    cnt = collections.Counter(e[4] for e in ev)
    uniq = {}
    first_str = {}
    with open(os.path.join(outdir, 'events.tsv'), 'w') as f:
        f.write('clock\ttid\tpid\tcpu\tguid\tmsg_line\tpayload_len\tstrings\n')
        for ts, b, p, mn, g, tid, pid, cpu, pl, mk, aux in ev:
            clock = ts + offset
            ss = strings_of(pl)
            sj = ' | '.join(esc(s) for s in ss)
            f.write('%d\t%d\t%d\t%d\t%s\t%d\t%d\t%s\n' % (clock, tid, pid, cpu, g, mn, len(pl), sj))
            u = uniq.setdefault((g, mn), [0, clock, []])
            u[0] += 1
            if len(u[2]) < 3 and sj not in u[2]:
                u[2].append(sj)
            for s in ss:
                first_str.setdefault(s, clock)
    with open(os.path.join(outdir, 'unique-messages.tsv'), 'w') as f:
        f.write('guid\tmsg_line\tcount\tfirst_clock\tsample1\tsample2\tsample3\n')
        for (g, mn) in sorted(uniq):
            c, fc, sm = uniq[(g, mn)]
            sm = sm + [''] * (3 - len(sm))
            f.write('%s\t%d\t%d\t%d\t%s\t%s\t%s\n' % (g, mn, c, fc, sm[0], sm[1], sm[2]))
    # strings by first occurrence
    with open(os.path.join(outdir, 'all-strings-first-seen.tsv'), 'w') as f:
        f.write('first_clock\tstring\n')
        for s, c in sorted(first_str.items(), key=lambda kv: kv[1]):
            f.write('%d\t%s\n' % (c, esc(s)))
    # validation
    exp = {}
    for line in open(summary, errors='replace'):
        m = re.match(r'\|\s*(\d+)\s+Unknown\s.*\{([0-9a-f-]{36})\}', line)
        if m:
            exp[m.group(2)] = int(m.group(1))
    with open(os.path.join(outdir, 'validation.txt'), 'w') as f:
        f.write('clock offset (FILETIME - perf ts) = %d\n' % offset)
        ok = True
        for g in sorted(set(exp) | set(cnt), key=lambda g: -exp.get(g, 0)):
            r = 'OK' if exp.get(g) == cnt.get(g, 0) else 'MISMATCH'
            ok &= r == 'OK'
            f.write('%s parsed=%d expected=%s %s\n' % (g, cnt.get(g, 0), exp.get(g), r))
        f.write('total parsed=%d expected=%d\n' % (len(ev), sum(exp.values())))
        f.write('ALL OK\n' if ok else 'SOME MISMATCH\n')
        f.write('first events: %s\n' % [(e[3], e[0] + offset, e[5], e[7]) for e in ev[:3]])

main(*sys.argv[1:4])

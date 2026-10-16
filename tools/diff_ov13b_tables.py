"""Compare the Windows OV13B mode-0 init table (findings.md, section 3) with the Linux ov13b10 driver's
4208x3120 register lists.

Usage:  python3 -I tools/diff_ov13b_tables.py <findings.md> <ov13b10.c>

Windows table: lines of the form "0x0103=01 0x0303=01 ..." inside the ``` block under "Mode 0 init sequence".
Linux: the entries of mipi_data_rate_1120mbps[] followed by mode_4208x3120_regs[] (the driver writes the link
frequency list first, then the mode list, so a later entry overrides an earlier one).
"""
import re
import sys


def windows_table(path):
    text = open(path, encoding="utf-8").read()
    start = text.index("### Mode 0 init sequence")
    block = text[start:].split("```")[1]
    return {int(a, 16): int(v, 16) for a, v in re.findall(r"0x([0-9A-Fa-f]{4})=([0-9A-Fa-f]{2})", block)}


def linux_array(src, name):
    m = re.search(r"static const struct ov13b10_reg %s\[\] = \{(.*?)\};" % re.escape(name), src, re.S)
    return [(int(a, 16), int(v, 16)) for a, v in re.findall(r"\{0x([0-9a-fA-F]{4}),\s*0x([0-9a-fA-F]{2})\}", m.group(1))]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    win = windows_table(sys.argv[1])
    src = open(sys.argv[2], encoding="utf-8").read()
    lin = {}
    for name in ("mipi_data_rate_1120mbps", "mode_4208x3120_regs"):
        for a, v in linux_array(src, name):
            lin[a] = v

    print("Windows entries: %d   Linux effective entries: %d" % (len(win), len(lin)))
    both = sorted(set(win) & set(lin))
    print("\nDIFFERENT VALUE (reg: windows / linux):")
    for a in both:
        if win[a] != lin[a]:
            print("  0x%04x: 0x%02x / 0x%02x" % (a, win[a], lin[a]))
    print("\nONLY IN WINDOWS (reg = value):")
    for a in sorted(set(win) - set(lin)):
        print("  0x%04x = 0x%02x" % (a, win[a]))
    print("\nONLY IN LINUX (reg = value):")
    for a in sorted(set(lin) - set(win)):
        print("  0x%04x = 0x%02x" % (a, lin[a]))


main()

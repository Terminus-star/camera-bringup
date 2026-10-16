"""Convert the three generated GZ302 headers into firmware files for /lib/firmware/amdgpu/.

usage: python3 -I tools/header_to_fw.py DRIVER_DIR OUT_DIR

Reads (all generated from Windows driver data, never shipped):
    DRIVER_DIR/isp4_ov13b_script.h       -> OUT_DIR/gz302-ov13b-script.bin       (SET_DEVICE_SCRIPT payload, 5868 bytes)
    DRIVER_DIR/isp4_ov13b_sensor_prop.h  -> OUT_DIR/gz302-ov13b-sensor-prop.bin  (SET_SENSOR_PROP payload, 360 bytes)
    DRIVER_DIR/isp4_phy_seq.h            -> OUT_DIR/gz302-ov13b-phy-seq.bin      (D-PHY receiver register operations)
The bytes are exactly the ones the driver used to compile in (patches 0012-0035), so the tested data does not change.

gz302-ov13b-phy-seq.bin layout (little-endian), read by isp4_interface.c (patch 0037):
    u32 magic 'G','Z','P','H' (0x48505a47), u32 version 1, u32 phy, u32 rate_mbps, u32 lanes, u32 count,
    then count x { u16 reg, u16 mask, u16 val, u16 kind }  (kind 0 = read-modify-write, 1 = plain write)
OUT_DIR must exist; existing files are not overwritten.
"""
import os
import re
import struct
import sys

PHY_MAGIC = 0x48505A47
PHY_VERSION = 1


def byte_array(text, name):
    m = re.search(r"static const unsigned char %s\[[A-Z0-9_]+\] = \{(.*?)\};" % name, text, re.S)
    if not m:
        sys.exit("array %s not found" % name)
    return bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", m.group(1)))


def define(text, name):
    m = re.search(r"#define %s\s+(\d+)" % name, text)
    if not m:
        sys.exit("#define %s not found" % name)
    return int(m.group(1))


def write_new(path, data):
    if os.path.exists(path):
        sys.exit("refusing to overwrite %s" % path)
    with open(path, "wb") as f:
        f.write(data)
    print("%s: %d bytes" % (path, len(data)))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    if not os.path.isdir(out):
        sys.exit("output directory does not exist: %s" % out)

    t = open(os.path.join(src, "isp4_ov13b_script.h")).read()
    script = byte_array(t, "isp4_ov13b_script")
    if len(script) != define(t, "ISP4_OV13B_SCRIPT_SIZE"):
        sys.exit("script size mismatch")

    t = open(os.path.join(src, "isp4_ov13b_sensor_prop.h")).read()
    prop = byte_array(t, "isp4_ov13b_sensor_prop")
    if len(prop) != define(t, "ISP4_OV13B_SENSOR_PROP_SIZE"):
        sys.exit("sensor prop size mismatch")

    t = open(os.path.join(src, "isp4_phy_seq.h")).read()
    kinds = {"ISP4_PHY_OP_RMW": define(t, "ISP4_PHY_OP_RMW"), "ISP4_PHY_OP_WRITE": define(t, "ISP4_PHY_OP_WRITE")}
    ops = re.findall(r"\{\s*0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+),\s*(ISP4_PHY_OP_\w+)\s*\}", t)
    if not ops:
        sys.exit("no PHY operations found")
    phy = struct.pack("<6I", PHY_MAGIC, PHY_VERSION, define(t, "ISP4_PHY_SEQ_PHY"),
                      define(t, "ISP4_PHY_SEQ_RATE_MBPS"), define(t, "ISP4_PHY_SEQ_LANES"), len(ops))
    for reg, mask, val, kind in ops:
        phy += struct.pack("<4H", int(reg, 16), int(mask, 16), int(val, 16), kinds[kind])

    write_new(os.path.join(out, "gz302-ov13b-script.bin"), script)
    write_new(os.path.join(out, "gz302-ov13b-sensor-prop.bin"), prop)
    write_new(os.path.join(out, "gz302-ov13b-phy-seq.bin"), phy)


if __name__ == "__main__":
    main()

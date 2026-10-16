# ov13b10 sensor driver for the GZ302 rear camera

`ov13b10.c` = upstream Linux 7.2.0 `drivers/media/i2c/ov13b10.c`
+ camera kernel patch 0004 (I2C device id `ov13b10`, needed because the AMD ISP platform glue creates the sensor as
  a plain I2C client)
+ `patches/0001-media-ov13b10-gz302-dmi-quirk.patch`: on the ASUS ROG Flow Z13 GZ302 (DMI vendor
  "ASUSTeK COMPUTER INC.", board "GZ302..."), in the 4208x3120 mode, write the Windows driver's values after the
  normal tables and controls, while still in standby: 24 MHz PLL (0x0303=01, 0x0305=46, 0x0325=55), the vertical
  window offset 0x3813=08 (fixes the magenta cast on the AMD ISP), 0x3600=1a, 0x380f=94, 0x3011=7c, 0x3774=2d,
  0x3823=18, 0x3827=01 (findings sections 58, 59, 88-90).

These values used to be written by the capture driver over raw I2C after stream-on (`sensor_pll=3`, patch 0033);
since patch 0036 the capture driver no longer does that by default.

Parameter (writable at run time in `/sys/module/ov13b10/parameters/gz302_fixups`, takes effect at the next stream
start): `gz302_fixups` = -1 auto via DMI (default), 0 off, 1 force.  To experiment with the old path, load with
`gz302_fixups=0` and the capture driver with `sensor_pll=3`.

Build: `./scripts/build-ov13b10.sh` (against the 7.2.0-1.7 headers). Nothing is installed.

Load for a test (not covered by the temporary sudo rule, run it yourself):

    sudo rmmod amd_isp4_capture
    sudo rmmod ov13b10
    sudo insmod sensor/ov13b10.ko

Base copy for the patch: `scratch/isp4-threshold/base-ov13b10/ov13b10.c` (= 7.2.0 + 0004, identical to the
`.orig` in the camera kernel's build tree).

# Pristine base files (CachyOS 7.2.0-1)

Unmodified copies of the kernel source files the camera patches change, from the CachyOS
`cachyos-7.2.0-1` tarball, under their kernel paths. The out-of-tree sources in `driver/` and
`sensor/` started from exactly these files, so:

- `scripts/make-capture-squash.sh` makes patch 0007 as the difference between this
  `drivers/media/platform/amd/isp4/` and `driver/` (then `scripts/refresh-patch.sh` rebases it onto
  the current CachyOS kernel), and
- `scripts/make-series.sh` uses them as the "base" tree for its tests.

Do not edit these files; they are GPL-2.0 Linux kernel source.

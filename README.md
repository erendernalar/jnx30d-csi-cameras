# CSI cameras on Jetson Xavier NX + Auvidea JNX30D

Native V4L2 drivers and device-tree overlays for two Raspberry-Pi-format CSI cameras on an
**NVIDIA Jetson Xavier NX** in an **Auvidea JNX30D** carrier, running **JetPack 5.1.x / L4T R35**
with NVIDIA's stock device tree (no Auvidea BSP needed):

| Folder | Camera | Sensor | Output | Validated |
|---|---|---|---|---|
| [`ov5647/`](ov5647/) | Raspberry Pi Camera v1.3 | OV5647, 5 MP colour | BG10 up to 2592x1944, Argus/GStreamer (ISP) | detection, raw capture, test pattern, Argus JPEG |
| [`ov9281/`](ov9281/) | Arducam UC-788 Rev.B | OV9281, 1 MP mono global shutter | 1280x800 10-bit at 60 fps | 1800/1800 frames at 60.3 fps, exposure, gain, 20 restart cycles |
| [`viewer/`](viewer/) | either | | live view window on the Jetson desktop, snapshot, MP4 recording | |

Tested on: Xavier NX (P3668-0001) on JNX30D, L4T R35.6.4, kernel 5.10.216-tegra, camera on **J10**,
Auvidea-style 22-pin (0.5 mm) to 15-pin (1.0 mm) flex cable.

## What makes the JNX30D different (read this first)

These are the things that kept the cameras from working, found on real hardware:

1. **Camera power enable = module pin 206 = `PR.00` (gpio 136), and on our board it is HIGH = on.**
   The JNX30D manual describes an inverter (LOW = on); it did not hold on our board
   (chip ID answers only with PR.00 HIGH). After boot PR.00 is a pulled-down input, so the camera is
   **off** until a driver drives the pin. An `i2cdetect` scan with nothing driving PR.00 finds
   nothing, even with a perfectly good camera. `scripts/20-i2c-chipid-probe.sh` tests both levels
   and tells you which one your board needs.
2. **No camera I2C mux.** J10 is on `i2c-2` (`/i2c@3180000`, CAM_I2C), J5 on `i2c-1`
   (`/i2c@c240000`). Overlays written for the NVIDIA devkit (camera on mux bus 9/10, power on
   PP.04/PP.05) cannot work on this board.
3. **The cable must be seated correctly at both ends.** A cable that is in the wrong way up gives exactly the same "no
   ACK" (-121) as a missing power enable. Once one camera works, keep the cable as it is.
4. **OV9281 line length (HTS) counts 2-pixel units.** NVIDIA's stock value 0x02d8 is correct (60 fps);
   "fixing" it to 1456 halves the frame rate.

## Quick start

On the Jetson :

```bash
sudo apt install nvidia-l4t-kernel-headers device-tree-compiler i2c-tools v4l-utils python3-numpy
cd ov5647        # or: cd ov9281
sudo scripts/20-i2c-chipid-probe.sh 2            # must print "... identified. PR.00 HIGH = camera on"
sudo scripts/30-build-install-driver.sh install  # builds against your kernel headers
sudo scripts/40-deploy-dt.sh j10 --set-default   # new extlinux entry + backup
sudo reboot
scripts/50-verify.sh                             # probe, /dev/video0, media graph
scripts/60-capture.sh                            # real frames -> PNG
```

Then optionally the desktop viewer: `viewer/install.sh` → "Drone Camera" in the app menu.

What the install changes, and nothing else:
- the module goes to `/lib/modules/$(uname -r)/updates/` (the stock modules stay)
- a merged DTB goes to `/boot/dtb/kernel_<board>-<camera>-j10.dtb` (the stock DTB stays)
- `/boot/extlinux/extlinux.conf` gets a new `LABEL` and `DEFAULT` points to it; `primary` stays
- backups go to `/boot/<camera>-backup-<timestamp>/`

## Switching cameras / uninstall

Only one camera setup can be active on J10. To switch:

```bash
sudo <old>/scripts/99-rollback.sh                 # restores extlinux.conf, removes module
sudo <new>/scripts/30-build-install-driver.sh install
sudo <new>/scripts/40-deploy-dt.sh j10 --set-default
sudo reboot
```

`99-rollback.sh` + reboot alone returns the board to stock. If a board ever fails to boot, pick
`primary` in the extlinux menu on the serial console (ttyTCU0, 115200).

## Limitations

- Only **J10** is validated. `ov9281/dts/*-j5.dts` (J5 = CSI-C, i2c-1) is prepared but untested.
- Xavier NX + L4T R35 only (Tegra194 GPIO numbers and DT labels). Orin/Nano need different overlays.
- OV9281 is monochrome; R35 has no Y10 path, so it appears as `BG10`. Use raw capture, not Argus.
- OV5647 colour through Argus uses a generic ISP tuning (colour cast possible); see the
  upstream project's `isp/` overrides.

## Credits and licence

- `ov5647/driver` is [akandr/ov5647-jetson](https://github.com/akandr/ov5647-jetson)
  (Artur Andrzejczak, GPL-2.0, register tables from the mainline `ov5647.c`) plus a small patch
  (`ov5647/driver/0001-*.patch`). The commit it is based on is listed in `ov5647/UPSTREAM.md`.
- `ov9281/driver` is NVIDIA's `nv_ov9281.c` from the L4T R35.6.4 kernel sources (GPL-2.0) plus a
  small patch (`ov9281/driver/0001-*.patch`); the stock files are in `ov9281/upstream-r35.6.4/`.
- Overlays follow NVIDIA's public p3668 camera device trees.

Licensed under **GPL-2.0** (see `LICENSE`), the same as the drivers it builds on. No warranty:
this changes the boot configuration of your board; keep the rollback steps at hand.

# Arducam UC-788 Rev.B (OV9281) on JNX30D J10

The UC-788 Rev.B is a bare OV9281 module in Raspberry Pi format (no Arducam "Jetvariety" MCU),
so it does not work with Arducam's Jetson drivers. It works with NVIDIA's own
`nv_ov9281` driver from the L4T R35 kernel sources, with a small patch and a JNX30D overlay.

## Result on hardware (L4T R35.6.4)

| Test | Result |
|---|---|
| Probe | `OV9281 chip ID 0x9281 verified`, `/dev/video0` = `vi-output, ov9281 2-0060` |
| Format | 1280x800 `BG10` (mono data; R35 has no Y10 path), stride 2560 |
| Frame rate | **60.3 fps**, 1800/1800 frames |
| Exposure / gain | image brightness follows both controls |
| Test pattern (0x5e00 = 0x80) | bars bit-exact, no line shear |
| Restarts | 20/20 stream start/stop cycles |
| Kernel log | no NVCSI/VI errors |

## Driver changes (`driver/0001-nv_ov9281-jnx30d-uc788.patch`)

Against the stock R35.6.4 `nv_ov9281.c` (copies in `upstream-r35.6.4/`); the mode table is unchanged.

| Change | Why |
|---|---|
| gain range 0x10..0xFF (was 0x01..0x1FFF) | analog gain is register 0x3509 only, 0x10 = 1x |
| default clock 24 MHz (was 26 MHz) | the UC-788 runs from its own 24 MHz oscillator |
| `test_pattern` module parameter (writes 0x5e00 at stream start) | link test without optics; replaces a compile-time `#ifdef` |
| power-off via regulator sets `SWITCH_OFF` + 1 ms delay | the stock code left the state "on" after power-off |
| logs `OV9281 chip ID 0x9281 verified` | identification, not just an I2C ACK |

## Overlay (`dts/tegra194-p3668-jnx30d-ov9281-j10.dts`)

| Fragment | Purpose |
|---|---|
| 0 | `regulator-fixed` "ov9281-cam-en" on `<&tegra_main_gpio 136 0>`, `enable-active-high` (PR.00 HIGH = on, measured), 20 ms startup delay |
| 1–3 | disable the devkit `/cam_i2cmux` and the stock IMX219 nodes |
| 4 | sensor `ov9281_a@60` on `&cam_i2c` (i2c-2): `serial_a`, 2 lanes, continuous clock, BGGR 10-bit, `line_length 1456` / `pix_clk_hz 160000000` (9.1 µs line, 60 fps), `mclk_khz 24000`. The required `mclk` clock entry only satisfies the driver; J10 carries no clock |
| 5–10 | graph: sensor → NVCSI channel 0 → VI port 0; channel 1 disabled |
| 11–14 | `tegra-camera-platform` module0 = `ov9281 2-0060`, module1 disabled |

`dts/...-j5.dts` is the same for J5 (CSI-C, i2c-1, `serial_c`, port-index 2) and is **untested**.

## Scripts (`scripts/`)

Same set as `ov5647/` (`00` inspect, `20` probe, `30` build/install, `40` deploy, `50` verify,
`60` capture, `99` rollback), plus:

| Script | What it does |
|---|---|
| `70-validate.sh [restarts]` | exposure/gain sweeps, test pattern shear check, restart cycles, 1800-frame run, kernel-log check → `validation/<ts>/validation-report.txt` |
| `raw10_tool.py` | RAW10-in-16-bit frame info, PNG, shear check, per-frame series |

## Usage

```bash
# 30 frames, gain 16 = 1x (0x3509), coarse_time = exposure lines * 16 (line = 9.1 us)
v4l2-ctl -d /dev/video0 --set-fmt-video=width=1280,height=800,pixelformat=BG10 \
  --set-ctrl=bypass_mode=0,override_enable=1,gain=32,coarse_time=10896 \
  --stream-mmap --stream-count=30 --stream-to=frames.raw
# 15 s MP4 (grey): raw to disk, then encode
v4l2-ctl ... --stream-count=900 --stream-to=video.raw
gst-launch-1.0 filesrc location=video.raw ! rawvideoparse format=gray16-le width=1280 height=800 framerate=60/1 \
  ! videoconvert ! video/x-raw,format=I420 ! x264enc ! h264parse ! mp4mux ! filesink location=video.mp4
```

`override_enable=1` is needed; otherwise the mode table overwrites gain/exposure at stream start.
Samples are 10-bit in the top bits of each 16-bit word (low bits replicate the top bits).

## Troubleshooting

| Symptom | Check |
|---|---|
| `Failed to read chip ID` / -121 | camera not powered / not connected: run `20-i2c-chipid-probe.sh` with the overlay not active; reseat or flip the cable |
| probe says "LOW = camera on" | your board inverts the enable: fragment 0 `gpio = <... 136 1>` and remove `enable-active-high` |
| `camera_common_regulator_get vana ERR` | regulator node missing or PR.00 owned elsewhere: `sudo cat /sys/kernel/debug/gpio` |
| frame rate about 30 instead of 60 | HTS was changed from the stock 0x02d8; it counts 2-pixel units |
| NVCSI PHY/CRC/SOT errors | cable quality, `cil_settletime`, `discontinuous_clk`; check with `test_pattern=128` |
| black image | `override_enable=1`, larger `coarse_time` / `gain` |

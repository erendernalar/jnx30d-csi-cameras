# Raspberry Pi Camera v1.3 (OV5647) on JNX30D J10

Driver: tegracam `ov5647.ko` from [akandr/ov5647-jetson](https://github.com/akandr/ov5647-jetson)
(see `UPSTREAM.md`) with one patch. Overlay: `dts/tegra194-p3668-jnx30d-ov5647-j10.dts`.

## Result on hardware (L4T R35.6.4)

- `ov5647 2-0036: OV5647 detected (chip id 0x5647)`, `/dev/video0` with 5 modes (BG10):
  2592x1944@15, 1920x1080@30, 1296x972@30, 640x480@90, 1280x720@60
- raw 1920x1080 BG10: 30/30 frames, correct size; sensor colour bars received bit-exact
- exposure and gain verified in the sensor registers (0x3500-0x3502, 0x350a/b)
- Argus: `nvarguscamerasrc ... ! nvjpegenc` produces 1920x1080 JPEGs

## Changes compared to upstream

**Driver patch** (`driver/0001-ov5647-honour-reset-gpios-active-low.patch`), generic and safe for
active-high boards:
1. honours `GPIO_ACTIVE_LOW` in `reset-gpios` (upstream drops the DT flags and always drives
   1 = on), and logs `pwdn gpio N, camera on = HIGH|LOW`
2. sets the enable line to output after `gpio_request` (upstream never sets the direction; on the
   devkit the pin is already an output, on the JNX30D PR.00 is an input after boot)

**Overlay**, compared to the upstream devkit overlay:

| Upstream (devkit) | JNX30D J10 |
|---|---|
| sensor on `cam_i2cmux` `i2c@0` (bus 9) | sensor on `&cam_i2c` = `/i2c@3180000` (bus 2), address 0x36 |
| `reset-gpios = <&tegra_main_gpio 0x7c 0>` (PP.04) | `<&tegra_main_gpio 136 0>` (PR.00, HIGH = on, measured) |
| mux and IMX219 nodes left enabled | `/cam_i2cmux`, `imx219_cam0/1`, graph channel 1, `cam_module1` disabled |
| devname `ov5647 9-0036` | `ov5647 2-0036` |
| CSI | unchanged: `serial_a`, port-index 0, 2 lanes, `discontinuous_clk "no"`, all mode timings |

No MCLK and no regulator are needed: the module has its own 25 MHz oscillator, and J10 pin 1 is
always-on 3.3 V.

## Wiring (J10 → 22/15-pin cable → camera)

JNX30D pin *n* = Raspberry-Pi-Zero 22-pin pin *23−n* (same connector, numbered from the other end).

| J10 | Signal | Module pin | Camera 15-pin |
|---|---|---|---|
| 1 | 3.3 V | – | 15 |
| 2 / 3 | CAM_I2C SDA / SCL | 215 / 213 | 14 / 13 |
| 5 | CAM LED input | – | 12 |
| 6 | camera power enable | 206 (PR.00) | 11 |
| 14/15 | CSI_A_CLK P/N | 12 / 10 | 9 / 8 |
| 17/18 | CSI_A_D1 P/N | 18 / 16 | 6 / 5 |
| 20/21 | CSI_A_D0 P/N | 6 / 4 | 3 / 2 |
| 4,7,10,13,16,19,22 | GND | – | 1,4,7,10 |

## Scripts (`scripts/`)

| Script | What it does |
|---|---|
| `00-inspect.sh` | read-only system report (versions, DT labels, I2C, GPIO, video) → `.tgz` |
| `20-i2c-chipid-probe.sh [bus] [addr]` | drives PR.00 low/high, reads chip ID, reports the enable polarity |
| `30-build-install-driver.sh [install]` | builds against installed headers, checks vermagic and symbols, installs to `updates/` |
| `40-deploy-dt.sh j10 [--set-default]` | checks base-DT labels, backs up, merges the overlay, adds an extlinux entry |
| `50-verify.sh` | post-reboot checks: DT node, module, polarity log, chip ID, `/dev/video0`, media graph |
| `60-capture.sh [mode] [frames] [exposure_us] [gain]` | raw capture → `captures/<ts>/` with stats and a colour PNG |
| `99-rollback.sh [backup]` | restores `extlinux.conf`, removes the module |
| `bayer_tool.py` | BG10 frame statistics and half-resolution debayer to PNG |

## Usage

```bash
# raw (sensor_mode 1 = 1920x1080; exposure in us, gain 16 = 1x)
v4l2-ctl -d /dev/video0 --set-ctrl=sensor_mode=1,exposure=16000,gain=16,override_enable=1 \
  --set-fmt-video=width=1920,height=1080,pixelformat=BG10 --stream-mmap --stream-count=30 --stream-to=frames.raw
# ISP / Argus
gst-launch-1.0 nvarguscamerasrc num-buffers=60 ! 'video/x-raw(memory:NVMM),width=1920,height=1080' \
  ! nvjpegenc ! multifilesink location=test.jpg
```

- 1296x972 raw needs `bytesperline=2624` in `--set-fmt-video`.
- After an Argus run, raw capture may need a rebind:
  `echo 2-0036 | sudo tee /sys/bus/i2c/drivers/ov5647/unbind /sys/bus/i2c/drivers/ov5647/bind`
- Sensor test pattern while streaming: `echo bars | sudo tee /sys/kernel/debug/ov5647-2-0036/test_pattern`
- In dim light Argus may lengthen exposure (up to the 0.5 s driver limit) and the frame rate
  drops; cap it with `nvarguscamerasrc exposuretimerange="13000 33000000"`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `error during i2c read probe (-121)` | camera not powered / not connected: run `20-i2c-chipid-probe.sh` with the driver not bound; reseat or flip the cable |
| probe says "LOW = camera on" | your board inverts the enable: use `reset-gpios = <&tegra_main_gpio 136 1>` |
| no `camera on = ...` line in dmesg | the stock/upstream module is loaded: `modinfo -n ov5647` must point to `updates/` |
| `invalid sensor chip id` | something else answers at 0x36 |
| sensor probed but no `/dev/video0` | `media-ctl -p`; VI log `cannot find remote port parent` → overlay/graph problem |
| NVCSI PHY/CRC errors, capture timeouts | cable quality; try `discontinuous_clk = "yes"`; use the test pattern |
| black raw frames | set `exposure` (it starts at the minimum) and `override_enable=1` |

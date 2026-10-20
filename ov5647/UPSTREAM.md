# Upstream

`driver/` is taken from https://github.com/akandr/ov5647-jetson at commit
`4371634a647cbb82669014f8b8e5fc72c6e95963` (`driver/` directory, GPL-2.0, Artur Andrzejczak),
with `driver/0001-ov5647-honour-reset-gpios-active-low.patch` applied.

`dts/tegra194-p3668-jnx30d-ov5647-j10.dts` is derived from that project's
`dt/xavier/tegra194-p3668-ov5647-overlay.dts`; the sensor modes are copied unchanged.

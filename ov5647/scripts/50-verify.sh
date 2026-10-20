#!/bin/bash
# Phase 7 - after rebooting into the ov5647 entry: DT, module, probe, graph.
D="$(cd "$(dirname "$0")" && pwd)"; . "$D/lib.sh"
ok()  { echo "[ OK ] $*"; }
bad() { echo "[FAIL] $*"; FAIL=1; }
FAIL=0
echo "boot: $(tr -d '\0' </proc/device-tree/model)   $(uname -r)"
grep -o 'FDT .*' /proc/cmdline >/dev/null 2>&1 || true
NODE=/proc/device-tree/i2c@3180000/rbpcv1_ov5647_a@36
[ -d $NODE ] && ok "sensor node in live DT" || bad "no $NODE in live DT (booted wrong entry?)"
[ "$(tr -d '\0' </proc/device-tree/cam_i2cmux/status 2>/dev/null)" = disabled ] && ok "devkit cam_i2cmux disabled" || bad "cam_i2cmux not disabled"
modinfo -n ov5647 2>/dev/null | grep -q updates && ok "module: $(modinfo -n ov5647)" || bad "patched ov5647.ko not installed"
lsmod | grep -q '^ov5647' && ok "ov5647 loaded" || bad "ov5647 not loaded (sudo modprobe ov5647)"
echo "---- dmesg (ov5647 / 2-0036 / vi / nvcsi) ----"
sudo dmesg | grep -i -E 'ov5647|2-0036|tegra-camrtc|vi5|nvcsi|tegra-capture' | tail -25 | sed 's/^/     /'
sudo dmesg | grep -q 'camera on = HIGH' && ok "enable polarity HIGH = on (measured)" || bad "no 'camera on = HIGH' line (old module / DT flag?)"
sudo dmesg | grep -q 'OV5647 detected (chip id 0x5647)' && ok "chip ID 0x5647 read by the driver" || bad "chip ID not read"
C=$(ov5647_i2c) && ok "i2c client bound: $C" || bad "no i2c device bound to the ov5647 driver"
DEV=$(ov5647_dev) && ok "video node: $DEV" || bad "no /dev/video* with an ov5647 card name"
grep PR.00 /sys/kernel/debug/gpio 2>/dev/null | sed 's/^/     gpio: /'
if [ -n "${DEV:-}" ]; then
  v4l2-ctl -d "$DEV" --list-formats-ext | sed 's/^/     /'
  v4l2-ctl -d "$DEV" -l | grep -E 'gain|exposure|frame_rate|sensor_mode|bypass|override' | sed 's/^/     /'
fi
for m in /dev/media*; do media-ctl -d $m -p 2>/dev/null | grep -E 'entity|ov5647|nvcsi|vi-output|->|<-' | sed 's/^/     /'; done
[ $FAIL = 0 ] && echo "RESULT: detection OK - next: scripts/60-capture.sh" || echo "RESULT: problems above - see README.md (Troubleshooting)"

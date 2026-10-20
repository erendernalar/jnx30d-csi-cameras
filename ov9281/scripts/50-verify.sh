#!/bin/bash
# Phase 7 - after rebooting into the ov9281 entry: check probe, power, graph,
# and identify the video node. Read-only.   sudo ./50-verify.sh
set -u
. "$(dirname "$0")/lib.sh"
ok()   { echo "  [ OK ] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
FAIL=0

echo "1. boot / DT"
FDT=$(tr -d '\0' </proc/device-tree/nvidia,dtsfilename 2>/dev/null)
echo "     dtsfilename: $FDT"
NODE=$(ls -d /proc/device-tree/i2c@*/ov9281_a@60 2>/dev/null | head -1)
[ -n "$NODE" ] && ok "sensor node in live DT: $NODE" || bad "no ov9281_a@60 in live DT (booted wrong entry?)"
[ "$(tr -d '\0' </proc/device-tree/cam_i2cmux/status 2>/dev/null)" = disabled ] && ok "dev-kit cam_i2cmux disabled" || bad "cam_i2cmux not disabled"

echo "2. module"
modinfo -n nv_ov9281 | grep -q updates && ok "patched module selected: $(modinfo -n nv_ov9281)" || bad "stock module selected: $(modinfo -n nv_ov9281)"
lsmod | grep -q nv_ov9281 && ok "nv_ov9281 loaded" || bad "nv_ov9281 not loaded (sudo modprobe nv_ov9281)"
echo "     test_pattern param: $(cat /sys/module/nv_ov9281/parameters/test_pattern 2>/dev/null)"

echo "3. power / gpio"
for r in /sys/class/regulator/regulator.*; do
  [ "$(cat $r/name 2>/dev/null)" = ov9281-cam-en ] && { ok "regulator ov9281-cam-en: state=$(cat $r/state 2>/dev/null) users=$(cat $r/num_users 2>/dev/null)"; RFOUND=1; }
done
[ -n "${RFOUND:-}" ] || bad "regulator ov9281-cam-en not registered"
echo "     $(grep -E '\(PR\.00' /sys/kernel/debug/gpio 2>/dev/null)"

echo "4. probe (kernel log)"
dmesg | grep -i -E 'ov9281|2-0060|1-0060' | tail -20 | sed 's/^/     /'
dmesg | grep -q 'OV9281 chip ID 0x9281 verified' && ok "chip ID read = 0x9281 (identified, not just ACK)" || bad "no 'chip ID verified' line"
dmesg | grep -q -i 'ov9281.*Probed v4l2 sensor' && ok "v4l2 subdev registered" || bad "no 'Probed v4l2 sensor'"
C=$(ov9281_i2c) && ok "i2c client bound: $C" || bad "no i2c client bound to ov9281 driver"
dmesg | grep -i -E 'unable to get clock|regulator .* ERR|Read unknown chip ID|Failed to read chip ID|power on failed|error power on' | sed 's/^/     ERR /'

echo "5. video node"
DEV=$(ov9281_dev) && ok "OV9281 video node: $DEV" || bad "no /dev/video* with ov9281 card name"
if [ -n "${DEV:-}" ]; then
  v4l2-ctl -d "$DEV" --info | sed 's/^/     /'
  v4l2-ctl -d "$DEV" --list-formats-ext | sed 's/^/     /'
  v4l2-ctl -d "$DEV" --list-ctrls | grep -E 'gain|coarse|frame_length|override|bypass|height_align|sensor_modes' | sed 's/^/     /'
  for m in /dev/media*; do media-ctl -d $m -p 2>/dev/null | grep -E 'entity|ov9281|nvcsi|vi-output|->|<-' | sed 's/^/     /'; done
fi
echo
[ $FAIL = 0 ] && echo "VERIFY: PASS (registration). Next: ./60-capture.sh" || echo "VERIFY: FAIL - see README.md (Troubleshooting)"
exit $FAIL

#!/bin/bash
# Phase 1/2 - READ-ONLY inspection of the Jetson. Changes nothing.
# Run on the Jetson:  sudo ./00-inspect.sh   -> writes ./inspect-<date>/ + a .tgz
# (sudo only to read debugfs / dmesg / dump the DT; no writes outside ./inspect-*)
set -u
OUT="inspect-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
log() { echo "== $*" | tee -a "$OUT/summary.txt"; }
run() { local f="$1"; shift; { echo "\$ $*"; "$@" 2>&1; echo; } >> "$OUT/$f"; }

log "Versions"
run versions.txt cat /etc/nv_tegra_release
run versions.txt uname -a
run versions.txt cat /proc/cmdline
run versions.txt bash -c 'tr -d "\0" </proc/device-tree/model; echo'
run versions.txt bash -c 'tr -d "\0" </proc/device-tree/compatible | tr "\0" " "; echo'
run versions.txt bash -c 'tr -d "\0" </proc/device-tree/nvidia,dtsfilename 2>/dev/null; echo'
run versions.txt bash -c "dpkg -l | grep -E 'nvidia-l4t|nvidia-jetpack|auvidea' "
run versions.txt bash -c 'ls -la /boot /boot/dtb 2>/dev/null'
run versions.txt cat /boot/extlinux/extlinux.conf
run versions.txt bash -c 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL,PARTLABEL'
grep -E 'R35|REVISION' /etc/nv_tegra_release | tee -a "$OUT/summary.txt"
echo "kernel: $(uname -r)" | tee -a "$OUT/summary.txt"
echo "dtsfilename: $(tr -d '\0' </proc/device-tree/nvidia,dtsfilename 2>/dev/null)" | tee -a "$OUT/summary.txt"

log "Board files: Auvidea BSP or stock NVIDIA?"
run board.txt bash -c 'grep -ril auvidea /boot/extlinux /etc/nv* 2>/dev/null; tr -d "\0" </proc/device-tree/model | grep -i -o auvidea'
run board.txt bash -c 'strings /proc/device-tree/compatible'
run board.txt bash -c 'ls /proc/device-tree/ | grep -i -E "cam|i2c|regulator"'

log "OV5647 driver availability"
run driver.txt find /lib/modules/$(uname -r) -iname '*ov5647*'
run driver.txt bash -c 'for m in $(find /lib/modules/$(uname -r) -iname "*ov5647*.ko*"); do echo "-- $m"; modinfo "$m" | grep -E "filename|vermagic|depends|alias: of|parm|srcversion"; done'
run driver.txt bash -c 'modinfo -n ov5647 2>&1'
run driver.txt bash -c 'zcat /proc/config.gz | grep -E "OV5647|VIDEO_TEGRA|CAMERA|MODULE_SIG|MODVERSIONS|GPIO_SYSFS|I2C_CHARDEV"'
run driver.txt bash -c 'lsmod | grep -i -E "ov5647|ov9281|arducam|imx|tegra_camera|nvhost_vi"'
run driver.txt bash -c 'find /usr/src -maxdepth 1; ls -la /lib/modules/$(uname -r)/build; ls $(readlink -f /lib/modules/$(uname -r)/build)/../nvidia/include/media/camera_common.h'
run driver.txt bash -c 'ls /lib/modules/$(uname -r)/extra /lib/modules/$(uname -r)/updates 2>&1'
modinfo -n ov5647 2>/dev/null | tee -a "$OUT/summary.txt" || echo "ov5647 NOT found" | tee -a "$OUT/summary.txt"
ls -d "$(readlink -f /lib/modules/$(uname -r)/build)/../nvidia/include/media" >/dev/null 2>&1 \
  && echo "kernel headers with nvidia/include: present" | tee -a "$OUT/summary.txt" \
  || echo "kernel headers with nvidia/include: MISSING (sudo apt install nvidia-l4t-kernel-headers)" | tee -a "$OUT/summary.txt"

log "I2C buses"
run i2c.txt i2cdetect -l
run i2c.txt bash -c 'for b in /sys/bus/i2c/devices/i2c-*; do echo "$(basename $b) -> $(readlink -f $b/of_node 2>/dev/null)"; done'
run i2c.txt bash -c 'ls -la /sys/bus/i2c/devices/ | grep -E " [0-9]+-00"'
for b in 1 2; do
  echo "i2c-$b -> $(readlink -f /sys/bus/i2c/devices/i2c-$b/of_node 2>/dev/null)" | tee -a "$OUT/summary.txt"
done

log "Device tree"
if command -v dtc >/dev/null; then
  dtc -I fs -O dts -o "$OUT/active-jetson.dts" /proc/device-tree 2>/dev/null
  cp /sys/firmware/fdt "$OUT/active-jetson.dtb" 2>/dev/null
  for l in cam_i2c tegra_main_gpio bpmp tcp cam_module0 cam_module0_drivernode0 cam_module1 \
           imx219_cam0 imx219_cam1 rbpcv2_imx219_vi_in0 rbpcv2_imx219_csi_in0 rbpcv2_imx219_csi_out0 \
           rbpcv2_imx219_vi_in1 rbpcv2_imx219_csi_in1 rbpcv2_imx219_csi_out1; do
    if [ -e "/proc/device-tree/__symbols__/$l" ]; then
      echo "symbol ok   $l = $(tr -d '\0' </proc/device-tree/__symbols__/$l)"
    else
      echo "symbol MISSING $l"
    fi
  done | tee -a "$OUT/summary.txt"
  grep -n -i -E 'ov5647|ov9281|arducam|imx219_a@|imx477_a@|cam_i2cmux|regulator-.*cam' "$OUT/active-jetson.dts" > "$OUT/dt-camera-nodes.txt"
else
  echo "dtc missing: sudo apt install device-tree-compiler" | tee -a "$OUT/summary.txt"
fi

log "Camera enable pin (module 206 = soc_gpio44_pr0 = PR.00)"
run gpio.txt bash -c 'grep -E "PR\.00|PP\.04|PP\.05|PCC\.03" /sys/kernel/debug/gpio'
run gpio.txt bash -c 'grep -i -E "soc_gpio44_pr0" -A2 /sys/kernel/debug/pinctrl/*/pinmux-pins /sys/kernel/debug/pinctrl/*/pinconf-groups 2>/dev/null | head -20'
run gpio.txt bash -c 'grep -i soc_gpio44 /sys/kernel/debug/tegra_pinctrl_reg 2>/dev/null'
grep -E 'PR\.00' /sys/kernel/debug/gpio 2>/dev/null | tee -a "$OUT/summary.txt"

log "Video / camera state"
run video.txt bash -c 'ls -la /dev/video* /dev/media* /dev/v4l-subdev* 2>&1'
run video.txt bash -c 'v4l2-ctl --list-devices 2>&1'
run video.txt bash -c 'for m in /dev/media*; do media-ctl -p -d $m 2>&1; done'
run video.txt bash -c 'dmesg | grep -i -E "ov5647|ov9281|arducam|imx219|imx477|tegra-cam|nvcsi|vi5|tegra-capture|i2c|regulator" | tail -200'
run video.txt bash -c 'dpkg -l | grep -E "v4l-utils|i2c-tools|python3-numpy|python3-opencv|device-tree-compiler"'

log "System health (drone)"
run health.txt bash -c 'date; uptime; df -h /; free -m'
run health.txt bash -c 'systemctl --no-pager list-units --type=service | grep -i -E "mav|ros|camera"'

tar czf "$OUT.tgz" "$OUT"
echo
echo "Done. Send back: $(pwd)/$OUT.tgz"

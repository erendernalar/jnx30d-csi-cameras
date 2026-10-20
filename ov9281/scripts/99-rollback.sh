#!/bin/bash
# Phase 6 - rollback. Restores the extlinux.conf from a backup made by
# 40-deploy-dt.sh and removes the patched module from updates/.
#   sudo ./99-rollback.sh              # uses newest /boot/ov9281-backup-*
#   sudo ./99-rollback.sh /boot/ov9281-backup-YYYYmmdd-HHMMSS
# If the board no longer boots: on the serial console (ttyTCU0, 115200) pick
# the original LABEL in the extlinux menu, then run this script.
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
BK="${1:-$(ls -d /boot/ov9281-backup-* 2>/dev/null | sort | tail -1)}"
[ -f "$BK/extlinux.conf" ] || { echo "no backup found"; exit 1; }
cp -a /boot/extlinux/extlinux.conf "/boot/extlinux/extlinux.conf.before-rollback-$(date +%s)"
cp -a "$BK/extlinux.conf" /boot/extlinux/extlinux.conf
echo "restored extlinux.conf from $BK"
M="/lib/modules/$(uname -r)/updates/drivers/media/i2c/nv_ov9281.ko"
if [ -f "$M" ]; then rm -f "$M"; depmod -a; echo "removed patched module; now: $(modinfo -n nv_ov9281)"; fi
echo "merged DTB/dtbo left in place (/boot/dtb/*ov9281*, /boot/ov9281-*.dtbo) - harmless, delete if wanted."
echo "Reboot to complete rollback (drone disarmed, props off)."

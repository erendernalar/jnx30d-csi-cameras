#!/bin/bash
# Phase 6 - rollback: restore extlinux.conf from the backup made by
# 40-deploy-dt.sh and remove the patched module. Reboot afterwards.
#   sudo ./99-rollback.sh [/boot/ov5647-backup-YYYYmmdd-HHMMSS]
# If the board no longer boots: serial console (ttyTCU0, 115200), pick the
# original LABEL in the extlinux menu, then run this script.
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
BK="${1:-$(ls -d /boot/ov5647-backup-* 2>/dev/null | sort | tail -1)}"
[ -f "$BK/extlinux.conf" ] || { echo "no backup found"; exit 1; }
cp -a /boot/extlinux/extlinux.conf "/boot/extlinux/extlinux.conf.before-rollback-$(date +%s)"
cp -a "$BK/extlinux.conf" /boot/extlinux/extlinux.conf
echo "restored extlinux.conf from $BK"
M="/lib/modules/$(uname -r)/updates/ov5647.ko"
[ -f "$M" ] && { rm -f "$M"; depmod -a; echo "removed $M"; }
echo "merged DTB left in place (/boot/dtb/*ov5647*, /boot/ov5647-j10.dtbo) - harmless."
echo "Reboot to complete rollback (drone disarmed, props off)."

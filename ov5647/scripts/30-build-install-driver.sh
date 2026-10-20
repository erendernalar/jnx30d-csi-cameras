#!/bin/bash
# Phase 5 - build the patched ov5647.ko ON THE JETSON against the installed
# nvidia-l4t-kernel-headers and (with "install") put it in
# /lib/modules/$(uname -r)/updates/ov5647.ko (same path upstream install.sh
# uses, so its --uninstall also removes it). Nothing else is touched.
#
#   ./30-build-install-driver.sh            # build + verify only
#   sudo ./30-build-install-driver.sh install
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KREL="$(uname -r)"
case "$KREL" in 5.10.*-tegra) ;; *) echo "unexpected kernel $KREL (want 5.10.x-tegra)"; exit 1;; esac
grep -q 'R35' /etc/nv_tegra_release || { echo "not L4T R35"; exit 1; }
HDRPKG=$(dpkg-query -W -f='${Version}' nvidia-l4t-kernel-headers 2>/dev/null || true)
KPKG=$(dpkg-query -W -f='${Version}' nvidia-l4t-kernel 2>/dev/null || true)
echo "kernel pkg  : $KPKG"; echo "headers pkg : $HDRPKG"
[ -n "$HDRPKG" ] && [ "$HDRPKG" = "$KPKG" ] || { echo "headers package must match kernel package exactly (sudo apt install nvidia-l4t-kernel-headers)"; exit 1; }

BUILD="$(mktemp -d /tmp/ov5647-build.XXXX)"
cp -r "$HERE/driver/." "$BUILD/"
make -C "$BUILD" KVER="$KREL"
NEW="$BUILD/ov5647.ko"

VM_NEW=$(modinfo -F vermagic "$NEW")
REF=$(find /lib/modules/$KREL/kernel/drivers/media/i2c -name 'nv_*.ko*' | head -1)
VM_REF=$(modinfo -F vermagic "$REF")
echo "vermagic new  : $VM_NEW"
echo "vermagic stock: $VM_REF  ($REF)"
[ "$(echo $VM_NEW)" = "$(echo $VM_REF)" ] || { echo "VERMAGIC MISMATCH - not installing"; exit 1; }
echo "depends       : $(modinfo -F depends "$NEW")"
MISSING=0
for s in $(nm -u "$NEW" | awk '{print $2}' | grep -v '^__this_module$'); do
  grep -q -w "$s" /proc/kallsyms || { echo "unresolved: $s"; MISSING=1; }
done
[ $MISSING = 0 ] && echo "all symbols resolvable in running kernel" || { echo "unresolved symbols - not installing"; exit 1; }
OTHER=$(find /lib/modules/$KREL -name 'ov5647.ko*' -not -path '*/updates/*' | head -1)
[ -n "$OTHER" ] && echo "NOTE: another ov5647 module exists ($OTHER); updates/ takes priority"

if [ "${1:-}" = "install" ]; then
  [ "$(id -u)" = 0 ] || { echo "install needs sudo"; exit 1; }
  install -D -m 0644 "$NEW" "/lib/modules/$KREL/updates/ov5647.ko"
  depmod -a "$KREL"
  echo "modinfo -n ov5647 -> $(modinfo -n ov5647)"
else
  echo "built OK: $NEW   (re-run with 'install' as root to install)"
fi

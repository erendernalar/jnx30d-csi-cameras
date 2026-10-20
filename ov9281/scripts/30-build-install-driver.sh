#!/bin/bash
# Phase 5 - build the patched nv_ov9281.ko ON THE JETSON and install it to
# /lib/modules/$(uname -r)/updates/ (takes priority over the stock module,
# stock file is left untouched -> rollback = delete our file + depmod).
#
#   ./30-build-install-driver.sh            # build + verify only
#   sudo ./30-build-install-driver.sh install
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KREL="$(uname -r)"
KDIR="/lib/modules/$KREL/build"

case "$KREL" in 5.10.*-tegra) ;; *) echo "unexpected kernel $KREL (want 5.10.x-tegra)"; exit 1;; esac
grep -q 'R35' /etc/nv_tegra_release || { echo "not L4T R35"; exit 1; }
[ -d "$KDIR" ] || { echo "no $KDIR - sudo apt install nvidia-l4t-kernel-headers"; exit 1; }
HDRPKG=$(dpkg-query -W -f='${Version}' nvidia-l4t-kernel-headers 2>/dev/null || true)
KPKG=$(dpkg-query -W -f='${Version}' nvidia-l4t-kernel 2>/dev/null || true)
echo "kernel pkg  : $KPKG"
echo "headers pkg : $HDRPKG"
[ -n "$HDRPKG" ] && [ "$HDRPKG" = "$KPKG" ] || { echo "headers package must match kernel package exactly"; exit 1; }

BUILD="$(mktemp -d /tmp/ov9281-build.XXXX)"
cp "$HERE/driver/nv_ov9281.c" "$HERE/driver/ov9281_mode_tbls.h" "$HERE/driver/Makefile" "$BUILD/"
make -C "$BUILD" KDIR="$KDIR"

NEW="$BUILD/nv_ov9281.ko"
STOCK="$(find /lib/modules/$KREL/kernel -name 'nv_ov9281.ko*' | head -1)"
VM_NEW=$(modinfo -F vermagic "$NEW")
VM_RUN="$KREL SMP preempt mod_unload modversions aarch64"
echo "vermagic new  : $VM_NEW"
if [ -n "$STOCK" ]; then
  VM_STOCK=$(modinfo -F vermagic "$STOCK"); echo "vermagic stock: $VM_STOCK  ($STOCK)"
  [ "$(echo $VM_NEW)" = "$(echo $VM_STOCK)" ] || { echo "VERMAGIC MISMATCH vs stock module - not installing"; exit 1; }
else
  [ "$(echo $VM_NEW)" = "$VM_RUN" ] || { echo "VERMAGIC MISMATCH vs '$VM_RUN'"; exit 1; }
fi
echo "depends       : $(modinfo -F depends "$NEW")"
# all undefined symbols must be exported by the running kernel / loaded modules
MISSING=0
for s in $(nm -u "$NEW" | awk '{print $2}' | grep -v '^__this_module$'); do
  grep -q -w "$s" /proc/kallsyms || { echo "unresolved: $s"; MISSING=1; }
done
[ $MISSING = 0 ] && echo "all symbols resolvable in running kernel" || { echo "unresolved symbols - not installing"; exit 1; }

if [ "${1:-}" = "install" ]; then
  [ "$(id -u)" = 0 ] || { echo "install needs sudo"; exit 1; }
  install -D -m 0644 "$NEW" "/lib/modules/$KREL/updates/drivers/media/i2c/nv_ov9281.ko"
  depmod -a "$KREL"
  echo "modinfo -n now resolves to: $(modinfo -n nv_ov9281)"
  modinfo nv_ov9281 | grep -E 'filename|vermagic|parm'
else
  echo "built OK: $NEW   (re-run with 'install' as root to install)"
fi

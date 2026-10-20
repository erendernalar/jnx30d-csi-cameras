#!/bin/bash
# Phase 4/6 - build the overlay, merge it into a COPY of the base DTB the board
# boots today, and add a NEW extlinux entry "ov9281" pointing at the merged DTB.
# The existing entries/files are not modified (only DEFAULT is switched, and
# only with --set-default). No reboot is performed.
#
#   sudo ./40-deploy-dt.sh j10 [--set-default]
#   sudo ./40-deploy-dt.sh j5  [--set-default]
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CONN="${1:-j10}"
SETDEF="${2:-}"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
for t in dtc fdtoverlay fdtget python3; do command -v $t >/dev/null || { echo "missing $t (apt install device-tree-compiler python3)"; exit 1; }; done
SRC="$HERE/dts/tegra194-p3668-jnx30d-ov9281-$CONN.dts"
[ -f "$SRC" ] || { echo "no $SRC"; exit 1; }
EXT=/boot/extlinux/extlinux.conf
TS=$(date +%Y%m%d-%H%M%S)
BK="/boot/ov9281-backup-$TS"

# --- which DTB does the current DEFAULT entry boot? ---
read -r DEFLABEL CURFDT < <(python3 - "$EXT" <<'PY'
import sys,re
t=open(sys.argv[1]).read().splitlines()
d=[l.split(None,1)[1].strip() for l in t if l.strip().upper().startswith('DEFAULT')]
d=d[0] if d else ''
lab=None; fdt=''
for l in t:
    s=l.strip()
    if s.upper().startswith('LABEL'): lab=s.split(None,1)[1].strip()
    elif lab==d and s.upper().startswith('FDT'): fdt=s.split(None,1)[1].strip()
print(d, fdt or '-')
PY
)
if [ "$DEFLABEL" = "ov9281" ] || echo "$CURFDT" | grep -q ov9281; then
  echo "DEFAULT already boots the ov9281 DTB. Restore the backup extlinux.conf (or set"
  echo "DEFAULT back to the original label) and reboot before redeploying."; exit 1
fi
DTSNAME=$(tr -d '\0' </proc/device-tree/nvidia,dtsfilename 2>/dev/null | xargs basename 2>/dev/null | sed 's/\.dts$//')
if [ "$CURFDT" != "-" ]; then BASE="$CURFDT"; else BASE="/boot/dtb/kernel_${DTSNAME}.dtb"; fi
echo "extlinux DEFAULT : $DEFLABEL"
echo "running dts name : $DTSNAME"
echo "base DTB         : $BASE"
[ -f "$BASE" ] || { echo "base DTB not found - set BASE manually"; exit 1; }
if [ "$CURFDT" = "-" ]; then
  # No FDT line: bootloader uses the flashed kernel-dtb partition. Make sure the
  # rootfs copy is the same board file (compare compatible + model).
  for p in compatible model; do
    a=$(fdtget -t s "$BASE" / $p 2>/dev/null | tr -d '\n'); b=$(tr '\0' ' ' </proc/device-tree/$p | sed 's/ $//')
    [ "$a" = "$b" ] || { echo "WARNING: $p differs: file='$a' running='$b'"; echo "Refusing: base DTB is not the one running."; exit 1; }
  done
fi
for l in cam_i2c tegra_main_gpio bpmp tcp cam_module0 cam_module0_drivernode0 cam_module1 imx219_cam0 imx219_cam1 \
         rbpcv2_imx219_vi_in0 rbpcv2_imx219_csi_in0 rbpcv2_imx219_csi_out0 rbpcv2_imx219_vi_in1 rbpcv2_imx219_csi_in1 rbpcv2_imx219_csi_out1; do
  fdtget "$BASE" /__symbols__ $l >/dev/null 2>&1 || { echo "base DTB lacks label '$l' - overlay cannot apply (see docs: Auvidea BSP case)"; exit 1; }
done
echo "all required labels present in base DTB"

# --- backups ---
mkdir -p "$BK"
cp -a "$EXT" "$BK/"
cp -a "$BASE" "$BK/"
cp /sys/firmware/fdt "$BK/running.dtb"
dpkg -l | grep -E 'nvidia-l4t|nvidia-jetpack' > "$BK/packages.txt"
cp /etc/nv_tegra_release "$BK/"
echo "backup -> $BK"

# --- build + merge ---
OUTDTBO="/boot/ov9281-$CONN.dtbo"
OUTDTB="/boot/dtb/kernel_${DTSNAME:-tegra194}-ov9281-$CONN.dtb"
dtc -q -@ -I dts -O dtb -o "$OUTDTBO" "$SRC"
fdtoverlay -i "$BASE" -o "$OUTDTB" "$OUTDTBO"
NODE=$([ "$CONN" = j10 ] && echo /i2c@3180000/ov9281_a@60 || echo /i2c@c240000/ov9281_a@60)
echo "merged node $NODE compatible = $(fdtget -t s "$OUTDTB" $NODE compatible)"
echo "cam_i2cmux status = $(fdtget -t s "$OUTDTB" /cam_i2cmux status)"
echo "merged DTB -> $OUTDTB"

# --- new extlinux entry cloned from DEFAULT ---
python3 - "$EXT" "$DEFLABEL" "$OUTDTB" "$SETDEF" <<'PY'
import sys
ext,deflab,dtb,setdef=sys.argv[1:5]
lines=open(ext).read().splitlines()
blocks=[];cur=None;head=[]
for l in lines:
    if l.strip().upper().startswith('LABEL'):
        cur=[l];blocks.append(cur)
    elif cur is None: head.append(l)
    else: cur.append(l)
blocks=[b for b in blocks if b[0].split(None,1)[1].strip()!='ov9281']
src=[b for b in blocks if b[0].split(None,1)[1].strip()==deflab][0]
new=['LABEL ov9281','      MENU LABEL ov9281 camera DTB (rollback: select '+deflab+')']
for l in src[1:]:
    s=l.strip().upper()
    if s.startswith('MENU LABEL') or s.startswith('FDT') or s.startswith('OVERLAYS'): continue
    if not l.strip() or l.lstrip().startswith('#'): continue
    new.append(l)
new.append('      FDT '+dtb)
if setdef=='--set-default':
    head=['DEFAULT ov9281' if h.strip().upper().startswith('DEFAULT') else h for h in head]
out=head+sum(blocks,[])+['']+new+['']
open(ext,'w').write('\n'.join(out))
PY
echo "----- new $EXT -----"; cat "$EXT"
echo "--------------------"
if [ "$SETDEF" = "--set-default" ]; then
  echo "DEFAULT is now ov9281. Previous default '$DEFLABEL' is still listed for rollback."
else
  echo "Entry added but DEFAULT unchanged. Pick 'ov9281' on the serial console boot menu,"
  echo "or rerun with --set-default."
fi
echo "Rollback: sudo cp $BK/extlinux.conf $EXT"
echo "Do NOT reboot while the drone is armed / props on."

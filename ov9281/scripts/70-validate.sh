#!/bin/bash
# Phase 8/9 - acceptance tests. Writes validation/<date>/validation-report.txt
#   ./70-validate.sh [restarts=20]
# Point the camera at a static, evenly lit, non-saturated scene first.
set -u
D="$(cd "$(dirname "$0")" && pwd)"; . "$D/lib.sh"
R="${1:-20}"
OUT="validation/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
REP="$OUT/validation-report.txt"
T="python3 -I $D/raw10_tool.py"
DEV=$(ov9281_dev) || { echo "no ov9281 video node"; exit 1; }
say() { echo "$*" | tee -a "$REP"; }
mean10() { $T info "$1" --stride "$STRIDE" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p'; }
MARK=$(sudo dmesg | wc -l)
PASS=1

say "OV9281 / JNX30D validation  $(date)"
say "host: $(uname -r)  $(grep -o 'R35[^,]*, REVISION: [0-9.]*' /etc/nv_tegra_release)"
say "device: $DEV  i2c: $(ov9281_i2c)  module: $(modinfo -n nv_ov9281)"
v4l2-ctl -d "$DEV" --info | grep -E 'Driver name|Card type' | tee -a "$REP"

# 1. baseline capture
ov9281_capture "$DEV" "$OUT/base.raw" 30 16 10896
STRIDE=$(ov9281_stride "$DEV"); SIZE=$(ov9281_sizeimage "$DEV")
N=$(( $(stat -c %s "$OUT/base.raw") / SIZE ))
say "[1] baseline: frames $N/30, $(ov9281_fps "$OUT/base.raw.log"), stride $STRIDE, sizeimage $SIZE"
$T info "$OUT/base.raw" --stride "$STRIDE" | tee -a "$REP"
$T png "$OUT/base.raw" "$OUT/base.png" --stride "$STRIDE" --stretch | tee -a "$REP"
[ "$N" = 30 ] || PASS=0

# 2. exposure sweep (gain 1x): mean must rise until saturation
say "[2] exposure sweep (coarse_time = lines*16, line = 9.1 us)"
PREV=-1; MONO=1
for L in 50 100 200 400 800 1600; do
  ov9281_capture "$DEV" "$OUT/exp$L.raw" 4 16 $((L*16))
  M=$(mean10 "$OUT/exp$L.raw"); say "    lines=$L (~$((L*91/10)) us) mean10=$M"
  python3 -c "import sys; p,m=float(sys.argv[1]),float(sys.argv[2]); sys.exit(0 if (p<0 or m>p*1.05 or m>1000) else 1)" "$PREV" "$M" || MONO=0
  PREV=$M
done
[ $MONO = 1 ] && say "    exposure: RESPONDS" || { say "    exposure: NOT MONOTONIC"; PASS=0; }

# 3. gain sweep at short exposure
say "[3] gain sweep (0x3509, 16 = 1x)"
PREV=-1; MONO=1
for G in 16 32 64 128 248; do
  ov9281_capture "$DEV" "$OUT/gain$G.raw" 4 "$G" 1600
  M=$(mean10 "$OUT/gain$G.raw"); say "    gain=$G mean10=$M"
  python3 -c "import sys; p,m=float(sys.argv[1]),float(sys.argv[2]); sys.exit(0 if (p<0 or m>p*1.05 or m>1000) else 1)" "$PREV" "$M" || MONO=0
  PREV=$M
done
[ $MONO = 1 ] && say "    gain: RESPONDS" || { say "    gain: NOT MONOTONIC"; PASS=0; }

# 4. sensor test pattern (no optics involved) - must be shear-free
say "[4] test pattern 0x80 (colour bar -> grey bars)"
echo 128 | sudo tee /sys/module/nv_ov9281/parameters/test_pattern >/dev/null
ov9281_capture "$DEV" "$OUT/tpg.raw" 4 16 10896
echo 0 | sudo tee /sys/module/nv_ov9281/parameters/test_pattern >/dev/null
$T png "$OUT/tpg.raw" "$OUT/tpg.png" --stride "$STRIDE" | tee -a "$REP"
$T shear "$OUT/tpg.raw" --stride "$STRIDE" | tee -a "$REP"
grep -q 'SHEAR: NONE' "$REP" || PASS=0

# 5. restart stability
say "[5] $R stream start/stop cycles x 30 frames"
FAILS=0
for i in $(seq 1 "$R"); do
  ov9281_capture "$DEV" "$OUT/rs.raw" 30 16 10896 || FAILS=$((FAILS+1))
  n=$(( $(stat -c %s "$OUT/rs.raw") / SIZE )); [ "$n" = 30 ] || FAILS=$((FAILS+1))
done
rm -f "$OUT/rs.raw"
say "    failed cycles: $FAILS / $R"; [ $FAILS = 0 ] || PASS=0

# 6. long run
say "[6] long run 1800 frames (not stored; ~30 s)"
ov9281_capture "$DEV" /dev/null 1800 16 10896 "$OUT/long.log"  # verbose: one dqbuf line per frame
n=$(grep -c 'dqbuf' "$OUT/long.log"); [ "$n" -gt 0 ] || n=$(tr -cd '<' < "$OUT/long.log" | wc -c)
S0=$(grep -o 'ts: [0-9.]*' "$OUT/long.log" | head -1 | cut -d' ' -f2); S1=$(grep -o 'ts: [0-9.]*' "$OUT/long.log" | tail -1 | cut -d' ' -f2)
FPS=$(python3 -c "import sys;a,b,n=map(float,sys.argv[1:]);print(f'{(n-1)/(b-a):.1f} fps' if b>a else '?')" "${S0:-0}" "${S1:-0}" "$n")
say "    frames dequeued $n/1800, $FPS (from buffer timestamps)"
[ "$n" -ge 1800 ] || PASS=0

# 7. kernel log during the run
say "[7] kernel log (new lines matching errors)"
sudo dmesg | tail -n +$((MARK+1)) | grep -i -E 'err|fail|timeout|uncorr|discard|mismatch' | tee "$OUT/dmesg-errors.txt" | head -20 | tee -a "$REP"
E=$(wc -l < "$OUT/dmesg-errors.txt"); say "    error lines: $E"; [ "$E" = 0 ] || PASS=0

say ""
[ $PASS = 1 ] && say "RESULT: PASS" || say "RESULT: FAIL (see items above)"
say "images: $OUT/base.png $OUT/tpg.png"

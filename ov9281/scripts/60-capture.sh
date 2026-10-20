#!/bin/bash
# Phase 8 - capture raw 1280x800 RAW10 frames to disk and render one.
#   ./60-capture.sh [outdir] [frames=30] [gain=16] [coarse=10896]
set -u
D="$(cd "$(dirname "$0")" && pwd)"; . "$D/lib.sh"
OUT="${1:-captures/$(date +%Y%m%d-%H%M%S)}"; N="${2:-30}"; G="${3:-16}"; C="${4:-10896}"
mkdir -p "$OUT"
DEV=$(ov9281_dev) || { echo "no ov9281 video node - run 50-verify.sh"; exit 1; }
echo "device $DEV"
MARK=$(sudo dmesg | wc -l)                        # only report log lines from this run
ov9281_capture "$DEV" "$OUT/frames.raw" "$N" "$G" "$C"; RC=$?
STRIDE=$(ov9281_stride "$DEV"); SIZE=$(ov9281_sizeimage "$DEV")
GOT=$(( $(stat -c %s "$OUT/frames.raw" 2>/dev/null || echo 0) / ${SIZE:-1} ))
echo "v4l2-ctl rc=$RC  stride=$STRIDE  sizeimage=$SIZE  frames written=$GOT/$N  rate=$(ov9281_fps "$OUT/frames.raw.log")"
python3 -I "$D/raw10_tool.py" info   "$OUT/frames.raw" --stride "$STRIDE"
python3 -I "$D/raw10_tool.py" series "$OUT/frames.raw" --stride "$STRIDE"
python3 -I "$D/raw10_tool.py" png    "$OUT/frames.raw" "$OUT/last.png" --stride "$STRIDE" --stretch
sudo dmesg | tail -n +$((MARK+1)) | grep -i -E 'ov9281|nvcsi|vi5|capture|uncorr|err|timeout|discard|corr' | tee "$OUT/dmesg.txt" | tail -20
[ $RC = 0 ] && [ "$GOT" = "$N" ] && echo "CAPTURE: OK ($OUT)" || echo "CAPTURE: FAIL ($OUT)"

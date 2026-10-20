#!/bin/bash
# Phase 8 - capture real BG10 frames and convert the last one to a colour PNG.
#   ./60-capture.sh [mode=1] [frames=30] [exposure_us=16000] [gain=16]
D="$(cd "$(dirname "$0")" && pwd)"; . "$D/lib.sh"
MODE=${1:-1}; N=${2:-30}; EXP=${3:-16000}; GAIN=${4:-16}
DEV=$(ov5647_dev) || { echo "no ov5647 video node - run 50-verify.sh"; exit 1; }
OUT="captures/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
read -r W H < <(ov5647_wh "$MODE")
MARK=$(sudo dmesg | wc -l)
echo "capturing $N frames, mode $MODE (${W}x${H}), exposure ${EXP}us, gain $GAIN from $DEV"
ov5647_capture "$DEV" "$OUT/frames.raw" "$MODE" "$N" "$EXP" "$GAIN"; rc=$?
STRIDE=$(ov5647_stride "$DEV")
echo "v4l2-ctl rc=$rc  stride=$STRIDE  file=$(stat -c %s "$OUT/frames.raw" 2>/dev/null) bytes  $(ov5647_fps "$OUT/frames.raw.log")"
tail -3 "$OUT/frames.raw.log"
python3 -I "$D/bayer_tool.py" info "$OUT/frames.raw" --w "$W" --h "$H" --stride "$STRIDE" | tee "$OUT/info.txt" | tail -6
python3 -I "$D/bayer_tool.py" png "$OUT/frames.raw" "$OUT/last.png" --w "$W" --h "$H" --stride "$STRIDE" --wb
echo "---- new kernel messages ----"
sudo dmesg | tail -n +$((MARK+1)) | grep -i -E 'ov5647|nvcsi|vi5|err|fail|timeout|discard' | tail -20
echo "output: $OUT"

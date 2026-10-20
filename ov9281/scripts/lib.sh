# shared helpers (sourced)
# find the /dev/videoN whose VI card name references the ov9281 subdev
ov9281_dev() {
  local d
  for d in /dev/video*; do
    if v4l2-ctl -d "$d" --info 2>/dev/null | grep -q -E 'Card type *:.*ov9281'; then
      echo "$d"; return 0
    fi
  done
  return 1
}
ov9281_i2c() {   # prints e.g. 2-0060
  local p
  for p in /sys/bus/i2c/drivers/ov9281/*-0060; do [ -e "$p" ] && { basename "$p"; return 0; }; done
  return 1
}

# capture DEV OUTFILE NFRAMES GAIN COARSE [LOG] -> raw file, v4l2-ctl log (default OUTFILE.log)
# GAIN   : 16..255   (0x3509, 16 = 1x)
# COARSE : exposure in 1/16-line units (0x3500-0x3502); lines = COARSE/16,
#          line time = 1456 px / 160 MHz = 9.1 us (measured 60 fps at VTS 1820)
#          (e.g. 10896 -> 681 lines -> 6.2 ms)
# override_enable=1 makes the driver re-apply gain/exposure/frame-length at
# stream-on (otherwise the mode table's defaults overwrite them).
ov9281_capture() {
  local dev=$1 out=$2 n=$3 gain=$4 coarse=$5 log=${6:-$2.log} fourcc
  fourcc=$(v4l2-ctl -d "$dev" --list-formats | sed -n "s/.*'\(..10\)'.*/\1/p" | head -1)
  [ -n "$fourcc" ] || { echo "no 10-bit format on $dev"; return 1; }
  v4l2-ctl -d "$dev" \
    --set-fmt-video=width=1280,height=800,pixelformat="$fourcc" \
    --set-ctrl=bypass_mode=0,override_enable=1,gain="$gain",coarse_time="$coarse" \
    --stream-mmap=4 --stream-count="$n" --stream-to="$out" --verbose > "$log" 2>&1
  local rc=$?
  v4l2-ctl -d "$dev" --get-fmt-video >> "$log" 2>&1
  return $rc
}
ov9281_sizeimage() { v4l2-ctl -d "$1" --get-fmt-video | sed -n 's/.*Size Image *: *\([0-9]*\).*/\1/p'; }
ov9281_stride()    { v4l2-ctl -d "$1" --get-fmt-video | sed -n 's/.*Bytes per Line *: *\([0-9]*\).*/\1/p'; }
ov9281_fps()       { grep -o '[0-9.]* fps' "$1" | tail -1; }

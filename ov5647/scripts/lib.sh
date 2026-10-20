# shared helpers (sourced)
ov5647_dev() {   # /dev/videoN whose VI card name references the ov5647 subdev
  local d
  for d in /dev/video*; do
    v4l2-ctl -d "$d" --info 2>/dev/null | grep -q -E 'Card type *:.*ov5647' && { echo "$d"; return 0; }
  done
  return 1
}
ov5647_i2c() { local p; for p in /sys/bus/i2c/drivers/ov5647/*-0036; do [ -e "$p" ] && { basename "$p"; return 0; }; done; return 1; }

# mode table (upstream README): 0=2592x1944 1=1920x1080 2=1296x972 3=640x480 4=1280x720
ov5647_wh() { case $1 in 0) echo "2592 1944";; 1) echo "1920 1080";; 2) echo "1296 972";; 3) echo "640 480";; 4) echo "1280 720";; esac; }

# capture DEV OUT MODE NFRAMES EXPOSURE_US GAIN [LOG]
#   exposure in microseconds, gain in 1/16 (16 = 1x). override_enable=1 keeps
#   the values across stream-on. 1296x972 needs bytesperline=2624 on R35.
ov5647_capture() {
  local dev=$1 out=$2 mode=$3 n=$4 exp=$5 gain=$6 log=${7:-$2.log} w h bpl=""
  read -r w h < <(ov5647_wh "$mode")
  [ "$mode" = 2 ] && bpl=",bytesperline=2624"
  v4l2-ctl -d "$dev" --set-ctrl=bypass_mode=0,override_enable=1,sensor_mode="$mode" \
    --set-fmt-video=width=$w,height=$h,pixelformat=BG10$bpl > "$log" 2>&1
  v4l2-ctl -d "$dev" --set-ctrl=exposure="$exp",gain="$gain" \
    --stream-mmap=4 --stream-count="$n" --stream-to="$out" --verbose >> "$log" 2>&1
  local rc=$?
  v4l2-ctl -d "$dev" --get-fmt-video >> "$log" 2>&1
  return $rc
}
ov5647_stride() { v4l2-ctl -d "$1" --get-fmt-video | sed -n 's/.*Bytes per Line *: *\([0-9]*\).*/\1/p'; }
ov5647_fps()    { grep -o '[0-9.]* fps' "$1" | tail -1; }

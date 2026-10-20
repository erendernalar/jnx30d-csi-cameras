#!/bin/bash
# Phase 2/7 - hardware check BEFORE any driver/DT change.
# Temporarily drives the camera-enable line (module pin 206 = PR.00) via sysfs,
# then reads the OV5647 chip-ID registers 0x300A/0x300B over I2C.
#
#   sudo ./20-i2c-chipid-probe.sh [bus] [addr]
#     bus  : 2 for J10 (CAM_I2C, default), 1 for J5 (GEN1_I2C)
#     addr : 0x36 (default)
#   sudo ./20-i2c-chipid-probe.sh toggle   # camera unplugged: multimeter on pin 6
#
# Distinguishes:  NACK (nothing answers)  vs  ACK + wrong ID  vs  ID 0x5647.
# Tests both enable levels (each after a pause at the other level) and reports
# which one powers the camera. Measured on our JNX30D: HIGH = on (the manual
# describes an inverter, LOW = on).
# Leaves the line released (unexported) afterwards.
set -u
BUS="${1:-2}"
ADDR="${2:-0x36}"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
command -v i2ctransfer >/dev/null || { echo "need i2c-tools: sudo apt install i2c-tools"; exit 1; }

if [ -e "/sys/bus/i2c/drivers/ov5647/$BUS-00${ADDR#0x}" ]; then
  echo "ov5647 is bound to $BUS-00${ADDR#0x}; unbind or boot without the overlay first."; exit 1
fi

LINE=$(grep -E '\(PR\.00' /sys/kernel/debug/gpio | head -1)
GPIO=$(echo "$LINE" | sed -n 's/.*gpio-\([0-9]\+\) *(PR\.00.*/\1/p')
[ -n "$GPIO" ] || { echo "PR.00 not found in /sys/kernel/debug/gpio"; exit 1; }
echo "PR.00 = gpio $GPIO   [$LINE]"
if echo "$LINE" | grep -q -E '\|ov9281|\|ov5647|\|regulator|\|cam'; then
  echo "PR.00 already claimed by a driver: $LINE"; echo "(overlay active?) - skipping manual drive"; CLAIMED=1
else
  CLAIMED=0
fi

# L4T names the sysfs dir after the line (PR.00); mainline uses gpioN
gp_export() {
  [ -d /sys/class/gpio/PR.00 ] || [ -d /sys/class/gpio/gpio$GPIO ] || echo $GPIO > /sys/class/gpio/export
  if [ -d /sys/class/gpio/PR.00 ]; then GP=/sys/class/gpio/PR.00; else GP=/sys/class/gpio/gpio$GPIO; fi
  [ -w "$GP/direction" ] || { echo "cannot export PR.00 (gpio $GPIO)"; exit 1; }
  echo out > "$GP/direction" || { echo "cannot set PR.00 to output"; exit 1; }
}
GP=""

if [ "$BUS" = toggle ]; then
  # Multimeter check of J10/J5 pin 6 (camera NOT attached): PR.00 toggles every
  # 3 s for 30 s. Expected (manual): PR.00=0 -> pin 6 ~3.3 V, PR.00=1 -> ~0 V.
  [ "$CLAIMED" = 0 ] || { echo "PR.00 claimed by a driver"; exit 1; }
  gp_export
  for i in $(seq 1 5); do
    echo 1 > $GP/value; echo "PR.00=1  (measured: pin 6 HIGH, camera on)"; sleep 3
    echo 0 > $GP/value; echo "PR.00=0  (pin 6 LOW, camera off)"; sleep 3
  done
  echo in > $GP/direction; echo $GPIO > /sys/class/gpio/unexport
  echo "If pin 6 never changed, the enable is NOT driven by module pin 206."
  exit 0
fi

read_id() {
  local out
  out=$(i2ctransfer -y "$BUS" w2@"$ADDR" 0x30 0x0a r2 2>&1)
  local rc=$?
  if [ $rc -ne 0 ]; then echo "NACK/err: $out"; return 2; fi
  echo "read: $out"
  if [ "$out" = "0x56 0x47" ]; then return 0; fi
  return 1
}

cleanup() { [ "$CLAIMED" = 0 ] && [ -n "$GP" ] && [ -e "$GP" ] && { echo 0 > $GP/value; echo in > $GP/direction; echo $GPIO > /sys/class/gpio/unexport; }; }
trap cleanup EXIT

[ "$CLAIMED" = 0 ] && gp_export

if [ "$CLAIMED" = 1 ]; then
  read_id; rc=$?
  [ $rc = 0 ] && { echo "RESULT: OV5647 identified (enable line owned by a driver)"; exit 0; }
  [ $rc = 1 ] && { echo "RESULT: ACK but ID is not 0x5647"; exit 3; }
  echo "RESULT: no ACK"; exit 2
fi

# Test BOTH enable levels (camera fully off for 0.5 s in between) and decide
# from the combination - this replaces a multimeter check of pin 6.
declare -A R
for LEVEL in 1 0 1 0; do
  echo $((1-LEVEL)) > $GP/value; sleep 0.5   # other level first (camera off at one of them)
  echo $LEVEL > $GP/value; sleep 0.3     # level under test
  echo "--- PR.00 = $LEVEL"
  read_id; rc=$?
  R[$LEVEL]="${R[$LEVEL]:-}$rc"                                # 0=ID ok 1=wrong ID 2=NACK
done
echo
echo "summary (two tries each, 0=ID 0x5647, 1=other ID, 2=NACK):  PR.00=0 -> ${R[0]}   PR.00=1 -> ${R[1]}"
case "${R[0]}/${R[1]}" in
  22/00) echo "RESULT: OV5647 identified. PR.00 HIGH = camera on (as measured on our JNX30D)."
         echo "        The overlay is correct as is."; V=0; ON=1 ;;
  00/22) echo "RESULT: OV5647 identified, but PR.00 LOW = camera on (inverted, as the manual says)."
         echo "        Overlay: reset-gpios = <&tegra_main_gpio 136 1> (GPIO_ACTIVE_LOW)."; V=0; ON=0 ;;
  00/00) echo "RESULT: OV5647 identified at both levels -> PR.00 does NOT switch camera power"
         echo "        (enable comes from elsewhere, or pin 6 is always pulled up)."
         echo "        Capture still works; reset-gpios then has no effect."; V=0; ON=1 ;;
  *1*)   echo "RESULT: something ACKs at $ADDR but the ID is not 0x5647 -> not the sensor"; exit 3 ;;
  22/22) V=2 ;;
  *)     echo "RESULT: inconsistent (${R[0]}/${R[1]}) - loose cable or marginal power; reseat and rerun"; exit 4 ;;
esac
if [ "${V}" = 0 ]; then
  echo "        sensor revision reg 0x302A = $(echo $ON > $GP/value; sleep 0.1; i2ctransfer -y $BUS w2@$ADDR 0x30 0x2a r1 2>&1)"
  exit 0
fi
echo "RESULT: no ACK at $ADDR on i2c-$BUS at either enable level."
echo "Check: cable type/orientation (22->15 pin), connector (J10=bus 2, J5=bus 1),"
echo "       camera enable not on PR.00. Bus scan (read-only probes):"
i2cdetect -y -r "$BUS"
exit 2

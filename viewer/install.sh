#!/bin/bash
# Install the "Drone Camera" live viewer for the current user:
# Python dependencies (apt) and a launcher in the app menu and on the desktop.
#   ./install.sh            # run as the desktop user (asks for sudo for apt)
#   ./install.sh --remove
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/drone_camera_viewer.py"
MENU="$HOME/.local/share/applications/drone-camera.desktop"
DESK="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")/drone-camera.desktop"

if [ "${1:-}" = "--remove" ]; then
  rm -f "$MENU" "$DESK"; echo "launchers removed"; exit 0
fi

need=""
python3 -c "import tkinter" 2>/dev/null || need="$need python3-tk"
python3 -c "from PIL import ImageTk" 2>/dev/null || need="$need python3-pil python3-pil.imagetk"
python3 -c "import numpy" 2>/dev/null || need="$need python3-numpy"
python3 -c "import gi; gi.require_version('Gst','1.0')" 2>/dev/null || need="$need python3-gi gir1.2-gstreamer-1.0"
command -v v4l2-ctl >/dev/null || need="$need v4l-utils"
if [ -n "$need" ]; then
  echo "installing:$need"; sudo apt-get install -y $need
fi
id -nG | grep -qw video || echo "NOTE: $USER is not in the 'video' group: sudo usermod -aG video $USER (then log out/in)"

chmod +x "$APP"
mkdir -p "$(dirname "$MENU")" "$(dirname "$DESK")"
cat > "$MENU" <<EOF
[Desktop Entry]
Type=Application
Name=Drone Camera
Comment=Live view of the CSI camera (snapshot / record)
Exec=python3 "$APP"
Icon=camera-video
Terminal=false
Categories=AudioVideo;Video;
EOF
cp "$MENU" "$DESK"; chmod +x "$DESK"
gio set "$DESK" metadata::trusted true 2>/dev/null || true
echo "installed: app menu 'Drone Camera' and $DESK"
echo "(first start from the desktop icon: right-click -> Allow Launching)"

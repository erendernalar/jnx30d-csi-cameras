# Drone Camera – local live viewer

A small Tk window for the Jetson desktop: live view, snapshot (PNG) and recording (MP4, hardware
H.264). It detects the installed camera from `/dev/video0`:

- **OV5647 (Pi Camera v1.3)**: Argus ISP, colour, auto exposure capped at 33 ms (keeps 30 fps in
  dim light); the picture is scaled to the window on the GPU.
- **OV9281 (UC-788)**: raw 1280x800 10-bit frames, grey, with exposure and gain sliders.

The top bar shows `camera N fps / display M fps`, so you can tell a slow camera from a slow display.

```bash
./install.sh          # apt dependencies + "Drone Camera" launcher (app menu and desktop)
./install.sh --remove
python3 drone_camera_viewer.py   # or run it directly
```

Files go to `~/Pictures/drone-camera/`. The camera driver from `../ov5647` or `../ov9281` must be
installed first. Starting a recording briefly restarts the stream.

#!/usr/bin/env python3
"""Drone Camera - local live viewer for the CSI camera on the Jetson.

Detects the installed camera from /dev/video0:
  ov5647 (Raspberry Pi Camera v1.3): Argus ISP -> colour, auto exposure
  ov9281 (Arducam UC-788):           raw V4L2 10-bit -> grey, manual exposure/gain
Snapshots (PNG) and recordings (MP4, H.264 hardware encoder) go to
~/Pictures/drone-camera/.

Speed notes: the Pi camera image is scaled to the window size on the GPU
(nvvidconv), and only frames that are actually drawn get converted for Tk.
Auto exposure is capped at 33 ms so the camera keeps 30 fps in dim light.
"""
import datetime
import os
import subprocess
import threading
import time
import tkinter as tk

import numpy as np
from PIL import Image, ImageTk

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

Gst.init(None)
DEV = "/dev/video0"
OUTDIR = os.path.expanduser("~/Pictures/drone-camera")


def detect_camera():
    try:
        info = subprocess.run(["v4l2-ctl", "-d", DEV, "--info"], capture_output=True,
                              text=True, timeout=5).stdout
    except Exception:
        return None
    for name in ("ov5647", "ov9281"):
        if name in info:
            return name
    return None


def stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def fit(iw, ih, vw, vh):
    """Largest even-sized w x h with aspect iw:ih that fits in vw x vh."""
    k = min(vw / iw, vh / ih)
    return max(160, int(iw * k) // 2 * 2), max(90, int(ih * k) // 2 * 2)


class Ov5647Source:
    """Argus -> GPU scale to window size -> BGRx appsink; optional H.264 recording branch."""
    name, label, size, fps = "ov5647", "Raspberry Pi Camera v1.3 (OV5647)", (1920, 1080), 30
    # Argus exposure range in ns: 13 us .. 33 ms keeps 30 fps (driver allows up to 0.5 s)
    EXPOSURE_RANGE = "13000 33000000"

    def __init__(self):
        self.pipe = None
        self.sample = None
        self.cam_frames = 0
        self.view = (960, 540)
        self._img, self._img_src = None, None

    def start(self, record_path=None):
        rec = ""
        if record_path:
            rec = (" t. ! queue ! nvv4l2h264enc bitrate=10000000 maxperf-enable=1 ! h264parse ! "
                   f"mp4mux ! filesink location=\"{record_path}\"")
        w, h = self.view
        desc = (f"nvarguscamerasrc exposuretimerange=\"{self.EXPOSURE_RANGE}\" "
                "! video/x-raw(memory:NVMM),width=1920,height=1080,framerate=30/1 "
                "! tee name=t "
                "t. ! queue leaky=downstream max-size-buffers=1 ! nvvidconv "
                f"! capsfilter name=viewcaps caps=video/x-raw,width={w},height={h},format=BGRx "
                "! appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false" + rec)
        self.pipe = Gst.parse_launch(desc)
        self.pipe.get_by_name("sink").connect("new-sample", self._on_sample)
        self.pipe.set_state(Gst.State.PLAYING)

    def _on_sample(self, sink):
        # keep only a reference; conversion happens in the UI thread for drawn frames
        self.sample = sink.emit("pull-sample")
        self.cam_frames += 1
        return Gst.FlowReturn.OK

    @property
    def latest(self):
        s = self.sample
        if s is None:
            return None
        if s is not self._img_src:
            st = s.get_caps().get_structure(0)
            w, h = st.get_value("width"), st.get_value("height")
            buf = s.get_buffer()
            ok, m = buf.map(Gst.MapFlags.READ)
            if not ok:
                return self._img
            self._img = Image.frombuffer("RGB", (w, h), bytes(m.data), "raw", "BGRX", 0, 1)
            buf.unmap(m)
            self._img_src = s
        return self._img

    @latest.setter
    def latest(self, v):
        self.sample, self._img, self._img_src = None, None, None

    def set_view(self, w, h):
        """Scale on the GPU to the window size (renegotiates nvvidconv output)."""
        if (w, h) == self.view:
            return
        self.view = (w, h)
        if self.pipe:
            self.pipe.get_by_name("viewcaps").set_property(
                "caps", Gst.Caps.from_string(f"video/x-raw,width={w},height={h},format=BGRx"))

    def stop(self):
        if self.pipe:
            # EOS so a recording gets a valid MP4 index
            self.pipe.send_event(Gst.Event.new_eos())
            self.pipe.get_bus().timed_pop_filtered(3 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
            self.pipe.set_state(Gst.State.NULL)
            self.pipe = None

    def set_controls(self, **kw):
        pass


class Ov9281Source:
    """Raw 1280x800 10-bit frames from v4l2-ctl; recording through a GStreamer appsrc."""
    name, label, size, fps = "ov9281", "Arducam UC-788 (OV9281, mono)", (1280, 800), 60
    FRAME = 1280 * 800 * 2

    def __init__(self):
        self.proc = None
        self.frame = None          # latest 8-bit numpy frame
        self.cam_frames = 0
        self.rec = None
        self.running = False
        self.gain, self.coarse = 32, 27200
        self.view = (1280, 800)
        self._img, self._img_src = None, None

    def start(self, record_path=None):
        subprocess.run(["v4l2-ctl", "-d", DEV, "--set-fmt-video=width=1280,height=800,pixelformat=BG10",
                        f"--set-ctrl=bypass_mode=0,override_enable=1,gain={self.gain},coarse_time={self.coarse}"],
                       capture_output=True)
        self.proc = subprocess.Popen(["v4l2-ctl", "-d", DEV, "--stream-mmap=4", "--stream-count=0",
                                      "--stream-to=-"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     bufsize=0)
        if record_path:
            self.rec = Gst.parse_launch(
                "appsrc name=src is-live=true format=time do-timestamp=true "
                "caps=video/x-raw,format=GRAY8,width=1280,height=800,framerate=60/1 "
                "! videoconvert ! video/x-raw,format=I420 ! nvvidconv ! video/x-raw(memory:NVMM),format=NV12 "
                f"! nvv4l2h264enc bitrate=8000000 maxperf-enable=1 ! h264parse ! mp4mux ! filesink location=\"{record_path}\"")
            self.rec.set_state(Gst.State.PLAYING)
        self.running = True
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        f = self.proc.stdout
        buf = bytearray(self.FRAME)
        mv = memoryview(buf)
        while self.running:
            n = 0
            while n < self.FRAME:
                k = f.readinto(mv[n:])
                if not k:
                    self.running = False
                    return
                n += k
            raw = np.frombuffer(buf, dtype="<u2").reshape(800, 1280)
            g8 = (raw >> 8).astype(np.uint8)  # 10-bit value sits in the top bits
            self.frame = g8
            self.cam_frames += 1
            if self.rec:
                self.rec.get_by_name("src").emit("push-buffer", Gst.Buffer.new_wrapped(g8.tobytes()))

    @property
    def latest(self):
        fr = self.frame
        if fr is None:
            return None
        if fr is not self._img_src:
            w, h = self.view
            step = max(1, min(1280 // w, 800 // h))   # cheap integer decimation first
            img = Image.fromarray(np.ascontiguousarray(fr[::step, ::step]), "L")
            if img.size != (w, h):
                img = img.resize((w, h), Image.NEAREST if step > 1 else Image.BILINEAR)
            self._img, self._img_src = img, fr
        return self._img

    @latest.setter
    def latest(self, v):
        self.frame, self._img, self._img_src = None, None, None

    def full_image(self):
        fr = self.frame
        return None if fr is None else Image.fromarray(fr, "L")

    def set_view(self, w, h):
        self.view = (w, h)

    def stop(self):
        self.running = False
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None
        if self.rec:
            self.rec.get_by_name("src").emit("end-of-stream")
            self.rec.get_bus().timed_pop_filtered(3 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
            self.rec.set_state(Gst.State.NULL)
            self.rec = None

    def set_controls(self, gain=None, coarse=None):
        if gain is not None:
            self.gain = int(gain)
        if coarse is not None:
            self.coarse = int(coarse)
        subprocess.run(["v4l2-ctl", "-d", DEV, f"--set-ctrl=gain={self.gain},coarse_time={self.coarse}"],
                       capture_output=True)


class App:
    def __init__(self, root):
        self.root = root
        root.title("Drone Camera")
        root.configure(bg="#1e1e1e")
        root.geometry("1000x700")
        self.src = None
        self.recording = None
        self._last_rec = None
        self.shown, self.t0, self.cam0 = 0, time.time(), 0
        self.last_img = None
        self._view_job = None

        bar = tk.Frame(root, bg="#2b2b2b")
        bar.pack(side=tk.TOP, fill=tk.X)
        style = dict(bg="#3c3f41", fg="white", activebackground="#4b6eaf", activeforeground="white",
                     relief=tk.FLAT, padx=12, pady=6, font=("Sans", 11))
        self.b_start = tk.Button(bar, text="Start", command=self.start, **style)
        self.b_stop = tk.Button(bar, text="Stop", command=self.stop, state=tk.DISABLED, **style)
        self.b_snap = tk.Button(bar, text="Snapshot", command=self.snapshot, state=tk.DISABLED, **style)
        self.b_rec = tk.Button(bar, text="Record", command=self.toggle_record, state=tk.DISABLED, **style)
        for b in (self.b_start, self.b_stop, self.b_snap, self.b_rec):
            b.pack(side=tk.LEFT, padx=4, pady=6)
        self.status = tk.Label(bar, text="", bg="#2b2b2b", fg="#9ad", font=("Sans", 11))
        self.status.pack(side=tk.RIGHT, padx=10)
        self.bar = bar

        self.ctrl = tk.Frame(root, bg="#2b2b2b")  # exposure/gain, only for ov9281
        self.msg = tk.Label(root, text="", bg="#1e1e1e", fg="#ccc", anchor="w", font=("Sans", 10))
        self.msg.pack(side=tk.BOTTOM, fill=tk.X, padx=8)
        self.view = tk.Label(root, bg="black")
        self.view.pack(fill=tk.BOTH, expand=True)
        self.view.bind("<Configure>", self._on_resize)

        cam = detect_camera()
        if cam == "ov5647":
            self.src = Ov5647Source()
        elif cam == "ov9281":
            self.src = Ov9281Source()
            self._build_controls()
        if self.src:
            self.status.config(text=self.src.label)
            self.say(f"Ready. Files are saved to {OUTDIR}")
        else:
            self.status.config(text="no camera")
            self.b_start.config(state=tk.DISABLED)
            self.say("No supported camera on /dev/video0 (is the right driver installed?)")
        root.protocol("WM_DELETE_WINDOW", self.quit)
        self.tick()

    def _build_controls(self):
        self.ctrl.pack(side=tk.TOP, fill=tk.X, after=self.bar)
        lab = dict(bg="#2b2b2b", fg="white", font=("Sans", 10))
        tk.Label(self.ctrl, text="Exposure (ms)", **lab).pack(side=tk.LEFT, padx=(10, 2))
        self.s_exp = tk.Scale(self.ctrl, from_=0.1, to=16.0, resolution=0.1, orient=tk.HORIZONTAL, length=260,
                              bg="#2b2b2b", fg="white", highlightthickness=0, command=self._on_ctrl)
        self.s_exp.set(15.5)
        self.s_exp.pack(side=tk.LEFT)
        tk.Label(self.ctrl, text="Gain (x)", **lab).pack(side=tk.LEFT, padx=(20, 2))
        self.s_gain = tk.Scale(self.ctrl, from_=1.0, to=15.5, resolution=0.5, orient=tk.HORIZONTAL, length=200,
                               bg="#2b2b2b", fg="white", highlightthickness=0, command=self._on_ctrl)
        self.s_gain.set(2.0)
        self.s_gain.pack(side=tk.LEFT)
        self._ctrl_job = None

    def _on_ctrl(self, _=None):
        if self._ctrl_job:
            self.root.after_cancel(self._ctrl_job)
        self._ctrl_job = self.root.after(150, self._apply_ctrl)

    def _apply_ctrl(self):
        # line time 9.1 us at 60 fps; coarse_time is in 1/16 lines
        lines = max(1, int(float(self.s_exp.get()) * 1000 / 9.1))
        self.src.set_controls(gain=int(float(self.s_gain.get()) * 16), coarse=lines * 16)

    def _on_resize(self, ev):
        if not self.src:
            return
        if self._view_job:
            self.root.after_cancel(self._view_job)
        self._view_job = self.root.after(200, lambda: self.src.set_view(*fit(*self.src.size, ev.width, ev.height)))

    def say(self, text):
        self.msg.config(text=text)

    def start(self, record_path=None):
        if isinstance(self.src, Ov9281Source):
            self._apply_ctrl()
        self.src.set_view(*fit(*self.src.size, self.view.winfo_width(), self.view.winfo_height()))
        try:
            self.src.start(record_path)
        except Exception as e:  # pipeline/launch errors
            self.say(f"Start failed: {e}")
            return
        self.b_start.config(state=tk.DISABLED)
        for b in (self.b_stop, self.b_snap, self.b_rec):
            b.config(state=tk.NORMAL)
        self.shown, self.t0, self.cam0 = 0, time.time(), self.src.cam_frames
        if not record_path:
            self.say("Live")

    def stop(self):
        self.src.stop()
        self.src.latest = None
        if self.recording:
            self.say(f"Saved video: {self.recording}")
            self.recording = None
        else:
            self.say("Stopped")
        self.b_rec.config(text="Record")
        self.b_start.config(state=tk.NORMAL)
        for b in (self.b_stop, self.b_snap, self.b_rec):
            b.config(state=tk.DISABLED)

    def snapshot(self):
        img = self.src.full_image() if hasattr(self.src, "full_image") else self.src.latest
        if img is None:
            return
        os.makedirs(OUTDIR, exist_ok=True)
        path = os.path.join(OUTDIR, f"{self.src.name}-{stamp()}.png")
        img.save(path)
        self.say(f"Saved snapshot: {path}")

    def toggle_record(self):
        # Recording is a branch of the capture pipeline, so the stream restarts briefly
        if self.recording:
            self.stop()
            self.start()
            self.say(f"Saved video: {self._last_rec}")
            return
        os.makedirs(OUTDIR, exist_ok=True)
        path = os.path.join(OUTDIR, f"{self.src.name}-{stamp()}.mp4")
        self.src.stop()
        self.start(record_path=path)
        self.recording = self._last_rec = path
        self.b_rec.config(text="Stop recording")
        self.say(f"Recording to {path}")

    def tick(self):
        img = self.src.latest if self.src else None
        if img is not None and img is not self.last_img:
            self.last_img = img
            self.shown += 1
            self.photo = ImageTk.PhotoImage(img)
            self.view.config(image=self.photo)
        now = time.time()
        if now - self.t0 >= 1.0 and self.src:
            dt = now - self.t0
            cam = (self.src.cam_frames - self.cam0) / dt
            disp = self.shown / dt
            self.shown, self.t0, self.cam0 = 0, now, self.src.cam_frames
            live = self.b_stop["state"] == tk.NORMAL
            rate = f"   camera {cam:.0f} fps / display {disp:.0f} fps" if live else ""
            rec = "   [REC]" if self.recording else ""
            self.status.config(text=f"{self.src.label}{rate}{rec}")
        self.root.after(10, self.tick)

    def quit(self):
        if self.src and self.b_stop["state"] == tk.NORMAL:
            self.stop()
        self.root.destroy()


if __name__ == "__main__":
    root = tk.Tk()
    App(root)
    root.mainloop()

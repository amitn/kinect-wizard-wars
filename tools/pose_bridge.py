#!/usr/bin/env python3
"""Pose bridge: Orbbec Gemini 2 color + depth -> MediaPipe Pose -> UDP body frames.

Real skeleton tracking for Wizard Wars. Runs on the Windows PC next to the
camera and sends the same JSON the game already accepts (see README "Body
frame format"), so the game needs no changes; its built-in depth tracker
stays as the fallback when this bridge is not running.

    python pose_bridge.py                 # -> 127.0.0.1:7777
    python pose_bridge.py --preview       # also show the camera with skeletons
    python pose_bridge.py --model pose_landmarker_full.task

Requires: mediapipe==0.10.21, numpy, opencv-python, and Orbbec's official
Python SDK wheel (pyorbbecsdk2 from https://github.com/orbbec/pyorbbecsdk/releases;
the PyPI "pyorbbecsdk" wheel for Windows is broken). The MediaPipe model file
is downloaded on first run.
"""
import argparse
import base64
import json
import math
import os
import socket
import sys
import time
import urllib.request

import numpy as np

MODEL_URLS = {
    "lite": "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task",
    "full": "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task",
    "heavy": "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task",
}

# MediaPipe pose landmark indices.
LM = {
    "nose": 0, "left_eye": 2, "right_eye": 5, "left_ear": 7, "right_ear": 8,
    "left_shoulder": 11, "right_shoulder": 12, "left_elbow": 13, "right_elbow": 14,
    "left_wrist": 15, "right_wrist": 16, "left_index": 19, "right_index": 20,
    "left_thumb": 21, "right_thumb": 22, "left_hip": 23, "right_hip": 24,
    "left_knee": 25, "right_knee": 26, "left_ankle": 27, "right_ankle": 28,
    "left_foot": 31, "right_foot": 32,
}

# Game joint -> landmark(s) averaged. "Left" in the game means the image's left,
# which is the person's right when they face the camera, so sides are swapped.
JOINT_MAP = {
    "Head": ["nose"],
    "Neck": ["left_shoulder", "right_shoulder", "nose"],
    "SpineShoulder": ["left_shoulder", "right_shoulder"],
    "SpineMid": ["left_shoulder", "right_shoulder", "left_hip", "right_hip"],
    "SpineBase": ["left_hip", "right_hip"],
    "ShoulderLeft": ["right_shoulder"], "ElbowLeft": ["right_elbow"], "WristLeft": ["right_wrist"],
    "HandLeft": ["right_wrist", "right_index"], "HandTipLeft": ["right_index"], "ThumbLeft": ["right_thumb"],
    "ShoulderRight": ["left_shoulder"], "ElbowRight": ["left_elbow"], "WristRight": ["left_wrist"],
    "HandRight": ["left_wrist", "left_index"], "HandTipRight": ["left_index"], "ThumbRight": ["left_thumb"],
    "HipLeft": ["right_hip"], "KneeLeft": ["right_knee"], "AnkleLeft": ["right_ankle"], "FootLeft": ["right_foot"],
    "HipRight": ["left_hip"], "KneeRight": ["left_knee"], "AnkleRight": ["left_ankle"], "FootRight": ["left_foot"],
}


def ensure_model(name_or_path: str) -> str:
    if os.path.isfile(name_or_path):
        return name_or_path
    url = MODEL_URLS.get(name_or_path)
    if url is None:
        sys.exit(f"unknown model {name_or_path!r}; use lite/full/heavy or a .task path")
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"pose_landmarker_{name_or_path}.task")
    if not os.path.isfile(path):
        print(f"downloading {url} ...")
        urllib.request.urlretrieve(url, path)
    return path


class Camera:
    """Orbbec color + depth, depth aligned to color, with color intrinsics."""

    def __init__(self, width: int, height: int, fps: int):
        from pyorbbecsdk import Config, OBFormat, OBSensorType, Pipeline
        self.ob = __import__("pyorbbecsdk")
        OBAlignMode = getattr(self.ob, "OBAlignMode", None)
        self.pipeline = Pipeline()
        config = Config()
        color_list = self.pipeline.get_stream_profile_list(OBSensorType.COLOR_SENSOR)
        try:
            color = color_list.get_video_stream_profile(width, height, OBFormat.RGB, fps)
        except Exception:
            color = color_list.get_default_video_stream_profile()
        config.enable_stream(color)
        depth_list = self.pipeline.get_stream_profile_list(OBSensorType.DEPTH_SENSOR)
        try:
            depth = depth_list.get_video_stream_profile(0, 0, OBFormat.Y16, fps)
        except Exception:
            depth = depth_list.get_default_video_stream_profile()
        config.enable_stream(depth)
        try:
            if OBAlignMode is not None:
                config.set_align_mode(OBAlignMode.SW_MODE)
        except Exception:
            pass
        self.align = None
        try:
            from pyorbbecsdk import AlignFilter, OBStreamType
            self.align = AlignFilter(align_to_stream=OBStreamType.COLOR_STREAM)
        except Exception:
            pass
        self.pipeline.start(config)
        self.intrinsic = None

    def read(self):
        frames = self.pipeline.wait_for_frames(200)
        if frames is None:
            return None, None, None
        if self.align is not None:
            aligned = self.align.process(frames)
            if aligned is not None:
                frames = aligned.as_frame_set()
        color = frames.get_color_frame()
        depth = frames.get_depth_frame()
        if color is None or depth is None:
            return None, None, None
        if self.intrinsic is None:
            try:
                self.intrinsic = color.get_stream_profile().as_video_stream_profile().get_intrinsic()
            except Exception:
                self.intrinsic = None
        w, h = color.get_width(), color.get_height()
        buf = np.frombuffer(color.get_data(), dtype=np.uint8)
        fmt = color.get_format()
        if fmt == self.ob.OBFormat.RGB:
            rgb = buf.reshape(h, w, 3)
        elif fmt == self.ob.OBFormat.BGR:
            rgb = buf.reshape(h, w, 3)[:, :, ::-1]
        elif fmt == self.ob.OBFormat.MJPG:
            import cv2
            rgb = cv2.imdecode(buf, cv2.IMREAD_COLOR)[:, :, ::-1]
        else:
            import cv2
            rgb = cv2.cvtColor(buf.reshape(h, w, 2), cv2.COLOR_YUV2RGB_YUY2)
        dw, dh = depth.get_width(), depth.get_height()
        scale_fn = getattr(depth, "get_depth_scale", None) or getattr(depth, "get_scale", None)
        scale = float(scale_fn()) if scale_fn is not None else 1.0
        depth_mm = np.frombuffer(depth.get_data(), dtype=np.uint16).reshape(dh, dw).astype(np.float32) * scale
        return np.ascontiguousarray(rgb), depth_mm, (w, h)


def depth_at(depth_mm: np.ndarray, x: float, y: float, win: int = 4) -> float:
    """Median valid depth in meters around a color pixel (depth is aligned to color)."""
    h, w = depth_mm.shape
    cx, cy = int(round(x)), int(round(y))
    x0, x1 = max(0, cx - win), min(w, cx + win + 1)
    y0, y1 = max(0, cy - win), min(h, cy + win + 1)
    if x1 <= x0 or y1 <= y0:
        return 0.0
    patch = depth_mm[y0:y1, x0:x1]
    valid = patch[(patch > 300) & (patch < 5000)]
    if valid.size == 0:
        return 0.0
    return float(np.median(valid)) / 1000.0


class Body3D:
    def __init__(self, intr, width, height):
        self.width, self.height = width, height
        if intr is not None and intr.fx > 0:
            self.fx, self.fy, self.cx, self.cy = intr.fx, intr.fy, intr.cx, intr.cy
        else:
            # Gemini 2 color at 1280x720 is roughly 91 degrees horizontal.
            self.fx = self.fy = width / (2.0 * math.tan(math.radians(91.0 / 2)))
            self.cx, self.cy = width / 2.0, height / 2.0

    def unproject(self, px: float, py: float, z: float):
        return ((px - self.cx) / self.fx * z, -(py - self.cy) / self.fy * z, z)


def build_body(landmarks, depth_mm, proj: Body3D, body_id: int):
    """Game joints from one person's landmarks, with depth-measured z."""
    w, h = proj.width, proj.height
    pix = {}
    for name, idx in LM.items():
        lm = landmarks[idx]
        pix[name] = (lm.x * w, lm.y * h, getattr(lm, "visibility", 1.0))
    # Torso depth as a robust anchor for landmarks whose own depth is missing.
    torso = [depth_at(depth_mm, *pix[n][:2]) for n in ("left_shoulder", "right_shoulder", "left_hip", "right_hip")]
    torso = [d for d in torso if d > 0]
    torso_z = float(np.median(torso)) if torso else 0.0
    if torso_z <= 0:
        return None
    joints = {}
    for joint, parts in JOINT_MAP.items():
        xs = [pix[p][0] for p in parts]
        ys = [pix[p][1] for p in parts]
        px, py = sum(xs) / len(xs), sum(ys) / len(ys)
        z = depth_at(depth_mm, px, py)
        # Hands often sit in front of the body; a missing reading falls back to the torso.
        if z <= 0 or abs(z - torso_z) > 1.5:
            z = torso_z
        x, y, zz = proj.unproject(px, py, z)
        vis = min(pix[p][2] for p in parts)
        joints[joint] = [round(x, 3), round(y, 3), round(zz, 3), 2 if vis > 0.5 else 1]
    left_up = joints["HandLeft"][1] > joints["Head"][1] and joints["HandRight"][1] > joints["Head"][1]
    return {
        "id": str(body_id),
        "hands": {"l": "tracked", "r": "tracked"},
        "hands_up": bool(left_up),
        "height": round(joints["Head"][1] - min(joints["FootLeft"][1], joints["FootRight"][1]) + 0.12, 2),
        "joints": joints,
    }


class IdTracker:
    """Keeps ids stable between frames by nearest hip position."""

    def __init__(self, max_dist=0.6, memory_s=1.0):
        self.next_id = 1
        self.known = {}  # id -> (x, z, t)
        self.max_dist, self.memory_s = max_dist, memory_s

    def assign(self, bodies, now):
        used = set()
        for b in bodies:
            x, _, z, _ = b["joints"]["SpineBase"]
            best, best_d = None, self.max_dist
            for bid, (kx, kz, t) in self.known.items():
                if bid in used or now - t > self.memory_s:
                    continue
                d = math.hypot(x - kx, z - kz)
                if d < best_d:
                    best, best_d = bid, d
            if best is None:
                best = self.next_id
                self.next_id += 1
            used.add(best)
            self.known[best] = (x, z, now)
            b["id"] = str(best)
        for bid in [k for k, v in self.known.items() if now - v[2] > self.memory_s + 1.0]:
            del self.known[bid]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--model", default="lite", help="lite, full, heavy, or a .task file")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--max-people", type=int, default=2)
    ap.add_argument("--preview", action="store_true", help="show the camera image with skeletons")
    ap.add_argument("--dump", default="", help="write one annotated frame (JPEG) to this path after 2 seconds, then keep running")
    args = ap.parse_args()

    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    model_path = ensure_model(args.model)
    options = vision.PoseLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=model_path),
        running_mode=vision.RunningMode.VIDEO,
        num_poses=args.max_people,
        min_pose_detection_confidence=0.5,
        min_tracking_confidence=0.5,
    )
    landmarker = vision.PoseLandmarker.create_from_options(options)

    cam = Camera(args.width, args.height, args.fps)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ids = IdTracker()
    print(f"pose bridge -> {args.host}:{args.port}  model={os.path.basename(model_path)}  (Ctrl+C to stop)")
    t0 = time.perf_counter()
    frames = 0
    last_report = t0
    proj = None
    while True:
        rgb, depth_mm, size = cam.read()
        if rgb is None:
            continue
        if proj is None:
            proj = Body3D(cam.intrinsic, size[0], size[1])
            print(f"color {size[0]}x{size[1]}  fx={proj.fx:.0f}  depth {depth_mm.shape[1]}x{depth_mm.shape[0]}")
        if depth_mm.shape[0] != size[1] or depth_mm.shape[1] != size[0]:
            import cv2
            depth_mm = cv2.resize(depth_mm, (size[0], size[1]), interpolation=cv2.INTER_NEAREST)
        now = time.perf_counter() - t0
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        result = landmarker.detect_for_video(mp_image, int(now * 1000))
        bodies = []
        for landmarks in result.pose_landmarks:
            body = build_body(landmarks, depth_mm, proj, 0)
            if body is not None:
                bodies.append(body)
        ids.assign(bodies, now)
        msg = {"t": round(now * 1000.0, 1), "bodies": bodies}
        sock.sendto(json.dumps(msg, separators=(",", ":")).encode("utf-8"), (args.host, args.port))
        frames += 1
        if now - (last_report - t0) >= 2.0:
            last_report = time.perf_counter()
            summary = "  ".join(f"id={b['id']} z={b['joints']['SpineBase'][2]:.2f} h={b['height']}" for b in bodies)
            print(f"{frames / now:5.1f} fps  people={len(bodies)}  {summary}")
        if args.preview or (args.dump and now > 2.0):
            import cv2
            bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
            for landmarks in result.pose_landmarks:
                pts = [(int(l.x * size[0]), int(l.y * size[1])) for l in landmarks]
                for a, b in [(11, 13), (13, 15), (12, 14), (14, 16), (11, 12), (23, 24), (11, 23), (12, 24), (23, 25), (25, 27), (24, 26), (26, 28)]:
                    cv2.line(bgr, pts[a], pts[b], (0, 255, 255), 2)
                for p in pts:
                    cv2.circle(bgr, p, 3, (0, 200, 255), -1)
            if args.dump and now > 2.0:
                # Depth as a small inset so the alignment can be judged too.
                small = cv2.resize(np.clip(depth_mm / 4000.0 * 255.0, 0, 255).astype(np.uint8), (320, 180))
                bgr[10:190, 10:330] = cv2.cvtColor(small, cv2.COLOR_GRAY2BGR)
                cv2.imwrite(args.dump, bgr)
                print(f"dumped {args.dump}")
                args.dump = ""
            if args.preview:
                cv2.imshow("pose bridge", bgr)
                if cv2.waitKey(1) & 0xFF == 27:
                    break


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass

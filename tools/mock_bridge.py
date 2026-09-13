#!/usr/bin/env python3
"""Fake Kinect bridge for testing the game without a sensor.

Streams two scripted skeletons over UDP in the same JSON format the real
bridge (bridge/Program.cs) produces. Player 1 stands on the sensor's left,
player 2 on its right; both run a loop of bolts, waves and shields.

    python3 tools/mock_bridge.py                 # -> 127.0.0.1:7777
    python3 tools/mock_bridge.py --host 172.x.x.x --port 7777
    python3 tools/mock_bridge.py --idle 2        # player 2 just stands there
    python3 tools/mock_bridge.py --style depth   # depth-camera format with silhouettes

Styles:
  kinect  full 25-joint Kinect v2 skeletons, hand states open/closed (default)
  depth   what the OrbbecCamera extension emits: the seven joints SpineBase,
          SpineShoulder, Head, HandLeft, HandRight, FootLeft, FootRight, hand
          states tracked/rest, hands_up, height, and a base64 LA8 silhouette
          drawn from the current pose (see README "Body frame format")
"""
import argparse
import base64
import json
import math
import socket
import time

# Standing pose, meters relative to SpineBase. Left/right are the player's own.
BASE_POSE = {
    "SpineBase": (0.0, 0.0, 0.0), "SpineMid": (0.0, 0.3, 0.0), "SpineShoulder": (0.0, 0.55, 0.0),
    "Neck": (0.0, 0.65, 0.0), "Head": (0.0, 0.8, 0.0),
    "ShoulderLeft": (-0.2, 0.55, 0.0), "ShoulderRight": (0.2, 0.55, 0.0),
    "HipLeft": (-0.1, -0.05, 0.0), "KneeLeft": (-0.11, -0.5, 0.0), "AnkleLeft": (-0.12, -0.9, 0.0), "FootLeft": (-0.12, -0.95, -0.1),
    "HipRight": (0.1, -0.05, 0.0), "KneeRight": (0.11, -0.5, 0.0), "AnkleRight": (0.12, -0.9, 0.0), "FootRight": (0.12, -0.95, -0.1),
}

# Hand targets relative to the same-side shoulder. Arm length is about 0.6 m.
REST = {"L": (-0.08, -0.57, 0.02), "R": (0.08, -0.57, 0.02)}
PUNCH = {"L": (-0.05, -0.1, -0.60), "R": (0.05, -0.1, -0.60)}
SHIELD = {"L": (-0.1, 0.55, -0.15), "R": (0.1, 0.55, -0.15)}
SWEEP_START = {"R": (-0.35, -0.05, -0.4), "L": (0.35, -0.05, -0.4)}
SWEEP_END = {"R": (0.45, -0.05, -0.4), "L": (-0.45, -0.05, -0.4)}


def action(name, hand="R"):
    """Return a list of (duration, {hand: target}) phases."""
    other = "L" if hand == "R" else "R"
    if name == "bolt":
        return [(0.25, {hand: PUNCH[hand]}), (0.25, {hand: PUNCH[hand]}), (0.4, {hand: REST[hand]})]
    if name == "shield":
        return [(0.4, {"L": SHIELD["L"], "R": SHIELD["R"]}), (2.0, {"L": SHIELD["L"], "R": SHIELD["R"]}),
                (0.4, {"L": REST["L"], "R": REST["R"]})]
    if name == "wave":
        return [(0.3, {hand: SWEEP_START[hand]}), (0.35, {hand: SWEEP_END[hand]}), (0.4, {hand: REST[hand]})]
    if name.startswith("idle"):
        return [(float(name.split(":")[1]), {})]
    raise ValueError(name)


DEPTH_JOINTS = ("SpineBase", "SpineShoulder", "Head", "HandLeft", "HandRight", "FootLeft", "FootRight")

# Silhouette rasterization: the figure is drawn in the camera's x/y plane (z is
# dropped, so a punch toward the camera comes out foreshortened) onto a canvas
# that is then cropped to the body's bounding box, like the tracker's blob mask.
SIL_PX_PER_M = 57.0     # a standing 1.9 m figure is about 110 px tall and 40 px wide
SIL_CANVAS_W = 100      # wide enough for both arms stretched out sideways
SIL_CANVAS_H = 124

SCRIPTS = {
    1: ["idle:1.5", ("bolt", "R"), "idle:0.8", ("bolt", "L"), "idle:1.5", ("wave", "R"), "idle:2.0", "shield", "idle:1.0"],
    2: ["idle:2.5", "shield", "idle:1.0", ("bolt", "R"), "idle:0.5", ("bolt", "R"), "idle:1.5", ("wave", "L"), "idle:1.0"],
}


def _fill_circle(canvas, cx, cy, r):
    """Set canvas pixels inside a circle. canvas is a bytearray, row-major."""
    x0, x1 = max(0, int(cx - r)), min(SIL_CANVAS_W - 1, int(cx + r) + 1)
    y0, y1 = max(0, int(cy - r)), min(SIL_CANVAS_H - 1, int(cy + r) + 1)
    r2 = r * r
    for y in range(y0, y1 + 1):
        dy = y + 0.5 - cy
        row = y * SIL_CANVAS_W
        for x in range(x0, x1 + 1):
            dx = x + 0.5 - cx
            if dx * dx + dy * dy <= r2:
                canvas[row + x] = 1


def _fill_capsule(canvas, ax, ay, bx, by, r):
    """Set canvas pixels within r of the segment a-b (a limb with round ends)."""
    x0, x1 = max(0, int(min(ax, bx) - r)), min(SIL_CANVAS_W - 1, int(max(ax, bx) + r) + 1)
    y0, y1 = max(0, int(min(ay, by) - r)), min(SIL_CANVAS_H - 1, int(max(ay, by) + r) + 1)
    vx, vy = bx - ax, by - ay
    vv = vx * vx + vy * vy
    r2 = r * r
    for y in range(y0, y1 + 1):
        py = y + 0.5
        row = y * SIL_CANVAS_W
        for x in range(x0, x1 + 1):
            px = x + 0.5
            t = 0.0 if vv == 0 else max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / vv))
            dx, dy = px - (ax + vx * t), py - (ay + vy * t)
            if dx * dx + dy * dy <= r2:
                canvas[row + x] = 1


def _fill_quad(canvas, pts):
    """Set canvas pixels inside a convex polygon given as [(x, y), ...]."""
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, x1 = max(0, int(min(xs))), min(SIL_CANVAS_W - 1, int(max(xs)) + 1)
    y0, y1 = max(0, int(min(ys))), min(SIL_CANVAS_H - 1, int(max(ys)) + 1)
    n = len(pts)
    for y in range(y0, y1 + 1):
        py = y + 0.5
        row = y * SIL_CANVAS_W
        for x in range(x0, x1 + 1):
            px = x + 0.5
            inside = True
            for i in range(n):
                x_a, y_a = pts[i]
                x_b, y_b = pts[(i + 1) % n]
                if (x_b - x_a) * (py - y_a) - (y_b - y_a) * (px - x_a) < 0:
                    inside = False
                    break
            if inside:
                canvas[row + x] = 1


def make_silhouette(joints, base):
    """Rasterize a person-shaped mask from a kinect-style joint dict.

    Returns {"w", "h", "cx", "cy", "data"}: the mask cropped to its bounding
    box, the centroid pixel inside it, and the LA8 pixels (luminance 255,
    alpha 0/255) as base64. Image x grows with camera +x, image y downward.
    """
    canvas = bytearray(SIL_CANVAS_W * SIL_CANVAS_H)
    # Camera-space meters -> canvas pixels, with SpineBase near the canvas center.
    ox = SIL_CANVAS_W / 2.0 - base[0] * SIL_PX_PER_M
    oy = SIL_CANVAS_H * 0.52 + base[1] * SIL_PX_PER_M

    def px(name):
        j = joints[name]
        return ox + j[0] * SIL_PX_PER_M, oy - j[1] * SIL_PX_PER_M

    m = SIL_PX_PER_M
    head = px("Head")
    _fill_circle(canvas, head[0], head[1] + 0.02 * m, 0.12 * m)
    _fill_capsule(canvas, *px("Head"), *px("SpineShoulder"), 0.06 * m)   # neck
    sl, sr = px("ShoulderLeft"), px("ShoulderRight")
    hl, hr = px("HipLeft"), px("HipRight")
    _fill_quad(canvas, [(sl[0] - 0.04 * m, sl[1]), (sr[0] + 0.04 * m, sr[1]),
                        (hr[0] + 0.07 * m, hr[1] + 0.05 * m), (hl[0] - 0.07 * m, hl[1] + 0.05 * m)])
    for side in ("Left", "Right"):
        _fill_capsule(canvas, *px(f"Hip{side}"), *px(f"Knee{side}"), 0.08 * m)
        _fill_capsule(canvas, *px(f"Knee{side}"), *px(f"Ankle{side}"), 0.065 * m)
        _fill_capsule(canvas, *px(f"Ankle{side}"), *px(f"Foot{side}"), 0.06 * m)
        _fill_capsule(canvas, *px(f"Shoulder{side}"), *px(f"Elbow{side}"), 0.06 * m)
        _fill_capsule(canvas, *px(f"Elbow{side}"), *px(f"Hand{side}"), 0.05 * m)
        _fill_circle(canvas, *px(f"Hand{side}"), 0.065 * m)

    # Crop to the bounding box and find the centroid, like the blob tracker does.
    min_x, min_y, max_x, max_y = SIL_CANVAS_W, SIL_CANVAS_H, -1, -1
    sum_x = sum_y = count = 0
    for y in range(SIL_CANVAS_H):
        row = y * SIL_CANVAS_W
        for x in range(SIL_CANVAS_W):
            if canvas[row + x]:
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y
                sum_x += x
                sum_y += y
                count += 1
    if count == 0:
        return None
    w = max_x - min_x + 1
    h = max_y - min_y + 1
    la8 = bytearray(w * h * 2)
    for y in range(h):
        src = (min_y + y) * SIL_CANVAS_W + min_x
        dst = y * w * 2
        for x in range(w):
            la8[dst + 2 * x] = 255
            la8[dst + 2 * x + 1] = 255 if canvas[src + x] else 0
    return {
        "w": w, "h": h,
        "cx": int(sum_x / count) - min_x, "cy": int(sum_y / count) - min_y,
        "data": base64.b64encode(bytes(la8)).decode("ascii"),
    }


class Player:
    def __init__(self, pid, x, z, idle=False, style="kinect"):
        self.pid = pid
        self.x = x
        self.z = z
        self.style = style
        self.hands = {"L": REST["L"], "R": REST["R"]}
        self.phases = []
        self.phase_t = 0.0
        self.phase_from = dict(self.hands)
        self.script = [] if idle else list(SCRIPTS[pid])
        self.script_i = 0
        self.current = ""

    def _next_phase(self):
        if not self.phases:
            if not self.script:
                self.phases = [(1.0, {})]
            else:
                step = self.script[self.script_i % len(self.script)]
                self.script_i += 1
                name, hand = (step, "R") if isinstance(step, str) else step
                self.current = name if name.startswith("idle") else f"{name} ({hand})"
                if not name.startswith("idle"):
                    print(f"  player {self.pid}: {self.current}")
                self.phases = action(name, hand)
        self.phase_t = 0.0
        self.phase_from = dict(self.hands)

    def step(self, dt):
        if not self.phases:
            self._next_phase()
        dur, targets = self.phases[0]
        self.phase_t += dt
        f = min(1.0, self.phase_t / dur)
        f = f * f * (3 - 2 * f)  # smoothstep
        for hand, tgt in targets.items():
            src = self.phase_from[hand]
            self.hands[hand] = tuple(src[i] + (tgt[i] - src[i]) * f for i in range(3))
        if self.phase_t >= dur:
            self.phases.pop(0)
            self._next_phase()

    def joints(self, t):
        sway = 0.03 * math.sin(t * 1.3 + self.pid)
        bob = 0.01 * math.sin(t * 2.1)
        base = (self.x + sway, -0.05 + bob, self.z)
        out = {}
        for name, (x, y, z) in BASE_POSE.items():
            out[name] = (base[0] + x, base[1] + y, base[2] + z)
        for side in ("Left", "Right"):
            key = side[0]
            sh = out[f"Shoulder{side}"]
            hx, hy, hz = self.hands[key]
            out[f"Elbow{side}"] = (sh[0] + hx * 0.5 + (-0.05 if key == "L" else 0.05), sh[1] + hy * 0.5, sh[2] + hz * 0.5 + 0.05)
            out[f"Wrist{side}"] = (sh[0] + hx * 0.92, sh[1] + hy * 0.92, sh[2] + hz * 0.92)
            out[f"Hand{side}"] = (sh[0] + hx, sh[1] + hy, sh[2] + hz)
            out[f"HandTip{side}"] = (sh[0] + hx * 1.08, sh[1] + hy * 1.08, sh[2] + hz * 1.08)
            out[f"Thumb{side}"] = (sh[0] + hx + 0.03, sh[1] + hy, sh[2] + hz)
        return {k: [round(v[0], 3), round(v[1], 3), round(v[2], 3), 2] for k, v in out.items()}

    def packet(self, t):
        joints = self.joints(t)
        if self.style == "depth":
            return self.depth_packet(joints)
        return {
            "id": str(1000 + self.pid),
            "hands": {"l": "open", "r": "closed" if "bolt" in self.current else "open"},
            "joints": joints,
        }

    def depth_packet(self, joints):
        """The body format the OrbbecCamera extension emits, derived from the kinect joints."""
        def hand_state(key):
            hx, hy, hz = self.hands[key]
            rx, ry, rz = REST[key]
            away = math.sqrt((hx - rx) ** 2 + (hy - ry) ** 2 + (hz - rz) ** 2)
            return "tracked" if away > 0.15 else "rest"

        head_y = joints["Head"][1]
        hands_up = joints["HandLeft"][1] > head_y and joints["HandRight"][1] > head_y
        height = head_y + 0.12 - min(joints["FootLeft"][1], joints["FootRight"][1])
        sil = make_silhouette(joints, joints["SpineBase"])
        body = {
            "id": str(1000 + self.pid),
            "hands": {"l": hand_state("L"), "r": hand_state("R")},
            "hands_up": hands_up,
            "height": round(height, 3),
            "joints": {name: joints[name] for name in DEPTH_JOINTS},
        }
        if sil is not None:
            body["silhouette"] = sil
        return body


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7777)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--idle", type=int, choices=[1, 2], action="append", default=[],
                    help="make this player stand still (repeatable)")
    ap.add_argument("--style", choices=["kinect", "depth"], default="kinect",
                    help="body format: full Kinect skeletons or the depth-camera "
                         "extension's joints + silhouette (default: %(default)s)")
    args = ap.parse_args()

    # Kinect camera space: +x is to the sensor's left as seen from the sensor,
    # so player 1 (screen left, with mirroring on) gets a positive x.
    players = [Player(1, 0.6, 2.4, idle=1 in args.idle, style=args.style),
               Player(2, -0.6, 2.4, idle=2 in args.idle, style=args.style)]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"mock bridge ({args.style} style) -> {args.host}:{args.port} at {args.fps:g} fps (Ctrl+C to stop)")
    dt = 1.0 / args.fps
    t0 = time.perf_counter()
    frames = 0
    try:
        while True:
            t = time.perf_counter() - t0
            for p in players:
                p.step(dt)
            msg = {"t": round(t * 1000.0, 1), "bodies": [p.packet(t) for p in players]}
            sock.sendto(json.dumps(msg, separators=(",", ":")).encode("utf-8"), (args.host, args.port))
            frames += 1
            target = t0 + frames * dt
            delay = target - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
    except KeyboardInterrupt:
        print(f"\nstopped after {frames} frames")


if __name__ == "__main__":
    main()

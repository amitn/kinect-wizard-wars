# Building camera games on this pipeline

This document explains the architecture behind Wizard Wars so the same pipeline can drive other
games with the Orbbec Gemini 2 - or with a plain webcam, which the same layers accept. It covers the layers, the contracts between them, what to reuse
as-is, what to copy and adapt, how to test without a camera, how to ship, and the lessons from
real sessions. Read it top to bottom once; afterwards the "Recipe for a new game" section is
enough.

## 1. The stack in one picture

```
Orbbec Gemini 2 (USB 3)                                      any webcam
   │  color 640x360 @30 + depth 640x400 @30,                    │  640x480 @30 through Media Foundation
   │  depth aligned to color inside the extension               │  (Windows) or V4L2 (Linux)
   ▼                                                            ▼
extension/  OrbbecCamera (OrbbecSDK v2)                      extension/  WebcamCamera
   │  get_color_image(), get_depth_at(x, y, r),                 │  the same color interface; has_depth() is
   │  deproject_pixel(x, y, z), frame ids, intrinsics           │  false, depth queries answer 0, intrinsics
   │  + a depth-only blob tracker (fallback)                    │  come from an assumed field of view
   ▼                                                            ▼
game/scripts/settings.gd  autoload Settings: "auto" | "depth" | "rgb", which webcam, persisted
   ▼
extension/  RtmPose (C++, ONNX Runtime C API): crop -> 17 COCO keypoints, ~6.6 ms a person
game/addons/GDMP  MediaPipe Pose Landmarker inside Godot (fallback, Godot 4.4+)
   ▼
game/tracking/  (GDScript, reusable as a whole)
   RtmPoseProcessor     color frame -> RTMPose -> depth fusion, or size-based distance without depth -> camera-space XYZ
   PoseProcessor        the MediaPipe equivalent (fallback), same output
   PlayerIdentityTracker stable Player 1 / Player 2 ids
   PoseFilter           One Euro smoothing per joint
   GestureDetector      push, punch, swipe, arms_up, hands_together, jump, crouch
   BodyTracker autoload players, signals, gesture(player, name)
   ▼
game/scripts/tracking.gd   adapter: BodyTracker players -> "body frames" (the game's input format)
   │  also accepts the same frames over UDP from tools/mock_bridge.py or any bridge
   ▼
your game   reads BodyTracker directly (recommended) or the body frames (Wizard Wars does both)
```

Two principles run through every layer:

- **Measured depth is the truth.** MediaPipe finds joints in the image; the Gemini depth image,
  aligned to color, gives each joint its distance. MediaPipe's own z is never used as physical depth.
- **Game code never sees the camera or MediaPipe.** It sees `TrackedPlayer` objects in meters,
  in one documented coordinate system, and named gestures.

## 2. Coordinate systems

| Space | Where | Units | Notes |
|---|---|---|---|
| normalized image | `TrackedJoint.normalized_position` | 0..1 | MediaPipe output, x right, y down |
| pixel image | `TrackedJoint.image_position` | color pixels | 1280x720 by default |
| camera space | `TrackedJoint.position_3d`, `TrackedPlayer.position` | meters | +x image right, +y up, +z away from the camera. Origin at the color camera. |
| game space | your game | whatever | convert once, in one place |

The camera sees the player mirrored relative to what the player expects on a screen in front of
them. Wizard Wars mirrors x at the game boundary (`Wizard.mirror_x`), so "player's right hand"
appears on the screen's right, and the debug views draw the color image flipped for the same
reason. Keep that decision in exactly one place in a new game.

"Left" and "right" in `TrackedPlayer` are the **person's own** sides (MediaPipe convention).
The older body-frame format uses **image** sides (Kinect convention); `tracking.gd` swaps them.

## 3. The reusable layers

### 3.1 OrbbecCamera extension (`extension/`)

C++ node registered as `OrbbecCamera`. Start it, poll it. It owns the SDK pipeline, aligns depth
to color, and hands the main thread copies of the latest frames under a mutex; the SDK callback
never touches Godot objects.

```gdscript
var cam := ClassDB.instantiate("OrbbecCamera")
add_child(cam)
if cam.start():                               # false + get_last_error() when no camera
    var img: Image = cam.get_color_image()    # RGB8 copy, null before the first frame
    var fid: int = cam.get_color_frame_id()   # increments per color frame; use it to avoid reprocessing
    var z: float = cam.get_depth_at(640, 360, 2)             # median of 5x5, meters, 0 = unknown
    var z_near: float = cam.get_depth_percentile(640, 360, 3, 0.25)  # nearest-surface variant (hands)
    var p: Vector3 = cam.deproject_pixel(640, 360, z)        # camera space, meters
    var k: PackedFloat32Array = cam.get_intrinsics()         # [fx, fy, cx, cy] of the color camera
```

Other members: `stop()`, `is_running()`, `get_device_name()`, `get_timestamp()` (ms),
`get_color_width/height()`, `learn_background()` and `frame_received(bodies)` (the fallback blob
tracker), `set_debug_enabled(bool)` / `get_debug_image()` (depth view with blobs).

Build: `cd extension && scons platform=windows target=template_release orbbec_sdk=<SDK dir>`
(MSVC on Windows, or llvm-mingw cross-build from Linux; see the README). The SConstruct copies
`OrbbecSDK.dll` and the SDK's `extensions/` folder next to the built DLL. Both must ship with the game.

### 3.1b WebcamCamera (`extension/src/webcam_camera.cpp`)

The same node for a camera without depth. It answers the color half of `OrbbecCamera`'s interface
(`start`, `stop`, `is_running`, `get_color_image`, `get_color_frame_id`, `get_timestamp`,
`get_intrinsics`, `deproject_pixel`, `get_last_error`, `get_device_name`) plus `list_devices()`,
`set_device(index)`, `set_mode(w, h, fps)`, `set_horizontal_fov(deg)`. `has_depth()` tells the two
apart (`OrbbecCamera` has it too, returning true); `get_depth_at` and `get_depth_percentile` return 0.

Capture is a small backend per platform behind `webcam_backend.h`, delivering RGB8 (or a complete
JPEG for MJPG cameras, decoded on the main thread) from its own thread:

- **Windows**: Media Foundation's source reader, RGB32 out. The three MF DLLs are loaded at run time
  and `<initguid.h>` defines the GUIDs in that one file, so the extension links nothing new and still
  loads on a Windows without Media Foundation.
- **Linux**: V4L2, memory-mapped, YUYV first and MJPG second (with the standard Huffman tables put
  back, which UVC cameras are allowed to omit). CI tests it against `v4l2loopback` fed by ffmpeg.

`game/probes/webcam_probe.gd` lists the cameras and measures each:
`godot --headless --path game --script res://probes/webcam_probe.gd -- --no-camera --out=<dir>`.

**Without depth**, `RtmPoseProcessor._person_from_size()` stands in for the depth image: distance is
`focal * L / pixels` for body segments of reference length L (the second longest reading, since
foreshortening only ever shortens), every joint sits on that plane, and each arm segment reaches
`sqrt(L^2 - seen^2)` toward the lens, which is what gives a webcam player a punch. `GestureDetector`
reads the result exactly as it reads real depth; `BodyTracker` only lowers `forward_scale`, because
inferred reach reads short. A player whose hips are out of view (close, or at a desk) is measured by
shoulder width alone and accepted on a confident face and shoulders.

### 3.2 RtmPose (`extension/src/rtmpose.cpp`)

The pose model, in the extension. `initialize(model_bytes, threads)`, `infer(image, box)` returning
one `Vector3` (x px, y px, score) per COCO keypoint, `get_last_ms()`. It needs a crop: get it from
`OrbbecCamera.get_person_boxes()` or from the previous frame's keypoints, as
`rtm_pose_processor.gd` does. Built when SCons gets `onnxruntime=<dir>`; `tools/build_extension.sh`
does that. Details and numbers in `docs/RTMPOSE_PORT.md`.

### 3.3 GDMP (`game/addons/GDMP`, fallback)

Prebuilt MediaPipe for Godot. We use only `MediaPipePoseLandmarker`, `MediaPipeImage`,
`MediaPipeTaskBaseOptions`. It needs Godot 4.4 or newer and ships Windows x86_64, Linux x86_64 and
Linux arm64 libraries. The model file lives in `game/models/pose_landmarker_lite.task`; `full` and
`heavy` variants from the same MediaPipe release are drop-in replacements (more accuracy, more CPU).

### 3.4 Tracking layer (`game/tracking/`)

Copy the folder unchanged into a new project and register `BodyTracker` as an autoload. Public API:

```gdscript
BodyTracker.players            # Array[TrackedPlayer] sorted by id
BodyTracker.player_count
BodyTracker.get_player(0)      # Player 1 or null
BodyTracker.camera             # the camera in use: OrbbecCamera or WebcamCamera, null until one starts
BodyTracker.camera_kind        # "depth", "rgb" or ""
BodyTracker.describe_camera()  # "Orbbec Gemini 2 (RGB + depth)", "Surface Camera Front (RGB)"
BodyTracker.list_webcams()     # names for a settings menu; BodyTracker.rescan() looks again
BodyTracker.status             # human-readable state for a HUD
BodyTracker.camera_fps, BodyTracker.processor.poses_per_second, BodyTracker.processor.inference_ms

signal player_entered(player)
signal player_left(player)
signal tracking_started()
signal tracking_lost()
signal gesture(player, gesture_name)
signal players_updated(players)
signal camera_changed()        # another device, another kind, or none: never cache BodyTracker.camera
```

`TrackedPlayer`: `id`, `position` (hips centre, torso depth), `velocity`, `standing_height`,
`tracking_confidence`, `visible`, `is_crouching`, `is_jumping`, `arms_up`, `hands_together`,
`gestures` (name -> time it last fired), `joints` (33, by MediaPipe name) and accessors `head`,
`left_hand`, `right_hand`, `left_elbow`, `right_elbow`, `left_shoulder`, `right_shoulder`,
`left_foot`, `right_foot`, `shoulder_center()`, `has_gesture(name)`.

`TrackedJoint`: `position_3d` (filtered), `raw_position`, `velocity` (m/s), `image_position`,
`normalized_position`, `visibility`, `confidence`, `valid`, `depth_inferred`.

Gestures and their meaning (all thresholds are public vars on `BodyTracker.gestures`):

| Gesture | Rule |
|---|---|
| `punch_left` / `punch_right` | hand moves toward the camera fast, or travels 25 cm closer within 0.35 s, and ends 25 cm in front of the shoulders. Not while the hand is sweeping: an arm swept across the body points at the camera halfway through, so a hand at swipe speed with more sideways than forward travel is never a punch |
| `swipe_left` / `swipe_right` | hand at chest height, in front, moving sideways fast and travelling 35 cm within 0.4 s. Reaching out to the side first is the wind-up and is ignored (a hand that starts clear of the body and moves further out), so the gesture fires on the stroke across the body |
| `arms_up` | both wrists above the head (state, re-fires every 0.5 s) |
| `hands_together` | wrists within 18 cm in 3D |
| `jump` | body root rising faster than 1.2 m/s for several updates |
| `crouch` | hips lower than 75 percent of the standing hip height for several updates |

Distances and speeds scale with `standing_height / 1.7`, so children trigger with shorter moves.

Tuning knobs worth knowing: `PoseProcessor.play_near_m / play_far_m` (detections outside are
dropped), `min_score` (mean landmark visibility to count as a person), `arm_depth_limit_m`,
`PlayerIdentityTracker.max_match_distance`, `PoseFilter.min_cutoff / beta`.

### 3.5 Body-frame format and UDP (`game/scripts/tracking.gd`, `tools/mock_bridge.py`)

Wizard Wars predates the pose layer, so it consumes "body frames": dictionaries with a Kinect-style
joint set (`SpineBase`, `SpineShoulder`, `Head`, `HandLeft`, `HandRight`, feet, and optionally the
full 25) plus `hands_up`, `height` and an optional depth silhouette. `tracking.gd` builds these from
`BodyTracker` players, from the extension's blob tracker, or from UDP JSON on port 7777. That last
path is what makes development without a camera possible.

A new game can skip this format entirely and read `BodyTracker` directly. Keep the UDP path only if
you want the mock; in that case the cheapest route is to keep `tracking.gd` and `mock_bridge.py`
as they are and consume body frames.

## 4. Recipe for a new game

1. **Start from this repo.** Copy `extension/` (with the `godot-cpp` submodule), `game/addons/GDMP`,
   `game/models`, `game/tracking`, `game/orbbec.gdextension`, `game/export_presets.cfg`,
   `tools/mock_bridge.py`, `tools/split_sheet.gd` and `.github/workflows`. Project settings:
   Godot 4.4.1, `gl_compatibility`, autoload `BodyTracker`.
2. **Write the game against `BodyTracker`.** Example:

   ```gdscript
   func _ready() -> void:
       BodyTracker.gesture.connect(_on_gesture)
       BodyTracker.player_left.connect(func(p): _remove_avatar(p.id))

   func _process(_delta: float) -> void:
       for p in BodyTracker.players:
           var avatar := _avatar_for(p.id)
           avatar.position = camera_to_screen(p.position)        # your one mapping function
           avatar.hand_position = camera_to_screen(p.right_hand.position_3d)

   func _on_gesture(p: TrackedPlayer, g: String) -> void:
       match g:
           "punch_right", "punch_left": _throw(p)
           "arms_up": _shield(p)
           "jump": _hop(p)
   ```

   Put the camera-to-screen mapping (mirror, scale, lane clamping) in one function. Wizard Wars uses
   320 px per meter, mirrors x, and anchors each avatar's lane to the spot where its player was first
   seen so the avatars stay apart even when the players stand close together.
3. **Add a debug overlay early.** Copy `game/scripts/debug_overlay.gd` and `game/demo/`. Cycle it
   with a key: skeleton only, skeleton plus mirrored camera view with per-joint depth, off. You
   will spend most tuning time looking at it.
4. **Add a `--tracklog` style print** of what your game consumes twice a second. Reading numbers
   from a log after a session is faster than guessing from feel.
5. **Test without hardware** (section 5) until the loop is fun with the mock, then test with people.
6. **Ship** with CI (section 6).

## 5. Testing without a camera

- `tools/mock_bridge.py` streams two scripted players over UDP (`--style kinect` full skeletons,
  `--style depth` for the pose-style joint set with silhouettes, `--idle N` to freeze a player,
  `--port`). Run the game with `-- --tracking-port=<port>` to listen elsewhere than 7777.
- Headless smoke test, also what CI runs:
  `godot --headless --path game --quit-after 1500` with the mock streaming; grep the log for the
  round flow and script errors.
- Rendered screenshots: `godot --path game -- --screenshots=<dir> --shot-count=N --shot-interval=0.25 --shot-delay=S`
  writes PNGs on a timer; `--ko-at=T` knocks a player out T seconds into the fight for animation checks.
- Movies: `--write-movie out.avi --fixed-fps 30 --quit-after 1200` renders every frame; encode with ffmpeg.
- Unit tests with plain g++: `extension/tests/body_tracker_test.cpp` (fallback tracker) and
  `extension/tests/webcam_convert_test.cpp` (webcam pixel conversions).
- `game/tests/rgb_pose_test.gd` walks a synthetic player through the no-depth path in real time:
  distance from body size, reach from foreshortening, and which gestures a punch, a sweep with its
  wind-up, raised hands and standing still must and must not fire. `--trace` prints every frame.
  It is how gesture rules get changed without a person in front of a camera:
  `godot --headless --path game --script res://tests/rgb_pose_test.gd -- --no-camera --no-save`.
- Keyboard fallbacks: Wizard Wars maps casts to keys so the round logic is playable with no tracking at all. Do the same.

## 6. Shipping

`.github/workflows/build.yml` produces `WizardWars-windows-x64`, `WizardWars-windows-x64-signed-runner`
and `WizardWars-linux-x64` on every push: it downloads the Orbbec SDK, ONNX Runtime, the pose model
and Godot, builds the extension, exports the project, copies the runtime (`OrbbecSDK.dll`,
`extensions/`, `onnxruntime.dll`), the player guide and the licence files next to the binary, and runs
the binary headless to check the extension loads. A `v*` tag also runs the `release` job, which zips
the packages into a **draft** GitHub release; the tag is the version (`tools/ci_set_version.sh`).
`test.yml` runs the unit tests, a headless mock round and the webcam backend against a loopback
camera. Rename the artifact and the export path for a new game and the workflows carry over.

What a published build needs beyond "it runs": a settings menu with the camera choice and a live
preview (`settings_menu.gd`, `camera_view.gd`: players cannot debug a camera they cannot see), a
fullscreen default with `--windowed` for development, an icon (`tools/make_icon.gd`), exe metadata
(rcedit, set up in CI), a guide written for players (`docs/PLAYING.md`), and
`THIRD_PARTY_NOTICES.md` with the licence files of everything bundled.

Runtime facts to keep in mind:

- The camera must be on a **USB 3** port. Nothing else to install on Windows: the SDK is user-mode.
- On a **Windows on ARM** PC the x64 build runs under emulation and the camera works; MediaPipe runs
  at roughly 20 poses per second on CPU there.
- **Smart App Control** blocks unsigned exports, and Godot's export templates are unsigned. The
  official editor binary is signed and runs a `.pck` named after it, so the signed-runner package
  (that binary renamed `WizardWars.exe`, plus `WizardWars.pck` from `--export-pack`, plus the DLLs)
  starts with a double click where the export is refused. A code-signing certificate fixes the export itself.
- **Webcams on Windows** need "Let desktop apps access your camera" in the privacy settings; the
  backend turns the access-denied error into that sentence.
- If the game reports "No device found" while the camera is plugged in, check `usbipd list`: a camera
  attached to WSL is invisible to Windows until detached.
- Export presets must include `models/*.task`; the gdextension `[dependencies]` entries copy the SDK DLL.

## 7. Lessons from real sessions

- **Distance.** 2 to 2.5 m is the sweet spot. Closer than 1.2 m the feet leave the frame, the hips get
  unreliable and MediaPipe degrades; the layer falls back to a shoulder-based root and the HUD warns.
- **Children.** Expect 0.7 to 1.2 m tall players who walk up to the camera. Scale every distance and
  speed by standing height, and never rely on feet being visible.
- **Hands need the nearest surface.** A landmark a few pixels off the hand reads the wall behind it.
  Elbows, wrists and fingers use `get_depth_percentile(..., 0.25)`; everything else uses the median.
  Limbs farther than 0.8 m from the torso depth are treated as missing.
- **Phantoms.** MediaPipe reports background people, reflections and sometimes the same person twice.
  Filter by mean visibility, by play-area depth, and de-duplicate in image space (shoulder centre distance).
- **Ids.** Match by hips position in x/z with the torso depth as z; hips' own depth readings jump.
  Remember players for about 1.5 s so a dropped frame does not create a new id.
- **Velocity.** Compute it from raw positions with light smoothing; the One Euro filter that makes
  positions pretty also damps punch speeds. Offer a displacement-based trigger as well.
- **Persistence.** States like crouch and jump must hold for a few updates; single-frame jitter otherwise fires them.
- **Mirroring.** Decide once. Every bug report of "wrong hand" traces back to a second mirror somewhere.

## 8. Extending the pipeline

- **Hand landmarker** (GDMP `MediaPipeHandLandmarker`): finger poses for finer spells. Add it as a
  second processor on the same color frame; fuse depth the same way.
- **Silhouette mask**: the extension's blob tracker already produces a per-player mask from depth
  (`silhouette` in body frames). Use it for auras, particle collisions and shadows around the real body.
- **Calibration**: map a measured play volume (width, near, far, floor) to normalized game coordinates
  so games do not depend on the room.
- **Two cameras or a wider lens**: the extension is per device; a second `OrbbecCamera` node with its own
  pipeline is possible, identity merging is not built.

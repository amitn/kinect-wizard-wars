# Wizard Wars

Two-player motion duel. One player is the **fire wizard**, the other the **water
wizard**, and a camera is the controller: punch to throw a bolt, sweep for a wave,
raise both hands to shield. It plays with **any webcam (RGB)** or with an **Orbbec
Gemini 2 depth camera (RGB + depth)**. The game is a Godot 4 project with a C++
extension that reads the camera and runs the pose model; no Python, no GPU, no
driver install.

```
any webcam ------> Media Foundation / V4L2 --+        RGB: distance estimated from body size
                                             |
Orbbec Gemini 2 -> OrbbecSDK v2 -------------+        RGB + depth: distance measured per joint
                                             |
                       extension/  GDExtension (C++): WebcamCamera, OrbbecCamera, RtmPose (ONNX Runtime)
                                             v
                                 game/  (Godot 4.4, GDScript)  <-- Settings: which camera, mirror, sensitivity
                                             ^
                                             |  UDP JSON on port 7777 (development fallback)
                                 tools/mock_bridge.py
```

Players: **[how to play](docs/PLAYING.md)**. Ready-to-run Windows and Linux builds are on the
[Releases](https://github.com/amitn/kinect-wizard-wars/releases) page; GitHub Actions builds them on every push.

## Gestures

| Spell  | Gesture                                   | Cost | Effect |
|--------|-------------------------------------------|------|--------|
| Bolt   | Punch one hand straight at the camera     | 15   | 12 damage, fast |
| Wave   | Sweep a hand sideways in front of you     | 35   | 25 damage, slow, tall; absorbs bolts |
| Shield | Raise both hands above your head, hold    | 11/s | Blocks everything while held |
| Heal   | Press both hands together at your chest for a second | 30 | Restores 18 health, once every 5 seconds |

Mana regenerates at 12 per second. Health is 100. First to zero loses.
When the round is over, both players raise their hands together to rematch.

Elemental edges:
- Water beats fire in a clash: a water bolt survives a fire bolt at half power.
- Fire beats water's shield: a fire bolt drains 25 mana from a water shield, a water bolt only 10 from a fire shield.
- A wave loses a third of its power for every bolt it swallows.

## Playing

1. Download the package for your system from [Releases](https://github.com/amitn/kinect-wizard-wars/releases) (or the latest artifact from the Actions tab) and unpack it anywhere. On a Windows PC with Smart App Control, take the `signed-runner` package (see below).
2. Use whatever camera you have. A webcam needs nothing. For the Gemini 2, plug it into a USB 3.0 port; if the camera has never been used on the PC, run Orbbec's own *OrbbecViewer* once to confirm it streams.
3. Run `WizardWars.exe`. In **Auto** the game takes the depth camera when one is connected and a webcam otherwise; **Esc** opens the settings to choose the camera, with a live preview. The middle of the waiting screen shows what the camera sees.
4. Step in about 2 to 3 meters from the camera, one player on each side, whole body in view. The screen is a mirror: the player on the camera's left is the fire wizard on the left of the screen. If the two of you appear swapped, turn off *Mirror the players* in the settings.

### Cameras

| Setting | Camera | Distance to each joint | Notes |
|---------|--------|------------------------|-------|
| RGB + depth | Orbbec Gemini 2 (`OrbbecCamera`) | measured, from the depth image aligned to color | the most exact; punches are read from real depth along the forearm |
| RGB | any webcam (`WebcamCamera`: Media Foundation on Windows, V4L2 on Linux) | estimated: a reference body's segment lengths against their size in pixels, and an arm's reach toward the lens from how much it foreshortens | works at a desk with only the upper body in view |
| Auto | the depth camera when present, else a webcam | | the default |

Both feed the same pose model (RTMPose) and produce the same `TrackedPlayer`s, so the game and the gestures do not know which camera is in use. Settings live in `user://settings.cfg`; `--camera=auto|depth|rgb`, `--webcam=<index>`, `--windowed` and `--fullscreen` override them for one run.

Windows on ARM works too: the app and the SDK are x64 and run under emulation, and the camera needs no kernel driver.

### Tips from real sessions

- Stand 2 to 2.5 m from the camera, one player on each side. Closer than 1.5 m cuts the feet out of the picture and makes two players overlap; the tracker ignores anything closer than 1 m, farther than 3.6 m, or more than 1.8 m to the side.
- Children work: bodies down to 0.85 m are tracked and gesture reach scales with height.
- Press **D** for the tracker overlay: the camera's depth view with tinted blobs and markers (cyan centre, yellow head, red left hand, green right hand) plus per-body numbers.
- Run `WizardWars.console.exe -- --tracklog` to print a body summary twice a second for tuning.
- If the game says "No device found" on Windows, check that the camera is not attached to WSL (`usbipd.exe list`); `usbipd.exe detach --busid <id>` gives it back and the game reconnects by itself.

### Keyboard (works with or without a camera)

| Key | Action |
|-----|--------|
| Q / W / E / A | Fire wizard: bolt / wave / toggle shield / heal |
| I / O / P / K | Water wizard: bolt / wave / toggle shield / heal |
| Enter | Start a round even if nobody is tracked |
| R | Restart the round |
| B | Re-learn the empty-room background (depth-blob fallback tracker only) |
| D | Tracker debug overlay with the camera view |
| F11 | Toggle fullscreen |
| Esc | Settings: camera, mirror, gesture sensitivity, fullscreen, restart, quit |

## Art

Everything in `game/art/` is generated with an image model (the `gen-image-cli` skill drives the local Codex CLI) and post-processed by Godot itself:

- `<element>_<pose>.png`: wizard poses `idle`, `cast`, `shield`, `hit`, `collapse`, `prone`, `victory`, cut from one-row sheets so the character stays consistent. Sheets are generated on a flat magenta background and split with `tools/split_sheet.gd`, which keys the magenta to alpha and slices at empty columns:
  ```
  godot --headless -s tools/split_sheet.gd -- images/fire_side_sheet.png game/art fire idle cast shield hit
  ```
- `<element>_orb.png`, `<element>_barrier.png`, `shards.png`, `spell_circle.png`: effect sprites on black, drawn additively.
- `arena_backdrop.png`: the 16:9 arena painting; the arena shader adds motes, energy flares and the ground line on top.

The game runs without any of these files: `WizardFX` falls back to a procedural robed silhouette, drawn shield disc and shader-only arena. Sprites face right; the water wizard is mirrored in code to face the fire wizard.

## Body tracking (RTMPose, with or without depth)

Skeletons come from **RTMPose** (MMPose) running inside the camera extension in C++ through ONNX
Runtime. There is no person detector: a candidate crop sweeps the frame until somebody is found, and
after that their next crop comes from their own keypoints. With the Gemini 2 every keypoint is given
real depth; with a webcam `rtm_pose_processor.gd` estimates it (`_person_from_size`): a body segment
of known length L that spans p pixels is `focal * L / p` away, all joints sit on the plane at that
distance, and each arm segment reaches `sqrt(L^2 - seen^2)` toward the lens. Lengths are those of a
reference adult, so a child reads as an adult standing further back, which is what the height-scaled
gesture thresholds want. See `docs/RTMPOSE_PORT.md` for the design, the numbers and the build steps
(`tools/fetch_onnxruntime.sh`, `tools/fetch_rtmpose_model.sh`, `tools/build_extension.sh`).
MediaPipe remains the fallback and `--mediapipe` forces it.

### MediaPipe fallback

The previous engine: MediaPipe Pose Landmarker running inside Godot through [GDMP](https://github.com/j20001970/GDMP) (`game/addons/GDMP`, prebuilt for Windows and Linux x86_64 and Linux arm64), fed with the Gemini 2 color image. Each of the 33 landmarks gets its depth from the Gemini depth image aligned to color (median of a 5x5 window, widened when empty, carried over briefly when missing, torso depth as the last resort) and is deprojected into camera space with the color intrinsics. MediaPipe's own z is never used as physical depth.

The tracking layer in `game/tracking/` follows `NEW_INTEGRATION`:

- `body_tracker.gd` (autoload `BodyTracker`): owns the camera and the pose processor; `players`, `get_player(i)`, signals `player_entered`, `player_left`, `tracking_started`, `tracking_lost`, `gesture(player, name)`.
- `tracked_player.gd` / `tracked_joint.gd`: 33 joints with image, normalized and camera-space positions, visibility, velocity; convenience accessors `head`, `left_hand`, `right_hand`, feet; `is_crouching`, `is_jumping`, `arms_up`, `hands_together`.
- `pose_filter.gd`: One Euro filter per joint. `player_identity_tracker.gd`: stable Player 1 / Player 2 ids by hips position. `gesture_detector.gd`: push, punch_left/right, swipe_left/right, arms_up, hands_together, jump, crouch from positions and velocities, all thresholds tunable.
- `pose_processor.gd`: the GDMP live-stream pipeline plus depth fusion; stale frames are dropped rather than queued.

Camera space is meters: +x right (image right), +y up, +z away from the camera. The game's `Tracking` source adapts BodyTracker players into the older Kinect-style body frames, so gameplay code is unchanged; the depth-blob tracker in the extension remains the fallback when GDMP is unavailable, and `--no-camera` keeps the UDP path.

Press **T** in the game for `demo/body_tracking_demo.tscn`: the color image with skeletons, per-joint depth and XYZ, velocities, player ids, camera and inference rates.

GDMP needs Godot 4.4 or newer; the project targets 4.4.1. The model file is `game/models/pose_landmarker_lite.task` (swap in the `full` or `heavy` variant for accuracy at a CPU cost).

### Windows Smart App Control

Many new PCs ship with Smart App Control on, which blocks unsigned executables such as an exported `WizardWars.exe` (the code-integrity log shows "did not meet the Enterprise signing level requirements"). Godot's export templates are unsigned, but the official editor binary is signed and runs a `.pck` named after it. So CI also builds a **signed-runner** package: `WizardWars.exe` there is that signed binary, renamed, next to `WizardWars.pck` and the same DLLs. It starts with a double click where the normal export is refused. A code-signing certificate would make the normal export pass too.

During development the same trick runs the project folder:

```
Godot_v4.4.1-stable_win64_console.exe --path C:\path\to\game -- --tracklog
```

## How tracking works (fallback depth-blob tracker)

`extension/src/body_tracker.cpp` does all of it on a 320x200 depth image:

1. Background: the farthest depth seen per pixel during the first 45 frames.
2. Foreground: pixels between 0.5 m and 4 m that are at least 15 cm closer than the background.
3. Connected components, joining neighbours only when their depth differs by less than 20 cm, so two people standing apart stay separate. The two largest blobs are the players; ids follow people by centroid distance.
4. Per blob: centroid (hips), top and bottom, standing height (minimum height over the last 3 s), estimated shoulders and head.
5. Hands: the points farthest from the torso among those that are well sideways, well in front, or above the head. If only one arm is found it stays with the hand it was nearest to last frame, so a sweep across the body keeps its identity.
6. Both hands up: the silhouette is taller than the standing height and has two separate columns near the top.

The tracker ships with a synthetic-scene test:

```
cd extension
g++ -std=c++17 -O2 -Isrc tests/body_tracker_test.cpp src/body_tracker.cpp -o body_tracker_test && ./body_tracker_test
```

## Building

### GitHub Actions (the normal way)

`.github/workflows/build.yml` runs on every push: it downloads OrbbecSDK v2, ONNX Runtime, the pose model and Godot, builds the extension (MSVC on Windows, GCC on Linux), exports the Godot project, smoke-tests the binary headless, and uploads the `WizardWars-windows-x64`, `WizardWars-windows-x64-signed-runner` and `WizardWars-linux-x64` artifacts, each with `HOW_TO_PLAY.md` and the licences of what it bundles. `.github/workflows/test.yml` runs the unit tests, a headless mock round, and the V4L2 webcam backend against a loopback camera fed by ffmpeg.

### Releasing

```
git tag v1.0.0 && git push origin v1.0.0
```

The tag is the version (`tools/ci_set_version.sh` stamps it into the project and the exe metadata; the settings menu shows it). The `release` job zips the three packages with checksums into a **draft** GitHub release. Read it over on GitHub and press *Publish*. `THIRD_PARTY_NOTICES.md` lists what the packages contain and under which licences.

### Locally on Windows

Needs Visual Studio Build Tools (C++ workload), Python 3 with `pip install scons`, and the [OrbbecSDK v2 Windows x64 zip](https://github.com/orbbec/OrbbecSDK_v2/releases) unpacked somewhere.

```
git clone --recurse-submodules <this repo>
cd kinect-wizard-wars\extension
scons platform=windows target=template_release orbbec_sdk=C:\path\to\OrbbecSDK_v2.x.y_..._win_x64
scons platform=windows target=template_debug   orbbec_sdk=...     # for the editor
```

The SConstruct copies `OrbbecSDK.dll` and the SDK's `extensions/` folder next to the built DLL in `game\bin\windows\`. Then open `game/project.godot` in Godot 4.4 and press F5.

### Locally on Linux (including WSL2 on arm64)

Same commands with `platform=linux` and the Linux SDK tarball. Cross-compiling for Windows also works with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw):

```
scons platform=windows arch=x86_64 use_mingw=yes use_llvm=yes mingw_prefix=/path/to/llvm-mingw \
      orbbec_sdk=/path/to/OrbbecSDK_win_x64 target=template_release
```

### Testing without a camera

```
python3 tools/mock_bridge.py            # two scripted skeletons on 127.0.0.1:7777
python3 tools/mock_bridge.py --idle 2   # player 2 stands still
godot --headless --path game --quit-after 3600   # prints casts and hits
```

The game takes frames from the camera when one is present and from UDP otherwise. The status line at the bottom of the screen says which.

## Layout

```
extension/ the GDExtension (C++)
  src/body_tracker.cpp           depth-only people tracker (no SDK or Godot dependency)
  src/orbbec_camera.cpp          Godot node OrbbecCamera: OrbbecSDK pipeline, color + aligned depth
  src/webcam_camera.cpp          Godot node WebcamCamera: the same color interface over any webcam
  src/webcam_backend_win.cpp     Media Foundation capture (loaded at run time, nothing to link)
  src/webcam_backend_v4l2.cpp    V4L2 capture (YUYV, MJPG)
  src/webcam_convert.h           YUY2 / NV12 / BGRX to RGB, MJPG Huffman tables
  src/rtmpose.cpp                RTMPose through ONNX Runtime's C API
  tests/body_tracker_test.cpp    synthetic-scene test
  tests/webcam_convert_test.cpp  pixel conversion test
  SConstruct                     build script; stages the SDK runtime next to the DLL
  godot-cpp/                     submodule, Godot 4.3 C++ bindings
game/      Godot project
  orbbec.gdextension             where the built libraries live, and which SDK files to export
  export_presets.cfg             "Windows Desktop" preset used by CI
  scripts/settings.gd            autoload "Settings": user://settings.cfg, command-line overrides
  scripts/settings_menu.gd       the Esc menu
  scripts/camera_view.gd         live camera image with skeletons (waiting screen, menu, debug)
  tracking/                      BodyTracker autoload: camera choice, RTMPose, players, gestures
  scripts/tracking.gd            autoload "Tracking": BodyTracker's players or UDP, as body frames
  scripts/body_data.gd           one tracked person, joints and silhouette
  scripts/gesture_recognizer.gd  bolt / wave / shield detection, thresholds at the top
  scripts/wizard.gd              health, mana, gesture wiring
  scripts/wizard_fx.gd           the look: pose sprite or silhouette, aura shader, orbs, barrier, floor circle
  scripts/fx_ring.gd             expanding rune rings for casts and hits
  shaders/                       aura, robe, arena
  art/                           generated sprites and backdrop (see Art)
  scripts/spell.gd               projectiles
  scripts/main.gd                round flow, player assignment, collisions
  scripts/hud.gd                 bars and messages
tools/mock_bridge.py             fake tracking source for development
legacy/kinect/                   the original Kinect v2 sources, kept for reference
```

## Body frame format

The extension emits `frame_received(bodies)`; the UDP bridge sends the same as JSON, one datagram per frame:

```json
{"bodies": [{"id": "3",
             "hands": {"l": "tracked", "r": "rest"},
             "hands_up": false, "height": 1.72,
             "joints": {"SpineBase": [x, y, z, 2], "SpineShoulder": [...], "Head": [...],
                        "HandLeft": [...], "HandRight": [...], "FootLeft": [...], "FootRight": [...]},
             "silhouette": {"w": 40, "h": 110, "cx": 20, "cy": 60, "data": "<LA8 bytes>"}}]}
```

Joints are meters in the camera frame: +x to the image's right, +y up, +z away from the camera. The silhouette is optional; the game draws a stick figure when it is absent (the mock bridge sends full 25-joint Kinect-style skeletons).

## Tuning

Tracker thresholds: `BodyTracker::Params` in `extension/src/body_tracker.h`.
Gesture thresholds: top of `game/scripts/gesture_recognizer.gd`.
Damage, costs and elemental rules: top of `game/scripts/main.gd`, `spell.gd` and `wizard.gd`.

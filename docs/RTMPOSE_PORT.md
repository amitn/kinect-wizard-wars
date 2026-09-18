# RTMPose in the native build

Wizard Wars' skeletons now come from [RTMPose](https://github.com/open-mmlab/mmpose/tree/main/projects/rtmpose)
(the MMPose project's real-time model) running **inside the camera extension in C++ through ONNX
Runtime's C API**. No Python, no bridge process, no second runtime: the same DLL that talks to the
Gemini 2 also runs the pose model. MediaPipe (GDMP) stays in the build as the fallback and is one
flag away for comparison.

The port follows the one made for camera-pong-brick and reuses its code; this document is what is
specific to this game.

## Why

Measured on the same Windows-on-ARM PC, x64 under emulation:

| | MediaPipe (GDMP, in-engine) | RTMPose-t (ONNX Runtime, in-extension) |
|---|---|---|
| per frame | 32 ms empty room, 48 ms with a person | about 6.6 ms per person, about 1 ms empty |
| pose rate | 21 to 31 per second, inference-bound | the camera's 30 per second |
| joints | 33 | 17 (COCO) |

Punch and swipe detection lives on hand velocity. Hands that lag by 48 ms feel mushy; hands that
lag by one camera frame do not.

## How it is wired

```
OrbbecCamera (extension)   color + depth aligned to color
   │
   ├── get_person_boxes()  person-shaped depth blobs -> candidate crops (0.1 ms)
   │
   ├── RtmPose (extension) crop -> ONNX Runtime -> SimCC decode -> 17 keypoints (x, y, score)
   │
   ▼
game/tracking/rtm_pose_processor.gd   depth fusion + deprojection, the same `poses_ready` people
   ▼
BodyTracker, TrackedPlayer, gestures   unchanged
   ▼
Tracking adapter, Wizard Wars          unchanged
```

RTMPose is a top-down model: it wants a crop around one person. The usual deployment puts a
detector network in front of it, which costs more than the pose model. Here the crop comes from
two cheap sources instead: the depth camera's person-shaped blobs, and a sweep of one candidate
crop across the frame while nobody is tracked. Once a person is found, their next crop is their
own keypoints from the previous frame, eased so the crop does not chase jitter.

Files:

- `extension/src/rtmpose.cpp` / `.h`: the `RtmPose` class. Model bytes in (so it works from
  inside an exported `.pck`), input size, keypoint count and SimCC split ratio read off the graph,
  ImageNet normalisation, bilinear crop, argmax decode. Built only when `onnxruntime=<dir>` is
  passed to SCons, so the extension still builds without the runtime.
- `extension/src/orbbec_camera.cpp`: `get_person_boxes(near_m, far_m, min_height_frac)`.
- `game/tracking/rtm_pose_processor.gd`: the processor; COCO-17 mapped onto the MediaPipe joint
  indices `TrackedPlayer` uses, wrists standing in for the fingers COCO does not have, nearest-
  surface depth for wrists and elbows, torso depth as the fallback.
- `game/tracking/body_tracker.gd`: picks RTMPose when `RtmPose` exists and the model is present;
  `--mediapipe` forces the old path.
- `tools/fetch_onnxruntime.sh`, `tools/fetch_rtmpose_model.sh`, `tools/build_extension.sh`:
  dependencies into `third_party/` (gitignored) and the cross-build from Linux with llvm-mingw.

## Building

```
tools/fetch_orbbec_sdk.sh          # OrbbecSDK v2, win x64
tools/fetch_onnxruntime.sh         # ONNX Runtime 1.20.1, win x64 (C API only, links from llvm-mingw)
tools/fetch_rtmpose_model.sh       # rtmpose-t 256x192 -> game/models/rtmpose-t.onnx
tools/build_extension.sh           # -> game/bin/windows/liborbbecwizard...dll + OrbbecSDK.dll + onnxruntime.dll
```

`fetch_rtmpose_model.sh s` or `m` fetch the larger RTMPose-s / RTMPose-m models; rename the file or
change `MODEL_PATH` in the processor. CI does the same on the Windows and Linux runners.

The model is not committed (13 MB, its own licence); the export preset includes `models/*.onnx`
so a fetched model ships inside the `.pck`.

## Checking it

- The console prints `BodyTracker: RTMPose ready (in-extension, boxes from depth)` and the status
  line reads `RTMPose N poses/s`.
- `--tracklog` prints one `rtm box ...` line a second per person with the mean and wrist scores.
- `D` cycles the debug overlay; in the camera view the white rectangles are the candidate boxes.
- `godot --headless --path game --script res://rtmpose_probe.gd` benchmarks inference on a synthetic blob.

## What to watch with a real person

- Hands on the correct side: a COCO left/right swap shows up at once and is a one-line fix in
  `COCO_TO_JOINT`.
- `set_rgb_input(false)` in the processor if keypoints are plausible but consistently off: RTMPose
  trains on RGB, but some exported graphs swap channels.
- Two people close together share one depth blob; the sweep still finds both, the box padding
  then matters. `box_padding` is exposed on `RtmPose`.

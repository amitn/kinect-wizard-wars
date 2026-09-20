# Third-party notices

Wizard Wars is built on the work of others. The release packages contain the
components below; each keeps its own licence. The full Apache 2.0 text is in
`licenses/Apache-2.0.txt`, and the packages carry the licence files that ship
with the Orbbec SDK and ONNX Runtime under `licenses/`.

| Component | What it does here | Licence |
| --- | --- | --- |
| [Godot Engine](https://godotengine.org) 4.4 | game engine and runtime | MIT |
| [godot-cpp](https://github.com/godotengine/godot-cpp) | C++ bindings the camera extension is built with | MIT |
| [OrbbecSDK v2](https://github.com/orbbec/OrbbecSDK_v2) | depth camera access (Gemini 2) | MIT, plus Orbbec's terms for the `extensions/` libraries |
| [ONNX Runtime](https://onnxruntime.ai) 1.20 | runs the pose model | MIT |
| [RTMPose](https://github.com/open-mmlab/mmpose/tree/main/projects/rtmpose) (MMPose) | the body pose model, `rtmpose-t` | Apache 2.0 |
| [GDMP](https://github.com/j20001970/GDMP) | MediaPipe for Godot, the fallback pose engine | MIT |
| [MediaPipe](https://github.com/google-ai-edge/mediapipe) and its pose landmarker model | fallback pose engine | Apache 2.0 |

Webcam capture uses the operating system's own interfaces (Media Foundation on
Windows, V4L2 on Linux); nothing is bundled for it.

## Godot Engine

Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Godot itself includes third-party code. The notices its documentation asks
games to carry:

- **FreeType.** Portions of this software are copyright (c) 1996-2023 The
  FreeType Project (www.freetype.org). All rights reserved.
- **ENet.** Copyright (c) 2002-2020 Lee Salzman. MIT licence, same terms as above.
- **Mbed TLS.** Copyright The Mbed TLS Contributors. Licensed under the Apache
  License, Version 2.0.

The complete list is Godot's
[COPYRIGHT.txt](https://github.com/godotengine/godot/blob/4.4.1-stable/COPYRIGHT.txt).

## godot-cpp

Copyright (c) 2017-present Godot Engine contributors. MIT licence, same terms
as Godot's above.

## OrbbecSDK v2

Copyright (c) 2024-2026 Orbbec Inc. The SDK library is under the MIT licence,
same terms as above. The libraries in the SDK's `extensions/` directory are
under Orbbec's own terms: free for personal, academic and commercial use with
Orbbec products, no modification or reverse engineering. The SDK's licence file
and the notices of its own dependencies (libusb, libuvc, libyuv, libjpeg,
jsoncpp, spdlog, tinyxml2, live555, mdns, rosbag, cmrc, dylib) are in the
release packages under `licenses/orbbec/`.

## ONNX Runtime

Copyright (c) Microsoft Corporation. MIT licence, same terms as above. Its
`LICENSE` and `ThirdPartyNotices.txt` are in the release packages under
`licenses/onnxruntime/`.

## RTMPose / MMPose

Copyright (c) OpenMMLab. Licensed under the Apache License, Version 2.0. The
model file `rtmpose-t.onnx` is OpenMMLab's published
`rtmpose-t_simcc-body7_pt-body7_420e-256x192` export, unmodified.

> Jiang et al., "RTMPose: Real-Time Multi-Person Pose Estimation based on
> MMPose", arXiv:2303.07399, 2023.

## GDMP

Copyright (c) 2021-present Jason Kuo & contributors. MIT licence, same terms
as above.

## MediaPipe

Copyright 2019-present The MediaPipe Authors. Licensed under the Apache
License, Version 2.0. `pose_landmarker_lite.task` is Google's published model,
unmodified.

## Artwork

The sound effects and music are synthesized by this project's own
`tools/make_sounds.cpp`; no recordings or samples are used.

The wizard, spell and interface art was generated for this game with AI image
tools and edited by the author; the arena backdrop was supplied by the author.

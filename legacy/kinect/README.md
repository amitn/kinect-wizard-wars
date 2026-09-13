# Legacy: Kinect v2 sources

The project started on the Kinect v2 and moved to the Orbbec Gemini 2 because the
Kinect runtime is x64-only and cannot be installed on Windows on ARM. These files
are kept for reference and are not built:

- `kinect_v2.cpp` / `kinect_v2.h`: the KinectV2 GDExtension node (Kinect SDK 2.0, loads Kinect20.dll at runtime).
- `fix_kinect_header.py`: makes the SDK's MIDL headers compile with clang/GCC.
- `bridge/`: C# console app streaming Kinect skeletons over UDP.

The UDP body-frame format they produce is still what `tools/mock_bridge.py` sends
and what the game accepts as a fallback.

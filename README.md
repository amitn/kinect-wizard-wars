# Wizard Wars

Two-player motion duel for the **Orbbec Gemini 2** depth camera. One player is the
**fire wizard**, the other the **water wizard**. The game is a Godot 4 project with a
small C++ extension that reads the camera and tracks both players from depth alone,
no machine learning, no GPU, no driver install.

```
Orbbec Gemini 2 --USB3--> OrbbecSDK v2 (user-mode, ships with the app)
                               |
                               |  extension/  OrbbecCamera GDExtension (C++): depth -> silhouettes + hands
                               v
                         game/  (Godot 4.3, GDScript)
                               ^
                               |  UDP JSON on port 7777 (development fallback)
                         tools/mock_bridge.py
```

GitHub Actions builds the whole thing into a ready-to-run Windows x64 app on every push.

## Gestures

| Spell  | Gesture                                   | Cost | Effect |
|--------|-------------------------------------------|------|--------|
| Bolt   | Punch one hand straight at the camera     | 15   | 12 damage, fast |
| Wave   | Sweep a hand sideways in front of you     | 35   | 25 damage, slow, tall; absorbs bolts |
| Shield | Raise both hands above your head, hold    | 20/s | Blocks everything while held |

Mana regenerates at 12 per second. Health is 100. First to zero loses.
When the round is over, both players raise their hands together to rematch.

Elemental edges:
- Water beats fire in a clash: a water bolt survives a fire bolt at half power.
- Fire beats water's shield: a fire bolt drains 25 mana from a water shield, a water bolt only 10 from a fire shield.
- A wave loses a third of its power for every bolt it swallows.

## Playing

1. Download the latest `WizardWars-windows-x64` (or `WizardWars-linux-x64`) artifact from the Actions tab, unzip it anywhere.
2. Plug the Gemini 2 into a USB 3.0 port. If the camera has never been used on the PC, run Orbbec's own *OrbbecViewer* once to confirm it streams; the SDK's Windows notes also recommend registering frame metadata (see `scripts/env_setup/obsensor_metadata_win10.md` in the [SDK repo](https://github.com/orbbec/OrbbecSDK_v2)), which only affects timestamps.
3. Point the camera at an empty area, run `WizardWars.exe`, and stay out of view for the first two seconds: the game learns the empty room as background. Press **B** any time to re-learn it.
4. Step in about 2 to 3 meters from the camera, one player on each side. The screen is a mirror: the player on the camera's left is the fire wizard on the left of the screen. If the two of you appear swapped, flip `MIRROR` at the top of `game/scripts/main.gd`.

Windows on ARM works too: the app and the SDK are x64 and run under emulation, and the camera needs no kernel driver.

### Keyboard (works with or without a camera)

| Key | Action |
|-----|--------|
| Q / W / E | Fire wizard: bolt / wave / toggle shield |
| I / O / P | Water wizard: bolt / wave / toggle shield |
| Enter | Start a round even if nobody is tracked |
| R | Restart the round |
| B | Re-learn the empty-room background |
| Esc | Quit |

## Art

Everything in `game/art/` is generated with an image model (the `gen-image-cli` skill drives the local Codex CLI) and post-processed by Godot itself:

- `<element>_<pose>.png`: wizard poses `idle`, `cast`, `shield`, `hit`, `collapse`, `prone`, `victory`, cut from one-row sheets so the character stays consistent. Sheets are generated on a flat magenta background and split with `tools/split_sheet.gd`, which keys the magenta to alpha and slices at empty columns:
  ```
  godot --headless -s tools/split_sheet.gd -- images/fire_side_sheet.png game/art fire idle cast shield hit
  ```
- `<element>_orb.png`, `<element>_barrier.png`, `shards.png`, `spell_circle.png`: effect sprites on black, drawn additively.
- `arena_backdrop.png`: the 16:9 arena painting; the arena shader adds motes, energy flares and the ground line on top.

The game runs without any of these files: `WizardFX` falls back to a procedural robed silhouette, drawn shield disc and shader-only arena. Sprites face right; the water wizard is mirrored in code to face the fire wizard.

## How tracking works

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

`.github/workflows/build.yml` runs on every push: it downloads OrbbecSDK v2 and Godot, builds the extension (MSVC on Windows, GCC on Linux), exports the Godot project, smoke-tests the binary headless, and uploads `dist/` as the `WizardWars-windows-x64` and `WizardWars-linux-x64` artifacts. `.github/workflows/test.yml` runs the tracker unit test and a headless mock round. Tags starting with `v` build the same.

### Locally on Windows

Needs Visual Studio Build Tools (C++ workload), Python 3 with `pip install scons`, and the [OrbbecSDK v2 Windows x64 zip](https://github.com/orbbec/OrbbecSDK_v2/releases) unpacked somewhere.

```
git clone --recurse-submodules <this repo>
cd kinect-wizard-wars\extension
scons platform=windows target=template_release orbbec_sdk=C:\path\to\OrbbecSDK_v2.x.y_..._win_x64
scons platform=windows target=template_debug   orbbec_sdk=...     # for the editor
```

The SConstruct copies `OrbbecSDK.dll` and the SDK's `extensions/` folder next to the built DLL in `game\bin\windows\`. Then open `game/project.godot` in Godot 4.3 and press F5.

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
extension/ OrbbecCamera GDExtension (C++)
  src/body_tracker.cpp           depth-only people tracker (no SDK or Godot dependency)
  src/orbbec_camera.cpp          Godot node: OrbbecSDK pipeline -> tracker -> frame_received signal
  tests/body_tracker_test.cpp    synthetic-scene test
  SConstruct                     build script; stages the SDK runtime next to the DLL
  godot-cpp/                     submodule, Godot 4.3 C++ bindings
game/      Godot project
  orbbec.gdextension             where the built libraries live, and which SDK files to export
  export_presets.cfg             "Windows Desktop" preset used by CI
  scripts/tracking.gd            autoload "Tracking": picks the camera or UDP
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

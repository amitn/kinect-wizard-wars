# Wizard Wars - how to play

A duel for two players. One is the fire wizard, the other the water wizard, and
the controller is your body: a camera watches you and your wizard does what you do.

## What you need

- A Windows 10/11 or Linux PC (x86-64).
- A camera. Either of:
  - **any webcam** (RGB) - the one in a laptop is fine, or
  - an **Orbbec Gemini 2** depth camera (RGB + depth) - tracking is more exact,
    punches in particular, because distance is measured rather than estimated.
- Room to stand. Two players side by side, 2 to 3 metres from the camera, with
  the camera at about chest height and your whole body in view. Even lighting
  helps a webcam a lot.

## Start

Unpack the archive anywhere and run `WizardWars.exe` (Windows) or
`WizardWars.x86_64` (Linux). Nothing is installed.

**Windows says "Smart App Control blocked this app"?** Use the
`...-windows-x64-signed-runner.zip` download instead: same game, started by the
official signed Godot binary. With SmartScreen's "Windows protected your PC",
choose *More info* and then *Run anyway*.

**Windows and a webcam:** desktop apps must be allowed to use the camera
(Settings > Privacy & security > Camera).

**Linux and the Gemini 2:** install the SDK's udev rules once
(`99-obsensor-libusb.rules`) so the camera can be opened without root.

The game finds a camera by itself: the depth camera when one is plugged in,
otherwise a webcam. The picture in the middle of the waiting screen shows what
the camera sees; step back until your skeleton covers your whole body. The
round starts when both players are seen.

## Spells

| Move | Spell |
| --- | --- |
| **Punch** toward the camera | Bolt - fast, light damage |
| **Sweep** an arm sideways at chest height | Wave - slow, heavy, hard to block |
| **Both hands above your head** | Shield - blocks while it lasts, drains mana |
| **Press your hands together** at your chest for a second | Heal - costs mana, 5 second cooldown |

Every spell costs mana, which refills on its own. Fire boils through water's
shield faster; water bolts survive a clash with fire bolts. After a knockout,
both players raise their hands to fight again.

## Settings (Esc)

- **Camera** - *Auto*, *RGB + depth (Orbbec Gemini 2)*, or *RGB (any webcam)*,
  and which webcam. The preview shows the choice working before you leave the menu.
  *Rescan cameras* finds a camera plugged in after the game started.
- **Mirror the players** - turn off if you appear on the wrong side.
- **Gesture sensitivity** - *High* for small children or a small room, *Low*
  if spells go off by accident.
- **Fullscreen** (also F11), and whether the camera shows on the waiting screen.
- **Music** and **Sound effects** volume; all the way down is off.

Settings are kept between runs. To reset them delete `settings.cfg` in
`%APPDATA%\Godot\app_userdata\Wizard Wars` (Windows) or
`~/.local/share/godot/app_userdata/Wizard Wars` (Linux).

## Keyboard

For trying the game without a camera, or for the person at the keyboard:
fire wizard **Q** bolt, **W** wave, **E** shield, **A** heal; water wizard
**I** bolt, **O** wave, **P** shield, **K** heal. **Enter** starts a round,
**R** restarts it, **D** cycles the tracking debug view, **Esc** opens settings.

## If tracking misbehaves

- *Nobody is found* - check the preview in Settings. If the picture is there but
  no skeleton appears, step back and add light. If there is no picture, another
  app may be holding the camera.
- *Punches do not register with a webcam* - punch straight at the lens, a full
  arm's length, and try *High* sensitivity. A webcam infers reach from how much
  your arm foreshortens; a depth camera measures it.
- *The wrong thing is tracked* - plants and coat racks can look like people to
  a camera. Move them, or stand closer than they are.

## Your camera

The picture is used to find your pose and then dropped, frame by frame, in
memory. Nothing is recorded, stored or sent anywhere, and the game makes no
network connections.

Licences of the bundled components: `THIRD_PARTY_NOTICES.md`.

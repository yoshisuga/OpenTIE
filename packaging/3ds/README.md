# Nintendo 3DS build (experimental)

This builds `OpenTIE.3dsx` for a Nintendo 3DS running homebrew. It plays the
1995 Collector's CD-ROM edition (TIE95) with its original software renderer,
iMUSE music and touch controls, and can show flight in stereoscopic 3D. You
need your own TIE Fighter Collector's CD-ROM; no game data is included.

A **New Nintendo 3DS** (or New 2DS) is strongly recommended: OpenTIE uses its
faster CPU mode and its extra core. An original 3DS has not been tested.

## Building

The build needs devkitARM, libctru, citro2d/citro3d and 3ds-tools.
`build.sh` builds SDL3 (which has no devkitPro package) from source into a
prefix, applying the patches here, then OpenTIE. Without a local devkitPro,
run it in the devkitPro image from the repository root:

```sh
docker run --rm -v "$PWD":/src -w /src devkitpro/devkitarm packaging/3ds/build.sh
```

The result is `build/3ds/opentie/src/tie_3ds/OpenTIE.3dsx`. To send it to a
console whose Homebrew Launcher is waiting for a network transfer (press Y):

```sh
docker run --rm -v "$PWD":/src -w /src devkitpro/devkitarm \
    /opt/devkitpro/tools/bin/3dslink -a <console IP> build/3ds/opentie/src/tie_3ds/OpenTIE.3dsx
```

## Installing

1. Copy `OpenTIE.3dsx` to `sdmc:/3ds/` on the SD card.
2. Copy the game to `sdmc:/3ds/OpenTIE/TIE95/`, either:
   - the installed or copied contents of the Collector's CD-ROM, so that
     `STRINGS.DAT`, `RESOURCE/`, `MISSION/`, `RES320/` and `CP320/` sit
     directly in `TIE95/`; or
   - a disc image: an ISO renamed to `game.fil`, or GOG's `game.gog` and
     `game.ins`.
3. Sound needs the console's DSP firmware at `sdmc:/3ds/dspfirm.cdc` (dump
   it with DSP1 if it is missing).
4. Start OpenTIE from the Homebrew Launcher.

The 1994 floppy edition (no `RES320`/`CP320`) and the 1998 Windows edition
are not supported on the 3DS. Settings, pilots and checkpoints are kept in
`sdmc:/3ds/OpenTIE/`, with a log in `opentie.log`.

## Controls

- **Buttons (flight):** Circle Pad flies; B or ZR fires; A or ZL is the roll
  and throttle modifier; X targets the nearest fighter, Y the next target, L
  your attacker; R toggles the high-angle view; D-pad up/down sets full and
  lower throttle, right matches speed, left clears the target; START pauses;
  SELECT is Esc (the in-flight options room, or back).
- **Touch panel (cockpit flight):** the bottom screen becomes a control panel
  with tabs:
  - **MAIN:** next/previous target, nearest, attacker, weapon, link, match
    speed, throttle up/down (hold to repeat), laser/shield transfers and
    shield mode.
  - **PWR:** recharge rates, beam, SLAM and throttle presets.
  - **TGT:** attacker chain, newest, components, target view, clear, auto,
    tracking and target memories T1-T3 (tap to recall, hold to store).
  - **VIEW, INFO, CMD:** look views and cameras, the information rooms, and
    wingman orders.
  - **MSN:** pause, time compression, hyperspace, recorder, OK, Esc, and
    eject and end mission (hold until the bar fills).
  - **SAVE:** in-mission checkpoints in three slots (loading needs a hold).
  - **SYS:** stick inversion for pitch, yaw and roll, and gyro aiming.
- **Gyro aiming:** with GYRO on, turning and tilting the console steers like
  the Circle Pad, and the pitch inversion applies to both. Hold the console
  still for a moment as flight starts while it finds its rest position.
- **Menus and other screens:** the touchscreen is a trackpad. Drag to move
  the pointer, tap to click where it points (hold L for a right click), and
  touch still for a moment before dragging to drag with the button held.
  X opens the system keyboard for text such as pilot names.
- **3D:** in cockpit flight, the 3D slider renders the scene from two
  cameras. The cockpit stays at the screen and space sits behind it.

## How it works

- **Engine:** the TIE95 game, its runtime, Landru and iMUSE, without
  Aeron's GPU renderer, remaster or desktop application
  (`TIE_PLATFORM_3DS`). `src/tie_3ds` builds the platform-neutral part of
  Aeron and replaces its window, renderer and DirectDraw seam.
- **Presentation:** the 8-bit classic frame is written into a tiled GPU
  texture and drawn 4:3 on the top screen with citro2d. Flight is fixed at
  320x200, whose cockpit art fits the screen.
- **Stereo:** `src/tie_runtime/display/flight_stereo.c` renders the 3D scene
  a second time from a camera moved to the right, saving and restoring the
  state the renderer touches. The rasterizer's cockpit mask keeps the
  cockpit at screen depth and lets each eye's space shift for convergence.
- **Speed:** the New 3DS's 804 MHz mode is enabled, the music synthesizer
  runs on the second application core (`sdl-n3ds-thread-cores.patch`), and
  the build uses `-O3` with link-time optimization.
- **GPU flight (disabled):** `flight_gpu_3ds.c` is an early citro3d flight
  renderer, off by default (`k_gpu_flight` in `main_3ds.c`).

## Known limits

- Experimental: expect rough edges.
- Stereo flight runs at roughly 20-30 fps; laser bolts close to the camera
  look slightly off in 3D.
- Cutscenes are 2D.
- OpenTIE's own settings menu is not available; the SYS tab covers stick
  inversion and gyro aiming. Music uses the OPL3 synthesizer.

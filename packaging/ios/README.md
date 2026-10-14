# iOS and iPadOS build (experimental)

This builds `OpenTIE.app` for an iPhone or iPad, or for the iOS Simulator. It
runs the same engine as the desktop builds: SDL3's GPU API draws through Metal,
so the classic and modern graphics, iMUSE music and both editions work as they
do on a Mac. You need your own TIE Fighter installation; no game data is
included.

## How it works

- **Graphics:** SDL_GPU on Metal, with the HLSL shaders compiled to MSL on
  the Mac by SDL_shadercross. On the Simulator, SDL needs
  `sdl-gpu-simulator.patch`: the Simulator's GPU reports only the Apple2
  family, though it runs on the Mac's GPU.
- **Game folders:** at launch, OpenTIE looks for TIE95 and TIE98 installations
  directly inside the app's Documents folder, so a fresh install needs no
  setup beyond copying the games there. Saved paths inside Documents are
  moved to the current app container at launch, since iOS moves it when the
  app is updated or reinstalled.
- **Touch controls:** a UIKit overlay over SDL's view
  (`src/tie_app/ios/ios_app.m`). The buttons sit in the black bars beside the
  4:3 picture; on a screen without bars they overlap its edges.
  - **Flying:** put a thumb down anywhere outside the buttons and drag; that
    is the flight stick. It drives a virtual SDL gamepad, so it uses the
    gamepad's axis settings.
  - **Right bar:** THR+ and THR− (hold to repeat), WPN, LINK, NEAR, ATKR,
    TGT◀ and TGT▶, MATCH, ROLL and FIRE. Hold ROLL and use the stick to roll
    and set the throttle, as with a joystick's second button; a tap targets
    the craft under the sight.
  - **Left bar:** ESC, KEYS (the screen keyboard), a throttle slider, and two
    panels that fold away: PWR (laser, shield and beam recharge rates,
    transfers between lasers and shields, shield mode, beam on/off) and MEM
    (target memories T1–T3: tap to recall, hold to store). The engines get
    the power the recharge rates leave, as in the original. The panels stay
    open or closed between launches.
  - **Top row:** PAUSE, OK (confirm), TGT VIEW (the target viewer), and
    submenus INFO (map, goals, messages, damage), VIEW (cockpit, external
    camera and its controls, missile camera) and CMD (wingman orders,
    reinforcements, hyperspace). One submenu opens at a time.
  - **Menus and briefings:** ESC, KEYS and SKIP; tap anywhere else to click.
    A tap ends the current cutscene scene; SKIP (Enter) skips the sequence.
  - **Paused:** PAUSE stays to resume.
  - **Game controllers:** the touch controls step aside when a controller is
    used, and come back on the next touch.

## Requirements

- macOS with Xcode
- CMake 3.23 or later, Ninja, pkg-config, Git and Make
- Autoconf, Automake and Libtool (for SpeexDSP)

```sh
brew install autoconf automake cmake libtool ninja pkg-config
```

## Building

Run from the repository root.

**Simulator:**

```sh
packaging/ios/build-package.sh simulator
xcrun simctl install booted build/ios/simulator/OpenTIE.app
```

**iPhone or iPad:** you need a development signing identity and a
provisioning profile that covers the bundle ID. A wildcard team profile works.

```sh
export IOS_CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
export IOS_PROVISIONING_PROFILE=/path/to/profile.mobileprovision
export IOS_BUNDLE_ID=com.example.opentie
packaging/ios/build-package.sh device
xcrun devicectl device install app --device <device-id> build/ios/device/OpenTIE.app
```

The first run builds SDL3, zstd, SpeexDSP and FFmpeg for the device or
Simulator under `build/ios/<device|simulator>`, and SDL_shadercross for the
Mac under `build/ios/host`. SDL_shadercross includes the DirectX shader
compiler, so that first build takes a while; later builds reuse it.

`TIE_BUILD_TYPE=Debug` builds with the in-game debug UI. `TIE_VERSION`,
`TIE_IOS_BUILD_VERSION` and `TIE_IOS_DEPLOYMENT_TARGET` (16.0 by default) set
the bundle's version and minimum iOS.

## Game files

Copy each edition's complete installation folder into the app's Documents
folder: in the Files app it is **On My iPhone › OpenTIE**, and Finder shows
it under the device's **Files** tab. A new install creates empty `TIE95` and
`TIE98` folders there to copy into; any folder names work.

You can also copy from the Mac:

```sh
xcrun devicectl device copy to --device <device-id> --domain-type appDataContainer \
    --domain-identifier com.example.opentie --source /path/to/TIE98 --destination Documents/TIE98
```

SC-55 ROMs work the same way: put them in a folder in Documents and choose it
in the setup window or in OpenTIE Settings.

## Not done yet

- FluidSynth (OPL3 and SC-55 MIDI work)
- gyro aiming
- time compression, component targeting and other less common keys on the
  touch screen
- moving and resizing the touch buttons

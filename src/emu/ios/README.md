# EKA2L1 — iOS port

A native iOS frontend for the EKA2L1 Symbian/N-Gage emulator. It reuses the full
emulator core (kernel, CPU JIT, services, drivers) and adds an iOS-specific
platform layer + a UIKit application, mirroring the Android port's design.

## Status

* Builds and runs on the **iOS Simulator** (arm64, iOS 15+). Verified on the
  iOS 26 simulator with Xcode 26.
* The whole emulator core cross-compiles, including the **dynarmic** ARM JIT
  (emits arm64 via oaknut — works under the simulator's JIT permissions).
* Rendering uses **OpenGL ES 3.0** through a new EAGL/`CAEAGLLayer` GL context.
* Audio uses a native **RemoteIO AudioUnit** output backend (see
  `src/emu/drivers/src/audio/backend/ios/audio_ios.mm`).
* Touch input, app installation (.sis/.sisx), device installation (ROM/RPKG),
  and the app launcher are wired up through a C++/Objective-C++ bridge.

### Not yet done / limitations
* **On-device** builds are untested. Device builds additionally require code
  signing and the JIT entitlement situation differs from the simulator.
* Native text-entry / yes-no dialogs auto-complete (no UIAlertController wiring yet).
* No game-controller support (iOS has no SDL2 path here).

## Building & running

```sh
./build_ios.sh          # configure + build + install + launch (from repo root)
./build_ios.sh build    # build only
./build_ios.sh run      # install + launch only
```

The script:
1. Uses a cached **CMake 3.31** (downloaded once to `~/Library/Caches/eka2l1-ios`).
   CMake 4.x cannot configure several of EKA2L1's older submodules (e.g. capstone
   forces the removed `CMP0048 OLD` policy).
2. Cross-compiles FFmpeg for the simulator once (`src/external/ffmpeg/build-ios-sim.sh`).
3. Configures with `-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator
   -DCMAKE_OSX_ARCHITECTURES=arm64`.
4. Ad-hoc signs the `.app` (required even on the simulator) and installs it.

`DEVELOPER_DIR` is exported to the full Xcode so `xcrun`/CMake find the iOS SDK.

## Using the app

Like the Android version, you must supply your own **Symbian ROM** (and an RPKG
firmware patch file for older firmwares) — these are proprietary and not shipped.

1. Launch the app → it shows *"No Symbian device installed"*.
2. **Install Device** → pick a ROM (and an `.rpkg` if required) from the Files app.
   The guest OS boots and renders into the GL view.
3. **Install Game** → pick a `.sis`/`.sisx` package.
4. **Apps** → tap an installed app to launch it.

Files can be added to the app's *Documents* via Finder (the app enables file
sharing) or the Files app.

## Layout

```
src/emu/ios/
  app/            UIKit application (AppDelegate, RootViewController, EmulatorView)
  include/ios/    bridge / state / launcher / window / thread headers
  src/            platform glue:
    emu_bridge.mm    C++ API the UIKit app calls
    state.cpp        emulator lifecycle (port of android/state.cpp)
    thread.cpp       OS + graphics threads
    launcher.cpp     launcher controller (port of android/launcher.cpp, no JNI)
    emu_window_ios.cpp  emu_window backed by the CAEAGLLayer surface
    input_dialog.cpp / applauncher.mm  drivers::ui + common glue
```

The EAGL GL ES context itself lives in the drivers library:
`src/emu/drivers/src/graphics/backend/context_eagl.{h,mm}`.

# Xcode builds: iOS and macOS

Open `KestrelFrontier.xcodeproj`. Choose the shared `KestrelFrontier-iOS`
scheme for iPhone and iPad, or `KestrelFrontier-macOS` for a native Mac build.
Both schemes support Debug, Release, and Archive. The Mac target builds and
embeds the game module (`SpaceFight.dylib`, from `Games/SpaceFight/Game`) automatically;
the iOS target compiles that game into the app and ships only its `Games/` folder.

For iOS, select an iPhone or iPad simulator to build and run. For a physical device,
choose your development team under Signing & Capabilities. Xcode compiles
the game directly and bakes its SceneKit models in DerivedData. Xcode-built
apps are named `KestrelFrontier.app` and display as **Kestrel Frontier**.

Regenerate after adding or removing source files:

```sh
sh Tools/Xcode/generate.sh
```

The generator uses an installed Python 3.9+ and works offline. Set
`FLIGHTSIM_PYTHON` to an installed interpreter if needed. The generator keeps
the shared scheme and existing signing settings. Pass `--team` or
`--bundle-id` to set those explicitly.

## Command line

Build either shared Xcode scheme without device signing:

```sh
xcodebuild -project KestrelFrontier.xcodeproj -scheme KestrelFrontier-macOS \
    -configuration Debug -destination 'platform=macOS' build
xcodebuild -project KestrelFrontier.xcodeproj -scheme KestrelFrontier-iOS \
    -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

The existing `build.sh` and Make targets below retain their legacy output paths.

On a Mac with Xcode and an installed iOS Simulator runtime:

```sh
./build.sh ios-simulator
app="build/iOS/iphonesimulator-$(uname -m)/SpaceFight.app"
xcrun simctl install booted "$app"
xcrun simctl launch booted com.igor.spacefight
```

For a paired physical device with Developer Mode enabled:

```sh
make iphone
make ipad
make ios-devices
make ipad DEVICE="My iPad"
```

The deploy targets build, sign, install, and launch the game on the requested
device family. They prefer a single USB-connected device when several are
available. Set `DEVICE` to a name, hardware UDID, or CoreDevice identifier to
choose explicitly. Unlock the device before launch.

Signing uses a local Apple Development identity and a development provisioning
profile covering both the device and `com.igor.spacefight`. Use
`PROFILE=/path/to/profile.mobileprovision` or `TEAM=<team-id>` to select signing
credentials, or set `BUNDLE_ID` to the identifier covered by your profile.
`./build.sh ios-device` still creates the unsigned bundle at
`build/iOS/iphoneos-arm64/SpaceFight.app`. Command-line builds share a model bake cache.

The game runs in either landscape orientation. The flight controls are centered
vertically on both iPhone and iPad.

In a mission, drag the left stick to pitch and yaw. Stay inside the ring for
fine adjustments, or pull past it for faster turns. The stick stretches past
the ring and reaches full steering at twice the ring's radius. It returns to
center when released. The throttle slider on the right holds its position. Hold **Fire**
for guns, tap **Target** to cycle the selection, and tap **Torpedo** to fire at
the selected target. **Missions** leaves the current mission.

When iOS exposes a connected controller through the extended Game Controller
profile, the touch flight controls hide. Use the left stick to steer, right
stick to roll, bumpers for throttle, right trigger for guns, left trigger for
boost, Y for targeting, B for torpedoes, and X for the camera. Use the D-pad and
A in menus. Disconnecting restores touch input at the current throttle.

Console commands and cvars (see `CONSOLE.md`) go after the bundle id as
launch arguments, or in the scheme's arguments in Xcode. To verify the touch
layout in Simulator even when it passes through a Mac controller:

```sh
xcrun simctl launch booted com.igor.spacefight +set in_touchOnly 1
```

For a quick flight check, add `+set net_port 0 +map 1`.

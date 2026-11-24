# Local builds and testing on Apple platforms

On a Mac with the Apple SDK command-line tools installed, run from the
repository root:

```sh
make macos
make ios-simulator
make ios-device
make racing-simulator
make racing-ios
```

These targets only build local apps. Neither signing for distribution nor
uploads run as part of a build or CI. See [PUBLISHING.md](../PUBLISHING.md) for
the output paths and manual publishing boundary.

With an iOS Simulator already booted:

```sh
app="build/iOS/iphonesimulator-$(uname -m)/KestrelFrontier.app"
xcrun simctl install booted "$app"
xcrun simctl launch booted com.corepunch.spacefight
```

Arcline uses `Games/Racing/build/ios/iphonesimulator-$(uname -m)/Racing.app`
and simulator bundle identifier `com.corepunch.arcline`.

For a paired physical device with Developer Mode enabled:

```sh
make iphone
make ipad
make ios-devices
make ipad DEVICE="My iPad"
make racing-iphone
make racing-ipad DEVICE="My iPad"
```

The deploy targets build, sign, install, and launch the game on the requested
device family. They prefer a single USB-connected device when several are
available. Set `DEVICE` to a name, hardware UDID, or CoreDevice identifier to
choose explicitly. Unlock the device before launch.

Signing uses a local Apple Development identity and a development provisioning
profile covering the device and the chosen app's bundle identifier. Use
`PROFILE=/path/to/profile.mobileprovision` or `TEAM=<team-id>` to select a local
profile, or explicitly set `BUNDLE_ID` for a development install with a
different identifier. `make ios-device` and `make racing-ios` only create
unsigned device bundles. Flight builds share a model bake cache.

The game runs in either landscape orientation. The flight controls are centered
vertically on both iPhone and iPad.

In a mission, the system's on-screen game controller appears. Drag the left
stick to pitch and yaw (dragging up climbs). Push the right stick up or down to
raise or lower the throttle and left or right to roll; hold it fully up at full
throttle to boost. X fires the guns, A fires a torpedo at the target and Y
cycles the target. B, the outer corner of the button cluster, opens the pause
menu. The buttons use the system's X, A, Y and B glyphs. A matching control
guide appears before mission launch, in pause and in the fixed-button settings;
it switches to the connected controller's symbols when a physical pad is used.

When iOS exposes a connected controller through the extended Game Controller
profile, the on-screen controller hides. The left stick steers (pushed forward
dives), the right stick rolls, the bumpers move the throttle, the right trigger
fires the guns, the left trigger boosts, B fires a torpedo, Y cycles the target
and X switches the camera. Menu or Select pauses. Use the D-pad and A in menus.
Disconnecting brings the on-screen controller back at the current throttle.

Console commands and cvars (see `CONSOLE.md`) go after the bundle id as
launch arguments. To verify the touch
layout in Simulator even when it passes through a Mac controller:

```sh
xcrun simctl launch booted com.corepunch.spacefight +set in_touchOnly 1
```

For a quick flight check, add `+set net_port 0 +map 1`.

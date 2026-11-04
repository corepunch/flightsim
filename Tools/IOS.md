# iPhone and iPad build

On a Mac with Xcode and an installed iOS Simulator runtime:

```sh
./build.sh ios-simulator
app="build/iOS/iphonesimulator-$(uname -m)/SpaceFight.app"
xcrun simctl install booted "$app"
xcrun simctl launch booted com.igor.spacefight
```

The simulator and Mac builds reuse the same model bake cache. For a physical
device, `./build.sh ios-device` creates
`build/iOS/iphoneos-arm64/SpaceFight.app`. Sign and provision that bundle with
your Apple Development identity before installing it on an iPhone or iPad.

The game runs in either landscape orientation. The flight controls sit halfway
down the screen on iPhone and two-thirds down on iPad.

In a mission, drag the left stick to pitch and yaw. It returns to center when
released. The throttle slider on the right holds its position. Hold **Fire**
for guns, tap **Target** to cycle the selection, and tap **Torpedo** to fire at
the selected target. **Missions** leaves the current mission.

When iOS exposes a connected controller through the extended Game Controller
profile, the touch flight controls hide. Use the left stick to steer, right
stick to roll, bumpers for throttle, right trigger for guns, left trigger for
boost, Y for targeting, B for torpedoes, and X for the camera. Use the D-pad and
A in menus. Disconnecting restores touch input at the current throttle.

To verify the touch layout in Simulator even when it passes through a Mac
controller, launch with `SIMCTL_CHILD_SF_TOUCH_ONLY=1`. For a quick flight
check, also pass `SIMCTL_CHILD_SF_MISSION=1 SIMCTL_CHILD_SF_NO_UDP=1`.

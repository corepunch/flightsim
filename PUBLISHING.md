# Test builds and publishing

Builds use Make and the Apple SDK command-line tools on macOS. There are no
checked-in IDE projects, generation steps, or store uploads in the build path.

| Product | Command | Local test output |
| --- | --- | --- |
| FlightSim (Kestrel Frontier), macOS | `make macos` | `build/KestrelFrontier.app` |
| FlightSim, iOS simulator | `make ios-simulator` | `build/iOS/iphonesimulator-<arch>/KestrelFrontier.app` |
| FlightSim, iOS device | `make ios-device` | `build/iOS/iphoneos-arm64/KestrelFrontier.app` |
| Arcline, iOS simulator | `make racing-simulator` | `Games/Racing/build/ios/iphonesimulator-<arch>/Racing.app` |
| Arcline, iOS device | `make racing-ios` | `Games/Racing/build/ios/iphoneos-arm64/Racing.app` |

The default `make all` compiles and links the native flight targets. GitHub CI
runs that target plus the headless unit suite on macOS. It does not sign,
archive, upload to TestFlight or the App Store, submit for review, or release.
It does not load any Apple account credentials.

## Local validation

Arcline iOS keeps `com.corepunch.arcline`, its source version/build, original
app icons, audio, privacy manifest, and `_arcline._udp` service. It is not
packaged inside the flight app. The iOS device build uses arm64; simulator
builds default to the host architecture. Arcline's former Mac Catalyst ID
`com.racing.app.desktop` is reserved but no Catalyst bundle is built by Make.

Test LAN without signing or needing a device: `make racing-net-test`.
For physical devices, `make iphone` and `make ipad` install FlightSim;
`make racing-iphone` and `make racing-ipad` install Arcline. These are separate,
explicit local development operations and require a matching profile on the
Mac. The unsigned app targets alone do not install anything. See
[local device testing](Tools/IOS.md).

## Manual distribution

The owner prepares and signs distribution packages separately and explicitly
uploads and submits them. Test bundles above are not distribution archives.
Keep the existing app identities: `com.corepunch.spacefight` for regular
FlightSim distribution and `com.corepunch.arcline` for Arcline iOS. Do not add
upload, App Store Connect credentials, submission, or release steps to Make
or CI. The existing FlightSim [manual operator commands](Tools/APPSTORE.md)
are not called by any build target or GitHub workflow.

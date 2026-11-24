# Test builds and publishing

Builds use Make and the Apple SDK command-line tools on macOS. There are no
checked-in IDE projects or generation steps, and no build target uploads anything.

| Product | Command | Local test output |
| --- | --- | --- |
| FlightSim (Kestrel Frontier), macOS | `make macos` | `build/KestrelFrontier.app` |
| FlightSim, iOS simulator | `make ios-simulator` | `build/iOS/iphonesimulator-<arch>/KestrelFrontier.app` |
| FlightSim, iOS device | `make ios-device` | `build/iOS/iphoneos-arm64/KestrelFrontier.app` |
| Arcline, iOS simulator | `make racing-simulator` | `Games/Racing/build/ios/iphonesimulator-<arch>/Racing.app` |
| Arcline, iOS device | `make racing-ios` | `Games/Racing/build/ios/iphoneos-arm64/Racing.app` |

| App Store package | Command | Output |
| --- | --- | --- |
| FlightSim, iOS | `make archive-ios` | `build/Archives/KestrelFrontier-ios-<version>-<build>/KestrelFrontier.ipa` |
| FlightSim, macOS (universal) | `make archive-macos` | `build/Archives/KestrelFrontier-macos-<version>-<build>/KestrelFrontier.pkg` |
| Arcline, iOS | `make racing-archive` | `build/Archives/Racing-ios-<version>-<build>/Racing.ipa` |

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

## Distribution

The archive targets follow the direct route in `~/Developer/PUBLISHING.md`
(section 4b). `Tools/archive.sh` builds the release app, keeps its dSYMs beside
the package, strips the binaries, and `Tools/sign-distribution.py` signs it with
the keychain's Apple Distribution identity, the installed App Store profile for
the bundle ID (`PROFILE=path` picks one) and the checked-in entitlements plus the
identifiers that profile grants. `Tools/stamp-bundle.py` gives every bundle the
SDK and toolchain keys Xcode writes. An IPA is checked with
`asc ipa-info --verify-signature`. The Mac package also needs a Mac Installer
Distribution identity in the keychain; an Xcode cloud-managed certificate has no
local private key and cannot sign it.

Uploading, attaching a build and submitting stay separate, explicit `asc` steps
([Tools/APPSTORE.md](Tools/APPSTORE.md)); no Make target or CI job uploads,
submits or holds App Store Connect credentials. Keep the existing app identities:
`com.corepunch.spacefight` for FlightSim on both platforms and
`com.corepunch.arcline` for Arcline iOS.

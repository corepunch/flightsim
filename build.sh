#!/bin/zsh
# Builds SpaceFight.app. Usage: ./build.sh [run|ios-simulator|ios-device|iphone|ipad]
#
# Sources/Shared  protocol, flight model and data tables (engine and game)
# Sources/Game    the game module: all gameplay, behind GameAPI.h
# Sources/Engine  server, client, renderer, UI and the app itself
set -e
cd "$(dirname "$0")"

log() {
    printf '[build +%ss] %s\n' "$SECONDS" "$*"
}

APP=build/SpaceFight.app
mkdir -p build
zmodload zsh/system
: >> build/.lock
if ! zsystem flock -t 0 -f build_lock build/.lock 2>/dev/null; then
    log "Waiting for the current build to finish"
    zsystem flock -f build_lock build/.lock
fi

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || jobs=1
platform=
case "$1" in
    ios-simulator) platform=iphonesimulator; arch=$(uname -m) ;;
    ios-device|iphone|ipad) platform=iphoneos; arch=arm64 ;;
esac
if [[ -n $platform ]]; then
    mobile=build/iOS/$platform-$arch
    APP=$mobile/SpaceFight.app
    log "Building for $platform ($arch)"
    make -j "$jobs" ios IOS_PLATFORM="$platform"
else
    log "Checking native targets ($jobs parallel jobs)"
    make -j "$jobs" all
fi

log "Assembling $APP"
rm -rf "$APP"
if [[ -n $platform ]]; then
    bundle_resources=$APP
    mkdir -p "$APP"
    cp "$mobile/SpaceFight" "$APP/"
    cp Resources/Info-iOS.plist "$APP/Info.plist"
    sdk_version=$(xcrun --sdk "$platform" --show-sdk-version)
    plutil -insert CFBundleSupportedPlatforms -json "[\"$([[ $platform == iphoneos ]] && print iPhoneOS || print iPhoneSimulator)\"]" "$APP/Info.plist"
    plutil -insert MinimumOSVersion -string 16.0 "$APP/Info.plist"
    plutil -insert DTPlatformName -string "$platform" "$APP/Info.plist"
    plutil -insert DTSDKName -string "$platform$sdk_version" "$APP/Info.plist"
    icon_info=$mobile/AppIcon-Info.plist
    xcrun --sdk "$platform" actool --compile "$APP" --platform "$platform" \
        --minimum-deployment-target 16.0 --target-device iphone --target-device ipad \
        --app-icon AppIcon --output-partial-info-plist "$icon_info" Resources/Assets.xcassets
    /usr/libexec/PlistBuddy -c "Merge $icon_info" "$APP/Info.plist"
else
    bundle_resources=$APP/Contents/Resources
    mkdir -p "$APP/Contents/MacOS" "$bundle_resources" "$APP/Contents/PlugIns"
    cp build/Native/SpaceFight "$APP/Contents/MacOS/"
    cp build/Native/game.dylib "$APP/Contents/PlugIns/"
    cp Resources/Info.plist "$APP/Contents/"
    cp Resources/AppIcon.icns "$bundle_resources/"
fi
/bin/zsh Tools/bundle-resources.sh "$bundle_resources" build
if [[ $1 == iphone || $1 == ipad ]]; then
    log "Signing and deploying $APP"
    python3 Tools/deploy-ios.py "$1" "$APP"
elif [[ $platform == iphoneos ]]; then
    log "Built an unsigned device app; sign with an Apple Development identity and provisioning profile before installing."
else
    log "Signing the app bundle"
    if [[ $platform == iphonesimulator ]]; then
        codesign --force --sign - "$APP"
    else
        codesign --force --sign - "$APP" || log "Code signing failed, continuing"
    fi
fi

log "Built $APP"
zsystem flock -u "$build_lock"
if [[ "$1" == "run" ]]; then
    log "Launching SpaceFight through macOS Launch Services"
    if ! /usr/bin/open -n -W "$PWD/$APP"; then
        print -u2 "Could not open SpaceFight.app. Run from your macOS desktop session or open the app in Finder."
        exit 1
    fi
fi

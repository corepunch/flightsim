#!/bin/zsh
# Builds a signed App Store package. Usage: Tools/archive.sh ios|macos|racing-ios
#
# ios         build/Archives/<app>-ios-<version>-<build>/<app>.ipa
# macos       build/Archives/<app>-macos-<version>-<build>/<app>.pkg (Apple silicon)
# racing-ios  build/Archives/Racing-ios-<version>-<build>/Racing.ipa (Arcline)
#
# Each folder also holds the signed .app and its dSYMs. The version and build come
# from the app's source Info.plist (Resources/Info-iOS.plist, Resources/Info.plist,
# Games/Racing/Resources/Info.plist). Signing needs an Apple
# Distribution identity and the app's App Store profile (Tools/sign-distribution.py);
# the Mac package also needs a Mac Installer Distribution identity. Nothing is
# uploaded: send the package with `asc builds upload` (Tools/APPSTORE.md).
set -e
cd "$(dirname "$0")/.."

log() {
    printf '[archive +%ss] %s\n' "$SECONDS" "$*"
}

product=$1
entitlements=()
case $product in
    ios)        platform=ios; ./build.sh ios-device; app=build/iOS/iphoneos-arm64/KestrelFrontier.app
                entitlements=(Resources/KestrelFrontier-iOS.entitlements) ;;
    macos)      platform=macos; ./build.sh; app=build/${GAME:-KestrelFrontier}.app
                entitlements=(Resources/KestrelFrontier-macOS.entitlements) ;;
    racing-ios) platform=ios; make -C Games/Racing ios-build; app=Games/Racing/build/ios/iphoneos-arm64/Racing.app ;;
    *)          print -u2 "Usage: Tools/archive.sh ios|macos|racing-ios"; exit 2 ;;
esac
info=$app/Info.plist
[[ $platform == macos ]] && info=$app/Contents/Info.plist

name=$(plutil -extract CFBundleExecutable raw -o - "$info")
version=$(plutil -extract CFBundleShortVersionString raw -o - "$info")
build=$(plutil -extract CFBundleVersion raw -o - "$info")
out=build/Archives/$name-$platform-$version-$build
staged=$out/${app:t}
log "Archiving $name $version ($build) for $platform in $out"
rm -rf "$out"
mkdir -p "$out/dSYMs"
ditto "$app" "$staged"

# Keep the debug information beside the package for symbolicating crash reports,
# then strip the shipped binaries as Xcode's Release configuration does.
if [[ $platform == ios ]]; then
    binaries=("$staged/$name")
else
    binaries=("$staged/Contents/MacOS/$name" "$staged"/Contents/PlugIns/*.dylib(N))
fi
for binary in $binaries; do
    xcrun dsymutil "$binary" -o "$out/dSYMs/${binary:t}.dSYM"
    if [[ $binary == *.dylib ]]; then xcrun strip -x "$binary"; else xcrun strip "$binary"; fi
done

python3 Tools/sign-distribution.py "$platform" "$staged" $entitlements

if [[ $platform == ios ]]; then
    mkdir "$out/Payload"
    ditto "$staged" "$out/Payload/${staged:t}"
    package=$out/$name.ipa
    ditto -c -k --keepParent "$out/Payload" "$package"
    rm -rf "$out/Payload"
    if (( $+commands[asc] )); then
        asc ipa-info --path "$package" --verify-signature --output json > "$out/ipa-info.json" ||
            { print -u2 "asc ipa-info rejected the signature; see $out/ipa-info.json"; exit 1; }
        log "asc ipa-info: signature valid"
    fi
else
    installer=$(security find-identity -v -p basic |
        sed -nE 's/.*"((3rd Party Mac Developer Installer|Mac Installer Distribution): [^"]+)".*/\1/p' | head -1)
    if [[ -z $installer ]]; then
        print -u2 "No Mac Installer Distribution identity in the keychain, so the signed app in $out was not"
        print -u2 "packaged. Create one in Xcode Settings > Accounts > Manage Certificates, then rerun."
        exit 1
    fi
    package=$out/$name.pkg
    productbuild --component "$staged" /Applications --sign "$installer" "$package"
    pkgutil --check-signature "$package" | sed -n 1,3p
fi
log "Built $package"

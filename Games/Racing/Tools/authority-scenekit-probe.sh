#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/arcline-authority-scenekit.XXXXXX")"
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun --sdk macosx clang -std=c11 -O2 -c Sources/Authority/RaceAuthority.c -o "$out/authority.o"
xcrun --sdk macosx swiftc -parse-as-library -import-objc-header Sources/Authority/RaceAuthority.h \
    Tools/authority-test/SceneKitDriverProbe.swift "$out/authority.o" -o "$out/probe"
"$out/probe"

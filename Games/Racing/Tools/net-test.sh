#!/bin/sh
# Headless check of the LAN netcode: builds Sources/Racing/Net with Tools/nettest/main.swift
# for macOS and runs host + two guests over loopback and UDP on 127.0.0.1.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/arcline-nettest"
swiftc -I ../../Sources/Net/PacketCore -O -o "$out" Sources/Racing/Net/*.swift Tools/nettest/main.swift
"$out"

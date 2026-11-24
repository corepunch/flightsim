#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/arcline-authority.XXXXXX")"
trap 'rm -rf "$out"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -Wall -Wextra -Wconversion -Werror -pedantic ${CFLAGS:-} \
    -I Sources/Authority Sources/Authority/RaceAuthority.c Tools/authority-test/main.c -lm \
    -o "$out/authority-test"
"$out/authority-test"

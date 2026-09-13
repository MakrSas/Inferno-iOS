#!/bin/bash
# Builds and signs sbnet — the helper that draws a network into the guest's
# status bar.
#
# The signature is what makes it work at all: SpringBoard takes the override
# only from a process holding `com.apple.UIKit.status-bar-override-allow`, and
# without the entitlements AMFI kills the binary before main(). The guest's
# kernel is patched to accept our own signatures, so ldid is enough.
#
# Put the result in the guest UNDER A NEW NAME each time it changes: the kernel
# remembers the signature it saw for a path, and overwriting one in place gives
# `Killed: 9`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/sbnet}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

command -v ldid >/dev/null || { echo "ldid is needed: brew install ldid" >&2; exit 1; }

xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK" -Os \
    -framework Foundation -o "$OUT" "$HERE/sbnet.m"
strip -x "$OUT"
ldid "-S$HERE/sbnet.entitlements.plist" "$OUT"
echo "built: $OUT"
ldid -e "$OUT" | grep -q status-bar-override-allow && echo "entitlements in place"

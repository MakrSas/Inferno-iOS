#!/bin/bash
# Builds and signs aprobe — the guest-side audio probe. The entitlements are
# the bare minimum a carried-in binary needs to survive AMFI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/aprobe}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
command -v ldid >/dev/null || { echo "ldid is needed: brew install ldid" >&2; exit 1; }
xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK" -Os \
    -framework Foundation -framework IOKit -framework AudioToolbox -o "$OUT" "$HERE/aprobe.m"
strip -x "$OUT"
ldid "-S$HERE/aprobe.entitlements.plist" "$OUT"
echo "built: $OUT"

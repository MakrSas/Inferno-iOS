#!/bin/bash
# Builds and signs chap — the Core Haptics probe (see chap.m). Signed like the
# other probes: without the entitlements AMFI kills a carried-in binary before
# main().
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/chap}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
command -v ldid >/dev/null || { echo "ldid is needed: brew install ldid" >&2; exit 1; }
xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK" -Os -fobjc-arc \
    -framework Foundation -framework CoreHaptics -o "$OUT" "$HERE/chap.m"
strip -x "$OUT"
ldid "-S$HERE/chap.entitlements.plist" "$OUT"
echo "built: $OUT"

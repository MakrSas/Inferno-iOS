#!/bin/bash
# Builds and signs the guest agent — the program that lives inside the guest,
# started by launchd, and takes the app's requests over the scratch NVMe
# namespace instead of the console.
#
# Signing is what makes it work at all: it opens the raw block device and posts
# the status bar override, and both are gated by entitlements. Without them AMFI
# kills the binary before main() — `Killed: 9` in the console. The guest's kernel
# is patched to accept our own signatures, so ldid is enough.
#
# Put the result in the guest UNDER A NEW NAME each time it changes: the kernel
# remembers the signature it saw for a path, and overwriting one in place gives
# `Killed: 9`. The app names it `agent-<crc>` for exactly this reason; the stable
# `agent` symlink the daemon points at is repointed to the new file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/agent/agent}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

command -v ldid >/dev/null || { echo "ldid is needed: brew install ldid" >&2; exit 1; }

xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK" -Os \
    -fobjc-arc -framework Foundation \
    -o "$OUT" \
    "$HERE/agent/main.m" "$HERE/agent/util.m" "$HERE/agent/jobs.m" \
    "$HERE/agent/statusbar.m" "$HERE/agent/files.m" "$HERE/agent/install.m"
strip -x "$OUT"
ldid "-S$HERE/agent/agent.entitlements.plist" "$OUT"
echo "built: $OUT"
ldid -e "$OUT" | grep -q disk-device-access && echo "entitlements in place"

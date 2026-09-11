#!/bin/bash
# Builds libqemu-aarch64-softmmu.so for Android arm64 from inferno-src and
# drops it into the Compose app's jniLibs, ready for QemuBridge.nativeLoad.
#
# Needs scripts/build-android-deps.sh to have already populated PREFIX, and
# inferno-src/ checked out at the "ios" branch of MakrSas/Inferno (it already
# carries every bionic/Android fix this needs — see ANDROID-PORT.md).
#
#   PREFIX=~/inferno-android/prefix ./scripts/build-android-qemu.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/inferno-android/prefix}"
BUILD="${BUILD:-$HOME/inferno-android/build}"
SRC="${SRC:-$HERE/inferno-src}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
JNI_LIBS="$HERE/android/app/src/main/jniLibs/arm64-v8a"

[ -d "$SRC" ] || { echo "Не нашёл $SRC" >&2; exit 1; }

PREFIX="$PREFIX" "$HERE/make-android-cross-file.sh"
CROSS="$HERE/cross-android-arm64.txt"

rm -rf "$BUILD"
meson setup "$BUILD" "$SRC" \
    --cross-file "$CROSS" \
    --prefix "$PREFIX" --buildtype release \
    -Dshared_lib=true -Db_staticpic=true -Dwerror=false \
    -Dkvm=disabled -Dhvf=disabled -Dwhpx=disabled \
    -Dcocoa=disabled -Dgtk=disabled -Dsdl=disabled -Dcurses=disabled \
    -Dcoreaudio=disabled -Dcurl=disabled -Dlibssh=disabled -Dbzip2=disabled \
    -Dvnc=disabled -Dtools=disabled \
    -Dcoroutine_backend=sigaltstack

ninja -C "$BUILD" libqemu-aarch64-softmmu.so

mkdir -p "$JNI_LIBS"
cp "$BUILD/libqemu-aarch64-softmmu.so" "$JNI_LIBS/"

echo
echo "==> Готово: $JNI_LIBS/libqemu-aarch64-softmmu.so"
ls -la "$JNI_LIBS/libqemu-aarch64-softmmu.so"

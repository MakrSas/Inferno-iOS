#!/bin/bash
# Builds qemu-system-aarch64 for Android arm64 from inferno-src and drops it
# into the Compose app's jniLibs as libqemu_helper.so — the standard trick
# for shipping an arbitrary executable inside an APK (native libraries are
# the one class of file the installer extracts with the execute bit set;
# anything else lands on a noexec filesystem). The app launches it as its
# own child process rather than dlopen()'ing it — see ANDROID-PORT.md on
# why: something about running inside an app process (almost certainly
# ART's own signal-handler chaining) corrupts the sigaltstack coroutine
# backend within milliseconds of qemu_init(), and a plain child process,
# proven by running the exact same library standalone via `adb shell`,
# does not have that problem.
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
    -Db_pie=true -Dwerror=false \
    -Dkvm=disabled -Dhvf=disabled -Dwhpx=disabled \
    -Dcocoa=disabled -Dgtk=disabled -Dsdl=disabled -Dcurses=disabled \
    -Dcoreaudio=disabled -Dcurl=disabled -Dlibssh=disabled -Dbzip2=disabled \
    -Dvnc=disabled -Dtools=disabled \
    -Dcoroutine_backend="${COROUTINE_BACKEND:-sigaltstack}"

ninja -C "$BUILD" qemu-system-aarch64

mkdir -p "$JNI_LIBS"
cp "$BUILD/qemu-system-aarch64" "$JNI_LIBS/libqemu_helper.so"

if [ "${ASAN:-0}" = "1" ]; then
    NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/*/ 2>/dev/null | sort -V | tail -1)}"
    CLANG_LIB="$(dirname "$(find "${NDK%/}" -iname 'clang++' -path '*bin/clang++' | head -1)")/../lib/clang"
    ASAN_SO="$(find "$CLANG_LIB" -iname 'libclang_rt.asan-aarch64-android.so' | sort -V | tail -1)"
    [ -n "$ASAN_SO" ] || { echo "Не нашёл libclang_rt.asan-aarch64-android.so в NDK" >&2; exit 1; }
    cp "$ASAN_SO" "$JNI_LIBS/"
    echo "==> ASan runtime: $JNI_LIBS/$(basename "$ASAN_SO")"
fi

echo
echo "==> Готово: $JNI_LIBS/libqemu_helper.so"
ls -la "$JNI_LIBS/libqemu_helper.so"

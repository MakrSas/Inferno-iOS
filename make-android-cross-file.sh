#!/bin/bash
# Writes cross-android-arm64.txt for this machine — the meson cross-file used
# to build libqemu-aarch64-softmmu.so itself, once scripts/build-android-deps.sh
# has populated PREFIX. Mirrors make-cross-file.sh (the iOS equivalent); see
# that file for why cross-files are generated rather than committed — every
# path here is absolute and specific to this machine's NDK install.
#
#   PREFIX=~/inferno-android/prefix ./make-android-cross-file.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/inferno-android/prefix}"
OUT="${OUT:-$HERE/cross-android-arm64.txt}"
API="${API:-28}"

NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/*/ 2>/dev/null | sort -V | tail -1)}"
NDK="${NDK%/}"
[ -d "$NDK" ] || { echo "Не нашёл NDK под $HOME/Library/Android/sdk/ndk" >&2; exit 1; }
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
BIN="$TOOLCHAIN/bin"
TARGET="aarch64-linux-android$API"

# ASAN=1 instruments this build with AddressSanitizer — for chasing the one
# specific bug it's for (a "destroyed mutex" abort at library-load time that
# the device's own SELinux policy won't let a normal tombstone capture, see
# ANDROID-PORT.md), not for day-to-day builds. Only inferno-src itself gets
# instrumented, not the dependencies from build-android-deps.sh — faster to
# iterate on, and the suspect code is almost certainly QEMU/t8030's own.
SAN_FLAGS=()
if [ "${ASAN:-0}" = "1" ]; then
    # -g too: buildtype release carries no debug info at all, so a crash
    # address resolves to a function name (from the surviving dynamic
    # symbol) but no source line — exactly the gap this whole detour
    # exists to close.
    SAN_FLAGS=(", '-fsanitize=address', '-fno-omit-frame-pointer', '-g'")
fi

[ -d "$PREFIX/lib" ] || echo "Внимание: $PREFIX/lib ещё нет — соберите зависимости." >&2

cat > "$OUT" <<EOF
# Meson cross-file: arm64 Android, API $API. Собрано make-android-cross-file.sh
# — правьте скрипт, а не этот файл.
[binaries]
c          = '$BIN/$TARGET-clang'
cpp        = '$BIN/$TARGET-clang++'
ar         = '$BIN/llvm-ar'
strip      = '$BIN/llvm-strip'
ranlib     = '$BIN/llvm-ranlib'
pkg-config = 'pkg-config'

[built-in options]
c_args        = ['-fPIC', '-I$PREFIX/include'${SAN_FLAGS[*]:-}]
c_link_args   = ['-fPIC', '-L$PREFIX/lib', '-Wl,-z,max-page-size=16384'${SAN_FLAGS[*]:-}]
cpp_args      = ['-fPIC', '-I$PREFIX/include'${SAN_FLAGS[*]:-}]
cpp_link_args = ['-fPIC', '-L$PREFIX/lib', '-Wl,-z,max-page-size=16384'${SAN_FLAGS[*]:-}]
prefix        = '$PREFIX'

[host_machine]
system     = 'android'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']
EOF

echo "Записан $OUT"
echo "  NDK:    $NDK"
echo "  prefix: $PREFIX"
if [ "${ASAN:-0}" = "1" ]; then echo "  ASan:   включён"; fi

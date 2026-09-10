#!/bin/bash
# Writes cross-ios-arm64.txt for this machine.
#
# Meson cross-files take no variables, so every path in them is absolute: the
# SDK, the toolchain, and wherever the dependency libraries were installed.
# Those differ on every machine — and change under you when Xcode updates — so
# the file is generated rather than committed.
#
#   PREFIX=~/inferno-ios/prefix ./make-cross-file.sh
#
# PREFIX is where the built dependencies live: glib, pixman, gmp, nettle, png,
# tasn1, slirp, lzfse, libucontext. Defaults to ./prefix.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HERE/prefix}"
OUT="${OUT:-$HERE/cross-ios-arm64.txt}"
DEPLOY="${DEPLOY:-16.0}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BIN="$(dirname "$(xcrun --sdk iphoneos --find ar)")"

[ -d "$SDK" ] || { echo "Не нашёл SDK для iPhoneOS: $SDK" >&2; exit 1; }
[ -d "$PREFIX" ] || echo "Внимание: $PREFIX ещё нет — соберите туда зависимости." >&2

FLAGS="'-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY'"

cat > "$OUT" <<EOF
# Meson cross-file: arm64 iOS (device). Deployment target $DEPLOY.
# Создан make-cross-file.sh — правьте скрипт, а не этот файл.
[binaries]
c          = 'clang'
cpp        = 'clang++'
objc       = 'clang'
ar         = '$BIN/ar'
strip      = '$BIN/strip'
ranlib     = '$BIN/ranlib'
pkg-config = 'pkg-config'

[built-in options]
c_args        = [$FLAGS, '-I$PREFIX/include']
c_link_args   = [$FLAGS, '-L$PREFIX/lib', '-framework', 'CoreFoundation', '-lucontext']
cpp_args      = [$FLAGS]
cpp_link_args = [$FLAGS]
objc_args     = [$FLAGS]
prefix        = '$PREFIX'

[host_machine]
system     = 'darwin'
subsystem  = 'ios'
kernel     = 'xnu'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'

[properties]
needs_exe_wrapper = true
# Keep pkg-config away from Homebrew: those are macOS libraries.
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']
EOF

echo "Записан $OUT"
echo "  SDK:    $SDK"
echo "  prefix: $PREFIX"

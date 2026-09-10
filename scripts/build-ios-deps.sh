#!/bin/bash
# Builds the emulator's dependencies for arm64 iOS into a single prefix — the
# same set as README-iOS.md's "Dependencies built for iOS", but reproducibly
# and with no human in the loop. Used by CI (.github/workflows), but also runs
# locally:
#
#   PREFIX=$PWD/prefix scripts/build-ios-deps.sh
#
# Needs macOS with Xcode (iPhoneOS SDK) and: meson, ninja, pkg-config, autoconf,
# automake, libtool, m4  (brew install meson ninja pkg-config autoconf automake libtool m4).
#
# Versions are pinned to what sits in the author's working prefix:
#   zlib 1.3.1, GMP 6.3.0, nettle 3.10.2 (+hogweed), libtasn1 4.20.0,
#   libpng 1.6.44, pixman 0.44.2, glib 2.84.3 (with its own libffi/pcre2/libintl),
#   libslirp 4.9.1, libucontext, lzfse.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HERE/prefix}"
WORK="${WORK:-$HERE/.deps-build}"
DEPLOY="${DEPLOY:-16.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
FLAGS="-arch arm64 -isysroot $SDK -mios-version-min=$DEPLOY"

export CC="clang $FLAGS"
export CXX="clang++ $FLAGS"
export CPP="clang -E $FLAGS"
export AR="$(xcrun --sdk iphoneos --find ar)"
export RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
export STRIP="$(xcrun --sdk iphoneos --find strip)"
export CFLAGS="$FLAGS -O2 -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$FLAGS -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
HOST=aarch64-apple-darwin

mkdir -p "$PREFIX" "$WORK"
cd "$WORK"

CROSS="$WORK/cross-ios-arm64.txt"
cat > "$CROSS" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
ar = '$AR'
strip = '$STRIP'
ranlib = '$RANLIB'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-I$PREFIX/include']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-L$PREFIX/lib', '-framework', 'CoreFoundation']
cpp_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-I$PREFIX/include']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY', '-L$PREFIX/lib', '-framework', 'CoreFoundation']
objc_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-mios-version-min=$DEPLOY']
prefix = '$PREFIX'
[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']
EOF

fetch() { # fetch <out.tar> <url> [url...]
    local out="$1"; shift
    [ -f "$out" ] && return 0
    local url
    for url in "$@"; do
        echo "    fetch $url"
        if curl -fL --connect-timeout 20 --retry 5 --retry-all-errors \
                --speed-limit 1024 --speed-time 30 -o "$out" "$url"; then
            return 0
        fi
        echo "    ...failed, trying next mirror" >&2
        rm -f "$out"
    done
    echo "could not download $out" >&2
    return 1
}
untar() { # untar <tar> <dest-dir>
    local t="$1" d="$2"
    rm -rf "$d"
    mkdir -p "$d"
    tar -xf "$t" -C "$d" --strip-components=1
}

meson_build() { # meson_build <srcdir> [extra opts...]
    local src="$1"; shift
    rm -rf "$src/_b"
    meson setup "$src/_b" "$src" --cross-file "$CROSS" \
        --prefix "$PREFIX" --buildtype release \
        --default-library static --wrap-mode default "$@"
    meson compile -C "$src/_b" -j "$JOBS"
    meson install -C "$src/_b"
}

conf_build() { # conf_build <srcdir> [configure opts...]
    local src="$1"; shift
    ( cd "$src" && ./configure --host="$HOST" --prefix="$PREFIX" \
        --enable-static --disable-shared "$@" \
      && make -j"$JOBS" && make install )
}

echo "==> prefix: $PREFIX"
echo "==> SDK:    $SDK"

# ── zlib ──────────────────────────────────────────────────────────────────
fetch zlib.tar.gz \
    "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz" \
    "https://zlib.net/zlib-1.3.1.tar.gz"
untar zlib.tar.gz zlib
( cd zlib && ./configure --prefix="$PREFIX" --static && make -j"$JOBS" && make install )

# ── GMP ───────────────────────────────────────────────────────────────────
fetch gmp.tar.xz \
    "https://ftpmirror.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz" \
    "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz" \
    "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
untar gmp.tar.xz gmp
conf_build gmp --disable-assembly

# ── nettle (+ hogweed, needs GMP) ────────────────────────────────────────
fetch nettle.tar.gz \
    "https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz" \
    "https://mirrors.kernel.org/gnu/nettle/nettle-3.10.2.tar.gz" \
    "https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz"
untar nettle.tar.gz nettle
conf_build nettle --disable-documentation --disable-openssl --disable-assembler

# ── libtasn1 ──────────────────────────────────────────────────────────────
fetch libtasn1.tar.gz \
    "https://ftpmirror.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz" \
    "https://mirrors.kernel.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz" \
    "https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz"
untar libtasn1.tar.gz libtasn1
conf_build libtasn1 --disable-doc

# ── libpng ────────────────────────────────────────────────────────────────
fetch libpng.tar.gz \
    "https://github.com/pnggroup/libpng/releases/download/v1.6.44/libpng-1.6.44.tar.gz" \
    "https://downloads.sourceforge.net/libpng/libpng-1.6.44.tar.gz"
untar libpng.tar.gz libpng
conf_build libpng --disable-tools

# ── pixman ────────────────────────────────────────────────────────────────
fetch pixman.tar.gz \
    "https://www.cairographics.org/releases/pixman-0.44.2.tar.gz" \
    "https://gitlab.freedesktop.org/pixman/pixman/-/archive/pixman-0.44.2/pixman-pixman-0.44.2.tar.gz"
untar pixman.tar.gz pixman
meson_build pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled

# ── glib (with its own libffi, pcre2, proxy-libintl — absent from the iOS SDK) ─
fetch glib.tar.xz \
    "https://download.gnome.org/sources/glib/2.84/glib-2.84.3.tar.xz" \
    "https://ftp.acc.umu.se/pub/gnome/sources/glib/2.84/glib-2.84.3.tar.xz"
untar glib.tar.xz glib
meson_build glib -Dtests=false -Ddtrace=disabled -Dintrospection=disabled \
    -Dnls=enabled -Dlibmount=disabled -Dselinux=disabled

# ── libslirp (needs glib) ────────────────────────────────────────────────
fetch libslirp.tar.gz \
    "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.1/libslirp-v4.9.1.tar.gz"
untar libslirp.tar.gz libslirp
meson_build libslirp

# ── libucontext (QEMU's coroutine backend: iOS has no usable sigaltstack) ─
fetch libucontext.tar.gz \
    "https://github.com/kaniini/libucontext/archive/refs/tags/v1.3.2.tar.gz"
untar libucontext.tar.gz libucontext
meson_build libucontext -Dexport_unprefixed=true

# ── lzfse ────────────────────────────────────────────────────────────────
fetch lzfse.tar.gz \
    "https://github.com/lzfse/lzfse/archive/refs/tags/lzfse-1.0.tar.gz"
untar lzfse.tar.gz lzfse
make -C lzfse -j"$JOBS" CC="$CC" INSTALL_PREFIX="$PREFIX"
make -C lzfse install INSTALL_PREFIX="$PREFIX"

echo
echo "==> Done. Contents of $PREFIX/lib:"
ls "$PREFIX/lib" | sed 's/^/    /'

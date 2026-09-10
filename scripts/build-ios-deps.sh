#!/bin/bash
# Собирает зависимости эмулятора под arm64 iOS в один prefix — то же, что было
# сделано руками для README-iOS.md «Зависимости, собранные под iOS», только
# воспроизводимо и без участия человека. Используется CI (.github/workflows),
# но запускается и локально:
#
#   PREFIX=$PWD/prefix scripts/build-ios-deps.sh
#
# Требуется macOS с Xcode (iPhoneOS SDK) и: meson, ninja, pkg-config, autoconf,
# automake, libtool, m4  (brew install meson ninja pkg-config autoconf automake libtool m4).
#
# Версии закреплены под то, что лежит в рабочем prefix у автора:
#   zlib 1.3.1, GMP 6.3.0, nettle 3.10.2 (+hogweed), libtasn1 4.20.0,
#   libpng 1.6.44, pixman 0.44.2, glib 2.84.3 (со своими libffi/pcre2/libintl),
#   libslirp 4.9.1, libucontext, lzfse.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HERE/prefix}"
WORK="${WORK:-$HERE/.deps-build}"
DEPLOY="${DEPLOY:-16.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BIN="$(dirname "$(xcrun --sdk iphoneos --find clang)")"
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

fetch() { # fetch <url> <out.tar>
    local url="$1" out="$2"
    [ -f "$out" ] || curl -fL --retry 3 -o "$out" "$url"
}
untar() { # untar <tar> <expected-dir>
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
fetch "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz" zlib.tar.gz
untar zlib.tar.gz zlib
( cd zlib && ./configure --prefix="$PREFIX" --static && make -j"$JOBS" && make install )

# ── GMP ───────────────────────────────────────────────────────────────────
fetch "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz" gmp.tar.xz
untar gmp.tar.xz gmp
conf_build gmp --disable-assembly

# ── nettle (+ hogweed, нужен GMP) ─────────────────────────────────────────
fetch "https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz" nettle.tar.gz
untar nettle.tar.gz nettle
conf_build nettle --disable-documentation --disable-openssl --disable-assembler

# ── libtasn1 ──────────────────────────────────────────────────────────────
fetch "https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz" libtasn1.tar.gz
untar libtasn1.tar.gz libtasn1
conf_build libtasn1 --disable-doc

# ── libpng ────────────────────────────────────────────────────────────────
fetch "https://github.com/pnggroup/libpng/releases/download/v1.6.44/libpng-1.6.44.tar.gz" libpng.tar.gz
untar libpng.tar.gz libpng
conf_build libpng --disable-tools

# ── pixman ────────────────────────────────────────────────────────────────
fetch "https://www.cairographics.org/releases/pixman-0.44.2.tar.gz" pixman.tar.gz
untar pixman.tar.gz pixman
meson_build pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled

# ── glib (со своими libffi, pcre2, proxy-libintl — их нет в iOS SDK) ──────
fetch "https://download.gnome.org/sources/glib/2.84/glib-2.84.3.tar.xz" glib.tar.xz
untar glib.tar.xz glib
meson_build glib -Dtests=false -Ddtrace=disabled -Dintrospection=disabled \
    -Dnls=enabled -Dlibmount=disabled -Dselinux=disabled

# ── libslirp (нужен glib) ────────────────────────────────────────────────
fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.1/libslirp-v4.9.1.tar.gz" libslirp.tar.gz
untar libslirp.tar.gz libslirp
meson_build libslirp

# ── libucontext (coroutine-бэкенд для QEMU: у iOS нет годного sigaltstack) ─
fetch "https://github.com/kaniini/libucontext/archive/refs/tags/v1.3.2.tar.gz" libucontext.tar.gz
untar libucontext.tar.gz libucontext
meson_build libucontext -Dexport_unprefixed=true

# ── lzfse ────────────────────────────────────────────────────────────────
fetch "https://github.com/lzfse/lzfse/archive/refs/tags/lzfse-1.0.tar.gz" lzfse.tar.gz
untar lzfse.tar.gz lzfse
make -C lzfse -j"$JOBS" CC="$CC" INSTALL_PREFIX="$PREFIX"
make -C lzfse install INSTALL_PREFIX="$PREFIX"

echo
echo "==> Готово. Содержимое $PREFIX/lib:"
ls "$PREFIX/lib" | sed 's/^/    /'

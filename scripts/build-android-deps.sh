#!/bin/bash
# Builds the emulator's dependencies for arm64 Android into a single prefix —
# the same set as build-ios-deps.sh, minus libucontext (Android needs no JIT
# handshake with a debugger, so the plain sigaltstack coroutine backend is
# fine — see ../ANDROID-PORT.md and the note on coroutine_backend below).
# Runs locally, not yet wired into CI:
#
#   PREFIX=$PWD/prefix-android scripts/build-android-deps.sh
#
# Needs the Android NDK (a version with LLVM binutils, i.e. r23+; this
# project uses whatever's under ~/Library/Android/sdk/ndk) and: meson, ninja,
# pkg-config, autoconf, automake, glibtool, m4
#   (brew install meson ninja pkg-config autoconf automake libtool m4).
#
# Same versions as build-ios-deps.sh, pinned for the same reason: this is
# what sits in the author's working prefix and is known to build against
# this QEMU fork.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# Deliberately outside "Inferno Pixel7": the space in that path breaks
# libtool and autotools (see the project's own README on this). Mirrors
# ~/inferno-ios for the same reason.
PREFIX="${PREFIX:-$HOME/inferno-android/prefix}"
WORK="${WORK:-$HOME/inferno-android/.deps-build}"
API="${API:-28}"                    # matches android/app's minSdk
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/*/ 2>/dev/null | sort -V | tail -1)}"
NDK="${NDK%/}"
[ -d "$NDK" ] || { echo "Не нашёл NDK под $HOME/Library/Android/sdk/ndk" >&2; exit 1; }
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "Не нашёл toolchain: $TOOLCHAIN" >&2; exit 1; }
BIN="$TOOLCHAIN/bin"
TARGET="aarch64-linux-android$API"
HOST=aarch64-linux-android

export CC="$BIN/$TARGET-clang"
export CXX="$BIN/$TARGET-clang++"
export CPP="$BIN/$TARGET-clang -E"
export AR="$BIN/llvm-ar"
export RANLIB="$BIN/llvm-ranlib"
export STRIP="$BIN/llvm-strip"
export NM="$BIN/llvm-nm"
# Autotools packages call plain "libtool"; on macOS that resolves to Apple's
# own (BSD) libtool unless told otherwise, which mishandles a cross triple.
export LIBTOOL=glibtool
export LIBTOOLIZE=glibtoolize
export CFLAGS="-fPIC -O2 -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# A few upstream Makefiles (lzfse's included) call the archiver by the bare
# literal name "ar"/"ranlib" instead of $(AR)/$(RANLIB), so no override of
# either variable — environment or make command-line — reaches them at all.
# The NDK toolchain only ships namespaced names (llvm-ar, llvm-ranlib), so a
# bare "ar" falls through PATH to macOS's own — which "succeeds" while
# mis-indexing the resulting archive for a format it doesn't understand
# (symptom: "ranlib: warning: archive member ... not a mach-o file", then
# undefined-symbol link errors against an archive that plainly has the
# object in it). Shimming the bare names fixes every such case at once
# rather than special-casing each package.
SHIM="$WORK/shim-bin"
mkdir -p "$SHIM"
ln -sf "$AR" "$SHIM/ar"
ln -sf "$RANLIB" "$SHIM/ranlib"
export PATH="$SHIM:$BIN:$PATH"

mkdir -p "$PREFIX" "$WORK"
cd "$WORK"

CROSS="$WORK/cross-android-arm64.txt"
cat > "$CROSS" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
ranlib = '$RANLIB'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_args = ['-fPIC', '-I$PREFIX/include']
cpp_link_args = ['-L$PREFIX/lib']
prefix = '$PREFIX'
[host_machine]
system = 'android'
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

# Resumability: a failed run (a dead URL, a flaky download) shouldn't mean
# re-building everything that already succeeded. Each stage is skipped if
# its marker file is already sitting in $PREFIX/lib — delete the relevant
# .a (or the whole prefix) to force a rebuild of that stage.
done_marker() { [ -e "$PREFIX/lib/$1" ]; }

echo "==> NDK:    $NDK"
echo "==> target: $TARGET"
echo "==> prefix: $PREFIX"

# ── zlib ──────────────────────────────────────────────────────────────────
if done_marker libz.a; then
    echo "==> zlib: уже собран, пропускаю"
else
    echo "==> zlib"
    # Built and installed by hand rather than `make install`: zlib's
    # Makefile ties `install` to the default `all` target, which also links
    # the example/minigzip demo binaries against a shared libz that was
    # never built here (--static only skips *installing* the shared lib,
    # not building the demos against it) — and that link fails under the
    # NDK toolchain. `libz.a` alone builds cleanly and is all anything else
    # here needs.
    #
    # AR=llvm-ar ARFLAGS=rc on the make command line, not just exported:
    # zlib's ./configure detects a Darwin *build* host (this Mac) and
    # unconditionally writes `AR=libtool` into the generated Makefile —
    # Apple's own libtool, not GNU ar — which silently produces an empty
    # archive when handed Android's ELF object files instead of failing
    # loudly. A plain assignment inside a Makefile beats an inherited
    # environment variable of the same name, but a make-command-line
    # assignment beats both, which is the only override that actually wins.
    fetch "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz" zlib.tar.gz
    untar zlib.tar.gz zlib
    ( cd zlib && ./configure --prefix="$PREFIX" --static \
        && make -j"$JOBS" AR="$AR" ARFLAGS=rc libz.a )
    mkdir -p "$PREFIX/include" "$PREFIX/lib/pkgconfig"
    cp zlib/zlib.h zlib/zconf.h "$PREFIX/include/"
    cp zlib/libz.a "$PREFIX/lib/"
    cp zlib/zlib.pc "$PREFIX/lib/pkgconfig/"
fi

# ── GMP ───────────────────────────────────────────────────────────────────
if done_marker libgmp.a; then
    echo "==> GMP: уже собран, пропускаю"
else
    echo "==> GMP"
    fetch "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz" gmp.tar.xz
    untar gmp.tar.xz gmp
    conf_build gmp --disable-assembly
fi

# ── nettle (+ hogweed, needs GMP) ────────────────────────────────────────
if done_marker libnettle.a; then
    echo "==> nettle: уже собран, пропускаю"
else
    echo "==> nettle"
    fetch "https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz" nettle.tar.gz
    untar nettle.tar.gz nettle
    conf_build nettle --disable-documentation --disable-openssl --disable-assembler
fi

# ── libtasn1 ──────────────────────────────────────────────────────────────
if done_marker libtasn1.a; then
    echo "==> libtasn1: уже собран, пропускаю"
else
    echo "==> libtasn1"
    fetch "https://ftp.gnu.org/gnu/libtasn1/libtasn1-4.20.0.tar.gz" libtasn1.tar.gz
    untar libtasn1.tar.gz libtasn1
    conf_build libtasn1 --disable-doc
fi

# ── libpng ────────────────────────────────────────────────────────────────
if done_marker libpng16.a; then
    echo "==> libpng: уже собран, пропускаю"
else
    echo "==> libpng"
    # The 1.6.44 release asset build-ios-deps.sh uses is gone (pnggroup
    # prunes old release binaries); the tag archive stays available.
    fetch "https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.58.tar.gz" libpng.tar.gz
    untar libpng.tar.gz libpng
    conf_build libpng --disable-tools
fi

# ── pixman ────────────────────────────────────────────────────────────────
if done_marker libpixman-1.a; then
    echo "==> pixman: уже собран, пропускаю"
else
    echo "==> pixman"
    fetch "https://www.cairographics.org/releases/pixman-0.44.2.tar.gz" pixman.tar.gz
    untar pixman.tar.gz pixman
    meson_build pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled
fi

# ── glib (with its own libffi, pcre2, proxy-libintl) ────────────────────
if done_marker libglib-2.0.a; then
    echo "==> glib: уже собран, пропускаю"
else
    echo "==> glib"
    fetch "https://download.gnome.org/sources/glib/2.84/glib-2.84.3.tar.xz" glib.tar.xz
    untar glib.tar.xz glib
    meson_build glib -Dtests=false -Ddtrace=disabled -Dintrospection=disabled \
        -Dnls=enabled -Dlibmount=disabled -Dselinux=disabled
fi

# ── libslirp (needs glib) ────────────────────────────────────────────────
if done_marker libslirp.a; then
    echo "==> libslirp: уже собран, пропускаю"
else
    echo "==> libslirp"
    fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.1/libslirp-v4.9.1.tar.gz" libslirp.tar.gz
    untar libslirp.tar.gz libslirp
    meson_build libslirp
fi

# ── lzfse ────────────────────────────────────────────────────────────────
if done_marker liblzfse.a; then
    echo "==> lzfse: уже собран, пропускаю"
else
    echo "==> lzfse"
    fetch "https://github.com/lzfse/lzfse/archive/refs/tags/lzfse-1.0.tar.gz" lzfse.tar.gz
    untar lzfse.tar.gz lzfse
    # lzfse's Makefile calls the archiver as a bare literal "ar", never
    # $(AR) — the shim earlier in this script (not any override here) is
    # what actually makes that resolve to the NDK's llvm-ar instead of
    # macOS's own.
    make -C lzfse -j"$JOBS" CC="$CC" INSTALL_PREFIX="$PREFIX"
    make -C lzfse install CC="$CC" INSTALL_PREFIX="$PREFIX"
fi

echo
echo "==> Done. Contents of $PREFIX/lib:"
ls "$PREFIX/lib" | sed 's/^/    /'

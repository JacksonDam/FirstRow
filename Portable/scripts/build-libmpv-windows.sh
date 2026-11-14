#!/bin/sh
# Builds a small libmpv for Windows from source, for First Row's Windows packages.
#
#   Portable/scripts/build-libmpv-windows.sh [x86_64|aarch64]
#
# mpv's own build of libmpv for Windows carries everything mpv can do: encoders, scripting,
# Vulkan and Direct3D renderers, shader compilers. First Row asks mpv to decode and to draw
# into its own OpenGL window, so this builds mpv with what that takes and nothing else,
# which comes to a quarter of the size.
#
# Everything in it is under the LGPL or a more permissive licence: FFmpeg is configured
# without --enable-gpl and --enable-nonfree, mpv with -Dgpl=false, and nothing in it reads
# DVDs or unscrambles discs. Each part is a named release whose download is checked against
# a checksum kept here, and the licences of all of them are put beside the DLL.
#
# It is a cross-build, from macOS or Linux, with llvm-mingw (fetched on the first run; set
# LLVM_MINGW to use one that is already unpacked). It needs meson, ninja, nasm, pkg-config,
# make, git, curl and python3. The work is done in a folder of its own (LIBMPV_BUILD_DIR, or
# one under TMPDIR), whose path can't have a space in it: FFmpeg's configure doesn't take one.
#
# The result is Portable/build/libmpv/<x64|arm64>: libmpv-2.dll, mpv's headers and a
# Licenses folder. build-windows.ps1 uses it when it is there.
set -e

arch=${1:-x86_64}
case "$arch" in
    x86_64) package_arch=x64 ;;
    aarch64) package_arch=arm64 ;;
    *) echo "usage: $0 [x86_64|aarch64]" >&2; exit 2 ;;
esac
triple=$arch-w64-mingw32

# What it is built from.
llvm_mingw=20261104
zlib=1.4
libiconv=1.19
dav1d=1.5.4
ffmpeg=8.1.3
freetype=2.14.3
fribidi=1.0.18
harfbuzz=15.1.0
libass=0.17.5
uchardet=0.0.8
libbluray=1.5.0
libplacebo=7.387.0
libplacebo_commit=275f7dea27924cdd34ab2e6c20e448b6bc4fab65
mpv=0.42.0

root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/Portable/build/libmpv/$package_arch"
work=${LIBMPV_BUILD_DIR:-${TMPDIR:-/tmp}/firstrow-libmpv}
work=${work%/}
case "$work" in
    *" "*) echo "The build folder's path has a space in it ($work): set LIBMPV_BUILD_DIR to one without" >&2; exit 1 ;;
esac
downloads=$work/downloads
src=$work/src-$arch
prefix=$work/prefix-$arch
mkdir -p "$downloads" "$src" "$prefix/lib/pkgconfig" "$prefix/include"
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

for tool in meson ninja nasm pkg-config make git curl python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is needed and wasn't found" >&2; exit 1; }
done

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <address> <sha256> [name to keep it under]: downloads a file once and checks it.
fetch() {
    name=${3:-${1##*/}}
    [ -s "$downloads/$name" ] || curl -fsSL --retry 3 -o "$downloads/$name" "$1"
    if [ "$(checksum "$downloads/$name")" != "$2" ]; then
        echo "$name isn't the file that was expected: its checksum differs" >&2
        exit 1
    fi
}

# unpack <archive> <the folder it holds>: into this build's source folder, once.
unpack() {
    [ -d "$src/$2" ] || tar -xf "$downloads/$1" -C "$src"
}

# Each part is built once: a file under the prefix's "built" folder says it has been.
mkdir -p "$prefix/built"
built() { [ -e "$prefix/built/$1" ]; }
done_with() { : > "$prefix/built/$1"; echo "built $1"; }

# The compiler.
if [ -z "$LLVM_MINGW" ]; then
    case "$(uname -s) $(uname -m)" in
        Darwin*) host=macos-universal; sum=66cbd5178c4a71b0d473e68ede172f8eb7d15d023e67f39201d0a69e21f6bf3c ;;
        "Linux x86_64") host=ubuntu-22.04-x86_64; sum=919380403de87dca3c581c2053230cd298af5e891286628ba0613b7fed370926 ;;
        "Linux aarch64" | "Linux arm64") host=ubuntu-22.04-aarch64; sum=595e95bdffabfc62559fe26e30bdfbccf277cbaed4902793555015ee47306b94 ;;
        *) echo "There is no llvm-mingw for this machine here: set LLVM_MINGW to one" >&2; exit 1 ;;
    esac
    LLVM_MINGW=$work/llvm-mingw-$llvm_mingw-ucrt-$host
    if [ ! -x "$LLVM_MINGW/bin/$triple-clang" ]; then
        fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$llvm_mingw/llvm-mingw-$llvm_mingw-ucrt-$host.tar.xz" "$sum"
        tar -xf "$downloads/llvm-mingw-$llvm_mingw-ucrt-$host.tar.xz" -C "$work"
    fi
fi
[ -x "$LLVM_MINGW/bin/$triple-clang" ] || { echo "No $triple-clang in $LLVM_MINGW/bin" >&2; exit 1; }
PATH=$LLVM_MINGW/bin:$PATH
export PATH
export CC=$triple-clang CXX=$triple-clang++ AR=$triple-ar RANLIB=$triple-ranlib NM=$triple-nm STRIP=$triple-strip
# Nothing of the machine it is built on goes into the DLL: where a source file's own path
# would be kept (for a message about something that should never happen), the build folder's
# part of it is left out, and so it is from the words FFmpeg and mpv keep about how they
# were configured (further down).
plain="-ffile-prefix-map=$work=/build"
# Only what is built here is found, never the building machine's own libraries.
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
unset PKG_CONFIG_PATH

# How meson is told about the compiler and the prefix. Every part is a static library; the
# one DLL is libmpv, with all of them and the compiler's own runtime inside it.
cross=$prefix/cross.ini
cat > "$cross" <<EOF
[built-in options]
buildtype = 'release'
default_library = 'static'
wrap_mode = 'nodownload'
prefix = '$prefix'
libdir = 'lib'
c_args = ['-I$prefix/include', '$plain']
cpp_args = ['-I$prefix/include', '$plain']
c_link_args = ['-L$prefix/lib', '-static']
cpp_link_args = ['-L$prefix/lib', '-static']
[binaries]
c = '$triple-clang'
cpp = '$triple-clang++'
ar = '$triple-ar'
nm = '$triple-nm'
ranlib = '$triple-ranlib'
strip = '$triple-strip'
windres = '$triple-windres'
dlltool = '$triple-dlltool'
pkg-config = 'pkg-config'
nasm = 'nasm'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$prefix/lib/pkgconfig']
[host_machine]
system = 'windows'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
EOF

# with_meson <part> <source folder> [options]: configures, builds and installs one.
with_meson() {
    part=$1
    folder=$2
    shift 2
    rm -rf "$src/$folder/build-$arch"
    meson setup "$src/$folder/build-$arch" "$src/$folder" --cross-file "$cross" "$@" > "$prefix/built/$part.log" 2>&1 ||
        { tail -30 "$prefix/built/$part.log" >&2; exit 1; }
    ninja -C "$src/$folder/build-$arch" install >> "$prefix/built/$part.log" 2>&1 ||
        { tail -40 "$prefix/built/$part.log" >&2; exit 1; }
}

# The licence of each part, to go out beside the DLL.
licenses=$prefix/licenses
mkdir -p "$licenses"

# zlib: its sources as they are, as one library.
if ! built zlib; then
    fetch "https://github.com/madler/zlib/releases/download/v$zlib/zlib-$zlib.tar.xz" 4f11c512053d7bab8d9e9b89bde3575add3e4c50a383b42ef6cb837035fc5a7c
    unpack "zlib-$zlib.tar.xz" "zlib-$zlib"
    (
        cd "$src/zlib-$zlib"
        objects=
        for name in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil; do
            $CC -O2 "$plain" -c "$name.c" -o "$name.o"
            objects="$objects $name.o"
        done
        rm -f libz.a
        # shellcheck disable=SC2086
        $AR rcs libz.a $objects
        cp libz.a "$prefix/lib/"
        cp zlib.h zconf.h "$prefix/include/"
        cp LICENSE "$licenses/zlib.txt"
    )
    cat > "$prefix/lib/pkgconfig/zlib.pc" <<EOF
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: $zlib
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF
    done_with zlib
fi

# libiconv: other encodings of text to and from Unicode, for subtitle files that aren't in it.
if ! built libiconv; then
    fetch "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$libiconv.tar.gz" 88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6
    unpack "libiconv-$libiconv.tar.gz" "libiconv-$libiconv"
    (
        rm -rf "$src/libiconv-$libiconv/build-$arch" && mkdir "$src/libiconv-$libiconv/build-$arch" && cd "$src/libiconv-$libiconv/build-$arch"
        ../configure --host="$triple" --prefix="$prefix" --enable-static --disable-shared --disable-nls --disable-rpath CFLAGS="-O2 $plain" > "$prefix/built/libiconv.log" 2>&1
        make -j"$jobs" >> "$prefix/built/libiconv.log" 2>&1
        make install >> "$prefix/built/libiconv.log" 2>&1
    ) || { tail -30 "$prefix/built/libiconv.log" >&2; exit 1; }
    # (libtool names the library as Visual C++ would with this compiler: under the usual name
    # too, every linker finds it.)
    [ -f "$prefix/lib/libiconv.a" ] || cp "$prefix/lib/libiconv.lib" "$prefix/lib/libiconv.a"
    cp "$src/libiconv-$libiconv/COPYING.LIB" "$licenses/libiconv.LGPL.txt"
    done_with libiconv
fi

# dav1d: AV1, which FFmpeg has no decoder of its own for.
if ! built dav1d; then
    fetch "https://downloads.videolan.org/pub/videolan/dav1d/$dav1d/dav1d-$dav1d.tar.xz" 686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
    unpack "dav1d-$dav1d.tar.xz" "dav1d-$dav1d"
    with_meson dav1d "dav1d-$dav1d" -Denable_tools=false -Denable_tests=false
    cp "$src/dav1d-$dav1d/COPYING" "$licenses/dav1d.BSD.txt"
    done_with dav1d
fi

# FFmpeg: what reads the files and decodes what is in them. Its own decoders, and nothing
# that encodes or writes files (but for the stream a receiver is sent sound in, untouched),
# or records the screen (its one part in C++, which a Mac's file system also trips up: there
# the C++ library's <version> is taken for FFmpeg's own VERSION file).
if ! built ffmpeg; then
    fetch "https://ffmpeg.org/releases/ffmpeg-$ffmpeg.tar.xz" 7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
    unpack "ffmpeg-$ffmpeg.tar.xz" "ffmpeg-$ffmpeg"
    (
        rm -rf "$src/ffmpeg-$ffmpeg/build-$arch" && mkdir "$src/ffmpeg-$ffmpeg/build-$arch" && cd "$src/ffmpeg-$ffmpeg/build-$arch"
        ../configure \
            --prefix="$prefix" --enable-cross-compile --cross-prefix="$triple-" --arch="$arch" --target-os=mingw32 \
            --cc="$CC" --cxx="$CXX" --pkg-config=pkg-config --pkg-config-flags=--static \
            --extra-cflags="-I$prefix/include $plain" --extra-ldflags="-L$prefix/lib" \
            --enable-static --disable-shared --disable-doc --disable-programs --disable-debug \
            --disable-autodetect --enable-zlib --enable-iconv --enable-schannel --enable-libdav1d \
            --enable-d3d11va --enable-dxva2 --enable-d3d12va --disable-pthreads --enable-w32threads \
            --disable-avdevice --disable-encoders --disable-muxers --enable-muxer=spdif \
            --disable-filter=gfxcapture \
            > "$prefix/built/ffmpeg.log" 2>&1
        # (The words it was configured with, which it keeps inside itself, without the
        # build folder's path.)
        sed -i.orig "s|$work|/build|g" config.h
        make -j"$jobs" >> "$prefix/built/ffmpeg.log" 2>&1
        make install >> "$prefix/built/ffmpeg.log" 2>&1
    ) || { tail -40 "$prefix/built/ffmpeg.log" >&2; exit 1; }
    # (Its own word on what it was built as.)
    grep -q '^#define CONFIG_GPL 0' "$src/ffmpeg-$ffmpeg/build-$arch/config.h" || { echo "FFmpeg came out under the GPL" >&2; exit 1; }
    grep -q '^#define CONFIG_NONFREE 0' "$src/ffmpeg-$ffmpeg/build-$arch/config.h" || { echo "FFmpeg came out unredistributable" >&2; exit 1; }
    cp "$src/ffmpeg-$ffmpeg/COPYING.LGPLv2.1" "$licenses/FFmpeg.LGPL.txt"
    done_with ffmpeg
fi

# FreeType, FriBidi, HarfBuzz and libass: subtitles, set and drawn.
if ! built freetype; then
    fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$freetype.tar.xz" 36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
    unpack "freetype-$freetype.tar.xz" "freetype-$freetype"
    with_meson freetype "freetype-$freetype" -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=system -Dtests=disabled
    cp "$src/freetype-$freetype/docs/FTL.TXT" "$licenses/FreeType.FTL.txt"
    done_with freetype
fi
if ! built fribidi; then
    fetch "https://github.com/fribidi/fribidi/releases/download/v$fribidi/fribidi-$fribidi.tar.xz" 1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f
    unpack "fribidi-$fribidi.tar.xz" "fribidi-$fribidi"
    with_meson fribidi "fribidi-$fribidi" -Ddocs=false -Dtests=false -Dbin=false
    cp "$src/fribidi-$fribidi/COPYING" "$licenses/FriBidi.LGPL.txt"
    done_with fribidi
fi
if ! built harfbuzz; then
    fetch "https://github.com/harfbuzz/harfbuzz/releases/download/$harfbuzz/harfbuzz-$harfbuzz.tar.xz" 0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d
    unpack "harfbuzz-$harfbuzz.tar.xz" "harfbuzz-$harfbuzz"
    with_meson harfbuzz "harfbuzz-$harfbuzz" -Dauto_features=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled
    cp "$src/harfbuzz-$harfbuzz/COPYING" "$licenses/HarfBuzz.MIT.txt"
    done_with harfbuzz
fi
if ! built libass; then
    fetch "https://github.com/libass/libass/releases/download/$libass/libass-$libass.tar.xz" 2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
    unpack "libass-$libass.tar.xz" "libass-$libass"
    with_meson libass "libass-$libass" -Dauto_features=disabled -Ddirectwrite=enabled -Dasm=enabled
    cp "$src/libass-$libass/COPYING" "$licenses/libass.ISC.txt"
    done_with libass
fi

# uchardet: which encoding a subtitle file is in. Its sources as they are, as one library
# (its own build wants CMake, for nothing more than this).
if ! built uchardet; then
    fetch "https://www.freedesktop.org/software/uchardet/releases/uchardet-$uchardet.tar.xz" e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0
    unpack "uchardet-$uchardet.tar.xz" "uchardet-$uchardet"
    (
        cd "$src/uchardet-$uchardet/src"
        rm -rf "objects-$arch" && mkdir "objects-$arch"
        objects=
        for file in *.cpp LangModels/*.cpp; do
            object=objects-$arch/$(echo "$file" | tr '/' '_').o
            $CXX -O2 "$plain" -std=c++11 -I. -DVERSION="\"$uchardet\"" -DBUILDING_UCHARDET -c "$file" -o "$object"
            objects="$objects $object"
        done
        rm -f "objects-$arch/libuchardet.a"
        # shellcheck disable=SC2086
        $AR rcs "objects-$arch/libuchardet.a" $objects
        cp "objects-$arch/libuchardet.a" "$prefix/lib/"
        mkdir -p "$prefix/include/uchardet" && cp uchardet.h "$prefix/include/uchardet/"
    )
    cat > "$prefix/lib/pkgconfig/uchardet.pc" <<EOF
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: uchardet
Description: An encoding detector library ported from Mozilla
Version: $uchardet
Libs: -L\${libdir} -luchardet
Libs.private: -lc++
Cflags: -I\${includedir}/uchardet
EOF
    cp "$src/uchardet-$uchardet/COPYING" "$licenses/uchardet.MPL.txt"
    done_with uchardet
fi

# libbluray: a Blu-ray's folder as a movie. It reads discs that aren't protected: there is
# nothing here, or anywhere in First Row, that unscrambles one that is.
if ! built libbluray; then
    fetch "https://downloads.videolan.org/pub/videolan/libbluray/$libbluray/libbluray-$libbluray.tar.xz" f676408e91a5d321abf8b8d4dfdae36205c297dab5c54c3ec519639025f474a2
    unpack "libbluray-$libbluray.tar.xz" "libbluray-$libbluray"
    with_meson libbluray "libbluray-$libbluray" -Denable_tools=false -Dbdj_jar=disabled -Dfontconfig=disabled -Dfreetype=disabled -Dlibxml2=disabled
    cp "$src/libbluray-$libbluray/COPYING" "$licenses/libbluray.LGPL.txt"
    done_with libbluray
fi

# libplacebo, which mpv is built on. (From its repository, at the release's commit: the
# archive of a release leaves out the parts it carries.)
if ! built libplacebo; then
    if [ ! -d "$downloads/libplacebo-v$libplacebo" ]; then
        git clone -q --depth 1 --recursive --shallow-submodules -b "v$libplacebo" https://github.com/haasn/libplacebo.git "$downloads/libplacebo-v$libplacebo"
    fi
    if [ "$(git -C "$downloads/libplacebo-v$libplacebo" rev-parse HEAD)" != "$libplacebo_commit" ]; then
        echo "libplacebo v$libplacebo isn't at the commit that was expected" >&2
        exit 1
    fi
    [ -d "$src/libplacebo-v$libplacebo" ] || cp -R "$downloads/libplacebo-v$libplacebo" "$src/libplacebo-v$libplacebo"
    with_meson libplacebo "libplacebo-v$libplacebo" -Dauto_features=disabled -Dopengl=enabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
    cp "$src/libplacebo-v$libplacebo/LICENSE" "$licenses/libplacebo.LGPL.txt"
    done_with libplacebo
fi

# mpv, as a library: the one DLL, with all of the above inside it. Only what First Row asks
# of it is turned on: sound through Windows' own audio, pictures drawn with OpenGL into a
# window that isn't mpv's, and the graphics card's decoders with their pictures copied back.
fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v$mpv.tar.gz" bcfebbfa2b65a6d88dc97ea18117831072373e38b5785a2afb874ed4df5070dd "mpv-$mpv.tar.gz"
unpack "mpv-$mpv.tar.gz" "mpv-$mpv"
# One change to mpv's build: the filter that goes with the graphics card's decoders uses two
# functions kept in a file that is only built with mpv's Direct3D renderer, which isn't built
# here. The file is added to the decoders' own list.
if ! grep -q "'video/filter/vf_d3d11vpp.c', 'video/out/gpu/d3d11_helpers.c'" "$src/mpv-$mpv/meson.build"; then
    sed -i.orig "s|'video/filter/vf_d3d11vpp.c')|'video/filter/vf_d3d11vpp.c', 'video/out/gpu/d3d11_helpers.c')|" "$src/mpv-$mpv/meson.build"
    grep -q "'video/filter/vf_d3d11vpp.c', 'video/out/gpu/d3d11_helpers.c'" "$src/mpv-$mpv/meson.build" ||
        { echo "mpv's build file isn't as it was expected to be" >&2; exit 1; }
fi
rm -rf "$src/mpv-$mpv/build-$arch"
# (meson looks for iconv in the compiler's own folders only, or in the C library: with it
# among what everything is linked with, it is found as if it were there. And mpv only asks
# whether Windows' headers have a name of Direct3D's when its Direct3D renderer is built,
# which it isn't here: they do, so it is told.)
meson setup "$src/mpv-$mpv/build-$arch" "$src/mpv-$mpv" --cross-file "$cross" \
    -Ddefault_library=shared -Dprefer_static=true -Dauto_features=disabled \
    -Dc_link_args="-L$prefix/lib -static -liconv" -Dcpp_link_args="-L$prefix/lib -static -liconv" \
    -Dc_args="-I$prefix/include $plain -DHAVE_DXGI_DEBUG_D3D11=1" \
    -Dlibmpv=true -Dcplayer=false -Dgpl=false -Dbuild-date=false -Dlua=disabled \
    -Diconv=enabled -Dzlib=enabled -Duchardet=enabled -Dlibbluray=enabled \
    -Dwin32-threads=enabled -Dwasapi=enabled \
    -Dgl=enabled -Dgl-win32=enabled -Dplain-gl=enabled \
    -Dd3d-hwaccel=enabled -Dd3d9-hwaccel=enabled \
    > "$prefix/built/mpv.log" 2>&1 || { tail -40 "$prefix/built/mpv.log" >&2; exit 1; }
# (mpv keeps the words it was configured with too.)
sed -i.orig "s|$work|/build|g" "$src/mpv-$mpv/build-$arch/config.h"
ninja -C "$src/mpv-$mpv/build-$arch" >> "$prefix/built/mpv.log" 2>&1 || { tail -60 "$prefix/built/mpv.log" >&2; exit 1; }
cp "$src/mpv-$mpv/LICENSE.LGPL" "$licenses/mpv.LGPL.txt"

# What goes out: the DLL without its symbols, mpv's headers, and the licences. The compiler's
# own runtime is inside the DLL too (libc++, libunwind, compiler-rt, mingw-w64 and
# winpthreads), under the licences llvm-mingw passes on.
rm -rf "$out"
mkdir -p "$out/include/mpv" "$out/Licenses"
dll=$(find "$src/mpv-$mpv/build-$arch" -maxdepth 1 -name 'libmpv-2.dll' | head -1)
[ -n "$dll" ] || { echo "mpv's build made no libmpv-2.dll" >&2; exit 1; }
cp "$dll" "$out/libmpv-2.dll"
$STRIP --strip-all "$out/libmpv-2.dll"
for folder in "$work" "$(cd "$work" && pwd -P)"; do
    if grep -q -a -F "$folder" "$out/libmpv-2.dll"; then
        echo "The DLL has the build folder's path in it ($folder)" >&2
        exit 1
    fi
done
cp "$src/mpv-$mpv/include/mpv/"*.h "$out/include/mpv/"
cp "$licenses/"* "$out/Licenses/"
cp "$LLVM_MINGW/LICENSE.TXT" "$out/Licenses/llvm-mingw.LLVM.txt"
for name in MinGW-w64-runtime MinGW-w64 winpthreads; do
    cp "$LLVM_MINGW/$triple/share/mingw32/COPYING.$name.txt" "$out/Licenses/llvm-mingw.$name.txt"
done
cat > "$out/built-from.txt" <<EOF
libmpv-2.dll for Windows ($arch), built by Portable/scripts/build-libmpv-windows.sh from:

mpv $mpv (-Dgpl=false; one change to its build file, which the script makes and describes)
FFmpeg $ffmpeg (without --enable-gpl and --enable-nonfree)
libplacebo $libplacebo
libass $libass, FreeType $freetype, FriBidi $fribidi, HarfBuzz $harfbuzz
dav1d $dav1d
libbluray $libbluray
uchardet $uchardet
libiconv $libiconv
zlib $zlib
llvm-mingw $llvm_mingw (the compiler, and its runtime inside the DLL)
EOF
echo "Built $out/libmpv-2.dll ($(($(wc -c < "$out/libmpv-2.dll") / 1048576)) MB)"

#!/bin/sh
# Builds the media engine for older systems: FirstRowMediaEngineOlder.framework, which plays the
# further kinds of movie file on the systems the main engine doesn't run on (macOS 10.15 to 14,
# iOS and tvOS 15.6 to 17). It is FFmpeg, built here from its source for those systems and under
# the LGPL, and one file of First Row's own (Engine.m) that plays what FFmpeg reads through the
# system's own layers and sound.
#
#   MediaEngine/Older/build.sh            every system
#   MediaEngine/Older/build.sh macos      or: ios, ios-simulator, tvos, tvos-simulator
#
# The Mac's is built with the Xcode named in OLDER_MAC_DEVELOPER_DIR if that is set (an Xcode
# old enough to build for macOS 10.15; the newest only go back to macOS 12), and otherwise for
# the oldest macOS the Xcode in use can build for. nasm is needed for the Intel Mac's build
# (brew install nasm). What it makes goes beside the main engine, in MediaEngine/build/<sdk>/.
#
# FFmpeg's own build can't be done in a folder with a space in its name, so it is done in
# OLDER_BUILD_DIR if that is set, and otherwise in a folder of its own among the temporary files.
set -e
here=${OLDER_SOURCE_DIR:-$(cd "$(dirname "$0")" && pwd)}
work=${OLDER_BUILD_DIR:-${TMPDIR:-/tmp}/firstrow-older-engine}
work=${work%/}
version=8.1.3
case $work in *" "*) echo "The build folder's name has a space in it: set OLDER_BUILD_DIR to one without."; exit 1 ;; esac
mkdir -p "$work"

if [ ! -d "$work/ffmpeg-$version" ]; then
    echo "Fetching FFmpeg $version..."
    [ -f "$work/ffmpeg-$version.tar.xz" ] || curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$work/ffmpeg-$version.tar.xz"
    tar -xf "$work/ffmpeg-$version.tar.xz" -C "$work"
fi

# slice <name> <sdk> <arch> <flag that sets the oldest system> [developer dir]
slice() {
    name=$1; sdk=$2; arch=$3; floor=$4; developer=$5
    out="$work/$name"
    [ -f "$out/lib/libavformat.a" ] && return 0
    echo "Building FFmpeg for $name..."
    if [ -n "$developer" ]; then export DEVELOPER_DIR="$developer"; else unset DEVELOPER_DIR; fi
    # (The system's files and the compiler are reached by names without spaces in them.)
    ln -sfn "$(xcrun --sdk "$sdk" --show-sdk-path)" "$work/sdk-$name"
    cc="xcrun --sdk $sdk clang"
    flags="-arch $arch $floor -isysroot $work/sdk-$name -fno-common"
    extra=""
    [ "$arch" = x86_64 ] && extra="--x86asmexe=nasm"
    rm -rf "$work/obj-$name" && mkdir -p "$work/obj-$name" && cd "$work/obj-$name"
    "$work/ffmpeg-$version/configure" --prefix="$out" --enable-cross-compile --target-os=darwin --arch="$arch" \
        --cc="$cc" --extra-cflags="$flags" --extra-ldflags="$flags" $extra \
        --enable-static --disable-shared --enable-pic --disable-debug --disable-doc --disable-programs \
        --disable-avdevice --disable-avfilter --disable-encoders --disable-muxers --disable-devices \
        --disable-autodetect --enable-zlib --enable-bzlib --enable-iconv --enable-network --enable-securetransport \
        --enable-videotoolbox --enable-audiotoolbox > configure.log 2>&1 || { tail -5 configure.log; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { grep -E "error" make.log | head -5; exit 1; }
    make install > install.log 2>&1
    cd "$here"
}

# plugin <sdk> <name of the slice> <arch> <floor flag> <thin output> [developer dir]
plugin() {
    sdk=$1; name=$2; arch=$3; floor=$4; thin=$5; developer=$6
    if [ -n "$developer" ]; then export DEVELOPER_DIR="$developer"; else unset DEVELOPER_DIR; fi
    root=$(xcrun --sdk "$sdk" --show-sdk-path)
    ffmpeg="$work/$name"
    printf '_OBJC_CLASS_$_FirstRowMediaEngineOlder\n_OBJC_METACLASS_$_FirstRowMediaEngineOlder\n' > "$work/exports.txt"
    case $sdk in
        macosx) inside="Versions/A/" ;;
        *) inside="" ;;
    esac
    xcrun --sdk "$sdk" clang -arch "$arch" $floor -isysroot "$root" -O2 -fobjc-arc -fmodules -dynamiclib \
        -I"$ffmpeg/include" "$here/Engine.m" \
        "$ffmpeg/lib/libavformat.a" "$ffmpeg/lib/libavcodec.a" "$ffmpeg/lib/libswresample.a" "$ffmpeg/lib/libswscale.a" "$ffmpeg/lib/libavutil.a" \
        -lz -lbz2 -liconv -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
        -framework AudioToolbox -framework QuartzCore -framework CoreGraphics -framework CoreFoundation -framework Foundation -framework Security \
        -Wl,-exported_symbols_list,"$work/exports.txt" \
        -install_name "@rpath/FirstRowMediaEngineOlder.framework/${inside}FirstRowMediaEngineOlder" -o "$thin"
}

# bundle <sdk> <binary>: the framework, with FFmpeg's licence in it.
bundle() {
    sdk=$1; binary=$2
    out="$here/../build/$sdk/FirstRowMediaEngineOlder.framework"
    rm -rf "$out"
    if [ "$sdk" = macosx ]; then
        mkdir -p "$out/Versions/A/Resources/Licenses"
        cp "$binary" "$out/Versions/A/FirstRowMediaEngineOlder"
        resources="$out/Versions/A/Resources"
        ln -s A "$out/Versions/Current"
        ln -s Versions/Current/FirstRowMediaEngineOlder "$out/FirstRowMediaEngineOlder"
        ln -s Versions/Current/Resources "$out/Resources"
    else
        mkdir -p "$out/Licenses"
        cp "$binary" "$out/FirstRowMediaEngineOlder"
        resources="$out"
    fi
    cat > "$resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>FirstRowMediaEngineOlder</string>
	<key>CFBundleIdentifier</key><string>jacksondam.firstrow.mediaengine.older</string>
	<key>CFBundleName</key><string>FirstRowMediaEngineOlder</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
    cp "$work/ffmpeg-$version/COPYING.LGPLv2.1" "$resources/Licenses/FFmpeg.LGPL-2.1.txt"
    printf 'FFmpeg %s, built from its source by MediaEngine/Older/build.sh with the options there\n(no --enable-gpl, no --enable-nonfree), is inside this framework under the LGPL 2.1 or later.\nIts source: https://ffmpeg.org/releases/ffmpeg-%s.tar.xz\n' "$version" "$version" > "$resources/Licenses/README.txt"
    codesign --force --sign - "$out" > /dev/null 2>&1 || true
    echo "  made MediaEngine/build/$sdk/FirstRowMediaEngineOlder.framework"
}

mac_developer="${OLDER_MAC_DEVELOPER_DIR:-}"
mac_floor_intel="-mmacosx-version-min=10.15"
[ -z "$mac_developer" ] && mac_floor_intel="-mmacosx-version-min=12.0"

build() {
    case $1 in
        macos)
            slice macosx-arm64 macosx arm64 -mmacosx-version-min=11.0 "$mac_developer"
            slice macosx-x86_64 macosx x86_64 "$mac_floor_intel" "$mac_developer"
            plugin macosx macosx-arm64 arm64 -mmacosx-version-min=11.0 "$work/older-arm64" "$mac_developer"
            plugin macosx macosx-x86_64 x86_64 "$mac_floor_intel" "$work/older-x86_64" "$mac_developer"
            lipo -create "$work/older-arm64" "$work/older-x86_64" -output "$work/older-macosx"
            bundle macosx "$work/older-macosx" ;;
        ios)
            slice iphoneos-arm64 iphoneos arm64 -miphoneos-version-min=15.6
            plugin iphoneos iphoneos-arm64 arm64 -miphoneos-version-min=15.6 "$work/older-iphoneos"
            bundle iphoneos "$work/older-iphoneos" ;;
        ios-simulator)
            slice iphonesimulator-arm64 iphonesimulator arm64 -mios-simulator-version-min=15.6
            plugin iphonesimulator iphonesimulator-arm64 arm64 -mios-simulator-version-min=15.6 "$work/older-iphonesimulator"
            bundle iphonesimulator "$work/older-iphonesimulator" ;;
        tvos)
            slice appletvos-arm64 appletvos arm64 -mtvos-version-min=15.6
            plugin appletvos appletvos-arm64 arm64 -mtvos-version-min=15.6 "$work/older-appletvos"
            bundle appletvos "$work/older-appletvos" ;;
        tvos-simulator)
            slice appletvsimulator-arm64 appletvsimulator arm64 -mtvos-simulator-version-min=15.6
            plugin appletvsimulator appletvsimulator-arm64 arm64 -mtvos-simulator-version-min=15.6 "$work/older-appletvsimulator"
            bundle appletvsimulator "$work/older-appletvsimulator" ;;
        *) echo "unknown system: $1"; exit 1 ;;
    esac
}

if [ $# -eq 0 ]; then
    for system in macos ios ios-simulator tvos tvos-simulator; do build "$system"; done
else
    for system in "$@"; do build "$system"; done
fi

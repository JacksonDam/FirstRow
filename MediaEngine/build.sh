#!/bin/sh
# Builds First Row's media engine (see README.md) for the systems named, or for all of them:
#
#   MediaEngine/build.sh [macos] [ios] [ios-simulator] [tvos] [tvos-simulator]
#
# What it makes goes in MediaEngine/build/<sdk>/, where the app's build looks for it. It needs
# Xcode 27 or later: set DEVELOPER_DIR if that isn't the one xcode-select names.
set -e

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

# The app and the engine know each other by one file, which is the app's.
mkdir -p Sources/FirstRowMediaEngine/Shared
cp ../firstrow/Movies.frappliance/MediaEngineInterface.swift Sources/FirstRowMediaEngine/Shared/MediaEngineInterface.swift

[ $# -gt 0 ] || set -- macos ios ios-simulator tvos tvos-simulator

for system in "$@"; do
    case "$system" in
        macos) destination="generic/platform=macOS"; sdk=macosx; products=Release ;;
        ios) destination="generic/platform=iOS"; sdk=iphoneos; products=Release-iphoneos ;;
        ios-simulator) destination="generic/platform=iOS Simulator"; sdk=iphonesimulator; products=Release-iphonesimulator ;;
        tvos) destination="generic/platform=tvOS"; sdk=appletvos; products=Release-appletvos ;;
        tvos-simulator) destination="generic/platform=tvOS Simulator"; sdk=appletvsimulator; products=Release-appletvsimulator ;;
        *) echo "build.sh: unknown system \"$system\"" >&2; exit 2 ;;
    esac
    echo "Building the media engine for $system..."
    derived="$here/.build/xcode-$sdk"
    xcodebuild -scheme FirstRowMediaEngine -destination "$destination" -configuration Release \
        -derivedDataPath "$derived" -skipPackagePluginValidation \
        SKIP_INSTALL=NO DEBUG_INFORMATION_FORMAT=dwarf build > "$here/.build/build-$sdk.log" 2>&1 || {
        tail -40 "$here/.build/build-$sdk.log" >&2
        echo "build.sh: the build for $system failed (the whole log is in MediaEngine/.build/build-$sdk.log)" >&2
        exit 1
    }
    built="$derived/Build/Products/$products"
    out="$here/build/$sdk"
    rm -rf "$out"
    mkdir -p "$out"
    cp -R "$built/PackageFrameworks/FirstRowMediaEngine.framework" "$out/"
    # The engine's own libraries, which it loads from beside itself.
    for framework in "$built"/Aether*.framework; do
        [ -d "$framework" ] && cp -R "$framework" "$out/"
    done
    # What the engine keeps beside its code (a silent sound it plays on Apple TV, its privacy manifest).
    for bundle in "$built"/*.bundle; do
        [ -d "$bundle" ] || continue
        if [ -d "$out/FirstRowMediaEngine.framework/Versions/A" ]; then
            mkdir -p "$out/FirstRowMediaEngine.framework/Versions/A/Resources"
            cp -R "$bundle" "$out/FirstRowMediaEngine.framework/Versions/A/Resources/"
            [ -e "$out/FirstRowMediaEngine.framework/Resources" ] || ln -s Versions/Current/Resources "$out/FirstRowMediaEngine.framework/Resources"
        else
            cp -R "$bundle" "$out/FirstRowMediaEngine.framework/"
        fi
    done
    # The terms the engine's parts come under travel with it.
    if [ -d "$out/FirstRowMediaEngine.framework/Versions/A" ]; then
        licenses="$out/FirstRowMediaEngine.framework/Versions/A/Resources/Licenses"
    else
        licenses="$out/FirstRowMediaEngine.framework/Licenses"
    fi
    mkdir -p "$licenses"
    checkouts="$derived/SourcePackages/checkouts"
    cp "$checkouts/AetherEngine/LICENSE" "$licenses/AetherEngine.txt"
    cp "$checkouts/FFmpegBuild/LICENSES/LGPL-2.1.txt" "$licenses/FFmpeg.LGPL-2.1.txt"
    cp "$checkouts/FFmpegBuild/LICENSES/dav1d.BSD-2-Clause.txt" "$licenses/dav1d.BSD-2-Clause.txt"
    cp "$checkouts/FFmpegBuild/LICENSES/zimg.WTFPL.txt" "$licenses/zimg.WTFPL.txt"
    cp "$checkouts/FFmpegBuild/LICENSES/libzvbi-ure.MIT.txt" "$licenses/libzvbi-ure.MIT.txt"
    cp "$checkouts/FFmpegBuild/LICENSES/README.md" "$licenses/FFmpeg-parts.md"
    cp "$checkouts/LibDovi/LICENSE" "$licenses/libdovi.txt"
    cp "$checkouts/SMBClient/LICENSE" "$licenses/SMBClient.txt"
    cp "$here/README.md" "$licenses/README.md"
    # The engine finds its own libraries beside itself, wherever the two are put.
    if [ -d "$out/FirstRowMediaEngine.framework/Versions/A" ]; then
        install_name_tool -add_rpath "@loader_path/../../.." "$out/FirstRowMediaEngine.framework/Versions/A/FirstRowMediaEngine"
    else
        install_name_tool -add_rpath "@loader_path/.." "$out/FirstRowMediaEngine.framework/FirstRowMediaEngine"
    fi
    codesign --force --sign - "$out/FirstRowMediaEngine.framework" 2> /dev/null
    echo "  made MediaEngine/build/$sdk"
done

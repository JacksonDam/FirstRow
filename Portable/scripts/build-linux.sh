#!/bin/sh
# Builds First Row for Linux into dist/linux/FirstRow.
# Needs Swift 6.4 (swift.org), SDL 3 and libmpv: on Ubuntu 26.04 and Debian 13,
#   sudo apt install libsdl3-dev libmpv-dev libgl-dev
set -e
cd "$(dirname "$0")/../.."
swift build -c release --product FirstRow --static-swift-stdlib
out=dist/linux/FirstRow
rm -rf "$out"
mkdir -p "$out/Resources"
cp .build/release/FirstRow "$out/first-row"
cp -R firstrow/Assets.xcassets firstrow/Sounds firstrow/ScreenSaverDefaultPhotos "$out/Resources/"
if [ -d firstrow/Videos ]; then cp -R firstrow/Videos "$out/Resources/"; fi
cp firstrow/Assets.xcassets/AppIcon.appiconset/icon-mac-512x512.png "$out/first-row.png"
cat > "$out/first-row.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=First Row
Comment=Your movies, music and photos, from the couch
Exec=first-row
Icon=first-row
Categories=AudioVideo;Player;
DESKTOP
echo "Built $out"

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
cp -R firstrow/Assets.xcassets firstrow/Sounds firstrow/ScreenSaverDefaultPhotos firstrow/Fonts "$out/Resources/"
if [ -d firstrow/Videos ]; then cp -R firstrow/Videos "$out/Resources/"; fi
cp firstrow/Assets.xcassets/AppIcon.appiconset/icon-mac-512x512.png "$out/first-row.png"
# The window shows its icon by itself where the desktop lets a window bring one. The desktop
# entry gives First Row its icon everywhere else (GNOME's dock, the applications menu), once
# install.sh has put it where the desktop looks.
cat > "$out/first-row.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=First Row
Comment=Your movies, music and photos, from the couch
Exec=first-row
Icon=first-row
StartupWMClass=first-row
Categories=AudioVideo;Player;
DESKTOP
cat > "$out/install.sh" <<'INSTALL'
#!/bin/sh
# Adds First Row to your applications menu, with its icon (which is also what gives its
# window an icon in GNOME's dock). Nothing is copied: the entry points at this folder, so run
# this again if the folder moves. "install.sh remove" takes the entry out again.
set -e
here=$(cd "$(dirname "$0")" && pwd)
entry="${XDG_DATA_HOME:-$HOME/.local/share}/applications/first-row.desktop"
if [ "$1" = remove ]; then
    rm -f "$entry"
    echo "Removed $entry"
    exit 0
fi
mkdir -p "$(dirname "$entry")"
sed -e "s|^Exec=.*|Exec=\"$here/first-row\"|" -e "s|^Icon=.*|Icon=$here/first-row.png|" "$here/first-row.desktop" > "$entry"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$entry")" >/dev/null 2>&1 || true
fi
echo "Added $entry"
INSTALL
chmod +x "$out/install.sh"
echo "Built $out"

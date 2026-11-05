# First Row on Linux and Windows

The Linux and Windows versions run the same Swift code as the Mac app. Instead of rewriting the interface, this folder provides portable versions of the Apple frameworks that code uses, so the Mac's layout, animations and timing carry over unchanged:

| Module | Stands in for | Built on |
|---|---|---|
| `QuartzCore` | Core Animation: layers, implicit and explicit animations, transactions, 3D transforms, masks, shadows, blur filters, gradients, replicators | An OpenGL 3.3 compositor that follows Core Animation's rules (each layer flattens its sublayers into its own plane; masks, blurs, shadows and group opacity render offscreen) |
| `CoreGraphics`, `ImageIO`, `CoreImage` | Bitmap contexts, paths, gradients, clipping, shadows and transparency layers; image decoding; the blur and colour filters First Row uses | [plutovg](https://github.com/sammycage/plutovg) (MIT), bundled in `Sources/CPortable` with its stb_image and stb_truetype |
| `CoreText` | Fonts, line layout, wrapping, truncation, glyph drawing, measured like Core Text (hhea metrics, kerning, UTF-16 ranges) | TrueType fonts found on the machine |
| `AVFoundation` | `AVPlayer`, `AVPlayerLayer`, assets and their tags, frame grabs, `AVAudioPlayer` | libmpv for playback and frames; SDL 3 audio for interface sounds; its own reader for ID3, MP4, FLAC, WAV and AIFF tags |
| `Combine` | `ObservableObject` and `@Published` | Plain Swift |
| `iTunesLibrary`, `Photos` | The Music and Photos libraries | Nothing: they answer like a Mac with access turned off, so music and photos come from folders, iTunes library files and iPhoto libraries |
| `FirstRowPortable` | `NSImage`, the window, the run loop, keys, game controllers, file pickers | SDL 3 |

`firstrow/` is shared with the Xcode project. Code that differs on Linux and Windows sits behind `#if FIRSTROW_PORTABLE`, and mostly takes the Mac's branch.

## Building

### Linux

Swift 6.4 from [swift.org](https://www.swift.org/install/linux/), SDL 3 and libmpv. On Ubuntu 26.04:

```sh
sudo apt install libsdl3-dev libmpv-dev libgl-dev
Portable/scripts/build-linux.sh
dist/linux/FirstRow/first-row
```

The Swift runtime is linked in, so `dist/linux/FirstRow` only needs SDL 3 and libmpv on the machine it runs on.

### Windows

Swift 6.4 for Windows and Visual Studio's C++ build tools. From a Developer PowerShell:

```powershell
Portable\scripts\build-windows.ps1            # or -Arch arm64
& "dist\windows\FirstRow\First Row.exe"
```

The script downloads SDL 3 and libmpv the first time and copies their DLLs and the Swift runtime next to the app. The Arm libmpv build has no OpenGL renderer, so on Windows on Arm video frames are converted on the processor and uploaded, which costs more processor time with large videos.

First Row needs OpenGL 3.3, which every current graphics driver provides. A machine or virtual machine without one can use Mesa's software renderer instead: put `opengl32.dll`, `libgallium_wgl.dll` and the DLLs they load (MSYS2's `mingw-w64-clang-x86_64-mesa` or `mingw-w64-clang-aarch64-mesa` package) next to `First Row.exe`.

## Fonts

First Row's interface is set in Lucida Grande, which is Apple's and can't be included. First Row looks for it in this order:

1. A folder named in `FIRSTROW_FONTS`
2. The user's and system's font folders (`~/.local/share/fonts`, `/usr/share/fonts`, `C:\Windows\Fonts` and so on)
3. Any other font fontconfig knows of, on Linux

TrueType and OpenType files, collections (`.ttc`) and old Mac `.dfont` files all work. If Lucida Grande is installed (copied from a Mac you own, for example), the text matches the Mac exactly. Otherwise First Row uses Lucida Sans Unicode, which is close and comes with Windows, then DejaVu Sans, then another plain sans-serif font such as Noto Sans or Liberation Sans. Bold is drawn from the regular face when no bold one is found. `FIRSTROW_DEBUG_FONTS=1` prints which font file each name was given, and `FIRSTROW_DEBUG_FONTS_LIST=1` adds every face found.

## Using it

- Arrow keys move, Return selects, Escape or Backspace goes back, Space plays and pauses.
- Ctrl+Q, Alt+F4 or closing the window quits with the fade. Ctrl+, opens Settings > Media Folders.
- Game controllers: D-pad or left stick moves, A selects, B, Back or Start goes back, X plays and pauses.
- Movies come from your Movies or Videos folder and music from your Music folder, plus any folders, iTunes library files and iPhoto libraries added in Settings > Media Folders (where photo folders are added too), and drives under `/media`, `/run/media` and `/mnt` (other drive letters on Windows).
- `FIRSTROW_WINDOWED=1` or `--windowed` opens a window instead of filling the screen. `FIRSTROW_WINDOW_SIZE=1280x720` sets its size.

## What differs from the Mac

- Apple Music, the Music app's library, Apple Photos and the Podcasts app aren't available, so those parts show what a Mac without them shows.
- SF Symbols can only ship on Apple platforms, so the few interface symbols (the chevron, play, pause, shuffle) are the hand-drawn versions the app uses on macOS 10.15.
- Colours are not colour-managed: on a wide-gamut display, saturated colours look stronger than on a Mac, which converts them.
- Movies with DRM can't play, as on the Mac.

## Testing

`FIRSTROW_HARNESS=1` turns on the test harness, which takes the same commands as the Mac one (`down`, `enter`, `escape`, `press:down`, `source:music:/path` and so on) from the FIFO in `FIRSTROW_HARNESS_FIFO` or a script file in `FIRSTROW_SCRIPT`, plus `wait 1.5`, `shot /path/file.png` and `quit`. With `SDL_VIDEO_DRIVER=offscreen` it runs without a display, and `FIRSTROW_SCALE=2` renders at Retina scale. `FIRSTROW_DEBUG_MPV=1` and `FIRSTROW_DEBUG_FRAMES=1` log playback and frame times.

The workflow in `.github/workflows/linux-windows.yml` builds both versions and saves a screenshot of the main menu from each.

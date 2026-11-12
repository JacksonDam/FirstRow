# What First Row for Linux and Windows is made with

First Row's own code is in its repository. These are the other people's parts that go out with
it, the terms each comes under, and where its source is. The licences' own texts are beside this
file.

| Part | Where it is | Licence | Source |
| --- | --- | --- | --- |
| mpv 0.42.0 as libmpv, with FFmpeg, libass, libplacebo and the other libraries it is built from inside it | Windows: `libmpv-2.dll` | LGPL 2.1 or later (`mpv.LGPL.txt`) | [mpv 0.42.0](https://github.com/mpv-player/mpv/releases/tag/v0.42.0) |
| SDL 3 | Windows: `SDL3.dll` | zlib (`SDL.zlib.txt`) | [SDL](https://github.com/libsdl-org/SDL) |
| The Swift runtime and Foundation | Windows: the `swift*.dll` and `Foundation*.dll` files, `dispatch.dll` and `BlocksRuntime.dll`. Linux: inside `first-row` | Apache 2.0 with the Runtime Library Exception (`Swift.Apache-2.0.txt`) | [swiftlang](https://github.com/swiftlang) |
| ICU | Windows: `_FoundationICU.dll`. Linux: inside `first-row` | Unicode License V3 (`ICU.Unicode.txt`) | [ICU](https://github.com/unicode-org/icu) |
| plutovg | inside the program | MIT (`plutovg.MIT.txt`) | [plutovg](https://github.com/sammycage/plutovg) |
| FreeType's rasteriser and stroker, as plutovg carries them | inside the program | The FreeType Project Licence (`FreeType.FTL.txt`) | [FreeType](https://freetype.org) |
| stb_image, stb_image_write and stb_truetype, as plutovg carries them | inside the program | MIT or public domain (`stb.txt`) | [stb](https://github.com/nothings/stb) |
| Inter | `Resources/Fonts/Inter` | SIL Open Font License 1.1 (`Resources/Fonts/Inter/OFL.txt`) | [Inter](https://github.com/rsms/inter) |
| Microsoft's Visual C++ runtime | Windows: `msvcp140*.dll`, `vcruntime140*.dll`, `concrt140.dll` and `vccorlib140.dll` | Microsoft's, passed on as Visual Studio's terms allow | |

Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights
reserved.

On Linux, SDL 3 and mpv are the system's own (`libsdl3` and `libmpv`) and aren't part of First
Row's download. Nor is Samba's client library (`libsmbclient`, under the GPL version 3), which
First Row loads from the system, if it is there, to read shared folders.

## mpv on Windows

`libmpv-2.dll` is the mpv project's own build of libmpv for Windows, the one it publishes under
the LGPL (`libmpv-v0.42.0-x86_64-w64-mingw32-lgpl.zip` and
`libmpv-v0.42.0-aarch64-w64-mingw32-lgpl.zip` at the address above), as it comes. mpv is built
there with `-Dgpl=false` and an FFmpeg configured without `--enable-gpl`, so nothing in it is
under the GPL, and it has nothing in it that reads DVDs or unscrambles them.

First Row uses it only through mpv's client API, so another build of libmpv 2 can be put in its
place by replacing the file.

Its source: mpv's is at the address above. The libraries inside it are the ones in the
[FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) images mpv's own build uses (`win64-lgpl`
and `winarm64-lgpl`), which that project's scripts fetch and build from source; mpv's part of
the recipe is `ci/build-mingw64-full.sh` in its repository.

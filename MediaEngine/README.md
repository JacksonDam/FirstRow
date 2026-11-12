# First Row's media engine

First Row plays what the system's own player can open with the system's player: MP4, MOV and
M4V files, and streams. Everything else goes through the engine in this folder: Matroska, AVI,
Windows Media, Flash video, MPEG-1 and MPEG-2, transport streams, WebM, RealMedia, pictures of
DVDs and Blu-rays, and the sound and subtitles that come in them (AC-3, DTS, TrueHD, FLAC,
Vorbis, WMA; SubRip, SSA/ASS, PGS, VobSub, DVB and the rest).

The engine is [AetherEngine](https://github.com/superuser404notfound/AetherEngine), which reads
files with FFmpeg, decodes with the system's own decoders where they can (and with FFmpeg's and
dav1d's where they can't), and shows the picture through the system's own player layers, so
HDR, Dolby Vision and Dolby Atmos reach the screen and the speakers as the system means them to.

This is the Mac, iPhone, iPad and Apple TV side. On Linux and Windows First Row plays
everything through mpv (see `Portable/README.md`).

## Why it is a framework of its own

The engine needs macOS 15, iOS 18 or tvOS 18, and Xcode 27 to build. First Row itself still
runs on macOS 10.15 and iOS and tvOS 15.6, and its Mac app is built with an older Xcode to keep
it so. So the engine is built apart from the app, into `FirstRowMediaEngine.framework`, and the
app loads it as it runs, on the systems new enough for it. On older systems, and in a copy of
First Row built without the engine, the kinds of file above simply can't be played, as before.

The app and the engine know each other only through
`firstrow/Movies.frappliance/MediaEngineInterface.swift`, which is compiled into both.

## Building it

```sh
MediaEngine/build.sh            # every system
MediaEngine/build.sh macos      # or: ios, ios-simulator, tvos, tvos-simulator
```

It needs Xcode 27 or later (set `DEVELOPER_DIR` if that isn't the one `xcode-select` names) and
the network the first time, to fetch AetherEngine and its prebuilt FFmpeg. What it makes goes
in `MediaEngine/build/<sdk>/`. The app's own build copies the engine for the system it's
building for into the app, if it finds it there, and signs it with the app.

## What's in it, and under what terms

| Part | Licence | How it's included |
| --- | --- | --- |
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) 7.63.0 | LGPL-3.0 with an exception for app stores | compiled into `FirstRowMediaEngine.framework` |
| [FFmpeg](https://ffmpeg.org) (from [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild)) | LGPL-2.1 or later | frameworks of its own beside the engine |
| [dav1d](https://code.videolan.org/videolan/dav1d) | BSD 2-Clause | a framework of its own |
| [zimg](https://github.com/sekrit-twc/zimg) | WTFPL | a framework of its own |
| [libzvbi](https://github.com/zapping-vbi/zvbi) | LGPL-2.0 or later | a framework of its own |
| [libdovi](https://github.com/quietvoid/dovi_tool) (from [LibDovi](https://github.com/superuser404notfound/LibDovi)) | MIT, © quietvoid | compiled in |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) | MIT, © Kishikawa Katsumi | compiled in |
| [Anime4K](https://github.com/bloc97/Anime4K) (a scaler in AetherEngine) | MIT, © bloc97 | compiled in |

The exact versions are in `Package.resolved`. The licences' own texts are copied into the built
framework (`Licenses/`), and so travel with every copy of First Row that carries the engine.
The source of each part is at the addresses above; First Row's own part is this folder.

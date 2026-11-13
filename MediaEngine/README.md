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

## Two engines

There are two, and First Row loads whichever the system it's on can run:

- **The main engine** (`MediaEngine/Sources`, built by `MediaEngine/build.sh`) on macOS 15, iOS 18
  and tvOS 18 and later. It is the one described above, and the only one with HDR, Dolby
  Vision, Dolby Atmos, picture in picture and shared folders.
- **The engine for older systems** (`MediaEngine/Older`, built by `MediaEngine/Older/build.sh`) on
  the systems before those that First Row still runs on: macOS 10.15 to 14, iOS and tvOS 15.6 to
  17. It is plainer: FFmpeg, built from its source for those systems, reads the file and
  decodes what the system's own decoders can't, and the picture and sound go out through the
  system's sample-buffer layer and renderer. It plays the same kinds of file, with their
  subtitles, audio tracks and chapters, and unprotected DVDs.

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

### Signing in to a Mac's shared folders

SMBClient signs in with NTLM, which a Mac takes only from an account that has Windows File
Sharing turned on (a Mac keeps no NTLM form of a password otherwise). So `build.sh` fetches
SMBClient at the version the engine is made for into `MediaEngine/Vendor/SMBClient`, applies
`SMBClient/kerberos.patch` and adds `SMBClient/Kerberos.swift`, and the engine is built with that
copy (SwiftPM says the copy and the engine's own mention of the library are the same package,
which is the point). With the addition, a server that offers it (a Mac) is signed in to with
Kerberos carried inside the sign-in, through the system's GSS framework, as one Mac signs in
to another: an account's name and password as they are. The Apple TV has no GSS framework,
so there the addition is left out and a Mac still wants Windows File Sharing for the account.

### The engine for older systems

```sh
MediaEngine/Older/build.sh            # every system, or name them as above
```

It fetches FFmpeg's source the first time and builds it for each system (a few minutes each),
then compiles `Engine.m` against it. The Mac's is built with the Xcode named in
`OLDER_MAC_DEVELOPER_DIR` if that is set: it has to be one old enough to build for macOS 10.15
(the newest only go back to macOS 12). `nasm` is needed for the Intel Mac's build. FFmpeg's own
build can't be done in a folder with a space in its name, so it is done among the temporary
files, or in `OLDER_BUILD_DIR` if that is set.

## What's in it, and under what terms

| Part | Licence | How it's included |
| --- | --- | --- |
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) 7.63.0 | LGPL-3.0 with an exception for app stores | compiled into `FirstRowMediaEngine.framework` |
| [FFmpeg](https://ffmpeg.org) (from [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild)) | LGPL-2.1 or later | frameworks of its own beside the engine |
| [dav1d](https://code.videolan.org/videolan/dav1d) | BSD 2-Clause | a framework of its own |
| [zimg](https://github.com/sekrit-twc/zimg) | WTFPL | a framework of its own |
| [libzvbi](https://github.com/zapping-vbi/zvbi) | LGPL-2.0 or later | a framework of its own |
| [libdovi](https://github.com/quietvoid/dovi_tool) (from [LibDovi](https://github.com/superuser404notfound/LibDovi)) | MIT, © quietvoid | compiled in |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) 0.3.1, with First Row's addition to it (`MediaEngine/SMBClient/`) | MIT, © Kishikawa Katsumi | compiled in |
| [Anime4K](https://github.com/bloc97/Anime4K) (a scaler in AetherEngine) | MIT, © bloc97 | compiled in |

The engine for older systems has one part that isn't First Row's own:

| Part | Licence | How it's included |
| --- | --- | --- |
| [FFmpeg](https://ffmpeg.org) 8.1.3, built from its source by `MediaEngine/Older/build.sh` without `--enable-gpl` or `--enable-nonfree`, with the decoders a library of movies needs (they are listed there) | LGPL-2.1 or later | compiled into `FirstRowMediaEngineOlder.framework` |

The exact versions are in `Package.resolved`. The licences' own texts are copied into the built
framework (`Licenses/`), and so travel with every copy of First Row that carries the engine.
The source of each part is at the addresses above; First Row's own part is this folder.

# First Row Classic

First Row Classic is [First Row](https://github.com/JacksonDam/FirstRow) with the look **Front Row** had when it first came with Mac OS X Tiger: a ring of four icons that turns on a glossy floor, lists of four large rows, and a title bar the chosen section's icon flies up into. Now Playing, messages and the question about where to start a movie are pages of their section, sliding in like any other.

This branch keeps that look and nothing else of its own. Everything under it is the main branch's: the Core Animation renderer, the libraries and the players. It is merged with main, so it gains what main gains.

It runs on the Mac, on macOS 10.15 Catalina and later.

## What's in it

- **Videos**: the movies in your Movies folder and in a `Movies` folder at the top of any drive, playing beside the list as you move through it; iTunes Top Movies, Music Videos and TV Episodes with their previews; and the video podcasts you've downloaded in Apple Podcasts.
- **Music** from your library and Apple Music, by playlist, artist, album, song, genre and composer, with audiobooks, podcasts, iTunes Top Songs and Shuffle Songs.
- **Photos** from Apple Photos as slideshows with music: the whole library by album, the last 12 months, or the last roll.
- **DVD**: a disc that isn't protected against copying plays in First Row; a protected one opens in the DVD player that comes with the Mac.

It opens by drawing your desktop back into the distance, and leaves the same way.

What main has and this doesn't, because the Tiger look has no place for it: the Modern look, Settings, Sources (media servers and shared folders), Spotify, YouTube, TV Shows, the screen saver and the intro movie. Use the main branch for those.

First Row Classic comes in English and German, and follows the language of the system.

## Controls

| | |
|---|---|
| **Keyboard** | Arrow keys move, `Return` chooses, `Esc` or `Delete` goes back, `Space` plays and pauses. `Cmd+Esc` quits. |
| **Siri Remote** (paired with the Mac) | Swipe or click the clickpad to move, click the centre to choose, Back goes back, Play/Pause plays and pauses. The volume buttons set the Mac's volume. |
| **Apple Remote** (Macs with an infrared receiver) | `+` and `-` move in menus and set the volume during playback. `⏮` and `⏭` move left and right, or change song in Now Playing (hold them to scrub). The centre button chooses and plays, `Menu` goes back. |
| **Game controller** | D-pad or left stick moves, `A` chooses, `B` or `Menu` goes back, `X` plays and pauses. |

In Now Playing, `Up` and `Down` change song and `Left` and `Right` scrub. In a movie, tap `Left` or `Right` to skip 10 seconds or hold them to scrub.

## Building

Open `First Row Classic.xcodeproj` in Xcode and run the **First Row** scheme for macOS. To have it play the kinds of movie file beyond MP4, MOV and M4V, build the media engines first with `MediaEngine/build.sh` and `MediaEngine/Older/build.sh` (see [`MediaEngine/README.md`](MediaEngine/README.md)): the app's build picks them up from there.

## How it's put together

The Tiger look is in `firstrow/Tiger/`:

```
TigerTheme.swift               Its measurements, timings and sounds
TigerMenuFeatures.swift        The four sections and their rows
MenuView+Tiger.swift           What its keys do, and the opening and leaving
MenuView+TigerPodcasts.swift   Podcasts under Music and Videos
TigerSceneLayer.swift          The ring, the icon's flight to the title bar, pages sliding
TigerPageLayer.swift           A page: its title, and a list, a song or a message
TigerPreviewLayers.swift       The movie and the photos that stand beside a list
TigerScrubberLayer.swift       The progress bar under a song or over a movie
TigerRing.swift, TigerMotion.swift
```

The rest of the tree is main's, with a line here and there that hands over to the look (`TigerTheme.isActive`). The main branch's README describes it.

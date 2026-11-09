# First Row


https://github.com/user-attachments/assets/2ff954c0-50fe-403b-b0b7-39557c937d62


First Row brings back **Front Row**, the media centre that came with Mac OS X Tiger through Snow Leopard and ran the first Apple TV. It's rebuilt from scratch in Swift on Core Animation, with the menus, carousels, sounds and transitions matched to the Leopard and Snow Leopard version.

It runs on macOS 10.15 Catalina and later, on iPhone, iPad and Apple TV (iOS and tvOS 15.6 and later), and there are beta builds for Linux and Windows on the [Releases](https://github.com/JacksonDam/FirstRow/releases) page.

There are two looks. **Classic** is the original, down to the pixel. **Modern** is a flatter take in the style of today's Apple TV, with capsule rows, a large preview card, artwork-tinted backgrounds, Liquid Glass controls on macOS 26 and iOS 26+, and its own softer sounds. You pick one the first time you open First Row and can switch any time in Settings.

## Classic

<p align="center">
  <img src="docs/images/2026-03-09-20-30-17.png" width="32%" />
  <img src="docs/images/2026-03-09-20-31-14.png" width="32%" />
  <img src="docs/images/2026-03-09-20-30-53.png" width="32%" />
</p>
<p align="center">
  <img src="docs/images/2026-03-09-20-33-43.png" width="32%" />
  <img src="docs/images/2026-03-09-20-32-16.png" width="32%" />
  <img src="docs/images/2026-03-09-20-34-19.png" width="32%" />
</p>

## Modern

<p align="center">
  <img src="docs/images/modern-welcome.png" width="32%" />
  <img src="docs/images/modern-main-menu.png" width="32%" />
  <img src="docs/images/modern-itunes-top-movies.png" width="32%" />
</p>
<p align="center">
  <img src="docs/images/modern-itunes-top-songs.png" width="32%" />
  <img src="docs/images/modern-now-playing.png" width="32%" />
  <img src="docs/images/modern-movie.png" width="32%" />
</p>

## What's in it

- **Movies** from your Movies folder, external drives and network shares (anything in a `Movies` folder at the top of a volume), plus any folders you add in Settings. Movies remember where you stopped, even after quitting, and show up in Continue Watching. Press `Down` while one plays for subtitles, audio track and speed.
- **Music** from your library and Apple Music, or folders and an iTunes library file you add in Settings (macOS), with a Now Playing screen that shows lyrics, lists the songs around the one playing and slowly flips the player round to protect the screen from burn-in.
- **Spotify** under Music: your Liked Songs, playlists, albums and artists, playing in the same Now Playing screen. You sign in once on Spotify's own page.
- **Jellyfin** under Sources: find servers on your network or add one by address, sign in with Quick Connect or a password, and browse Continue Watching, Next Up and your libraries. Videos and songs play in First Row's own players and your progress goes back to the server.
- **Photos** from Apple Photos, an iPhoto library or folders you add in Settings, as slideshows with music and a Ken Burns effect.
- **Podcasts** you've downloaded in Apple Podcasts (macOS).
- **iTunes Top Charts** for movies, TV episodes, songs and music videos, with playable previews.
- **A screen saver** of floating photos, after anything from a minute to an hour of inactivity.
- **Media keys, Control Center and headphone buttons** on macOS, iOS and tvOS, with whatever's playing shown in the system's Now Playing.

Movies and shows bought from the Apple TV app won't play because of their DRM, and Theatrical Trailers is empty because Apple's trailer servers are gone (a replacement would be welcome).

## Controls

| | |
|---|---|
| **Keyboard** | Arrow keys move, `Return` chooses, `Esc` or `Delete` goes back, `Space` plays and pauses. `Cmd+Esc` quits on a Mac, `Ctrl+Esc` or `Ctrl+Q` elsewhere. |
| **Mouse or trackpad** (macOS, Linux, Windows; turn on in Settings) | Point at a row and click it. Scroll long lists, use the on-screen Back button, and click or drag the progress bar to seek. In Now Playing, move to the right edge for the song list. |
| **Touch** (iPhone, iPad) | Tap a row to open it. Drag a list to scroll it, or hold and slide to move through it. Swipe in from the left or tap Back to go back. In Now Playing, swipe in from the right for the song list. |
| **Siri Remote** (Apple TV, or paired with a Mac) | Swipe or click the clickpad to move, click the centre to choose, Back goes back, Play/Pause plays and pauses. On a Mac, the TV button opens Now Playing's song list and the volume buttons set the Mac's volume. |
| **Apple Remote** (Macs with an infrared receiver) | `+` and `-` move in menus and set the volume during playback. `⏮` and `⏭` move left and right, or change song in Now Playing (hold them to scrub). The centre button chooses and plays, `Menu` goes back. |
| **Game controller** | D-pad or left stick moves, `A` chooses, `B` or `Menu` goes back, `X` plays and pauses. |

In Now Playing, `Up` and `Down` change song, `Left` and `Right` scrub, and `Return` shows the lyrics. In a movie, tap `Left` or `Right` to skip 10 seconds or hold them to scrub, and press `Down` for subtitles, audio and speed.

## Building

Open `First Row.xcodeproj` in Xcode and run the **First Row** scheme for macOS, iOS or tvOS. The Linux and Windows builds use the Swift package in `Package.swift` and need SDL 3 and mpv.

## How it's put together

```
firstrow/
├── AppShell.swift, AppDelegate.swift   Launch, windows, input routing
├── MenuView.swift, MenuView+*.swift    The app's state and behaviour, split by area
├── Engine/                             The Core Animation renderer: menus, carousels, previews, players
├── MenuConfiguration.swift             The list of top-level menus
├── Movies.frappliance/                 Movies, Continue Watching and iTunes Top Movies
├── TV.frappliance/                     iTunes Top TV Episodes
├── Music.frappliance/                  Music library, Spotify, Now Playing
├── Podcasts.frappliance/               Podcasts
├── Photos.frappliance/                 Photos and slideshows
├── FRSettings.frappliance/             Settings, media folders and the screen saver
├── FRSources.frappliance/              Sources and Jellyfin support
├── Assets.xcassets, Sounds/, Videos/   Images, interface sounds and the intro movie
└── ScreenSaverDefaultPhotos/           Photos for the screen saver
Portable/                               Stand-ins for Apple's frameworks on Linux and Windows
```

Each `.frappliance` folder holds one top-level menu, and the idea is for each to become a separately loadable plugin.

### Adding a menu

Say you want a **NewTube** item on the main menu.

1. Make a `NewTube.frappliance` folder with a feature that describes the item and its submenu:

   ```swift
   struct NewTubeMenuFeature: MenuFeatureConfiguration {
       let rootItem = RootMenuItemConfig(id: "newtube", title: "NewTube", iconAssetName: "newtube")
       let submenuItems: [SubmenuItemConfig] = [
           .init(id: "newtube_playlists", title: "Playlists", leadsToMenu: true),
           .init(id: "newtube_videos", title: "Videos", leadsToMenu: true),
       ]
   }
   ```

   Set `leadsToMenu` for rows that open another list, and override `defaultSubmenuSelectedIndex` if the submenu shouldn't start on its first row.

2. Add a `newtube` image set to `Assets.xcassets` for the main menu's carousel.

3. Add `NewTubeMenuFeature()` to the catalog in `MenuConfiguration.swift`. Its place in that list is its place on the main menu.

   The item now shows up, opens and closes with the right sounds, and lists its rows.

4. Make the rows do something in `triggerSubmenuAction()` in `MenuView+InputHandling.swift`:

   ```swift
   if activeRootItemID == "newtube", item.id == "newtube_playlists" {
       playSound(named: "Selection")
       enterNewTubePlaylistsMenu()
       return
   }
   ```

For a third level of lists, add a case to `ThirdMenuMode` in `MenuView+MenuNavigation.swift`, fill in `thirdMenuItems` and set `thirdMenuMode` when the row is chosen; `enterMoviesFolderMenu()` is a good example. The picture beside the list comes from `gapContentItems(sceneSize:pass:memo:)` in `MenuView+GapContent.swift`, which can show the item's icon (the default), a preview, details or a carousel of covers.

## Thanks

If you'd like to support the project, you can [buy me a coffee](https://buymeacoffee.com/gameroof1w).

## License

[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)

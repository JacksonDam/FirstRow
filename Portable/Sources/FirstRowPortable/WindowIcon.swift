import CoreGraphics
import CSDL3
import Foundation

/// The window's icon in the task bar, the dock and the window switcher, from the app icon's
/// artwork that ships in Resources.
///
/// Windows needs none of this: there the icon is part of `First Row.exe` (the build script
/// puts it in, in every size Windows asks for), and SDL gives that one to the window. Linux
/// programs can't carry an icon, so the window is handed its pictures as it opens. Desktops
/// that take a window's icon from its desktop entry instead (GNOME on Wayland) find it by the
/// app's name below, once `install.sh` has added the entry.
enum WindowIcon {
    /// What the desktop knows the app by: the name of its desktop entry.
    static let appID = "first-row"

    /// The app icon's sizes. The first is the one every desktop gets (docks and window
    /// switchers scale it down); the others go along where SDL can pass on more than one.
    private static let files = ["icon-mac-128x128.png", "icon-mac-256x256.png", "icon-mac-32x32@2x.png", "icon-mac-32x32.png", "icon-mac-16x16.png"]

    /// Before SDL starts: the name windows are grouped and matched to a desktop entry by.
    static func nameApp() {
        #if !os(Windows)
            SDL_SetHint(SDL_HINT_APP_ID, appID)
        #endif
    }

    static func apply(to window: OpaquePointer?) {
        #if !os(Windows)
            var surfaces: [UnsafeMutablePointer<SDL_Surface>] = []
            var buffers: [UnsafeMutablePointer<UInt8>] = []
            defer {
                // SDL has copied what it needs by now.
                surfaces.forEach { SDL_DestroySurface($0) }
                buffers.forEach { $0.deallocate() }
            }
            for file in files {
                guard let url = AppResources.url("Assets.xcassets/AppIcon.appiconset/\(file)"),
                      let data = try? Data(contentsOf: url),
                      let image = CGImage.decode(data), image.width > 0, image.height > 0
                else { continue }
                // Ours are blue, green, red, alpha with the colours multiplied by the alpha. SDL
                // wants them not multiplied.
                let rowBytes = image.width * 4
                let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes * image.height)
                for y in 0 ..< image.height {
                    let source = image.storage.bytes + y * image.storage.bytesPerRow
                    let target = pixels + y * rowBytes
                    for x in 0 ..< image.width {
                        let alpha = Int(source[x * 4 + 3])
                        for channel in 0 ..< 3 {
                            target[x * 4 + channel] = alpha == 0 ? 0 : UInt8(min(255, (Int(source[x * 4 + channel]) * 255 + alpha / 2) / alpha))
                        }
                        target[x * 4 + 3] = UInt8(alpha)
                    }
                }
                guard let surface = SDL_CreateSurfaceFrom(Int32(image.width), Int32(image.height), SDL_PIXELFORMAT_ARGB8888, pixels, Int32(rowBytes)) else {
                    pixels.deallocate()
                    continue
                }
                buffers.append(pixels)
                surfaces.append(surface)
            }
            guard let first = surfaces.first else { return }
            for other in surfaces.dropFirst() {
                SDL_AddSurfaceAlternateImage(first, other)
            }
            SDL_SetWindowIcon(window, first)
        #endif
    }
}

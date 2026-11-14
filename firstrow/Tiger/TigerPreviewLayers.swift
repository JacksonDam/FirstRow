import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// The movie that is chosen in a list of movies, playing to the left of the list.
@MainActor
final class TigerMoviePreviewLayer {
    let layer = SceneLayer()

    func update(menu _: MenuView, sceneSize _: CGSize) {}
    func pause() {}
    func tearDown() {}
}

/// The album that is chosen in Photos, to the left of the list.
@MainActor
final class TigerPhotosPreviewLayer {
    let layer = SceneLayer()

    func update(menu _: MenuView, pass _: RenderPass, sceneSize _: CGSize) {}
}

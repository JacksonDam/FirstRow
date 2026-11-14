import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// Where a preview stands to the left of a list: turned a little towards the list, over its
/// own reflection.
@MainActor
enum TigerPreview {
    static let width: CGFloat = 548
    static let reflectionHeight: CGFloat = 168
    static let centerX: CGFloat = 390
    static let yawDegrees: Double = 23.8
    static let perspective: CGFloat = 0.75

    /// Lays `stand` out for a picture of `height`, with room for the reflection under it.
    static func place(_ stand: CALayer, pictureHeight height: CGFloat, sceneSize: CGSize) {
        let size = CGSize(width: width, height: height + reflectionHeight)
        stand.bounds = CGRect(origin: .zero, size: size)
        stand.position = CGPoint(x: centerX, y: sceneSize.height * 0.5 + reflectionHeight * 0.5)
        stand.transform = yawTransform(degrees: yawDegrees, perspective: perspective, viewSize: size)
    }

    /// The fade a reflection has from its top to its foot.
    static func reflectionMask() -> CAGradientLayer {
        let mask = StillGradientLayer()
        mask.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        return mask
    }
}

/// The movie that is chosen in a list of movies, playing over and over to the left of the
/// list once the list has rested on it for a moment.
@MainActor
final class TigerMoviePreviewLayer {
    let layer = SceneLayer()
    private let stand = StillLayer()
    private let picture = AVPlayerLayer()
    private let reflectionBox = SceneLayer()
    private let reflection = AVPlayerLayer()
    private let reflectionMask = TigerPreview.reflectionMask()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playingURL: URL?
    private var wantedURL: URL?
    private var wait: Task<Void, Never>?
    private var isPaused = false

    private static let pictureHeight = TigerPreview.width / (16.0 / 9.0)

    init() {
        picture.videoGravity = .resizeAspectFill
        picture.masksToBounds = true
        reflection.videoGravity = .resizeAspectFill
        reflection.masksToBounds = true
        reflectionBox.masksToBounds = true
        reflectionBox.opacity = 0.5
        reflectionBox.mask = reflectionMask
        reflectionBox.addSublayer(reflection)
        stand.addSublayer(picture)
        stand.addSublayer(reflectionBox)
        stand.isHidden = true
        layer.addSublayer(stand)
    }

    func update(menu: MenuView, sceneSize: CGSize) {
        let height = Self.pictureHeight
        withoutLayerActions {
            layer.place(CGRect(origin: .zero, size: sceneSize))
            TigerPreview.place(stand, pictureHeight: height, sceneSize: sceneSize)
            picture.frame = CGRect(x: 0, y: 0, width: TigerPreview.width, height: height)
            reflectionBox.place(CGRect(x: 0, y: height, width: TigerPreview.width, height: TigerPreview.reflectionHeight))
            reflectionMask.frame = CGRect(x: 0, y: 0, width: TigerPreview.width, height: TigerPreview.reflectionHeight)
            // The same picture upside down, hanging from the picture's foot.
            reflection.bounds = CGRect(x: 0, y: 0, width: TigerPreview.width, height: height)
            reflection.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            reflection.position = CGPoint(x: TigerPreview.width * 0.5, y: height * 0.5)
            reflection.transform = CATransform3DMakeScale(1, -1, 1)
        }
        // While a movie itself plays, the preview behind it stops.
        let pauses = menu.isMoviePlaybackVisible || menu.isMovieTransitioning
        if pauses != isPaused {
            isPaused = pauses
            if pauses { player?.pause() } else { player?.play() }
        }
        show(menu.tigerMoviePreviewURL())
    }

    private func show(_ url: URL?) {
        guard url != wantedURL else { return }
        wantedURL = url
        wait?.cancel()
        wait = nil
        guard let url else {
            stop()
            return
        }
        guard url != playingURL else { return }
        // (The one playing stays until the next is ready, a moment after the list rests on it.)
        wait = Task { @MainActor [weak self] in
            try? await firstRowSleep(1.0)
            guard !Task.isCancelled, let self, self.wantedURL == url else { return }
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            let looper = AVPlayerLooper(player: queue, templateItem: item)
            if !self.isPaused { queue.play() }
            let previous = self.player
            self.player = queue
            self.looper = looper
            self.playingURL = url
            withoutLayerActions {
                self.picture.player = queue
                self.reflection.player = queue
                self.stand.isHidden = false
            }
            previous?.pause()
            self.wait = nil
        }
    }

    private func stop() {
        player?.pause()
        looper = nil
        player = nil
        playingURL = nil
        withoutLayerActions {
            stand.isHidden = true
            picture.player = nil
            reflection.player = nil
        }
    }

    func pause() {
        wait?.cancel()
        wait = nil
        player?.pause()
    }

    func tearDown() {
        wait?.cancel()
        wait = nil
        wantedURL = nil
        stop()
    }
}

/// The album that is chosen in Photos, to the left of the list: its cover, or a stack of
/// prints where there is none to show.
@MainActor
final class TigerPhotosPreviewLayer {
    let layer = SceneLayer()
    /// Slides in from the left as Photos opens, and away again as it closes.
    private let slider = SceneLayer()
    private let stand = StillLayer()
    private let picture = SceneLayer()
    private let reflectionBox = SceneLayer()
    private let reflection = SceneLayer()
    private let reflectionMask = TigerPreview.reflectionMask()
    private let standIn = StillLayer()
    private var shown: NSImage?
    private var isIn: Bool?

    private static let pictureHeight = TigerPreview.width * 3.0 / 4.0

    init() {
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        reflection.contentsGravity = .resizeAspectFill
        reflection.masksToBounds = true
        reflectionBox.masksToBounds = true
        reflectionBox.opacity = 0.5
        reflectionBox.mask = reflectionMask
        reflectionBox.addSublayer(reflection)
        stand.addSublayer(picture)
        stand.addSublayer(reflectionBox)
        standIn.contentsGravity = .resize
        slider.addSublayer(stand)
        slider.addSublayer(standIn)
        layer.addSublayer(slider)
    }

    func update(menu: MenuView, pass: RenderPass, sceneSize: CGSize) {
        let height = Self.pictureHeight
        let image = menu.tiger.photosPreviewImage
        withoutLayerActions {
            layer.place(CGRect(origin: .zero, size: sceneSize))
            slider.bounds = CGRect(origin: .zero, size: sceneSize)
            TigerPreview.place(stand, pictureHeight: height, sceneSize: sceneSize)
            picture.place(CGRect(x: 0, y: 0, width: TigerPreview.width, height: height))
            reflectionBox.place(CGRect(x: 0, y: height, width: TigerPreview.width, height: TigerPreview.reflectionHeight))
            reflectionMask.frame = CGRect(x: 0, y: 0, width: TigerPreview.width, height: TigerPreview.reflectionHeight)
            reflection.bounds = CGRect(x: 0, y: 0, width: TigerPreview.width, height: height)
            reflection.anchorPoint = .zero
            reflection.position = CGPoint(x: 0, y: height)
            reflection.transform = CATransform3DMakeScale(1, -1, 1)
            standIn.bounds = CGRect(x: 0, y: 0, width: 495, height: 685)
            standIn.position = CGPoint(x: TigerPreview.centerX - 30, y: sceneSize.height * 0.5 + TigerPreview.reflectionHeight * 0.5)
            if image !== shown || picture.contents == nil && image != nil {
                shown = image
                let cover = LayerImageCache.cgImage(for: image)
                picture.contents = cover
                reflection.contents = cover
            }
            stand.isHidden = image == nil
            standIn.isHidden = image != nil
            if image == nil, standIn.contents == nil {
                standIn.contents = LayerImageCache.cgImage(for: NSImage(named: "PhotosSharedPreview"))
            }
        }
        let slidIn = menu.tiger.isPhotosPreviewIn
        let place = CGPoint(x: slidIn ? 0 : -(TigerPreview.centerX + TigerPreview.width), y: 0)
        slider.setPosition(place, isIn == nil ? nil : pass.animation)
        isIn = slidIn
    }
}

#if os(iOS)
    import AVFoundation
    import QuartzCore
    import UIKit

    /// Bent at the fold, the part of the screen under it shows the movie's picture again behind
    /// the movie's controls: upside down, out of focus and dim, as a table top shows what stands
    /// on it, coming up out of black at the fold.
    ///
    /// While the screen is bent both pictures are drawn here, from one frame of the player's at
    /// one moment: the picture over the fold lies over the player's own, and the one under it
    /// is that same frame under the system's blur. So the two can't differ, whatever the player
    /// is doing. (A copy shown beside the player's own picture ran a frame or two behind it,
    /// and further behind while the bar was dragged. And the system draws a video's layer once:
    /// it can't be had to show it a second time.)
    @MainActor
    final class MovieReflection {
        /// The frame over the fold: it goes in the player's layer, over the player's picture.
        let picture = SceneLayer()
        /// The part of the screen under the fold.
        let layer = SceneLayer()
        private let turned = SceneLayer()
        private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        private let shade = StillGradientLayer()
        private var output: AVPlayerItemVideoOutput?
        private weak var item: AVPlayerItem?
        private var outputSize = CGSize.zero
        private let clock = FrameClock()
        private var hasPicture = false
        /// What `update` was last told, for asking for the frames between two of its calls.
        private weak var player: AVPlayer?
        private var pixelsWide: CGFloat = 0
        private var staysReady = false
        /// When the frames were asked for, and when the first of them was there.
        private var askedAt: CFTimeInterval?
        private var firstFrameAt: CFTimeInterval?

        init() {
            picture.contentsGravity = .resize
            picture.isHidden = true
            layer.masksToBounds = true
            layer.opacity = 0
            layer.isHidden = true
            turned.contentsGravity = .resizeAspectFill
            // Upside down: the foot of the picture is what is nearest the fold.
            turned.transform = CATransform3DMakeScale(1, -1, 1)
            layer.addSublayer(turned)
            blur.isUserInteractionEnabled = false
            layer.addSublayer(blur.layer)
            // Black at the fold, which the picture comes out of little by little; then dim,
            // and dimmer towards the bottom, where the controls are.
            shade.colors = [1, 0.9, 0.68, 0.42, 0.2, 0.1, 0.28, 0.58].map { CGColor(gray: 0, alpha: $0) }
            shade.locations = [0, 0.04, 0.1, 0.17, 0.25, 0.34, 0.62, 1]
            shade.startPoint = CGPoint(x: 0.5, y: 0)
            shade.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(shade)
        }

        /// `under` is the part of the screen under the fold, in the window's points: nil while
        /// the screen isn't bent. `pixelsWide` is how wide the picture over the fold is drawn.
        /// `staysReady`: the screen is one that folds, so the player is asked for its frames
        /// from the movie's start. Asked for them only as the screen bent, it held the picture
        /// still for a fifth of a second while it made room for them, just as the picture was
        /// moving up.
        func update(player: AVPlayer?, under: CGRect?, pixelsWide: CGFloat, staysReady: Bool) {
            self.player = player
            self.pixelsWide = pixelsWide
            self.staysReady = staysReady
            guard let item = player?.currentItem, under != nil || staysReady else {
                rest()
                detach()
                return
            }
            askForFrames(of: item)
            guard let under, under.width > 1, under.height > 1 else {
                rest()
                return
            }
            layer.isHidden = false
            layer.place(under)
            let box = CGRect(origin: .zero, size: under.size)
            if turned.bounds != box {
                // (Turned over about its top edge, it hangs from its bottom one.)
                withoutLayerActions {
                    turned.bounds = box
                    turned.position = CGPoint(x: 0, y: box.height)
                }
            }
            if blur.frame != box {
                blur.frame = box
                blur.layoutIfNeeded()
            }
            if shade.frame != box { withoutLayerActions { shade.frame = box } }
            if clock.onFrame == nil {
                clock.onFrame = { [weak self] seconds in self?.showNextFrame(after: seconds) ?? false }
            }
            clock.run()
        }

        /// Asks the player for each frame at the size it's drawn over the fold, in the
        /// picture's own shape (known once the movie has loaded, and again when a video
        /// changes its shape).
        private func askForFrames(of item: AVPlayerItem) {
            if item !== self.item { detach() }
            let shape = item.presentationSize
            guard shape.width > 1, shape.height > 1, pixelsWide > 1 else { return }
            let width = (pixelsWide / 2).rounded() * 2
            let wanted = CGSize(width: width, height: max(2, (width * shape.height / shape.width / 2).rounded() * 2))
            guard output == nil || wanted != outputSize else { return }
            detach()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(wanted.width),
                kCVPixelBufferHeightKey as String: Int(wanted.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            item.add(output)
            self.output = output
            self.item = item
            outputSize = wanted
            askedAt = CACurrentMediaTime()
        }

        /// Whether a movie that is starting can let its picture be seen. On a screen that
        /// folds the frames are asked for as the movie starts, and the first frame the
        /// player's own layer then shows has been seen drawn at the wrong size: as large as
        /// the frames asked for, from the layer's corner, for that one frame. So the picture
        /// is kept out of sight (see `MoviePlaybackLayers.holdPictureBack`) until the first
        /// of the frames has been there for a moment.
        func isSettled(at now: CFTimeInterval) -> Bool {
            guard staysReady, let item = player?.currentItem else { return true }
            askForFrames(of: item)
            guard let output, let askedAt else { return false }
            if firstFrameAt == nil, hasPicture || output.hasNewPixelBuffer(forItemTime: output.itemTime(forHostTime: now)) {
                firstFrameAt = now
            }
            if let firstFrameAt, now - firstFrameAt >= 0.1 { return true }
            // (Not for ever, should no frame come.)
            return now - askedAt >= 0.75
        }

        private func showNextFrame(after seconds: Double) -> Bool {
            guard let output, item != nil, !layer.isHidden else { return false }
            // The frame for the moment this one is on the screen: what is drawn now shows at
            // the screen's next frame.
            let ahead = min(max(seconds, 1.0 / 120), 1.0 / 30)
            let time = output.itemTime(forHostTime: CACurrentMediaTime() + ahead)
            // Over the player's own picture, wherever in its layer that is.
            let place = (picture.superlayer as? AVPlayerLayer)?.videoRect ?? .zero
            guard place.width > 1, place.height > 1 else {
                picture.isHidden = true
                return true
            }
            if picture.frame != place { picture.place(place) }
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                  let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return true }
            withoutLayerActions {
                picture.contents = surface
                turned.contents = surface
            }
            picture.isHidden = false
            if !hasPicture {
                hasPicture = true
                layer.setOpacity(1, .easeOut(duration: 0.6))
            }
            return true
        }

        /// Out of sight, with nothing drawn (the player goes on being asked for its frames).
        private func rest() {
            guard !layer.isHidden else { return }
            clock.stop()
            hasPicture = false
            layer.setOpacity(0, nil)
            layer.isHidden = true
            picture.isHidden = true
            withoutLayerActions {
                picture.contents = nil
                turned.contents = nil
            }
        }

        private func detach() {
            if let output, let item { item.remove(output) }
            output = nil
            item = nil
            outputSize = .zero
            askedAt = nil
            firstFrameAt = nil
        }
    }
#endif

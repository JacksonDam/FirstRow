#if !FIRSTROW_PORTABLE
    import AVFoundation
    import CoreImage
    import QuartzCore

    /// Bent at the fold, the part of the screen under it shows the movie's picture again
    /// behind the movie's controls: upside down, out of focus and dim, as a table top shows
    /// what stands on it, coming up out of black at the fold. The picture is read from the
    /// player frame by frame, at a small size (out of focus, it needs no more).
    @MainActor
    final class MovieReflectionLayer {
        let layer = SceneLayer()
        private let picture = SceneLayer()
        private let shade = StillGradientLayer()
        private var output: AVPlayerItemVideoOutput?
        private weak var item: AVPlayerItem?
        private var outputSize = CGSize.zero
        private let clock = FrameClock()
        private lazy var context = CIContext(options: [.cacheIntermediates: false])
        private var hasPicture = false

        init() {
            layer.masksToBounds = true
            layer.opacity = 0
            layer.isHidden = true
            picture.contentsGravity = .resizeAspectFill
            // Upside down: the foot of the picture is what is nearest the fold.
            picture.transform = CATransform3DMakeScale(1, -1, 1)
            layer.addSublayer(picture)
            // Black at the fold, which the picture comes out of little by little; then dim,
            // and dimmer towards the bottom, where the controls are.
            shade.colors = [1, 0.93, 0.78, 0.58, 0.42, 0.34, 0.58, 0.85].map { CGColor(gray: 0, alpha: $0) }
            shade.locations = [0, 0.04, 0.1, 0.17, 0.25, 0.34, 0.62, 1]
            shade.startPoint = CGPoint(x: 0.5, y: 0)
            shade.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(shade)
        }

        /// `frame` is where it shows, in the window's points: nil while the screen isn't bent.
        /// `staysReady`: the screen is one that folds, so the player is asked for its small
        /// copies from the movie's start. Asked for them only as the screen bent, it held the
        /// picture still for a fifth of a second while it made room for them, just as the
        /// picture was moving up.
        func update(player: AVPlayer?, frame: CGRect?, staysReady: Bool) {
            guard let item = player?.currentItem, frame != nil || staysReady else {
                rest()
                detach()
                return
            }
            // A small copy of each frame, in the picture's own shape (known once the movie has
            // loaded, and again when a video changes its size).
            if item !== self.item { detach() }
            let shape = item.presentationSize
            if shape.width > 1, shape.height > 1 {
                let wanted = CGSize(width: 160, height: max(2, (160 * shape.height / shape.width / 2).rounded() * 2))
                if output == nil || wanted != outputSize {
                    detach()
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: Int(wanted.width),
                        kCVPixelBufferHeightKey as String: Int(wanted.height),
                    ])
                    item.add(output)
                    self.output = output
                    self.item = item
                    outputSize = wanted
                }
            }
            guard let frame, frame.width > 1, frame.height > 1 else {
                rest()
                return
            }
            layer.isHidden = false
            layer.place(frame)
            let box = CGRect(origin: .zero, size: frame.size)
            if picture.bounds != box {
                // (Turned over about its top edge, it hangs from its bottom one.)
                withoutLayerActions {
                    picture.bounds = box
                    picture.position = CGPoint(x: 0, y: box.height)
                }
            }
            if shade.frame != box { withoutLayerActions { shade.frame = box } }
            if clock.onFrame == nil {
                clock.onFrame = { [weak self] seconds in self?.showNextPicture(after: seconds) ?? false }
            }
            clock.run()
        }

        private func showNextPicture(after seconds: Double) -> Bool {
            guard let output, item != nil, !layer.isHidden else { return false }
            // The frame that will be on the screen when this copy of it is: what is drawn now
            // shows at the screen's next frame. (Drawn for the present moment, and only some
            // thirty times a second, the copy ran a frame or two behind the picture, which
            // every cut gave away.)
            let ahead = min(max(seconds, 1.0 / 120), 1.0 / 30)
            let time = output.itemTime(forHostTime: CACurrentMediaTime() + ahead)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return true }
            let image = CIImage(cvPixelBuffer: buffer)
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: image.extent)
            guard let rendered = context.createCGImage(blurred, from: image.extent) else { return true }
            withoutLayerActions { picture.contents = rendered }
            if !hasPicture {
                hasPicture = true
                layer.setOpacity(1, .easeOut(duration: 0.6))
            }
            return true
        }

        /// Out of sight, with nothing drawn (the player goes on being asked for its copies).
        private func rest() {
            guard !layer.isHidden else { return }
            clock.stop()
            hasPicture = false
            layer.setOpacity(0, nil)
            layer.isHidden = true
            withoutLayerActions { picture.contents = nil }
        }

        private func detach() {
            if let output, let item { item.remove(output) }
            output = nil
            item = nil
            outputSize = .zero
        }
    }
#endif

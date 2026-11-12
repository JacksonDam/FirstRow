#if !FIRSTROW_PORTABLE
    import AVFoundation
    import CoreImage
    import QuartzCore

    /// Bent at the fold, the part of the screen under a movie's picture shows the picture again
    /// behind the movie's controls: upside down, out of focus and dim, as a table top shows
    /// what stands on it. The picture is read from the player some thirty times a second, at a
    /// small size (out of focus, it needs no more), and only while this shows.
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
        private var sinceLastPicture: Double = 0
        private var hasPicture = false

        init() {
            layer.masksToBounds = true
            layer.opacity = 0
            layer.isHidden = true
            picture.contentsGravity = .resizeAspectFill
            // Upside down: the foot of the picture is what is nearest the fold.
            picture.transform = CATransform3DMakeScale(1, -1, 1)
            layer.addSublayer(picture)
            // Dim, and dimmer further from the fold, where the controls are.
            shade.colors = [CGColor(gray: 0, alpha: 0.3), CGColor(gray: 0, alpha: 0.6), CGColor(gray: 0, alpha: 0.85)]
            shade.locations = [0, 0.55, 1]
            shade.startPoint = CGPoint(x: 0.5, y: 0)
            shade.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(shade)
        }

        /// `frame` is where it shows, in the window's points: nil when there is nothing to
        /// show it under (the screen isn't bent, or no movie is playing).
        func update(player: AVPlayer?, frame: CGRect?) {
            guard let frame, frame.width > 1, frame.height > 1, let item = player?.currentItem else {
                putAway()
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
            // A small copy of each frame, in the picture's own shape (known once the movie has
            // loaded, and again when a video changes its size).
            let shape = item.presentationSize
            guard shape.width > 1, shape.height > 1 else { return }
            let wanted = CGSize(width: 160, height: max(2, (160 * shape.height / shape.width / 2).rounded() * 2))
            if item !== self.item || wanted != outputSize {
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
            if clock.onFrame == nil {
                clock.onFrame = { [weak self] seconds in self?.showNextPicture(after: seconds) ?? false }
            }
            clock.run()
        }

        private func showNextPicture(after seconds: Double) -> Bool {
            guard let output, item != nil else { return false }
            sinceLastPicture += seconds
            guard sinceLastPicture >= 1.0 / 32 else { return true }
            sinceLastPicture = 0
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
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

        private func detach() {
            if let output, let item { item.remove(output) }
            output = nil
            item = nil
            outputSize = .zero
        }

        private func putAway() {
            guard output != nil || !layer.isHidden else { return }
            clock.stop()
            detach()
            hasPicture = false
            layer.setOpacity(0, nil)
            layer.isHidden = true
            withoutLayerActions { picture.contents = nil }
        }
    }
#endif

#if os(macOS)
    import AppKit
    import AVFoundation
    import CoreVideo
    import Metal
    import MetalFX
    import QuartzCore

    /// MetalFX Video Upscaling, a setting on Macs with Apple silicon: a movie whose picture is
    /// smaller than its place on the screen is drawn there by MetalFX's scaler, which makes a
    /// sharper picture of it than stretching it does.
    enum MovieUpscaling {
        /// Whether this Mac can do it: Apple silicon, a system that has MetalFX (macOS 13 and
        /// later), and a graphics processor its scaler takes.
        static let isAvailable: Bool = {
            #if arch(arm64)
                guard #available(macOS 13.0, *), let device = MTLCreateSystemDefaultDevice() else { return false }
                return MTLFXSpatialScalerDescriptor.supportsDevice(device)
            #else
                return false
            #endif
        }()

        /// Whether movies are to be scaled up here now: it can be done, and is turned on.
        static var isOn: Bool { isAvailable && AppSettings.upscalesVideo }
    }

    /// Scales a movie's picture up as it plays. The system's player goes on showing the movie
    /// as it always does; this asks it for each frame as the frame comes due, has MetalFX scale
    /// it to the screen's own pixels, and shows the result in a layer that lies over the
    /// player's picture, in the player's layer. Whatever the scaler shouldn't have is left to
    /// the player, with nothing over it: a picture already as large as its place, a movie in
    /// HDR (the frames come here in eight bits), and one whose subtitles the player draws
    /// itself, in its own layer, where this would cover them.
    ///
    /// The layer is never hidden. A hidden layer drops the frames it is given and keeps the
    /// last one it showed, to show again when it is next brought out: the end of the movie
    /// before, at the start of the next. Whenever there is to be nothing over the player's
    /// picture the layer is changed for a new one instead, which has nothing in it.
    @available(macOS 13.0, *)
    @MainActor
    final class MovieUpscaler: NSObject {
        /// The picture scaled up. It goes in the layer showing the movie, over its picture.
        var layer: CALayer { metal }

        private var metal: CAMetalLayer
        private let device: MTLDevice
        private let renderer: UpscaleRenderer
        private weak var player: AVPlayer?
        private weak var item: AVPlayerItem?
        private var output: AVPlayerItemVideoOutput?
        /// Where the movie's picture is in the layer `layer` lies in, asked for at each frame
        /// (a player's layer knows it only once the movie has loaded).
        private var pictureBox: (() -> CGRect)?
        private var pixelsPerPoint: CGFloat = 1
        /// The display link (a `CADisplayLink`, from macOS 14), or the timer before that.
        private var link: AnyObject?
        private var timer: Timer?
        /// The subtitles a movie brings with it, which the player draws when one is chosen.
        private var ownSubtitles: AVMediaSelectionGroup?
        private var playerDrawsSubtitles = false
        private var framesUntilSubtitleCheck = 0
        private var shownColorSpace: CGColorSpace?
        /// When the next frame is to be looked at, while a movie is being left to the player
        /// (it is looked at again every second: a video can change its size, and its place).
        private var looksAgainAt: CFTimeInterval = 0
        /// The size the last frame was sent to be drawn at.
        private var askedPixels = CGSize.zero
        /// A frame has been asked for since the layer in use was made: it may have one in it.
        private var layerMayHavePicture = false

        /// Nil on a Mac with no graphics processor to ask.
        init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
            guard let device else { return nil }
            let metal = Self.makeLayer(device: device)
            guard let renderer = UpscaleRenderer(device: device, layer: metal) else { return nil }
            self.metal = metal
            self.device = device
            self.renderer = renderer
            super.init()
        }

        /// A layer for the scaled-up picture, out of sight and with nothing in it.
        private static func makeLayer(device: MTLDevice) -> CAMetalLayer {
            let metal = CAMetalLayer()
            metal.device = device
            metal.pixelFormat = .bgra8Unorm
            // (What the layer shows is copied into, not drawn into.)
            metal.framebufferOnly = false
            metal.isOpaque = true
            metal.contentsGravity = .resize
            metal.maximumDrawableCount = 3
            metal.allowsNextDrawableTimeout = true
            metal.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
            return metal
        }

        /// Takes the scaled-up picture off the player's: a layer that may have been given a
        /// frame is changed for a new one, which has nothing in it (see above). `ifSent` is
        /// for asking again and again while a movie is left to the player: then only a layer
        /// that is known to have been given one.
        private func clearPicture(ifSent: Bool = false) {
            guard ifSent ? renderer.state.hasSent : layerMayHavePicture else { return }
            layerMayHavePicture = false
            let old = metal
            let new = Self.makeLayer(device: device)
            new.frame = old.frame
            new.drawableSize = old.drawableSize
            metal = new
            shownColorSpace = nil
            renderer.draw(into: new)
            if let host = old.superlayer {
                withoutLayerActions {
                    host.insertSublayer(new, above: old)
                    old.removeFromSuperlayer()
                }
            }
        }

        /// `player` is the system's player showing the movie in the layer `layer` has been
        /// put in, or nil when there is nothing to scale up (no movie, or one this is not
        /// for). `pictureBox` says where in that layer its picture is.
        func update(player: AVPlayer?, pixelsPerPoint: CGFloat, pictureBox: (() -> CGRect)?) {
            self.pictureBox = pictureBox
            self.pixelsPerPoint = max(1, pixelsPerPoint)
            guard let player, pictureBox != nil else {
                self.player = nil
                detach()
                return
            }
            self.player = player
            follow(player.currentItem)
            run()
        }

        /// Takes `item` up (and lets go of the one before it).
        private func follow(_ item: AVPlayerItem?) {
            guard item !== self.item else { return }
            detach(stopping: false)
            guard let item else { return }
            self.item = item
            framesUntilSubtitleCheck = 0
            looksAgainAt = 0
            askedPixels = .zero
            Task { [weak self, weak item] in
                guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
                guard let self, self.item === item else { return }
                self.ownSubtitles = group
            }
        }

        /// Asks the movie for its frames, once it is ready to play: a stream asked any sooner
        /// never hands one over.
        private func askForFrames() {
            guard output == nil, let item, item.status == .readyToPlay else { return }
            // As they come: at the picture's own size and in its own colours, which each frame
            // names (and which say, too, when a movie is in HDR).
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(output)
            self.output = output
            renderer.follow(output)
        }

        private func detach(stopping: Bool = true) {
            if let output, let item { item.remove(output) }
            output = nil
            item = nil
            ownSubtitles = nil
            playerDrawsSubtitles = false
            clearPicture()
            renderer.follow(nil)
            if stopping { stop() }
        }

        // MARK: - A frame at a time

        private func run() {
            if #available(macOS 14.0, *) {
                if let link = link as? CADisplayLink {
                    link.isPaused = false
                    return
                }
                if let view = ProMotionPacer.shared.sceneView {
                    // (At the screen's own rate, each call naming when its frame will show.)
                    let link = view.displayLink(target: self, selector: #selector(linkFired(_:)))
                    link.add(to: .main, forMode: .common)
                    self.link = link
                    return
                }
            }
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.frame(showingAt: CACurrentMediaTime() + 1.0 / 60) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func stop() {
            if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = true }
            timer?.invalidate()
            timer = nil
        }

        @available(macOS 14.0, *)
        @objc private func linkFired(_ link: CADisplayLink) {
            frame(showingAt: link.targetTimestamp)
        }

        /// Once for each frame the screen shows: the picture's place is kept up, the movie's
        /// frame for that moment is sent to be scaled, and the layer shows or doesn't by how
        /// the last one went.
        private func frame(showingAt time: CFTimeInterval) {
            guard let player else {
                detach()
                return
            }
            if player.currentItem !== item { follow(player.currentItem) }
            askForFrames()
            guard let item, let output, let box = pictureBox?(), box.width > 1, box.height > 1 else {
                clearPicture()
                return
            }
            if metal.frame != box { metal.frame = box }
            // Whole, even numbers of pixels.
            let pixels = CGSize(
                width: max(2, (box.width * pixelsPerPoint / 2).rounded() * 2),
                height: max(2, (box.height * pixelsPerPoint / 2).rounded() * 2),
            )
            if metal.drawableSize != pixels { metal.drawableSize = pixels }
            framesUntilSubtitleCheck -= 1
            if framesUntilSubtitleCheck <= 0 {
                framesUntilSubtitleCheck = 30
                playerDrawsSubtitles = ownSubtitles.map { item.currentMediaSelection.selectedMediaOption(in: $0) != nil } ?? false
            }
            var state = renderer.state
            // The player's own picture is to show, with nothing over it: what the layer was
            // given before goes.
            if playerDrawsSubtitles {
                clearPicture()
                return
            }
            if state.isLeftAlone { clearPicture(ifSent: true) }
            if time >= looksAgainAt, state.wantsAnother || pixels != askedPixels || output.hasNewPixelBuffer(forItemTime: output.itemTime(forHostTime: time)) {
                // (Only when there is something to draw: a new frame, or the old one at a new size.)
                askedPixels = pixels
                layerMayHavePicture = true
                // (The last frame wasn't for scaling up: no need to look at every one.)
                if state.isLeftAlone { looksAgainAt = time + 1 }
                renderer.draw(forHostTime: time, pixels: pixels)
                state = renderer.state
            }
            if let space = state.colorSpace, space !== shownColorSpace {
                shownColorSpace = space
                metal.colorspace = space
            }
        }
    }

    /// The part that runs off the main thread: takes the frame due, scales it, and shows it.
    @available(macOS 13.0, *)
    private final class UpscaleRenderer: @unchecked Sendable {
        struct State {
            /// The layer in use has been sent a frame.
            var hasSent = false
            /// The last frame looked at wasn't for scaling up: the movie is the player's to show.
            var isLeftAlone = false
            /// The colours the frames are in.
            var colorSpace: CGColorSpace?
            /// The last frame couldn't be drawn as things stood, and is to be asked for again.
            var wantsAnother = false
        }

        /// How a frame fared.
        private enum Outcome {
            /// No new frame, and nothing to draw again.
            case nothing
            /// Not for scaling up.
            case leftAlone(CGColorSpace?)
            /// Sent to the layer.
            case sent(CGColorSpace?)
            /// Couldn't be drawn as things stood.
            case missed
        }

        /// A picture this near its place's size is left as it is.
        private static let leastScale = 1.1

        private let device: MTLDevice
        private let commands: MTLCommandQueue
        private let cache: CVMetalTextureCache
        private let queue = DispatchQueue(label: "firstrow.movie-upscaler", qos: .userInteractive)
        private let lock = NSLock()
        // Under the lock.
        private var layer: CAMetalLayer
        private var output: AVPlayerItemVideoOutput?
        private var shared = State()
        private var isBusy = false
        // On the queue.
        private var scaler: MTLFXSpatialScaler?
        private var scalerShape = [0, 0, 0, 0]
        /// What the scaler draws into (it wants a texture of its own, kept by the graphics
        /// processor), copied from there into what the layer shows.
        private var scaled: MTLTexture?
        private var lastFrame: CVPixelBuffer?
        private var lastPixels = CGSize.zero

        init?(device: MTLDevice, layer: CAMetalLayer) {
            var cache: CVMetalTextureCache?
            guard let commands = device.makeCommandQueue(),
                  CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
            self.device = device
            self.commands = commands
            self.layer = layer
            self.cache = cache
        }

        var state: State {
            lock.lock()
            defer { lock.unlock() }
            return shared
        }

        /// The layer the frames are drawn into from now on: a new one, with nothing in it.
        func draw(into layer: CAMetalLayer) {
            lock.lock()
            self.layer = layer
            shared.hasSent = false
            lock.unlock()
        }

        /// The frames to take from now on (nil: none).
        func follow(_ output: AVPlayerItemVideoOutput?) {
            lock.lock()
            self.output = output
            shared = State()
            lock.unlock()
            queue.async {
                self.lastFrame = nil
                self.lastPixels = .zero
                CVMetalTextureCacheFlush(self.cache, 0)
            }
        }

        /// Has the frame for `time` scaled to `pixels` and shown, unless the one before is
        /// still being seen to (then this one is passed over).
        func draw(forHostTime time: CFTimeInterval, pixels: CGSize) {
            lock.lock()
            let output = output
            let layer = layer
            let free = !isBusy
            if free, output != nil { isBusy = true }
            lock.unlock()
            guard free, let output else { return }
            queue.async {
                let outcome = self.draw(output, into: layer, forHostTime: time, pixels: pixels)
                self.lock.lock()
                self.isBusy = false
                // (Not for a movie that has been let go of meanwhile.)
                if self.output === output {
                    switch outcome {
                    case .nothing:
                        break
                    case let .leftAlone(space):
                        self.shared.isLeftAlone = true
                        self.shared.colorSpace = space
                        self.shared.wantsAnother = false
                    case let .sent(space):
                        // (Into the layer it was drawn for, if that is still the one in use.)
                        if self.layer === layer { self.shared.hasSent = true }
                        self.shared.isLeftAlone = false
                        self.shared.colorSpace = space
                        self.shared.wantsAnother = false
                    case .missed:
                        self.shared.wantsAnother = true
                    }
                }
                self.lock.unlock()
            }
        }

        private func draw(_ output: AVPlayerItemVideoOutput, into layer: CAMetalLayer, forHostTime time: CFTimeInterval, pixels: CGSize) -> Outcome {
            let itemTime = output.itemTime(forHostTime: time)
            var frame: CVPixelBuffer?
            if output.hasNewPixelBuffer(forItemTime: itemTime) {
                frame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
            }
            if let frame {
                lastFrame = frame
            } else if pixels != lastPixels {
                // The picture's place has changed size: the frame it has is drawn again for it.
                frame = lastFrame
            }
            guard let frame else { return .nothing }
            lastPixels = pixels
            let space = CVImageBufferGetColorSpace(frame)?.takeUnretainedValue()
            // HDR is the player's to show: these frames are eight bits of it.
            if let transfer = CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil) as? String,
               transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            {
                return .leftAlone(space)
            }
            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            let wide = Int(pixels.width)
            let high = Int(pixels.height)
            guard width > 1, height > 1, min(Double(wide) / Double(width), Double(high) / Double(height)) >= Self.leastScale else { return .leftAlone(space) }
            let shape = [width, height, wide, high]
            if scaler == nil || scalerShape != shape {
                let descriptor = MTLFXSpatialScalerDescriptor()
                descriptor.inputWidth = width
                descriptor.inputHeight = height
                descriptor.outputWidth = wide
                descriptor.outputHeight = high
                descriptor.colorTextureFormat = .bgra8Unorm
                descriptor.outputTextureFormat = .bgra8Unorm
                // (A movie's frames are stored as they are to look, not as amounts of light.)
                descriptor.colorProcessingMode = .perceptual
                scaler = descriptor.makeSpatialScaler(device: device)
                scalerShape = shape
                scaled = nil
                if let scaler {
                    let texture = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: wide, height: high, mipmapped: false)
                    texture.storageMode = .private
                    texture.usage = scaler.outputTextureUsage
                    scaled = device.makeTexture(descriptor: texture)
                }
            }
            var held: CVMetalTexture?
            guard let scaler, let scaled,
                  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, frame, nil, .bgra8Unorm, width, height, 0, &held) == kCVReturnSuccess,
                  let held, let picture = CVMetalTextureGetTexture(held),
                  let drawable = layer.nextDrawable() else { return .leftAlone(space) }
            // (The layer is given its size on the main thread: a frame made for the size
            // before waits for the next.)
            guard drawable.texture.width == wide, drawable.texture.height == high, let buffer = commands.makeCommandBuffer() else {
                lastPixels = .zero
                return .missed
            }
            scaler.colorTexture = picture
            scaler.outputTexture = scaled
            scaler.encode(commandBuffer: buffer)
            guard let copy = buffer.makeBlitCommandEncoder() else {
                lastPixels = .zero
                return .missed
            }
            copy.copy(from: scaled, to: drawable.texture)
            copy.endEncoding()
            buffer.present(drawable)
            // (The frame's texture is kept until it has been drawn from.)
            buffer.addCompletedHandler { _ in _ = held }
            buffer.commit()
            return .sent(space)
        }
    }
#endif

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
    @available(macOS 13.0, *)
    @MainActor
    final class MovieUpscaler: NSObject {
        /// The picture scaled up. It goes in the layer showing the movie, over its picture.
        var layer: CALayer { metal }

        private let metal: CAMetalLayer
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
        /// Frames to pass before the next is asked for, while a movie is being left to the
        /// player (it is looked at again every so often: a video can change its size).
        private var framesToPass = 0
        /// The size the last frame was sent to be drawn at.
        private var askedPixels = CGSize.zero

        /// Nil on a Mac with no graphics processor to ask.
        init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
            let metal = CAMetalLayer()
            guard let device, let renderer = UpscaleRenderer(device: device, layer: metal) else { return nil }
            self.metal = metal
            self.renderer = renderer
            super.init()
            metal.device = device
            metal.pixelFormat = .bgra8Unorm
            // (What the layer shows is copied into, not drawn into.)
            metal.framebufferOnly = false
            metal.isOpaque = true
            metal.contentsGravity = .resize
            metal.maximumDrawableCount = 3
            metal.allowsNextDrawableTimeout = true
            metal.isHidden = true
            metal.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
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
            framesToPass = 0
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
            renderer.follow(nil)
            metal.isHidden = true
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
                metal.isHidden = true
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
            if framesToPass > 0 {
                framesToPass -= 1
            } else if state.wantsAnother || pixels != askedPixels || output.hasNewPixelBuffer(forItemTime: output.itemTime(forHostTime: time)) {
                // (Only when there is something to draw: a new frame, or the old one at a new size.)
                askedPixels = pixels
                renderer.draw(forHostTime: time, pixels: pixels)
                state = renderer.state
            }
            // (A frame has come and wasn't for scaling up: no need to take every one.)
            if !state.hasPicture, state.colorSpace != nil, framesToPass == 0 { framesToPass = 30 }
            if let space = state.colorSpace, space !== shownColorSpace {
                shownColorSpace = space
                metal.colorspace = space
            }
            let shows = state.hasPicture && !playerDrawsSubtitles
            if metal.isHidden == shows { metal.isHidden = !shows }
        }
    }

    /// The part that runs off the main thread: takes the frame due, scales it, and shows it.
    @available(macOS 13.0, *)
    private final class UpscaleRenderer: @unchecked Sendable {
        struct State {
            /// A scaled-up frame of the movie being followed is in the layer.
            var hasPicture = false
            /// The colours the frames are in.
            var colorSpace: CGColorSpace?
            /// The last frame couldn't be drawn as things stood, and is to be asked for again.
            var wantsAnother = false
        }

        /// A picture this near its place's size is left as it is.
        private static let leastScale = 1.1

        private let device: MTLDevice
        private let commands: MTLCommandQueue
        private let layer: CAMetalLayer
        private let cache: CVMetalTextureCache
        private let queue = DispatchQueue(label: "firstrow.movie-upscaler", qos: .userInteractive)
        private let lock = NSLock()
        // Under the lock.
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
        private var missed = false

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
            let free = !isBusy
            if free, output != nil { isBusy = true }
            lock.unlock()
            guard free, let output else { return }
            queue.async {
                self.missed = false
                let result = self.draw(output, forHostTime: time, pixels: pixels)
                self.lock.lock()
                self.isBusy = false
                // (Not for a movie that has been let go of meanwhile.)
                if self.output === output {
                    if let result { self.shared = result }
                    self.shared.wantsAnother = self.missed
                }
                self.lock.unlock()
            }
        }

        /// Nil when there was nothing new to do.
        private func draw(_ output: AVPlayerItemVideoOutput, forHostTime time: CFTimeInterval, pixels: CGSize) -> State? {
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
            guard let frame else { return nil }
            lastPixels = pixels
            var result = State()
            result.colorSpace = CVImageBufferGetColorSpace(frame)?.takeUnretainedValue()
            // HDR is the player's to show: these frames are eight bits of it.
            if let transfer = CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil) as? String,
               transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            {
                return result
            }
            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            let wide = Int(pixels.width)
            let high = Int(pixels.height)
            guard width > 1, height > 1, min(Double(wide) / Double(width), Double(high) / Double(height)) >= Self.leastScale else { return result }
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
                  let drawable = layer.nextDrawable() else { return result }
            // (The layer is given its size on the main thread: a frame made for the size
            // before waits for the next.)
            guard drawable.texture.width == wide, drawable.texture.height == high, let buffer = commands.makeCommandBuffer() else {
                lastPixels = .zero
                missed = true
                return nil
            }
            scaler.colorTexture = picture
            scaler.outputTexture = scaled
            scaler.encode(commandBuffer: buffer)
            guard let copy = buffer.makeBlitCommandEncoder() else { return nil }
            copy.copy(from: scaled, to: drawable.texture)
            copy.endEncoding()
            buffer.present(drawable)
            // (The frame's texture is kept until it has been drawn from.)
            buffer.addCompletedHandler { _ in _ = held }
            buffer.commit()
            result.hasPicture = true
            return result
        }
    }
#endif

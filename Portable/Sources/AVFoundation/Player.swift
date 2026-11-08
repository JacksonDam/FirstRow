import CMPV
import CoreGraphics
import CPortable
import Foundation
import QuartzCore

public extension Notification.Name {
    static let AVPlayerItemDidPlayToEndTime = Notification.Name("AVPlayerItemDidPlayToEndTimeNotification")
    static let AVPlayerItemFailedToPlayToEndTime = Notification.Name("AVPlayerItemFailedToPlayToEndTimeNotification")
}

public final class AVPlayerItem: NSObject, @unchecked Sendable {
    public enum Status: Int {
        case unknown, readyToPlay, failed
    }

    public let asset: AVAsset
    public internal(set) var status: Status = .unknown
    weak var player: AVPlayer?
    var loadedDuration: Double?

    public init(url: URL) {
        asset = AVURLAsset(url: url)
    }

    public init(asset: AVAsset) {
        self.asset = asset
    }

    public var duration: CMTime {
        if let loadedDuration, loadedDuration > 0 { return CMTime(seconds: loadedDuration, preferredTimescale: 600) }
        if let known = asset.info.duration, known > 0 { return CMTime(seconds: known, preferredTimescale: 600) }
        return .indefinite
    }

    public func currentTime() -> CMTime {
        player?.currentTime() ?? .zero
    }

    public func seek(to time: CMTime, completionHandler: ((Bool) -> Void)? = nil) {
        player?.seek(to: time, completionHandler: completionHandler ?? { _ in })
    }
}

/// AVFoundation's player, playing through libmpv.
open class AVPlayer: NSObject, @unchecked Sendable {
    public enum TimeControlStatus: Int {
        case paused, waitingToPlayAtSpecifiedRate, playing
    }

    public enum ActionAtItemEnd: Int {
        case advance, pause, none
    }

    public private(set) var currentItem: AVPlayerItem?
    public var automaticallyWaitsToMinimizeStalling = true
    public var actionAtItemEnd: ActionAtItemEnd = .pause
    public var allowsExternalPlayback = false
    public var preventsDisplaySleepDuringVideoPlayback = true

    var core: MPVCore?
    private var wantsVideo = false
    private var pendingLoad = false
    private var playing = false
    private var lastTime: Double = 0
    private var timeObservers: [ObjectIdentifier: TimeObserver] = [:]

    public var volume: Float = 1 { didSet { core?.setProperty("volume", Double(volume) * 100) } }
    public var isMuted = false { didSet { core?.setFlag("mute", isMuted) } }

    public var rate: Float {
        get { playing ? 1 : 0 }
        set { newValue > 0 ? play() : pause() }
    }

    public var timeControlStatus: TimeControlStatus { playing ? .playing : .paused }

    override public init() {
        super.init()
    }

    public convenience init(url: URL) {
        self.init(playerItem: AVPlayerItem(url: url))
    }

    public init(playerItem: AVPlayerItem?) {
        super.init()
        replaceCurrentItem(with: playerItem)
    }

    deinit {
        MPVCore.debug("player released")
        core?.close()
    }

    public func replaceCurrentItem(with item: AVPlayerItem?) {
        currentItem?.player = nil
        currentItem = item
        item?.player = self
        lastTime = 0
        guard item != nil else {
            core?.command(["stop"])
            return
        }
        pendingLoad = true
        loadWaitStarted = CACurrentMediaTime()
        scheduleLoad()
    }

    /// Video needs a render context; asked for by AVPlayerLayer.
    func enableVideo() -> MPVCore? {
        MPVCore.debug("enableVideo")
        wantsVideo = true
        let core = ensureCore()
        if let core, core.renderContext == nil { _ = core.makeRenderContext() }
        if pendingLoad { scheduleLoad() }
        return core
    }

    /// Every player can show video, so a layer attached after creation still gets frames.
    private func ensureCore() -> MPVCore? {
        if let core { return core }
        guard let made = MPVCore(video: true) else { return nil }
        made.setProperty("volume", Double(volume) * 100)
        made.setFlag("mute", isMuted)
        made.setFlag("pause", !playing)
        made.onEvent = { [weak self] event in self?.handle(event) }
        if wantsVideo { _ = made.makeRenderContext() }
        core = made
        return made
    }

    private var loadWaitStarted: CFTimeInterval = 0
    private var loadScheduled = false

    private func scheduleLoad() {
        guard !loadScheduled else { return }
        loadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }
            self.loadScheduled = false
            self.loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        MPVCore.debug("loadIfNeeded pending \(pendingLoad) item \(currentItem != nil) render \(core?.renderContext != nil)")
        guard pendingLoad, let item = currentItem else { return }
        // A file with pictures waits a moment for its player layer, which is usually attached
        // in the same pass that created the player.
        let needsLayer = item.asset.info.hasVideo && core?.renderContext == nil
        if needsLayer, CACurrentMediaTime() - loadWaitStarted < 0.25 {
            scheduleLoad()
            return
        }
        guard let core = ensureCore() else { return }
        MPVCore.debug("loadfile \(item.asset.url.lastPathComponent) playing \(playing) render \(core.renderContext != nil)")
        pendingLoad = false
        core.setFlag("pause", !playing)
        let url = item.asset.url
        var options: [String] = []
        if lastTime > 0 { options.append("start=\(lastTime)") }
        if options.isEmpty {
            core.command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
        } else {
            core.command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace", "-1", options.joined(separator: ",")])
        }
    }

    private func handle(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            currentItem?.status = .readyToPlay
            currentItem?.loadedDuration = core?.double("duration")
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let name = data.name.map({ String(cString: $0) }), name == "eof-reached",
                  data.format == MPV_FORMAT_FLAG, let flag = data.data?.assumingMemoryBound(to: Int32.self).pointee, flag != 0
            else { return }
            playing = false
            core?.setFlag("pause", true)
            if let item = currentItem {
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            }
        case MPV_EVENT_END_FILE:
            if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee, data.reason == MPV_END_FILE_REASON_ERROR {
                currentItem?.status = .failed
                if let item = currentItem {
                    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
                }
            }
        default:
            break
        }
    }

    public func play() {
        MPVCore.debug("play()")
        playing = true
        let core = ensureCore()
        if playbackSpeed != 1 { core?.setProperty("speed", playbackSpeed) }
        core?.setFlag("pause", false)
        fireObservers()
    }

    /// How fast playback runs (1 is normal), kept across pauses. First Row's own addition:
    /// AVFoundation sets this through `rate` instead.
    public var playbackSpeed: Double = 1 {
        didSet { core?.setProperty("speed", playbackSpeed) }
    }

    /// The subtitle ("sub") or audio ("audio") tracks mpv found in the file.
    public func tracks(ofType type: String) -> [PlayerTrack] {
        guard let core, let count = core.int("track-list/count") else { return [] }
        var result: [PlayerTrack] = []
        for index in 0 ..< count where core.string("track-list/\(index)/type") == type {
            guard let id = core.int("track-list/\(index)/id") else { continue }
            let language = core.string("track-list/\(index)/lang") ?? ""
            let title = core.string("track-list/\(index)/title") ?? ""
            let name = PlayerTrack.languageName(language)
            let label = [name, title].filter { !$0.isEmpty }.joined(separator: " – ")
            result.append(PlayerTrack(id: id, title: label.isEmpty ? "Track \(result.count + 1)" : label, isSelected: core.flag("track-list/\(index)/selected") ?? false))
        }
        return result
    }

    /// Chooses a subtitle or audio track by its id, or none (subtitles off) for nil.
    public func selectTrack(ofType type: String, id: Int?) {
        let property = type == "sub" ? "sid" : "aid"
        core?.setProperty(property, id.map(String.init) ?? "no")
    }

    public func pause() {
        MPVCore.debug("pause()")
        playing = false
        core?.setFlag("pause", true)
        lastTime = currentTime().seconds.isFinite ? currentTime().seconds : lastTime
        fireObservers()
    }

    public func playImmediately(atRate rate: Float) {
        if rate > 0 { play() } else { pause() }
    }

    public func currentTime() -> CMTime {
        if let position = core?.double("time-pos"), position.isFinite {
            lastTime = position
        }
        return CMTime(seconds: lastTime, preferredTimescale: 600)
    }

    public func seek(to time: CMTime) {
        seek(to: time, toleranceBefore: .indefinite, toleranceAfter: .indefinite, completionHandler: { _ in })
    }

    public func seek(to time: CMTime, completionHandler: @escaping (Bool) -> Void) {
        seek(to: time, toleranceBefore: .indefinite, toleranceAfter: .indefinite, completionHandler: completionHandler)
    }

    public func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
        seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: { _ in })
    }

    public func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter _: CMTime, completionHandler: @escaping (Bool) -> Void) {
        let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
        lastTime = seconds
        let exact = toleranceBefore == .zero
        if !pendingLoad {
            core?.command(["seek", String(seconds), "absolute", exact ? "exact" : "keyframes"])
        }
        fireObservers()
        DispatchQueue.main.async { completionHandler(true) }
    }

    // MARK: Time observers

    final class TimeObserver {
        let interval: Double
        let block: (CMTime) -> Void
        var timer: Timer?

        init(interval: Double, block: @escaping (CMTime) -> Void) {
            self.interval = interval
            self.block = block
        }
    }

    public func addPeriodicTimeObserver(forInterval interval: CMTime, queue _: DispatchQueue?, using block: @escaping (CMTime) -> Void) -> Any {
        let observer = TimeObserver(interval: max(0.01, interval.seconds.isFinite ? interval.seconds : 0.5), block: block)
        let timer = Timer(timeInterval: observer.interval, repeats: true) { [weak self, weak observer] _ in
            guard let self, let observer, self.playing else { return }
            observer.block(self.currentTime())
        }
        RunLoop.main.add(timer, forMode: .common)
        observer.timer = timer
        timeObservers[ObjectIdentifier(observer)] = observer
        return observer
    }

    public func removeTimeObserver(_ observer: Any) {
        guard let observer = observer as? TimeObserver else { return }
        observer.timer?.invalidate()
        timeObservers.removeValue(forKey: ObjectIdentifier(observer))
    }

    private func fireObservers() {
        let time = currentTime()
        for observer in timeObservers.values { observer.block(time) }
    }

    /// Delivers mpv events for every player; the host calls this once a frame.
    public static func pumpEvents() {
        MPVCore.pumpAll()
        if debugLog {
            let now = Date()
            if now.timeIntervalSince(lastDebug) > 1 {
                lastDebug = now
                for core in MPVCore.live.values {
                    let position = core.double("time-pos") ?? -1
                    let paused = core.flag("pause") ?? false
                    let core_idle = core.flag("core-idle") ?? false
                    FileHandle.standardError.write(Data("[mpv] time-pos \(position) pause \(paused) core-idle \(core_idle) vo-configured \(core.flag("vo-configured") ?? false)\n".utf8))
                }
            }
        }
    }

    nonisolated(unsafe) private static var lastDebug = Date.distantPast
    private static let debugLog = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_MPV"] == "1"

    /// Where mpv's renderer finds OpenGL functions; set by the host.
    public static func setOpenGLLoader(_ loader: @escaping (String) -> UnsafeMutableRawPointer?) {
        MPVCore.procAddress = loader
    }
}

public final class AVQueuePlayer: AVPlayer, @unchecked Sendable {}

public struct AVLayerVideoGravity: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let resizeAspect = AVLayerVideoGravity(rawValue: "AVLayerVideoGravityResizeAspect")
    public static let resizeAspectFill = AVLayerVideoGravity(rawValue: "AVLayerVideoGravityResizeAspectFill")
    public static let resize = AVLayerVideoGravity(rawValue: "AVLayerVideoGravityResize")
}

/// The texture an mpv render context draws video frames into.
final class VideoSurface: ExternalTextureProviding {
    weak var player: AVPlayer?
    private var framebuffer: GLuint = 0
    private var texture: GLuint = 0
    private var size = (0, 0)
    private var hasFrame = false
    /// Where the software renderer draws, when mpv can't draw with OpenGL.
    private var pixels: UnsafeMutableRawPointer?
    private var stride = 0

    nonisolated(unsafe) static var all: [ObjectIdentifier: Weak] = [:]

    final class Weak {
        weak var surface: VideoSurface?
        init(_ surface: VideoSurface) { self.surface = surface }
    }

    init() {
        Self.all[ObjectIdentifier(self)] = Weak(self)
    }

    deinit {
        Self.all.removeValue(forKey: ObjectIdentifier(self))
        var fbo = framebuffer
        var tex = texture
        if fbo != 0 { glDeleteFramebuffers(1, &fbo) }
        if tex != 0 { glDeleteTextures(1, &tex) }
        pixels?.deallocate()
    }

    func currentTexture() -> ExternalTexture? {
        guard hasFrame, texture != 0 else { return nil }
        // With FLIP_Y off, mpv draws the picture's top row first, like an image.
        return ExternalTexture(id: texture, width: size.0, height: size.1, bottomUp: false)
    }

    /// Draws mpv's latest frame, if there is a new one.
    func update() {
        guard let player, let core = player.core, let context = core.renderContext else { return }
        let flags = mpv_render_context_update(context)
        let width = core.int("dwidth") ?? 0
        let height = core.int("dheight") ?? 0
        guard width > 0, height > 0 else { return }
        if size != (width, height) {
            resize(width, height)
        } else if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) == 0, hasFrame {
            return
        }
        if core.softwareRendering {
            renderInMemory(context, width, height)
            return
        }
        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: Int32(width), h: Int32(height), internal_format: 0)
        var flip: Int32 = 0
        // Never wait for the frame's display time: the interface draws on this thread too.
        var block: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                withUnsafeMutablePointer(to: &block) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(context, &params)
                }
            }
        }
        hasFrame = true
    }

    private func resize(_ width: Int, _ height: Int) {
        if texture == 0 { glGenTextures(1, &texture) }
        if framebuffer == 0 { glGenFramebuffers(1, &framebuffer) }
        glBindTexture(GL_TEXTURE_2D, texture)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
        size = (width, height)
        if player?.core?.softwareRendering == true {
            // The software renderer leaves the fourth byte undefined, so the picture is opaque.
            glTexParameteri(GL_TEXTURE_2D, GLenum(0x8E45), 1) // GL_TEXTURE_SWIZZLE_A, GL_ONE
            pixels?.deallocate()
            stride = (width * 4 + 63) & ~63
            pixels = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
        }
    }

    private func renderInMemory(_ context: OpaquePointer, _ width: Int, _ height: Int) {
        guard let pixels else { return }
        var surfaceSize: [Int32] = [Int32(width), Int32(height)]
        var rowBytes = stride
        let format = strdup("rgb0")
        defer { free(format) }
        surfaceSize.withUnsafeMutableBufferPointer { sizePointer in
            withUnsafeMutablePointer(to: &rowBytes) { stridePointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(context, &params)
            }
        }
        glBindTexture(GL_TEXTURE_2D, texture)
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
        glPixelStorei(GL_UNPACK_ROW_LENGTH, GLint(stride / 4))
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, GLsizei(width), GLsizei(height), GL_RGBA, GL_UNSIGNED_BYTE, pixels)
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)
        hasFrame = true
    }
}

/// Shows an AVPlayer's video.
open class AVPlayerLayer: CALayer {
    private let surface = VideoSurface()

    public var player: AVPlayer? {
        didSet {
            surface.player = player
            _ = player?.enableVideo()
            contents = player == nil ? nil : surface
        }
    }

    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            contentsGravity = switch videoGravity {
            case .resizeAspectFill: .resizeAspectFill
            case .resize: .resize
            default: .resizeAspect
            }
        }
    }

    public var isReadyForDisplay: Bool { surface.currentTexture() != nil }

    override public init() {
        super.init()
        contentsGravity = .resizeAspect
    }

    override public init(layer: Any) {
        super.init(layer: layer)
    }

    public convenience init(player: AVPlayer?) {
        self.init()
        self.player = player
        surface.player = player
        _ = player?.enableVideo()
        contents = player == nil ? nil : surface
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// True while some player layer shows a playing video, so frames keep coming.
    public static var hasActiveVideo: Bool {
        VideoSurface.all.values.contains { $0.surface?.player?.rate ?? 0 > 0 }
    }

    /// Draws new video frames into their textures. The host calls this before compositing.
    public static func renderVideoFrames() {
        for entry in VideoSurface.all.values {
            entry.surface?.update()
        }
    }
}

/// A subtitle or audio track in a file.
public struct PlayerTrack: Equatable {
    public let id: Int
    public let title: String
    public let isSelected: Bool

    /// "English" for "eng" or "en", or the code itself when it isn't known.
    static func languageName(_ code: String) -> String {
        let names = [
            "en": "English", "eng": "English", "fr": "French", "fre": "French", "fra": "French", "de": "German", "ger": "German",
            "deu": "German", "es": "Spanish", "spa": "Spanish", "it": "Italian", "ita": "Italian", "ja": "Japanese", "jpn": "Japanese",
            "ko": "Korean", "kor": "Korean", "zh": "Chinese", "chi": "Chinese", "zho": "Chinese", "pt": "Portuguese", "por": "Portuguese",
            "ru": "Russian", "rus": "Russian", "nl": "Dutch", "dut": "Dutch", "nld": "Dutch", "sv": "Swedish", "swe": "Swedish",
            "pl": "Polish", "pol": "Polish", "ar": "Arabic", "ara": "Arabic", "hi": "Hindi", "hin": "Hindi",
        ]
        return names[code.lowercased()] ?? code.uppercased()
    }
}

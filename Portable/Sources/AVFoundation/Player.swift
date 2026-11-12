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
    /// The file has reached its end, and mpv is playing out the last of its sound (or has).
    private var hasReachedEnd = false
    /// A place was asked for and mpv hasn't said it's there yet: until it does (or a second
    /// has gone by) the place asked for is where the player is.
    private var seekAskedAt: TimeInterval?
    /// What mpv had last said when the player was paused. The time counted on from that is
    /// where it stopped, until mpv says something else.
    private var reportedAtPause: Double?
    private var timeObservers: [ObjectIdentifier: TimeObserver] = [:]

    // Nothing here waits for mpv: what it's told is sent without waiting for it to be done
    // (it is done in the order sent), and what it knows is kept as it says (see MPVCore).

    public var volume: Float = 1 {
        didSet { core?.setPropertyWithoutWaiting("volume", Double(volume) * 100) }
    }

    public var isMuted = false {
        didSet { core?.setFlagWithoutWaiting("mute", isMuted) }
    }

    public var rate: Float {
        get { playing ? 1 : 0 }
        set { newValue > 0 ? play() : pause() }
    }

    /// Asked to play, the player is waiting while mpv has nothing to show: the file still
    /// opening, a jump to another place still being made, more of a stream still to come.
    public var timeControlStatus: TimeControlStatus {
        guard playing else { return .paused }
        if hasReachedEnd { return .playing }
        return core?.isCoreIdle ?? true ? .waitingToPlayAtSpecifiedRate : .playing
    }

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
            core?.commandWithoutWaiting(["stop"])
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
        guard let made = MPVCore.forPlayer() else { return nil }
        made.setPropertyWithoutWaiting("volume", Double(volume) * 100)
        made.setFlagWithoutWaiting("mute", isMuted)
        made.setFlagWithoutWaiting("pause", !playing)
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
        let url = item.asset.url
        let pair = AVPlayer.pairedStreams(in: url)
        let needsLayer = (item.asset.info.hasVideo || pair != nil) && core?.renderContext == nil
        if needsLayer, CACurrentMediaTime() - loadWaitStarted < 0.25 {
            scheduleLoad()
            return
        }
        guard let core = ensureCore() else { return }
        MPVCore.debug("loadfile \(item.asset.url.lastPathComponent) playing \(playing) render \(core.renderContext != nil)")
        pendingLoad = false
        hasReachedEnd = false
        seekAskedAt = nil
        core.setFlagWithoutWaiting("pause", !playing)
        core.noteLoading()
        var target = url.isFileURL ? url.path : url.absoluteString
        if let pair {
            // As mpv's own list of pieces to play together: each address with its length in
            // bytes before it, since addresses hold the characters such a list is cut at.
            func piece(_ address: String) -> String { "!no_clip;!no_chapters;%\(address.utf8.count)%\(address)" }
            target = "edl://" + piece(pair.video) + (pair.audio.map { ";!new_stream;" + piece($0) } ?? "")
        }
        var options: [String] = []
        if lastTime > 0 { options.append("start=\(lastTime)") }
        if options.isEmpty {
            core.commandWithoutWaiting(["loadfile", target, "replace"])
        } else {
            core.commandWithoutWaiting(["loadfile", target, "replace", "-1", options.joined(separator: ",")])
        }
    }

    /// An address that stands for a picture and its sound kept at two addresses (as a
    /// streamed video's often are), for a player item: mpv plays the two together.
    public static func pairedStreamsURL(video: URL, audio: URL?) -> URL? {
        var parts = URLComponents()
        parts.scheme = pairedStreamsScheme
        parts.host = "play"
        parts.queryItems = [URLQueryItem(name: "video", value: video.absoluteString)] + (audio.map { [URLQueryItem(name: "audio", value: $0.absoluteString)] } ?? [])
        return parts.url
    }

    private static let pairedStreamsScheme = "firstrow-streams"

    static func pairedStreams(in url: URL) -> (video: String, audio: String?)? {
        guard url.scheme == pairedStreamsScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let video = items.first(where: { $0.name == "video" })?.value
        else { return nil }
        return (video, items.first { $0.name == "audio" }?.value)
    }

    private func handle(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            currentItem?.status = .readyToPlay
            if let duration = core?.reportedDuration { currentItem?.loadedDuration = duration }
        case MPV_EVENT_PLAYBACK_RESTART:
            // (Playing again from the place asked for, or from the start.)
            seekAskedAt = nil
        case MPV_EVENT_PROPERTY_CHANGE:
            if event.pointee.reply_userdata == MPVCore.durationID {
                // The file's length, which mpv may say before or after it says it's loaded.
                if let duration = core?.reportedDuration, currentItem?.status == .readyToPlay { currentItem?.loadedDuration = duration }
                return
            }
            guard event.pointee.reply_userdata == MPVCore.endOfFileID else { return }
            guard let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let name = data.name.map({ String(cString: $0) }), name == "eof-reached",
                  data.format == MPV_FORMAT_FLAG, let flag = data.data?.assumingMemoryBound(to: Int32.self).pointee, flag != 0
            else { return }
            playing = false
            hasReachedEnd = true
            // mpv is playing out the last of the sound, and answers nothing until it has (up
            // to half a second, which the main thread used to spend waiting for this pause).
            // So the pause isn't waited for, and its answer, which comes when the sound has
            // been heard out, is what says the file has played to its end.
            if core?.setFlagWithoutWaiting("pause", true, reply: Self.endReply) != true {
                tellOfEnd()
            }
        case MPV_EVENT_SET_PROPERTY_REPLY:
            guard event.pointee.reply_userdata == Self.endReply, hasReachedEnd else { return }
            tellOfEnd()
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

    /// Marks mpv's answer to the pause sent at a file's end.
    private static let endReply: UInt64 = 0x656E64

    private func tellOfEnd() {
        if let item = currentItem {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
    }

    public func play() {
        MPVCore.debug("play()")
        playing = true
        hasReachedEnd = false
        let core = ensureCore()
        if playbackSpeed != 1 { core?.setPropertyWithoutWaiting("speed", playbackSpeed) }
        if normalizesLoudness { core?.setPropertyWithoutWaiting("af", "lavfi=[loudnorm=I=-16:TP=-1.5:LRA=11]") }
        core?.setFlagWithoutWaiting("pause", false)
        fireObservers()
    }

    /// How fast playback runs (1 is normal), kept across pauses. First Row's own addition:
    /// AVFoundation sets this through `rate` instead.
    public var playbackSpeed: Double = 1 {
        didSet { core?.setPropertyWithoutWaiting("speed", playbackSpeed) }
    }

    /// Levels the sound to about -16 LUFS as it plays (for previews mastered louder than the
    /// library). First Row's own addition; Apple's players are given a measured volume instead.
    public var normalizesLoudness = false

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
        core?.setPropertyWithoutWaiting(property, id.map(String.init) ?? "no")
    }

    /// The file's chapters: what each is called (nothing, for one with no name) and where it
    /// starts, in seconds.
    public func chapterList() -> [(title: String, start: Double)] {
        guard let core, let count = core.int("chapter-list/count"), count > 0 else { return [] }
        return (0 ..< count).compactMap { index in
            guard let start = core.double("chapter-list/\(index)/time") else { return nil }
            return (core.string("chapter-list/\(index)/title") ?? "", max(0, start))
        }
    }

    public func pause() {
        MPVCore.debug("pause()")
        // (Where it has got to, read while it still counts as playing.)
        _ = currentTime()
        reportedAtPause = core?.reportedTime
        playing = false
        // (At its file's end it has stopped by itself.)
        guard !hasReachedEnd else { return }
        core?.setFlagWithoutWaiting("pause", true)
        fireObservers()
    }

    public func playImmediately(atRate rate: Float) {
        if rate > 0 { play() } else { pause() }
    }

    /// Where playback is: where mpv last said it was, counted on from then while it plays
    /// (mpv says a few times to sixty times a second, with the picture's frames).
    public func currentTime() -> CMTime {
        let now = ProcessInfo.processInfo.systemUptime
        if let asked = seekAskedAt, now - asked > 1 { seekAskedAt = nil }
        if !hasReachedEnd, seekAskedAt == nil, let core, let reported = core.reportedTime, reported.isFinite,
           playing || reported != reportedAtPause
        {
            var position = reported
            if playing, !core.isCoreIdle {
                position += min(0.5, max(0, now - core.reportedTimeAt)) * playbackSpeed
            }
            if let duration = core.reportedDuration, duration > 0 { position = min(position, duration) }
            lastTime = max(0, position)
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
        hasReachedEnd = false
        let exact = toleranceBefore == .zero
        if !pendingLoad, let core {
            core.commandWithoutWaiting(["seek", String(seconds), "absolute", exact ? "exact" : "keyframes"])
            seekAskedAt = ProcessInfo.processInfo.systemUptime
            reportedAtPause = nil
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

    /// Delivers mpv events for every player; the host calls this once a frame, saying whether
    /// anything on screen is moving (players that have been let go of are cleared away when
    /// nothing is).
    public static func pumpEvents(interfaceIsMoving: Bool = false) {
        MPVCore.pumpAll(interfaceIsMoving: interfaceIsMoving)
        if debugLog {
            let now = Date()
            if now.timeIntervalSince(lastDebug) > 1 {
                lastDebug = now
                for core in MPVCore.live.values {
                    // (What mpv has said: asking it here would hold the main thread up, which is what's being looked for.)
                    FileHandle.standardError.write(Data("[mpv] time-pos \(core.reportedTime ?? -1) core-idle \(core.isCoreIdle) idle \(core.isIdle) picture \(core.videoWidth)x\(core.videoHeight)\n".utf8))
                }
            }
        }
    }

    nonisolated(unsafe) private static var lastDebug = Date.distantPast
    private static let debugLog = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_MPV"] == "1"

    /// Where mpv's renderer finds OpenGL functions; set by the host.
    public static func setOpenGLLoader(_ loader: @escaping (String) -> UnsafeMutableRawPointer?) {
        MPVCore.procAddress = loader
        MPVCore.prepareSpare()
    }

    /// Starts making the first player's core, off the main thread. Called as First Row
    /// starts, so that it's being made while the window and OpenGL are: the intro movie
    /// wants it the moment the interface is up.
    public static func prepareFirstPlayer() {
        MPVCore.prepareSpare()
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
    weak var player: AVPlayer? {
        didSet {
            // The texture still holds the last picture drawn into it, which was another
            // player's: nothing is shown until this one has drawn. (The movie screen keeps one
            // layer, so a movie used to open on the last frame of the movie before.)
            if player !== oldValue { hasFrame = false }
        }
    }

    private var framebuffer: GLuint = 0
    private var texture: GLuint = 0
    private var size = (0, 0)
    private var hasFrame = false
    /// A few pixels for a frame drawn before its size is known (see `drawUnseen`).
    private var unseenFramebuffer: GLuint = 0
    private var unseenTexture: GLuint = 0
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
        if unseenFramebuffer != 0 { glDeleteFramebuffers(1, &unseenFramebuffer) }
        if unseenTexture != 0 { glDeleteTextures(1, &unseenTexture) }
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
        let hasNewFrame = flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        if hasNewFrame { core.hasVideoFrame = true }
        let width = core.videoWidth
        let height = core.videoHeight
        // (Before mpv has a frame of its file there is nothing of it to draw: only black.)
        guard core.hasVideoFrame else { return }
        guard width > 0, height > 0 else {
            if hasNewFrame { drawUnseen(context, inMemory: core.softwareRendering) }
            return
        }
        if size != (width, height) {
            resize(width, height)
        } else if !hasNewFrame, hasFrame {
            return
        }
        if core.softwareRendering {
            renderInMemory(context, width, height)
            return
        }
        draw(context, into: framebuffer, width: width, height: height)
        hasFrame = true
    }

    /// Lets mpv go on from the first frame of a file whose picture size isn't known yet. Its
    /// core does nothing more until that frame has been drawn, telling the size included,
    /// and gives up waiting after a fifth of a second: every movie began that much late. So
    /// the frame is drawn into a few pixels that are never shown. The size comes within a
    /// pass or two of the main loop, and the frame is drawn properly then.
    private func drawUnseen(_ context: OpaquePointer, inMemory: Bool) {
        let side = 16
        if inMemory {
            var rowBytes = 64
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * side, alignment: 64)
            defer { scratch.deallocate() }
            var surfaceSize: [Int32] = [Int32(side), Int32(side)]
            let format = strdup("rgb0")
            defer { free(format) }
            surfaceSize.withUnsafeMutableBufferPointer { sizePointer in
                withUnsafeMutablePointer(to: &rowBytes) { stridePointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: scratch),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(context, &params)
                }
            }
            return
        }
        if unseenTexture == 0 {
            glGenTextures(1, &unseenTexture)
            glGenFramebuffers(1, &unseenFramebuffer)
            glBindTexture(GL_TEXTURE_2D, unseenTexture)
            glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(side), GLsizei(side), 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_LINEAR))
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_LINEAR))
            glBindFramebuffer(GL_FRAMEBUFFER, unseenFramebuffer)
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, unseenTexture, 0)
        }
        draw(context, into: unseenFramebuffer, width: side, height: side)
    }

    /// Has mpv draw its current frame into a framebuffer.
    private func draw(_ context: OpaquePointer, into target: GLuint, width: Int, height: Int) {
        var fbo = mpv_opengl_fbo(fbo: Int32(target), w: Int32(width), h: Int32(height), internal_format: 0)
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

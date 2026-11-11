import CMPV
import CoreGraphics
import CPortable
import Foundation

/// One libmpv instance. A player's calls happen on the main thread; events are pumped once a frame.
final class MPVCore {
    let handle: OpaquePointer
    var onEvent: ((UnsafeMutablePointer<mpv_event>) -> Void)?
    private(set) var renderContext: OpaquePointer?
    /// The players' cores, whose events are delivered each frame (main thread only).
    nonisolated(unsafe) static var live: [ObjectIdentifier: MPVCore] = [:]
    private var isRegistered = false

    /// Whether mpv has said it has events waiting. mpv says so on a thread of its own, and
    /// may go on saying so while the core is being closed down, so this is kept apart from
    /// the core and handed to mpv with a reference of its own.
    private final class Wakeup: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = true

        func set() {
            lock.lock()
            isSet = true
            lock.unlock()
        }

        /// Whether it was set; it's cleared.
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let was = isSet
            isSet = false
            return was
        }
    }

    private let wakeup = Wakeup()
    private var wakeupReference: Unmanaged<Wakeup>?

    // MARK: A core made ahead

    private static let spareLock = NSLock()
    nonisolated(unsafe) private static var spare: MPVCore?
    nonisolated(unsafe) private static var isMakingSpare = false

    /// A core for a player: the one made ahead if it's ready (another is started for next
    /// time), or a new one. Making a core takes milliseconds (mpv starts its threads and
    /// sets itself up), and one is wanted the moment a song or a movie starts, which is the
    /// moment its screen starts to come in.
    static func forPlayer() -> MPVCore? {
        spareLock.lock()
        let ready = spare
        spare = nil
        spareLock.unlock()
        let core = ready ?? MPVCore(video: true)
        core?.register()
        prepareSpare()
        return core
    }

    /// Makes the next player's core now, off the main thread.
    static func prepareSpare() {
        spareLock.lock()
        let needed = spare == nil && !isMakingSpare
        if needed { isMakingSpare = true }
        spareLock.unlock()
        guard needed else { return }
        DispatchQueue.global(qos: .utility).async {
            let made = MPVCore(video: true)
            spareLock.lock()
            spare = made
            isMakingSpare = false
            spareLock.unlock()
        }
    }

    /// Runs mpv with no audio output, for tests and headless runs.
    static var silent: Bool { ProcessInfo.processInfo.environment["FIRSTROW_NO_AUDIO"] == "1" }

    init?(video: Bool) {
        guard let handle = mpv_create() else { return nil }
        self.handle = handle
        set("vo", video ? "libmpv" : "null")
        if !video { set("vid", "no") }
        set("keep-open", "yes")
        set("idle", "yes")
        set("terminal", "no")
        set("input-default-bindings", "no")
        set("input-vo-keyboard", "no")
        set("osc", "no")
        set("hwdec", "no")
        // Frames are drawn at their own size and scaled by the compositor, like AVPlayerLayer,
        // so mpv's expensive scalers would only cost time.
        set("profile", "fast")
        set("audio-client-name", "First Row")
        set("msg-level", "all=error")
        set("ytdl", "no")
        // Cover art in audio files is not a video to show.
        set("audio-display", "no")
        if Self.silent { set("ao", "null") }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return nil
        }
        observe("eof-reached", MPV_FORMAT_FLAG, id: 1)
        if Self.debugEnabled { mpv_request_log_messages(handle, "v") }
        // mpv says when it has events, so that it's asked for them only then: asking takes
        // a lock inside mpv and a wait on it, which every pass of the main loop was paying
        // for every player.
        let reference = Unmanaged.passRetained(wakeup)
        wakeupReference = reference
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<Wakeup>.fromOpaque(context).takeUnretainedValue().set()
        }, reference.toOpaque())
        Self.debug("core created (video \(video))")
    }

    /// Takes its place among the players' cores (on the main thread).
    func register() {
        isRegistered = true
        Self.live[ObjectIdentifier(self)] = self
    }

    static let debugEnabled = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_MPV"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[mpv] \(stamp) \(message())\n".utf8))
    }

    /// Whether `close` has handed mpv over to be shut down.
    private var isShutDown = false

    deinit {
        guard !isShutDown else { return }
        if let renderContext { mpv_render_context_free(renderContext) }
        mpv_terminate_destroy(handle)
        // (mpv is gone, and with it the last thing that could call on this.)
        wakeupReference?.release()
    }

    /// The player is done with it (on the main thread). mpv is shut down on another thread:
    /// that waits for mpv's own threads to finish, and at a song's end mpv is still playing
    /// out the sound it holds, for up to half a second.
    func close() {
        Self.debug("core closed")
        if isRegistered {
            isRegistered = false
            Self.live.removeValue(forKey: ObjectIdentifier(self))
        }
        guard !isShutDown else { return }
        isShutDown = true
        // (The renderer goes here, where OpenGL is.)
        if let renderContext { mpv_render_context_free(renderContext) }
        renderContext = nil
        let handle = handle
        let reference = wakeupReference
        wakeupReference = nil
        DispatchQueue.global(qos: .utility).async {
            mpv_terminate_destroy(handle)
            // (mpv is gone, and with it the last thing that could call on this.)
            reference?.release()
        }
    }

    @discardableResult
    func set(_ option: String, _ value: String) -> Bool {
        mpv_set_option_string(handle, option, value) >= 0
    }

    func setProperty(_ name: String, _ value: String) {
        mpv_set_property_string(handle, name, value)
    }

    func setProperty(_ name: String, _ value: Double) {
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    func setFlag(_ name: String, _ value: Bool) {
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    /// Sets a flag without waiting for mpv to have done it: for when mpv may be busy (at a
    /// file's end it plays out the sound it holds before it answers anything).
    /// (mpv's answer comes later as an event carrying `reply`. False if it couldn't be sent.)
    @discardableResult
    func setFlagWithoutWaiting(_ name: String, _ value: Bool, reply: UInt64 = 0) -> Bool {
        var v: Int32 = value ? 1 : 0
        return mpv_set_property_async(handle, reply, name, MPV_FORMAT_FLAG, &v) >= 0
    }

    func setPropertyWithoutWaiting(_ name: String, _ value: Double) {
        var v = value
        mpv_set_property_async(handle, 0, name, MPV_FORMAT_DOUBLE, &v)
    }

    func double(_ name: String) -> Double? {
        var v = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func int(_ name: String) -> Int? {
        var v: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &v) >= 0 ? Int(v) : nil
    }

    func string(_ name: String) -> String? {
        guard let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    func flag(_ name: String) -> Bool? {
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
    }

    func observe(_ name: String, _ format: mpv_format, id: UInt64) {
        mpv_observe_property(handle, id, name, format)
    }

    func command(_ args: [String]) {
        var cStrings = args.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                _ = mpv_command(handle, pointer)
            }
        }
    }

    /// Delivers queued events to `onEvent`.
    func pump() {
        // Nothing new since they were last collected.
        guard wakeup.take() else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            if event.pointee.event_id == MPV_EVENT_NONE { return }
            if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE {
                if let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    Self.debug("log \(String(cString: message.prefix)): \(String(cString: message.text).trimmingCharacters(in: .newlines))")
                }
                continue
            }
            Self.debug("event \(String(cString: mpv_event_name(event.pointee.event_id)))")
            onEvent?(event)
        }
    }

    static func pumpAll() {
        for core in live.values { core.pump() }
    }

    // MARK: Video

    nonisolated(unsafe) static var procAddress: ((String) -> UnsafeMutableRawPointer?)?

    /// Set when frames are drawn into memory because this libmpv has no OpenGL renderer
    /// (the Windows on Arm builds, for one).
    private(set) var softwareRendering = false

    /// Creates the render context that draws frames into our textures. Needs a current GL context.
    func makeRenderContext() -> OpaquePointer? {
        if let renderContext { return renderContext }
        guard Self.procAddress != nil else { return nil }
        var status = makeOpenGLContext()
        if renderContext == nil {
            Self.debug("OpenGL render context failed: \(String(cString: mpv_error_string(status)))")
            status = makeSoftwareContext()
            softwareRendering = renderContext != nil
        }
        Self.debug("render context \(renderContext == nil ? "failed: \(String(cString: mpv_error_string(status)))" : softwareRendering ? "made (software)" : "made")")
        return renderContext
    }

    private func makeOpenGLContext() -> Int32 {
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                return MPVCore.procAddress?(String(cString: name))
            },
            get_proc_address_ctx: nil,
        )
        var context: OpaquePointer?
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        var advanced: Int32 = 0
        var status: Int32 = 0
        withUnsafeMutablePointer(to: &initParams) { initPointer in
            withUnsafeMutablePointer(to: &advanced) { advancedPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advancedPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                status = mpv_render_context_create(&context, handle, &params)
            }
        }
        renderContext = context
        return status
    }

    private func makeSoftwareContext() -> Int32 {
        var context: OpaquePointer?
        let apiType = strdup(MPV_RENDER_API_TYPE_SW)
        defer { free(apiType) }
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        let status = mpv_render_context_create(&context, handle, &params)
        renderContext = context
        return status
    }
}

/// A one-off mpv used to read a file's length or grab a frame.
enum MediaProbe {
    static func duration(of url: URL) -> Double? {
        guard let core = MPVCore(video: false) else { return nil }
        defer { core.close() }
        core.set("ao", "null")
        core.setFlag("pause", true)
        core.command(["loadfile", url.path])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let event = mpv_wait_event(core.handle, 0.25) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED: return core.double("duration")
            case MPV_EVENT_END_FILE: return nil
            default: continue
            }
        }
        return nil
    }

    /// A frame of a video, decoded in software and read back with mpv's screenshot command.
    static func frame(of url: URL, at seconds: Double, maximumSize: CGSize) -> CGImage? {
        guard let handle = mpv_create() else { return nil }
        defer { mpv_terminate_destroy(handle) }
        for (option, value) in [("vo", "null"), ("ao", "null"), ("terminal", "no"), ("hwdec", "no"), ("msg-level", "all=error"), ("pause", "yes"), ("start", String(format: "%.3f", max(0, seconds)))] {
            mpv_set_option_string(handle, option, value)
        }
        guard mpv_initialize(handle) >= 0 else { return nil }
        var args: [UnsafeMutablePointer<CChar>?] = [strdup("loadfile"), strdup(url.path), nil]
        defer { args.forEach { free($0) } }
        args.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { _ = mpv_command(handle, $0) }
        }
        let deadline = Date().addingTimeInterval(8)
        var loaded = false
        while Date() < deadline, !loaded {
            guard let event = mpv_wait_event(handle, 0.25) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_PLAYBACK_RESTART: loaded = true
            case MPV_EVENT_END_FILE: return nil
            default: continue
            }
        }
        guard loaded else { return nil }
        var node = mpv_node()
        var shot: [UnsafeMutablePointer<CChar>?] = [strdup("screenshot-raw"), strdup("video"), nil]
        defer { shot.forEach { free($0) } }
        let status = shot.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { mpv_command_ret(handle, $0, &node) }
        }
        guard status >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        return image(from: node, maximumSize: maximumSize)
    }

    private static func image(from node: mpv_node, maximumSize: CGSize) -> CGImage? {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee else { return nil }
        var width = 0, height = 0, stride = 0
        var format = ""
        var bytes: UnsafeRawPointer?
        for index in 0 ..< Int(list.num) {
            guard let key = list.keys?[index].map({ String(cString: $0) }), let value = list.values?[index] else { continue }
            switch key {
            case "w": width = Int(value.u.int64)
            case "h": height = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "format": format = value.u.string.map { String(cString: $0) } ?? ""
            case "data": bytes = value.u.ba.map { UnsafeRawPointer($0.pointee.data) } ?? nil
            default: break
            }
        }
        guard width > 0, height > 0, stride > 0, let bytes, format == "bgr0" || format == "bgra" else { return nil }
        let storage = PixelStorage(copying: bytes.assumingMemoryBound(to: UInt8.self), width: width, height: height, bytesPerRow: stride)
        if format == "bgr0" {
            for i in 0 ..< width * height { storage.bytes[i * 4 + 3] = 255 }
        }
        let image = CGImage(storage: storage, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), alphaInfo: .premultipliedFirst)
        if maximumSize.width > 0, maximumSize.height > 0, CGFloat(width) > maximumSize.width || CGFloat(height) > maximumSize.height {
            let scale = min(maximumSize.width / CGFloat(width), maximumSize.height / CGFloat(height))
            return image.resized(width: max(1, Int(CGFloat(width) * scale)), height: max(1, Int(CGFloat(height) * scale)))
        }
        return image
    }
}

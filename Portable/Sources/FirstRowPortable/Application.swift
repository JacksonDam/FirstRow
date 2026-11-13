import AVFoundation
import CPortable
import CSDL3
import Foundation
import QuartzCore
#if os(Windows)
    import WinSDK
#endif

/// Keys First Row reacts to.
public enum PortableKey: Sendable {
    case up, down, left, right, enter, escape, delete, space
    case other(UInt32)
}

public struct PortableModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = PortableModifiers(rawValue: 1)
    public static let alt = PortableModifiers(rawValue: 2)
    public static let shift = PortableModifiers(rawValue: 4)
    public static let meta = PortableModifiers(rawValue: 8)
}

public enum GamepadButton: Sendable {
    case up, down, left, right, south, east, west, north, start, back
}

public enum PortablePointerButton: Sendable {
    case primary, secondary, middle, back, forward
}

/// What the window shows and where its input goes.
@MainActor
public protocol PortableHost: AnyObject {
    /// The layer tree drawn into the window, origin at the bottom left like a Mac view's.
    var rootLayer: CALayer { get }
    func layout(size: CGSize, scale: CGFloat)
    func keyDown(_ key: PortableKey, isRepeat: Bool, modifiers: PortableModifiers, character: String?)
    func keyUp(_ key: PortableKey)
    func gamepad(_ button: GamepadButton, pressed: Bool)
    /// The window was asked to close; return false to handle it (for a fade out) yourself.
    func shouldQuitImmediately() -> Bool
    /// The mouse moved, in window points from the top left.
    func pointerMoved(to point: CGPoint)
    func pointerButton(_ button: PortablePointerButton, pressed: Bool, at point: CGPoint)
    /// Wheel notches (fractions from trackpads); positive `dy` scrolls towards the top.
    func pointerScrolled(dx: CGFloat, dy: CGFloat, at point: CGPoint)
    /// Text typed while text input is on (see `PortableApplication.setTextInputActive`).
    func textInput(_ text: String)
}

public extension PortableHost {
    func pointerMoved(to _: CGPoint) {}
    func pointerButton(_: PortablePointerButton, pressed _: Bool, at _: CGPoint) {}
    func pointerScrolled(dx _: CGFloat, dy _: CGFloat, at _: CGPoint) {}
    func textInput(_: String) {}
}

/// Work to run once per pass of the main loop, after input, timers and tasks and before any
/// layer changes are committed and drawn: what a run-loop observer does on the Mac.
@MainActor
public enum FrameObservers {
    private static var observers: [Int: () -> Void] = [:]
    private static var nextID = 0

    public static func add(_ body: @escaping () -> Void) -> Int {
        nextID += 1
        observers[nextID] = body
        return nextID
    }

    public static func remove(_ id: Int) {
        observers.removeValue(forKey: id)
    }

    static func run() {
        for id in observers.keys.sorted() {
            observers[id]?()
        }
    }
}

/// SDL's window flags, which are macros Swift can't import.
private enum WindowFlag {
    static let fullscreen: SDL_WindowFlags = 0x1
    static let opengl: SDL_WindowFlags = 0x2
    static let resizable: SDL_WindowFlags = 0x20
    static let highPixelDensity: SDL_WindowFlags = 0x2000
}

/// Opens the window and runs First Row until it quits.
/// Whether a setting has changed since the settings were last saved (set from whichever
/// thread changed it).
private final class SettingsChanged: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    func set() {
        lock.lock()
        changed = true
        lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = changed
        changed = false
        return was
    }
}

@MainActor
public enum PortableApplication {
    private static var window: OpaquePointer?
    private static var glContext: SDL_GLContext?
    private static var compositor: Compositor?
    private static var host: PortableHost?
    private static var needsFrame = true
    private static var running = true
    private static var gamepads: [SDL_JoystickID: OpaquePointer] = [:]
    private static var offscreen: (framebuffer: GLuint, texture: GLuint, width: Int, height: Int)?
    private static var lastLayout: (CGSize, CGFloat)?
    private static var isHeadless = false
    static var forcedScale: CGFloat? {
        ProcessInfo.processInfo.environment["FIRSTROW_SCALE"].flatMap { Double($0) }.map { CGFloat($0) }
    }

    /// The SDL window, for dialogs that sit over it.
    static var windowHandle: OpaquePointer? { window }

    public static func hideCursorIfFullscreen() {
        if let window, SDL_GetWindowFlags(window) & WindowFlag.fullscreen != 0 { SDL_HideCursor() }
    }

    /// Turns typed text events on while something on screen takes typing.
    public static func setTextInputActive(_ active: Bool) {
        guard let window else { return }
        _ = active ? SDL_StartTextInput(window) : SDL_StopTextInput(window)
    }

    /// Ends the main loop after the current frame.
    public static func quit() {
        running = false
    }

    /// Has a frame drawn on the next pass of the loop even if no layer has changed, for what
    /// moves a frame at a time.
    public static func requestFrame() {
        needsFrame = true
    }

    /// Run once the main loop has ended, before the window closes and First Row exits.
    public static var quitHandlers: [@MainActor () -> Void] = []

    /// Set by the marker the loop puts on the main queue each pass (see `run`).
    nonisolated(unsafe) private static var pumpMarkerRan = false

    // MARK: - Waits the loop keeps

    private static var waits: [Int: (due: CFTimeInterval, continuation: CheckedContinuation<Void, Never>)] = [:]
    private static var waitCount = 0

    /// Waits until `due` on the animation clock (`CACurrentMediaTime`), to within a frame
    /// while frames are being drawn and a millisecond otherwise, or until the task waiting is
    /// cancelled. For steps that follow one another in time, like a held arrow's through a
    /// list: a Task's own sleep can't keep time on Windows, where it only ends on one of the
    /// system clock's 64 ticks a second (asked for 33 ms it takes 47), which made those
    /// steps uneven.
    public static func wait(until due: CFTimeInterval) async {
        guard due > CACurrentMediaTime(), !Task.isCancelled else { return }
        waitCount += 1
        let id = waitCount
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waits[id] = (due, continuation)
            }
        } onCancel: {
            Task { @MainActor in endWait(id) }
        }
    }

    /// A pause of `seconds` kept by the main loop, from any thread; thrown out of when the
    /// task is cancelled, as `Task.sleep` is.
    public nonisolated static func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        await wait(until: CACurrentMediaTime() + max(0, seconds))
        try Task.checkCancellation()
    }

    private static func endWait(_ id: Int) {
        waits.removeValue(forKey: id)?.continuation.resume()
    }

    private static func endDueWaits() {
        guard !waits.isEmpty else { return }
        let now = CACurrentMediaTime()
        for id in waits.filter({ $0.value.due <= now }).keys.sorted() {
            endWait(id)
        }
    }

    /// How long until the first of those waits is over, rounded down: under a millisecond
    /// the loop goes round again rather than sleep past it.
    private static var millisecondsToNextWait: Int32? {
        guard let next = waits.values.map(\.due).min() else { return nil }
        return Int32(max(0, min(1000, (next - CACurrentMediaTime()) * 1000)))
    }

    public static func run(makeHost: () -> PortableHost) -> Never {
        setlocale(LC_ALL, "C")
        // (Before the first thread is started: see the function.)
        fr_tune_allocator()
        AssetCatalog.decodeAhead()
        AVPlayer.prepareFirstPlayer()
        // Inter, which ships with First Row, stands in for the Apple system font of the modern
        // look. Its folder is named here, before the fonts are looked for.
        if let fonts = AppResources.url("Fonts") {
            FontRegistry.extraDirectories.append(fonts)
        }
        FontRegistry.findAhead()
        let environment = ProcessInfo.processInfo.environment
        let headless = environment["SDL_VIDEO_DRIVER"] == "offscreen"
        isHeadless = headless
        #if os(Windows)
            // Windows' timer ticks 64 times a second unless asked for more, and a wait ends
            // only on a tick: the loop's 8 ms waits took 16. This asks for a tick every
            // millisecond while First Row runs.
            timeBeginPeriod(1)
        #endif
        // Swift provides main itself, so SDL's own entry point never ran.
        SDL_SetMainReady()
        WindowIcon.nameApp()
        guard SDL_Init(UInt32(SDL_INIT_VIDEO) | UInt32(SDL_INIT_GAMEPAD) | UInt32(SDL_INIT_EVENTS)) else {
            fail("SDL could not start: \(String(cString: SDL_GetError()))")
        }
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3)
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, Int32(SDL_GL_CONTEXT_PROFILE_CORE))
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1)
        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8)

        let size = windowSize(environment)
        let windowed = environment["FIRSTROW_WINDOWED"] == "1" || CommandLine.arguments.contains("--windowed") || headless
        var flags: SDL_WindowFlags = WindowFlag.opengl | WindowFlag.highPixelDensity | WindowFlag.resizable
        if !windowed { flags |= WindowFlag.fullscreen }
        guard let created = SDL_CreateWindow("First Row", Int32(size.width), Int32(size.height), flags) else {
            fail("The window could not be created: \(String(cString: SDL_GetError()))")
        }
        window = created
        if !headless { WindowIcon.apply(to: created) }
        guard let context = SDL_GL_CreateContext(created) else {
            fail("OpenGL 3.3 is needed: \(String(cString: SDL_GetError()))")
        }
        glContext = context
        SDL_GL_MakeCurrent(created, context)
        SDL_GL_SetSwapInterval(1)
        let loader: (String) -> UnsafeMutableRawPointer? = { name in
            SDL_GL_GetProcAddress(name).map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
        }
        do {
            compositor = try Compositor(loader: loader)
        } catch {
            fail("The renderer could not start: \(error)")
        }
        AVPlayer.setOpenGLLoader(loader)
        if !windowed { SDL_HideCursor() }
        CATransaction.onChange = { needsFrame = true }

        let host = makeHost()
        self.host = host
        Harness.start()
        relayout()

        var event = SDL_Event()
        var lastFrame = CACurrentMediaTime()
        // Here (unlike on Apple's systems) settings only reach the disk when told to: every few
        // seconds, so a crash or a forced quit loses little, and again on the way out.
        var lastSettingsSave = lastFrame
        var lastPictureSweep = lastFrame
        // (Only when a setting has changed: a setting read on the main thread while they're
        // being saved waits for the save, tens of milliseconds on Windows.)
        let settingsChanged = SettingsChanged()
        let settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            settingsChanged.set()
        }
        defer { NotificationCenter.default.removeObserver(settingsObserver) }
        while running {
            // Sleep until something happens when nothing on screen is moving.
            let quiet = !needsFrame && !(compositor?.isAnimating ?? false)
            if quiet, let wait = Harness.idleWait(limit: pendingPointerMove == nil ? 8 : 2) {
                // (Not past the next wait the loop keeps, below.)
                let bounded = min(wait, millisecondsToNextWait ?? wait)
                if bounded > 0, SDL_WaitEventTimeout(&event, bounded) { handle(event) }
            }
            let loopStart = CACurrentMediaTime()
            while SDL_PollEvent(&event) { handle(event) }
            endDueWaits()
            let polled = CACurrentMediaTime()
            // Timers, dispatched blocks and main-actor tasks. Each turn of the run loop services
            // one kind of thing (the timers that are due, or the main queue with everything on
            // it, or one other source), and a due timer can hide the main queue. So a marker
            // goes on the main queue and the run loop is turned until it has run, by when
            // everything queued before it has too, and at least twice, so that timers get
            // their turn as well: two turns as a rule. (It was eight every pass, which on
            // Windows, where a turn makes two system calls, was most of what the main thread
            // did for a frame.) The deadline is in the past: on Windows a deadline of now
            // still waits for the next 16 ms timer tick.
            pumpMarkerRan = false
            DispatchQueue.main.async { pumpMarkerRan = true }
            var turns = 0
            repeat {
                _ = RunLoop.main.run(mode: .default, before: .distantPast)
                turns += 1
            } while turns < 8 && (turns < 2 || !pumpMarkerRan)
            AVPlayer.pumpEvents(interfaceIsMoving: compositor?.isAnimating ?? false)
            AVAudioPlayer.pumpEvents()
            let pumped = CACurrentMediaTime()
            Harness.tick()
            deliverPointerMove(force: false)
            if CACurrentMediaTime() - lastSettingsSave > 5, settingsChanged.take() {
                lastSettingsSave = CACurrentMediaTime()
                // Off the main thread: writing the file takes many milliseconds when a setting
                // has changed, which was a frame or two lost every time.
                DispatchQueue.global(qos: .utility).async { UserDefaults.standard.synchronize() }
            }
            if CACurrentMediaTime() - lastPictureSweep > 5 {
                lastPictureSweep = CACurrentMediaTime()
                NSImage.releaseIdlePictures()
            }
            let handled = CACurrentMediaTime()
            // First Row brings its layers up to date with whatever the input, timers and tasks
            // changed. That's what asks for a frame, if anything on screen is different.
            FrameObservers.run()
            let now = CACurrentMediaTime()
            if debugFrames {
                // Input (the harness's stands in for the mouse and keys) apart from timers and tasks.
                frameTimes.input += (polled - loopStart) + (handled - pumped)
                frameTimes.tasks += pumped - polled
                frameTimes.updates += now - handled
            }
            let shouldDraw = needsFrame || (compositor?.isAnimating ?? false) || now - lastFrame > 0.5 || hasVideo
            guard shouldDraw else { continue }
            needsFrame = false
            drawFrame()
            if debugFrames {
                frameTimes.interval = now - lastFrame
                timings.frameDone(frameTimes)
                frameTimes = FrameTimes()
            }
            lastFrame = now
        }
        for handler in quitHandlers {
            handler()
        }
        UserDefaults.standard.synchronize()
        AVPlayer.shutDownAll()
        SDL_GL_DestroyContext(context)
        SDL_DestroyWindow(created)
        SDL_Quit()
        exit(0)
    }

    /// `FIRSTROW_DEBUG_FRAMES=1` times the parts of each frame (which waits for the drawing to
    /// finish, so the drawing's own time can be told from the time spent asking for it).
    private static let debugFrames = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_FRAMES"] == "1"
    private static var frameTimes = FrameTimes()
    private static var hasVideo: Bool { AVPlayerLayer.hasActiveVideo }

    private static func windowSize(_ environment: [String: String]) -> CGSize {
        let parts = (environment["FIRSTROW_WINDOW_SIZE"] ?? environment["FIRSTROW_HARNESS_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        if let display = SDL_GetDesktopDisplayMode(SDL_GetPrimaryDisplay()) {
            return CGSize(width: Int(display.pointee.w), height: Int(display.pointee.h))
        }
        return CGSize(width: 1280, height: 720)
    }

    /// Point size and pixels per point of the window.
    private static func metrics() -> (CGSize, CGFloat, Int, Int) {
        guard let window else { return (.zero, 1, 0, 0) }
        var w: Int32 = 0, h: Int32 = 0, pw: Int32 = 0, ph: Int32 = 0
        SDL_GetWindowSize(window, &w, &h)
        SDL_GetWindowSizeInPixels(window, &pw, &ph)
        let size = CGSize(width: Int(w), height: Int(h))
        if let forced = forcedScale {
            return (size, forced, Int((size.width * forced).rounded()), Int((size.height * forced).rounded()))
        }
        let scale = w > 0 ? CGFloat(pw) / CGFloat(w) : 1
        return (size, max(1, scale), Int(pw), Int(ph))
    }

    private static func relayout() {
        let (size, scale, _, _) = metrics()
        guard size.width > 0, size.height > 0 else { return }
        if let lastLayout, lastLayout.0 == size, lastLayout.1 == scale { return }
        lastLayout = (size, scale)
        host?.layout(size: size, scale: scale)
        needsFrame = true
    }

    private static func drawFrame() {
        guard let host, let compositor, let window else { return }
        let flushStart = CACurrentMediaTime()
        CATransaction.flush()
        let (_, _, pixelWidth, pixelHeight) = metrics()
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        let start = CACurrentMediaTime()
        AVPlayerLayer.renderVideoFrames()
        let videoDone = CACurrentMediaTime()
        var framebuffer: GLuint = 0
        if forcedScale != nil {
            framebuffer = offscreenTarget(width: pixelWidth, height: pixelHeight)
        }
        compositor.render(root: host.rootLayer, pixelWidth: pixelWidth, pixelHeight: pixelHeight, time: CACurrentMediaTime(), framebuffer: framebuffer)
        if debugFrames {
            let submitted = CACurrentMediaTime()
            glFinish()
            frameTimes.updates += start - flushStart
            frameTimes.video += videoDone - start
            frameTimes.submit += submitted - videoDone
            frameTimes.raster += CACurrentMediaTime() - submitted
        } else if isHeadless {
            // Nothing paces the frames without a display: wait for this one to be drawn, as a
            // screen's refresh would, so a software renderer doesn't queue them up.
            glFinish()
        }
        Harness.frameDrawn(compositor: compositor, width: pixelWidth, height: pixelHeight, framebuffer: framebuffer)
        if framebuffer != 0 {
            // Show the scaled frame in the window too.
            var w: Int32 = 0, h: Int32 = 0
            SDL_GetWindowSizeInPixels(window, &w, &h)
            glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer)
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)
            glBlitFramebuffer(0, 0, GLint(pixelWidth), GLint(pixelHeight), 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_LINEAR)
            glBindFramebuffer(GL_FRAMEBUFFER, 0)
        }
        let swapStart = CACurrentMediaTime()
        SDL_GL_SwapWindow(window)
        if debugFrames { frameTimes.swap += CACurrentMediaTime() - swapStart }
        CATransaction.runCompletions()
    }

    /// Where one frame's time went, in seconds.
    private struct FrameTimes {
        /// From the frame before to this one.
        var interval: Double = 0
        /// Mouse, keys and controllers, and what First Row does about them.
        var input: Double = 0
        /// Timers, dispatched blocks, main-actor tasks and the players' events.
        var tasks: Double = 0
        /// First Row bringing its layers up to date for the frame.
        var updates: Double = 0
        var video: Double = 0
        /// Walking the layers and asking OpenGL to draw them.
        var submit: Double = 0
        /// OpenGL doing the drawing (on the processor, with a software renderer).
        var raster: Double = 0
        var swap: Double = 0
    }

    /// Where frame time goes, printed every five seconds with FIRSTROW_DEBUG_FRAMES=1.
    private struct FrameTimings {
        var frames = 0
        var longest: Double = 0
        var sum = FrameTimes()
        var since = CACurrentMediaTime()

        mutating func frameDone(_ frame: FrameTimes) {
            frames += 1
            longest = max(longest, frame.interval)
            sum.input += frame.input; sum.tasks += frame.tasks; sum.updates += frame.updates; sum.video += frame.video
            sum.submit += frame.submit; sum.raster += frame.raster; sum.swap += frame.swap
            let now = CACurrentMediaTime()
            guard now - since >= 5 else { return }
            let n = Double(max(1, frames)) / 1000
            let line = String(format: "[frames] %.1f fps, longest %.0f ms; per frame: input %.2f, tasks %.2f, updates %.2f, video %.2f, layers %.2f, drawing %.2f, swap %.2f ms; ",
                              Double(frames) / (now - since), longest * 1000, sum.input / n, sum.tasks / n, sum.updates / n, sum.video / n, sum.submit / n, sum.raster / n, sum.swap / n)
            FileHandle.standardError.write(Data((line + RenderStats.takeSummary(frames: frames) + "\n").utf8))
            self = FrameTimings()
        }
    }

    private static var timings = FrameTimings()

    private static func offscreenTarget(width: Int, height: Int) -> GLuint {
        if let offscreen, offscreen.width == width, offscreen.height == height { return offscreen.framebuffer }
        if var existing = offscreen {
            glDeleteFramebuffers(1, &existing.framebuffer)
            glDeleteTextures(1, &existing.texture)
        }
        var texture: GLuint = 0
        glGenTextures(1, &texture)
        glBindTexture(GL_TEXTURE_2D, texture)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
        var framebuffer: GLuint = 0
        glGenFramebuffers(1, &framebuffer)
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
        offscreen = (framebuffer, texture, width, height)
        return framebuffer
    }

    // MARK: Events

    private static func handle(_ event: SDL_Event) {
        let type = SDL_EventType(rawValue: numericCast(event.type))
        switch type {
        case SDL_EVENT_QUIT, SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            if host?.shouldQuitImmediately() ?? true { running = false }
        case SDL_EVENT_WINDOW_RESIZED, SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
            relayout()
        case SDL_EVENT_WINDOW_EXPOSED, SDL_EVENT_WINDOW_RESTORED, SDL_EVENT_WINDOW_SHOWN:
            needsFrame = true
        case SDL_EVENT_KEY_DOWN:
            deliverPointerMove(force: true)
            let key = portableKey(event.key.key)
            let modifiers = portableModifiers(event.key.mod)
            if let window, SDL_GetWindowFlags(window) & WindowFlag.fullscreen != 0 { SDL_HideCursor() }
            host?.keyDown(key, isRepeat: event.key.repeat, modifiers: modifiers, character: character(event.key.key))
        case SDL_EVENT_KEY_UP:
            host?.keyUp(portableKey(event.key.key))
        case SDL_EVENT_TEXT_INPUT:
            if let text = event.text.text {
                host?.textInput(String(cString: text))
            }
        case SDL_EVENT_MOUSE_MOTION:
            if !SDL_CursorVisible() { SDL_ShowCursor() }
            notePointerMoved(to: CGPoint(x: CGFloat(event.motion.x), y: CGFloat(event.motion.y)))
        case SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP:
            if !SDL_CursorVisible() { SDL_ShowCursor() }
            deliverPointerMove(force: true)
            pointerLocation = CGPoint(x: CGFloat(event.button.x), y: CGFloat(event.button.y))
            if let button = pointerButton(event.button.button) {
                host?.pointerButton(button, pressed: type == SDL_EVENT_MOUSE_BUTTON_DOWN, at: pointerLocation)
            }
        case SDL_EVENT_MOUSE_WHEEL:
            deliverPointerMove(force: true)
            // The values already follow the system's scroll direction setting.
            host?.pointerScrolled(dx: CGFloat(event.wheel.x), dy: CGFloat(event.wheel.y), at: pointerLocation)
        case SDL_EVENT_GAMEPAD_ADDED:
            if let pad = SDL_OpenGamepad(event.gdevice.which) {
                gamepads[event.gdevice.which] = pad
            }
        case SDL_EVENT_GAMEPAD_REMOVED:
            if let pad = gamepads.removeValue(forKey: event.gdevice.which) { SDL_CloseGamepad(pad) }
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN, SDL_EVENT_GAMEPAD_BUTTON_UP:
            if let button = gamepadButton(SDL_GamepadButton(rawValue: Int32(event.gbutton.button))) {
                host?.gamepad(button, pressed: type == SDL_EVENT_GAMEPAD_BUTTON_DOWN)
            }
        case SDL_EVENT_GAMEPAD_AXIS_MOTION:
            handleAxis(event.gaxis)
        default:
            break
        }
    }

    private static var stickState: [UInt8: GamepadButton?] = [:]
    private static var pointerLocation = CGPoint.zero
    /// Where the pointer has got to, when First Row hasn't been told yet.
    private static var pendingPointerMove: CGPoint?
    private static var lastPointerMoveDelivery: CFTimeInterval = 0

    /// A mouse reports where it is up to thousands of times a second, far more often than a
    /// frame is drawn. First Row is told where it has got to once per pass of the loop.
    private static func notePointerMoved(to point: CGPoint) {
        pointerLocation = point
        pendingPointerMove = point
    }

    /// Tells First Row where the pointer is now. Before a click, a scroll or a key (`force`)
    /// it's told at once, so those land where the pointer is. With nothing being drawn the
    /// loop turns for every report, so it's told at most every 4 ms.
    private static func deliverPointerMove(force: Bool) {
        guard let point = pendingPointerMove else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastPointerMoveDelivery >= 0.004 else { return }
        pendingPointerMove = nil
        lastPointerMoveDelivery = now
        host?.pointerMoved(to: point)
    }

    private static func pointerButton(_ button: UInt8) -> PortablePointerButton? {
        // SDL_BUTTON_LEFT, MIDDLE, RIGHT, X1, X2.
        switch button {
        case 1: .primary
        case 2: .middle
        case 3: .secondary
        case 4: .back
        case 5: .forward
        default: nil
        }
    }

    private static func handleAxis(_ axis: SDL_GamepadAxisEvent) {
        let value = Int(axis.value)
        let direction: GamepadButton?
        switch SDL_GamepadAxis(rawValue: Int32(axis.axis)) {
        case SDL_GAMEPAD_AXIS_LEFTX: direction = value > 16000 ? .right : value < -16000 ? .left : nil
        case SDL_GAMEPAD_AXIS_LEFTY: direction = value > 16000 ? .down : value < -16000 ? .up : nil
        default: return
        }
        let previous = stickState[axis.axis] ?? nil
        guard previous != direction else { return }
        if let previous { host?.gamepad(previous, pressed: false) }
        if let direction { host?.gamepad(direction, pressed: true) }
        stickState[axis.axis] = direction
    }

    private static func gamepadButton(_ button: SDL_GamepadButton) -> GamepadButton? {
        switch button {
        case SDL_GAMEPAD_BUTTON_DPAD_UP: .up
        case SDL_GAMEPAD_BUTTON_DPAD_DOWN: .down
        case SDL_GAMEPAD_BUTTON_DPAD_LEFT: .left
        case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: .right
        case SDL_GAMEPAD_BUTTON_SOUTH: .south
        case SDL_GAMEPAD_BUTTON_EAST: .east
        case SDL_GAMEPAD_BUTTON_WEST: .west
        case SDL_GAMEPAD_BUTTON_NORTH: .north
        case SDL_GAMEPAD_BUTTON_START: .start
        case SDL_GAMEPAD_BUTTON_BACK: .back
        default: nil
        }
    }

    private static func portableKey(_ key: SDL_Keycode) -> PortableKey {
        switch key {
        case SDL_Keycode(SDLK_UP): .up
        case SDL_Keycode(SDLK_DOWN): .down
        case SDL_Keycode(SDLK_LEFT): .left
        case SDL_Keycode(SDLK_RIGHT): .right
        case SDL_Keycode(SDLK_RETURN), SDL_Keycode(SDLK_KP_ENTER): .enter
        case SDL_Keycode(SDLK_ESCAPE): .escape
        case SDL_Keycode(SDLK_BACKSPACE), SDL_Keycode(SDLK_DELETE): .delete
        case SDL_Keycode(SDLK_SPACE): .space
        // Media keys and remotes that send keys (a Siri Remote through a helper, say).
        case SDL_Keycode(SDLK_MEDIA_PLAY_PAUSE): .space
        case SDL_Keycode(SDLK_SELECT): .enter
        case SDL_Keycode(SDLK_AC_BACK): .escape
        default: .other(key)
        }
    }

    private static func character(_ key: SDL_Keycode) -> String? {
        guard key < 0x80, key >= 0x20, let scalar = Unicode.Scalar(key) else { return nil }
        return String(Character(scalar))
    }

    private static func portableModifiers(_ mod: SDL_Keymod) -> PortableModifiers {
        var result: PortableModifiers = []
        if mod & SDL_Keymod(SDL_KMOD_CTRL) != 0 { result.insert(.control) }
        if mod & SDL_Keymod(SDL_KMOD_ALT) != 0 { result.insert(.alt) }
        if mod & SDL_Keymod(SDL_KMOD_SHIFT) != 0 { result.insert(.shift) }
        if mod & SDL_Keymod(SDL_KMOD_GUI) != 0 { result.insert(.meta) }
        return result
    }

    /// Pointer events from the harness, as if from the mouse.
    static func injectPointerMoved(to point: CGPoint) {
        notePointerMoved(to: point)
    }

    static func injectPointerButton(_ button: PortablePointerButton, pressed: Bool, at point: CGPoint) {
        deliverPointerMove(force: true)
        pointerLocation = point
        host?.pointerButton(button, pressed: pressed, at: point)
    }

    static func injectPointerScroll(dx: CGFloat, dy: CGFloat) {
        deliverPointerMove(force: true)
        host?.pointerScrolled(dx: dx, dy: dy, at: pointerLocation)
    }

    static func injectKey(_ key: PortableKey, down: Bool) {
        deliverPointerMove(force: true)
        if down {
            host?.keyDown(key, isRepeat: false, modifiers: [], character: nil)
        } else {
            host?.keyUp(key)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("First Row: \(message)\n".utf8))
        let title = "First Row"
        SDL_ShowSimpleMessageBox(SDL_MessageBoxFlags(SDL_MESSAGEBOX_ERROR), title, message, nil)
        exit(1)
    }
}

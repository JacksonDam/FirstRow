import AVFoundation
import CPortable
import CSDL3
import Foundation
import QuartzCore

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
}

/// Work to run once per frame, just before layer changes are committed and drawn.
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
    static var forcedScale: CGFloat? {
        ProcessInfo.processInfo.environment["FIRSTROW_SCALE"].flatMap { Double($0) }.map { CGFloat($0) }
    }

    /// The SDL window, for dialogs that sit over it.
    static var windowHandle: OpaquePointer? { window }

    static func hideCursorIfFullscreen() {
        if let window, SDL_GetWindowFlags(window) & WindowFlag.fullscreen != 0 { SDL_HideCursor() }
    }

    /// Ends the main loop after the current frame.
    public static func quit() {
        running = false
    }

    /// Run once the main loop has ended, before the window closes and First Row exits.
    public static var quitHandlers: [@MainActor () -> Void] = []

    public static func run(makeHost: () -> PortableHost) -> Never {
        setlocale(LC_ALL, "C")
        let environment = ProcessInfo.processInfo.environment
        let headless = environment["SDL_VIDEO_DRIVER"] == "offscreen"
        // Swift provides main itself, so SDL's own entry point never ran.
        SDL_SetMainReady()
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
        while running {
            // Sleep until something happens when nothing on screen is moving.
            let idle = !needsFrame && !(compositor?.isAnimating ?? false) && !Harness.isBusy
            if idle {
                if SDL_WaitEventTimeout(&event, 8) { handle(event) }
            }
            let loopStart = CACurrentMediaTime()
            while SDL_PollEvent(&event) { handle(event) }
            // Timers, dispatched blocks and main-actor tasks. Each pass services one source,
            // and a due timer can hide the main queue, so take a few passes. The deadline is in
            // the past: on Windows a deadline of now still waits for the next 16 ms timer tick.
            for _ in 0 ..< 8 {
                _ = RunLoop.main.run(mode: .default, before: .distantPast)
            }
            AVPlayer.pumpEvents()
            AVAudioPlayer.pumpEvents()
            Harness.tick()
            let now = CACurrentMediaTime()
            if debugFrames { timings.events += now - loopStart }
            let shouldDraw = needsFrame || (compositor?.isAnimating ?? false) || now - lastFrame > 0.5 || hasVideo
            guard shouldDraw else { continue }
            needsFrame = false
            drawFrame()
            if debugFrames { timings.frameDone(interval: now - lastFrame) }
            lastFrame = now
        }
        for handler in quitHandlers {
            handler()
        }
        SDL_GL_DestroyContext(context)
        SDL_DestroyWindow(created)
        SDL_Quit()
        exit(0)
    }

    private static let debugFrames = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_FRAMES"] == "1"
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
        FrameObservers.run()
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
            glFinish()
            let end = CACurrentMediaTime()
            timings.flush += start - flushStart
            timings.video += videoDone - start
            timings.layers += end - videoDone
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
        if debugFrames { timings.swap += CACurrentMediaTime() - swapStart }
        CATransaction.runCompletions()
    }

    /// Where frame time goes, printed every five seconds with FIRSTROW_DEBUG_FRAMES=1.
    private struct FrameTimings {
        var frames = 0
        var longest: Double = 0
        var events: Double = 0
        var flush: Double = 0
        var video: Double = 0
        var layers: Double = 0
        var swap: Double = 0
        var since = CACurrentMediaTime()

        mutating func frameDone(interval: Double) {
            frames += 1
            longest = max(longest, interval)
            let now = CACurrentMediaTime()
            guard now - since >= 5 else { return }
            let n = Double(max(1, frames))
            let line = String(format: "[frames] %.1f fps, longest %.0f ms; per frame: events %.1f, updates %.1f, video %.1f, layers %.1f, swap %.1f ms; ",
                              n / (now - since), longest * 1000, events / n * 1000, flush / n * 1000, video / n * 1000, layers / n * 1000, swap / n * 1000)
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
            let key = portableKey(event.key.key)
            let modifiers = portableModifiers(event.key.mod)
            if let window, SDL_GetWindowFlags(window) & WindowFlag.fullscreen != 0 { SDL_HideCursor() }
            host?.keyDown(key, isRepeat: event.key.repeat, modifiers: modifiers, character: character(event.key.key))
        case SDL_EVENT_KEY_UP:
            host?.keyUp(portableKey(event.key.key))
        case SDL_EVENT_MOUSE_MOTION:
            SDL_ShowCursor()
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

    static func injectKey(_ key: PortableKey, down: Bool) {
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

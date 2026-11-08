import CoreGraphics
import CPortable
import Foundation
import QuartzCore
#if canImport(Glibc)
    import Glibc
#endif

/// Test driving for development, like the Mac harness: key commands from a FIFO
/// (`FIRSTROW_HARNESS_FIFO`) or a script file (`FIRSTROW_SCRIPT`), and `shot:<file.png>` to
/// save the next frame.
@MainActor
public enum Harness {
    public static var isActive: Bool { ProcessInfo.processInfo.environment["FIRSTROW_HARNESS"] == "1" }

    /// Commands the app understands itself, such as `source:music:/path`.
    public static var customCommand: ((String) -> Bool)?

    private static var queue: [String] = []
    private static let lock = NSLock()
    nonisolated(unsafe) private static var incoming: [String] = []
    private static var resumeAt: CFTimeInterval = 0
    private static var pendingShots: [String] = []
    private static var scriptLines: [String] = []

    static var isBusy: Bool { !scriptLines.isEmpty || !pendingShots.isEmpty || !queue.isEmpty }

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FIRSTROW_SCRIPT"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
            scriptLines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        #if !os(Windows)
            if isActive, let path = environment["FIRSTROW_HARNESS_FIFO"] {
                let thread = Thread {
                    let fd = open(path, O_RDWR)
                    guard fd >= 0 else { return }
                    var pending = [UInt8]()
                    var buffer = [UInt8](repeating: 0, count: 256)
                    while true {
                        let count = read(fd, &buffer, buffer.count)
                        guard count > 0 else { continue }
                        pending.append(contentsOf: buffer[0 ..< count])
                        while let newline = pending.firstIndex(of: 0x0A) {
                            let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                            pending.removeSubrange(...newline)
                            guard !line.isEmpty else { continue }
                            Harness.lock.lock()
                            Harness.incoming.append(line)
                            Harness.lock.unlock()
                        }
                    }
                }
                thread.start()
            }
        #endif
    }

    static func tick() {
        lock.lock()
        if !incoming.isEmpty {
            queue.append(contentsOf: incoming)
            incoming.removeAll()
        }
        lock.unlock()
        let now = CACurrentMediaTime()
        guard now >= resumeAt else { return }
        if queue.isEmpty, !scriptLines.isEmpty {
            queue.append(scriptLines.removeFirst())
        }
        while !queue.isEmpty, CACurrentMediaTime() >= resumeAt {
            perform(queue.removeFirst())
        }
    }

    private static let keys: [String: PortableKey] = [
        "down": .down, "up": .up, "left": .left, "right": .right, "enter": .enter, "return": .enter,
        "delete": .delete, "escape": .escape, "space": .space,
    ]

    private static func perform(_ line: String) {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        let words = line.split(separator: " ").map(String.init)
        switch parts.first ?? "" {
        case "wait":
            resumeAt = CACurrentMediaTime() + (Double(parts.count > 1 ? parts[1] : "") ?? 1)
        case "shot" where parts.count == 2:
            pendingShots.append(parts[1])
            CATransaction.onChange?()
        case "quit":
            PortableApplication.quit()
        case "press" where parts.count == 2:
            if let key = keys[parts[1]] { PortableApplication.injectKey(key, down: true) }
        case "release" where parts.count == 2:
            if let key = keys[parts[1]] { PortableApplication.injectKey(key, down: false) }
        case "mouse" where parts.count == 2:
            performPointer(parts[1].split(separator: ":").map(String.init))
        case "volume" where parts.count == 2:
            NotificationCenter.default.post(name: Notification.Name("firstRowVolumeChanged"), object: nil, userInfo: ["volume": Double(parts[1]) ?? 0])
        default:
            if words.count == 2, words[0] == "wait" {
                resumeAt = CACurrentMediaTime() + (Double(words[1]) ?? 1)
            } else if words.count == 2, words[0] == "shot" {
                pendingShots.append(words[1])
                CATransaction.onChange?()
            } else if let key = keys[line] {
                PortableApplication.injectKey(key, down: true)
                PortableApplication.injectKey(key, down: false)
            } else if customCommand?(line) != true {
                FileHandle.standardError.write(Data("First Row harness: unknown command \(line)\n".utf8))
            }
        }
    }

    /// `mouse:move|down|up|click|right|back:x:y` and `mouse:scroll:dx:dy`, in window points.
    private static func performPointer(_ words: [String]) {
        guard words.count >= 3, let a = Double(words[1]), let b = Double(words[2]) else {
            FileHandle.standardError.write(Data("First Row harness: bad mouse command\n".utf8))
            return
        }
        let point = CGPoint(x: a, y: b)
        switch words[0] {
        case "move":
            PortableApplication.injectPointerMoved(to: point)
        case "down":
            PortableApplication.injectPointerButton(.primary, pressed: true, at: point)
        case "up":
            PortableApplication.injectPointerButton(.primary, pressed: false, at: point)
        case "click":
            PortableApplication.injectPointerMoved(to: point)
            PortableApplication.injectPointerButton(.primary, pressed: true, at: point)
            PortableApplication.injectPointerButton(.primary, pressed: false, at: point)
        case "right":
            PortableApplication.injectPointerButton(.secondary, pressed: true, at: point)
            PortableApplication.injectPointerButton(.secondary, pressed: false, at: point)
        case "back":
            PortableApplication.injectPointerButton(.back, pressed: true, at: point)
            PortableApplication.injectPointerButton(.back, pressed: false, at: point)
        case "scroll":
            PortableApplication.injectPointerScroll(dx: CGFloat(a), dy: CGFloat(b))
        default:
            FileHandle.standardError.write(Data("First Row harness: unknown mouse command \(words[0])\n".utf8))
        }
        CATransaction.onChange?()
    }

    static func frameDrawn(compositor: Compositor, width: Int, height: Int, framebuffer: GLuint) {
        guard !pendingShots.isEmpty else { return }
        let image = compositor.snapshot(pixelWidth: width, pixelHeight: height, framebuffer: framebuffer)
        for path in pendingShots {
            image.writePNG(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("First Row harness: saved \(path)\n".utf8))
        }
        pendingShots.removeAll()
    }
}

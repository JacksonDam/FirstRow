import CPortable
import Foundation

/// A WebSocket to another program on this machine, such as a browser's DevTools. Text messages
/// arrive on the main thread in the order they were sent.
public final class LocalWebSocket: @unchecked Sendable {
    public var onMessage: (@MainActor (String) -> Void)?
    public var onClose: (@MainActor () -> Void)?

    private let socket: Int64
    private let lock = NSLock()
    private var isClosed = false
    private var received: [UInt8]

    /// Connects to `ws://127.0.0.1:<port><path>`, or returns nil if nothing answers there.
    public init?(port: Int, path: String) {
        let socket = fr_tcp_connect_loopback(Int32(port))
        guard socket >= 0 else { return nil }
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard Self.sendAll(Array(request.utf8), on: socket),
              let (header, rest) = Self.readHeader(from: socket),
              header.hasPrefix("HTTP/1.1 101")
        else {
            fr_tcp_close(socket)
            return nil
        }
        self.socket = socket
        received = rest
    }

    /// Starts reading. Set the handlers first.
    public func start() {
        let thread = Thread { [self] in readFrames() }
        thread.name = "LocalWebSocket"
        thread.start()
    }

    @discardableResult
    public func send(_ text: String) -> Bool {
        sendFrame(opcode: 0x1, payload: Array(text.utf8))
    }

    public func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        guard !wasClosed else { return }
        fr_tcp_close(socket)
    }

    /// A plain HTTP GET to `127.0.0.1:<port><path>`, returning the body.
    public static func get(port: Int, path: String) -> String? {
        let socket = fr_tcp_connect_loopback(Int32(port))
        guard socket >= 0 else { return nil }
        defer { fr_tcp_close(socket) }
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        guard sendAll(Array(request.utf8), on: socket), let (header, rest) = readHeader(from: socket),
              header.hasPrefix("HTTP/1.1 200")
        else { return nil }
        var body = rest
        let length = header.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while length.map({ body.count < $0 }) ?? true {
            let count = buffer.withUnsafeMutableBytes { fr_tcp_receive(socket, $0.baseAddress, Int64($0.count)) }
            if count <= 0 { break }
            body.append(contentsOf: buffer[0 ..< Int(count)])
        }
        return String(decoding: body, as: UTF8.self)
    }

    // MARK: - Frames

    private static func sendAll(_ bytes: [UInt8], on socket: Int64) -> Bool {
        bytes.withUnsafeBytes { fr_tcp_send(socket, $0.baseAddress, Int64($0.count)) } == Int64(bytes.count)
    }

    /// Reads up to the blank line after an HTTP header: the header, and any bytes after it.
    private static func readHeader(from socket: Int64) -> (String, [UInt8])? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end: [UInt8] = [13, 10, 13, 10]
        while bytes.count < 65536 {
            let count = buffer.withUnsafeMutableBytes { fr_tcp_receive(socket, $0.baseAddress, Int64($0.count)) }
            if count <= 0 { return nil }
            bytes.append(contentsOf: buffer[0 ..< Int(count)])
            if let index = bytes.indices.dropLast(3).first(where: { Array(bytes[$0 ..< $0 + 4]) == end }) {
                return (String(decoding: bytes[0 ..< index], as: UTF8.self), Array(bytes[(index + 4)...]))
            }
        }
        return nil
    }

    /// Frames from a client are always masked.
    private func sendFrame(opcode: UInt8, payload: [UInt8]) -> Bool {
        var frame: [UInt8] = [0x80 | opcode]
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count < 65536 {
            frame += [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            frame += (0 ..< 8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) }
        }
        let mask = (0 ..< 4).map { _ in UInt8.random(in: 0 ... 255) }
        frame += mask
        frame.reserveCapacity(frame.count + count)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index & 3])
        }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        return Self.sendAll(frame, on: socket)
    }

    private func readFrames() {
        var start = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        var message: [UInt8] = []
        var messageIsText = false

        // Makes sure `count` unread bytes are waiting.
        func fill(_ count: Int) -> Bool {
            while received.count - start < count {
                let read = buffer.withUnsafeMutableBytes { fr_tcp_receive(socket, $0.baseAddress, Int64($0.count)) }
                if read <= 0 { return false }
                if start > 1 << 20 {
                    received.removeFirst(start)
                    start = 0
                }
                received.append(contentsOf: buffer[0 ..< Int(read)])
            }
            return true
        }

        reading: while fill(2) {
            let first = received[start]
            let second = received[start + 1]
            var length = Int(second & 0x7F)
            var offset = 2
            if length == 126 {
                guard fill(4) else { break }
                length = Int(received[start + 2]) << 8 | Int(received[start + 3])
                offset = 4
            } else if length == 127 {
                guard fill(10) else { break }
                length = (2 ..< 10).reduce(0) { $0 << 8 | Int(received[start + $1]) }
                offset = 10
            }
            var mask: [UInt8]?
            if second & 0x80 != 0 {
                guard fill(offset + 4) else { break }
                mask = Array(received[(start + offset) ..< (start + offset + 4)])
                offset += 4
            }
            guard fill(offset + length) else { break }
            var payload = Array(received[(start + offset) ..< (start + offset + length)])
            start += offset + length
            if let mask {
                for index in payload.indices {
                    payload[index] ^= mask[index & 3]
                }
            }
            let isFinal = first & 0x80 != 0
            switch first & 0x0F {
            case 0x1, 0x2:
                message = payload
                messageIsText = first & 0x0F == 0x1
            case 0x0:
                message += payload
            case 0x8:
                break reading
            case 0x9:
                _ = sendFrame(opcode: 0xA, payload: payload)
                continue reading
            default:
                continue reading
            }
            if isFinal, messageIsText {
                let text = String(decoding: message, as: UTF8.self)
                message = []
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onMessage?(text) }
                }
            }
        }
        close()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onClose?() }
        }
    }
}

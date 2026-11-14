import CSDL3
import Foundation

public protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?)
}

public extension AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {}
    func audioPlayerDecodeErrorDidOccur(_: AVAudioPlayer, error _: (any Error)?) {}
}

/// Short sounds played from memory through SDL, so interface clicks start without delay.
/// Formats SDL can't take directly (MP3 and the like) play through an AVPlayer.
open class AVAudioPlayer: NSObject, @unchecked Sendable {
    public let url: URL?
    public weak var delegate: AVAudioPlayerDelegate?
    public var numberOfLoops = 0
    public var volume: Float = 1 {
        didSet { if let stream { SDL_SetAudioStreamGain(stream, volume) } }
    }

    public private(set) var duration: TimeInterval = 0
    private var pcm: Data
    private var spec = SDL_AudioSpec()
    private var stream: OpaquePointer?
    private var fallback: AVPlayer?
    private var startedAt: Date?

    nonisolated(unsafe) private static var playing: [ObjectIdentifier: AVAudioPlayer] = [:]
    nonisolated(unsafe) private static var audioReady: Bool?

    public init(contentsOf url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        if let decoded = PCMDecoder.decode(data) {
            pcm = decoded.samples
            spec.format = decoded.format
            spec.channels = Int32(decoded.channels)
            spec.freq = Int32(decoded.rate)
            let frameBytes = decoded.channels * (decoded.format == SDL_AUDIO_U8 ? 1 : 2)
            duration = Double(decoded.samples.count) / Double(max(1, frameBytes * decoded.rate))
        } else {
            pcm = Data()
            fallback = AVPlayer(url: url)
            duration = AVURLAsset(url: url).duration.seconds
        }
        super.init()
    }

    deinit {
        if let stream { SDL_DestroyAudioStream(stream) }
    }

    private static func ensureAudio() -> Bool {
        if let audioReady { return audioReady }
        let ready = SDL_InitSubSystem(SDL_INIT_AUDIO)
        audioReady = ready
        return ready
    }

    @discardableResult
    public func prepareToPlay() -> Bool {
        guard fallback == nil else { return true }
        guard stream == nil else { return true }
        guard Self.ensureAudio() else { return false }
        stream = SDL_OpenAudioDeviceStream(SDL_AudioDeviceID(0xFFFF_FFFF), &spec, nil, nil)
        if let stream { SDL_SetAudioStreamGain(stream, volume) }
        return stream != nil
    }

    @discardableResult
    public func play() -> Bool {
        if let fallback {
            fallback.seek(to: .zero)
            fallback.play()
            Self.playing[ObjectIdentifier(self)] = self
            startedAt = Date()
            return true
        }
        guard prepareToPlay(), let stream else { return false }
        SDL_ClearAudioStream(stream)
        pcm.withUnsafeBytes { raw in
            _ = SDL_PutAudioStreamData(stream, raw.baseAddress, Int32(raw.count))
        }
        SDL_FlushAudioStream(stream)
        SDL_ResumeAudioStreamDevice(stream)
        startedAt = Date()
        Self.playing[ObjectIdentifier(self)] = self
        return true
    }

    public func pause() {
        if let fallback { fallback.pause() }
        if let stream { SDL_PauseAudioStreamDevice(stream) }
    }

    public func stop() {
        fallback?.pause()
        if let stream { SDL_ClearAudioStream(stream) }
        Self.playing.removeValue(forKey: ObjectIdentifier(self))
        startedAt = nil
    }

    public var isPlaying: Bool {
        if let fallback { return fallback.rate > 0 }
        guard let stream, startedAt != nil else { return false }
        return SDL_GetAudioStreamQueued(stream) > 0
    }

    public var currentTime: TimeInterval {
        get { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
        set {}
    }

    /// Tells delegates about sounds that ended; the host calls this once a frame.
    public static func pumpEvents() {
        for player in playing.values {
            let finished: Bool
            if let fallback = player.fallback {
                finished = fallback.rate == 0 && (player.startedAt.map { Date().timeIntervalSince($0) > 0.2 } ?? true)
            } else if let stream = player.stream {
                finished = SDL_GetAudioStreamQueued(stream) == 0
            } else {
                finished = true
            }
            guard finished else { continue }
            if player.numberOfLoops != 0 {
                if player.numberOfLoops > 0 { player.numberOfLoops -= 1 }
                player.play()
                continue
            }
            playing.removeValue(forKey: ObjectIdentifier(player))
            player.startedAt = nil
            player.delegate?.audioPlayerDidFinishPlaying(player, successfully: true)
        }
    }
}

/// Uncompressed WAV and AIFF, as First Row's interface sounds are stored.
enum PCMDecoder {
    struct Decoded {
        let samples: Data
        let format: SDL_AudioFormat
        let channels: Int
        let rate: Int
    }

    static func decode(_ data: Data) -> Decoded? {
        let b = [UInt8](data)
        guard b.count > 12 else { return nil }
        let tag = String(decoding: b[0 ..< 4], as: UTF8.self)
        let form = String(decoding: b[8 ..< 12], as: UTF8.self)
        if tag == "RIFF", form == "WAVE" { return wav(b) }
        if tag == "FORM", form == "AIFF" || form == "AIFC" { return aiff(b, compressedForm: form == "AIFC") }
        return nil
    }

    private static func wav(_ b: [UInt8]) -> Decoded? {
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func le32(_ i: Int) -> Int { le16(i) | le16(i + 2) << 16 }
        var i = 12
        var channels = 0, rate = 0, bits = 0, formatCode = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i ..< i + 4], as: UTF8.self)
            let size = le32(i + 4)
            if id == "fmt ", i + 24 <= b.count {
                formatCode = le16(i + 8)
                channels = le16(i + 10)
                rate = le32(i + 12)
                bits = le16(i + 22)
            } else if id == "data", formatCode == 1 || formatCode == 0xFFFE, channels > 0 {
                let end = min(b.count, i + 8 + size)
                let samples = Data(b[(i + 8) ..< end])
                guard bits == 16 || bits == 8 else { return nil }
                return Decoded(samples: samples, format: bits == 8 ? SDL_AUDIO_U8 : SDL_AUDIO_S16LE, channels: channels, rate: rate)
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    private static func aiff(_ b: [UInt8], compressedForm: Bool) -> Decoded? {
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        var i = 12
        var channels = 0, bits = 0
        var rate = 0.0
        var littleEndian = false
        while i + 8 <= b.count {
            let id = String(decoding: b[i ..< i + 4], as: UTF8.self)
            let size = be32(i + 4)
            if id == "COMM", i + 26 <= b.count {
                channels = be16(i + 8)
                bits = be16(i + 14)
                rate = TagReader.extended80(Array(b[(i + 16) ..< (i + 26)]))
                if compressedForm, i + 30 <= b.count {
                    let compression = String(decoding: b[(i + 26) ..< (i + 30)], as: UTF8.self)
                    if compression == "sowt" { littleEndian = true } else if compression != "NONE" { return nil }
                }
            } else if id == "SSND", channels > 0, bits == 16 || bits == 8 {
                let offset = be32(i + 8)
                let start = i + 16 + offset
                let end = min(b.count, i + 8 + size)
                guard start < end else { return nil }
                var samples = Data(b[start ..< end])
                if bits == 8 {
                    // AIFF 8-bit is signed; SDL wants unsigned.
                    samples = Data(samples.map { $0 ^ 0x80 })
                    return Decoded(samples: samples, format: SDL_AUDIO_U8, channels: channels, rate: Int(rate))
                }
                return Decoded(samples: samples, format: littleEndian ? SDL_AUDIO_S16LE : SDL_AUDIO_S16BE, channels: channels, rate: Int(rate))
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }
}

/// iOS's audio session; nothing to configure on Linux or Windows.
public final class AVAudioSession: @unchecked Sendable {
    public struct Category: Hashable { public let rawValue: String
        public static let playback = Category(rawValue: "playback")
        public static let ambient = Category(rawValue: "ambient")
    }

    public struct Mode: Hashable { public let rawValue: String
        public static let `default` = Mode(rawValue: "default")
        public static let moviePlayback = Mode(rawValue: "moviePlayback")
    }

    public struct CategoryOptions: OptionSet, Sendable { public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mixWithOthers = CategoryOptions(rawValue: 1)
    }

    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    public func setCategory(_: Category, mode _: Mode = .default, options _: CategoryOptions = []) throws {}
    public func setActive(_: Bool) throws {}
}

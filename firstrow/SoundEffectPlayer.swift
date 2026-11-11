import AVFoundation
import Foundation

final class SoundEffectPlayer: @unchecked Sendable {
    static let shared = SoundEffectPlayer()

    /// Players that are ready to play, by sound. More than one of a sound: a sound asked for
    /// again while it still plays (an arrow held down a list) needs another.
    private var preparedPlayers: [String: [AVAudioPlayer]] = [:]
    private var activePlayers: [ObjectIdentifier: (name: String, player: AVAudioPlayer)] = [:]
    private var cachedURLs: [String: URL] = [:]
    private var lastPlayedAt: [String: Date] = [:]
    private let minimumReplayInterval: TimeInterval = 0.015
    private let readyPlayersPerSound = 3
    private let listener = FinishListener()
    #if !FIRSTROW_PORTABLE
        /// Where Apple's players are made, got ready and started: starting one waits on the
        /// system's sound server and making one opens its file, which on the main thread cost
        /// two or three frames for every row an arrow moved (on Apple TV 30 to 100 ms each
        /// down a long list).
        private let queue = DispatchQueue(label: "firstrow.sounds", qos: .userInteractive)
    #endif
    #if os(tvOS)
        private lazy var mixer = SoundMixer(queue: queue)
        private var soundsAsked = 0
    #endif

    private init() {}

    /// Runs `work` where the players live (everything above is only touched there).
    private func onPlayers(_ work: @escaping @Sendable () -> Void) {
        #if FIRSTROW_PORTABLE
            Task { @MainActor in work() }
        #else
            queue.async(execute: work)
        #endif
    }

    func warmUp(soundNames: [String], fileExtension: String = "aif") {
        // Found on disk off the main thread: looking for twenty files took it 20 ms on
        // Windows, as First Row's first frames were being drawn.
        Task.detached(priority: .userInitiated) {
            let found = soundNames.map { ($0, bundledResourceURL($0, fileExtension)) }
            self.onPlayers {
                for (name, url) in found {
                    guard self.preparedPlayers[name] == nil, let url else { continue }
                    self.cachedURLs[name] = url
                    #if os(tvOS)
                        if self.mixer.prepare(name, url: url) { continue }
                    #endif
                    guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                    player.prepareToPlay()
                    self.preparedPlayers[name] = [player]
                }
            }
        }
    }

    func play(named fileName: String, fileExtension: String = "aif") {
        // The test harness runs silently: it shares the Mac with whoever is using it.
        guard !FirstRowHarness.isActive else { return }
        let asked = Date()
        onPlayers {
            #if !FIRSTROW_PORTABLE
                // A sound that has waited this long for its turn is let go: late, it would
                // belong to nothing on screen.
                guard Date().timeIntervalSince(asked) < 0.2 else { return }
            #endif
            if let lastPlayed = self.lastPlayedAt[fileName],
               asked.timeIntervalSince(lastPlayed) < self.minimumReplayInterval
            {
                return
            }
            self.lastPlayedAt[fileName] = asked

            let url: URL
            if let cachedURL = self.cachedURLs[fileName] {
                url = cachedURL
            } else if let resolvedURL = bundledResourceURL(fileName, fileExtension) {
                self.cachedURLs[fileName] = resolvedURL
                url = resolvedURL
            } else {
                print("Sound file \(fileName).\(fileExtension) not found")
                return
            }

            #if os(tvOS)
                if self.mixer.play(fileName, url: url) {
                    self.restMixerWhenQuiet()
                    return
                }
            #endif
            let player: AVAudioPlayer
            if let prepared = self.preparedPlayers[fileName]?.popLast() {
                player = prepared
            } else {
                guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
                newPlayer.prepareToPlay()
                player = newPlayer
            }
            player.delegate = self.listener
            let key = ObjectIdentifier(player)
            self.activePlayers[key] = (name: fileName, player: player)
            if !player.play() {
                self.activePlayers.removeValue(forKey: key)
                self.reprepareAndCache(player, for: fileName)
            }
        }
    }

    #if os(tvOS)
        /// The mixer runs while there are sounds to play and rests a few seconds after the
        /// last, so the app isn't one that is always playing something.
        private func restMixerWhenQuiet() {
            soundsAsked += 1
            let asked = soundsAsked
            queue.asyncAfter(deadline: .now() + 4) {
                guard self.soundsAsked == asked else { return }
                self.mixer.rest()
            }
        }
    #endif

    /// A player has played its sound through (or couldn't): it's got ready for the next time.
    fileprivate func finished(_ key: ObjectIdentifier, reusable: Bool) {
        onPlayers {
            guard let entry = self.activePlayers.removeValue(forKey: key), reusable else { return }
            self.reprepareAndCache(entry.player, for: entry.name)
        }
    }

    private func reprepareAndCache(_ player: AVAudioPlayer, for name: String) {
        guard (preparedPlayers[name]?.count ?? 0) < readyPlayersPerSound else { return }
        player.currentTime = 0
        player.prepareToPlay()
        preparedPlayers[name, default: []].append(player)
    }
}

/// Hears from the players as they finish. (Apple's delegate belongs to the main actor, where
/// the players no longer live, so it's kept apart from them and only passes the word on.)
private final class FinishListener: NSObject, AVAudioPlayerDelegate {
    override nonisolated init() {
        super.init()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        SoundEffectPlayer.shared.finished(ObjectIdentifier(player), reusable: true)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        SoundEffectPlayer.shared.finished(ObjectIdentifier(player), reusable: false)
        if let error { print("Audio decode error: \(error)") }
    }
}

#if os(tvOS)
    /// Apple TV's sounds, played as buffers through one engine. A player of the usual kind
    /// does its finishing on the main thread, a round trip to the system's sound server for
    /// every sound, which with an arrow held down a list (ten sounds a second) still cost a
    /// frame in three. Here a sound is started by handing its buffer to a voice, and nothing
    /// comes back to the main thread. Only touched on `SoundEffectPlayer`'s queue; where it
    /// can't play a sound it says so, and a player of the usual kind does.
    private final class SoundMixer: @unchecked Sendable {
        private final class Voice {
            let node = AVAudioPlayerNode()
            var busyUntil = Date.distantPast
        }

        private let queue: DispatchQueue
        private let engine = AVAudioEngine()
        private var buffers: [String: AVAudioPCMBuffer] = [:]
        private var voices: [String: [Voice]] = [:]
        private var unplayable: Set<String> = []
        private var changeObserver: NSObjectProtocol?
        private let voicesPerSound = 3

        init(queue: DispatchQueue) {
            self.queue = queue
        }

        /// Reads the sound into a buffer. False if it can't be played this way.
        func prepare(_ name: String, url: URL) -> Bool {
            if buffers[name] != nil { return true }
            guard !unplayable.contains(name) else { return false }
            // (Nothing to play through: the engine would refuse to be set up at all.)
            let output = engine.outputNode.outputFormat(forBus: 0)
            guard output.sampleRate > 0, output.channelCount > 0 else { return false }
            guard let file = try? AVAudioFile(forReading: url), file.length > 0,
                  let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: read)) != nil, read.frameLength > 0
            else {
                unplayable.insert(name)
                return false
            }
            // A sound of one channel goes into both as it is: left to the engine's mixer it
            // can come out 3 dB down (it did whenever the output ran at the sound's own rate).
            var buffer = read
            if read.format.channelCount == 1,
               let format = AVAudioFormat(standardFormatWithSampleRate: read.format.sampleRate, channels: 2),
               let both = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: read.frameLength),
               let from = read.floatChannelData, let to = both.floatChannelData
            {
                both.frameLength = read.frameLength
                let bytes = Int(read.frameLength) * MemoryLayout<Float>.size
                memcpy(to[0], from[0], bytes)
                memcpy(to[1], from[0], bytes)
                buffer = both
            }
            if changeObserver == nil {
                // The sound output changing (another screen, other speakers) stops the engine
                // and can change what it needs its voices joined with: they're made again.
                changeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                    self?.queue.async { self?.forgetVoices() }
                }
            }
            buffers[name] = buffer
            return true
        }

        func play(_ name: String, url: URL) -> Bool {
            guard prepare(name, url: url), let buffer = buffers[name] else { return false }
            let now = Date()
            var mine = voices[name] ?? []
            let voice: Voice
            if let free = mine.first(where: { $0.busyUntil <= now }) {
                voice = free
            } else if mine.count < voicesPerSound {
                voice = Voice()
                engine.attach(voice.node)
                engine.connect(voice.node, to: engine.mainMixerNode, format: buffer.format)
                mine.append(voice)
                voices[name] = mine
            } else if let soonest = mine.min(by: { $0.busyUntil < $1.busyUntil }) {
                // Every voice of this sound is sounding: the one nearest its end starts over.
                voice = soonest
                voice.node.stop()
            } else {
                return false
            }
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    forgetVoices()
                    return false
                }
            }
            voice.busyUntil = now.addingTimeInterval(Double(buffer.frameLength) / buffer.format.sampleRate)
            voice.node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !voice.node.isPlaying { voice.node.play() }
            return true
        }

        /// Stops the engine until the next sound (its voices stay as they are).
        func rest() {
            if engine.isRunning { engine.pause() }
        }

        private func forgetVoices() {
            engine.stop()
            for voice in voices.values.joined() { engine.detach(voice.node) }
            voices = [:]
        }
    }
#endif

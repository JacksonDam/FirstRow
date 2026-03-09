import AVFoundation
import Foundation

final class SoundEffectPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SoundEffectPlayer()

    private var preparedPlayers: [String: AVAudioPlayer] = [:]
    private var activePlayers: [ObjectIdentifier: (name: String, player: AVAudioPlayer)] = [:]
    private var cachedURLs: [String: URL] = [:]
    private var lastPlayedAt: [String: Date] = [:]
    private let minimumReplayInterval: TimeInterval = 0.015

    override private init() {
        super.init()
    }

    func warmUp(soundNames: [String], fileExtension: String = "aif") {
        DispatchQueue.main.async {
            for name in soundNames {
                guard self.preparedPlayers[name] == nil else { continue }
                guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else { continue }
                self.cachedURLs[name] = url
                guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                player.prepareToPlay()
                self.preparedPlayers[name] = player
            }
        }
    }

    func play(named fileName: String, fileExtension: String = "aif") {
        DispatchQueue.main.async {
            let now = Date()
            if let lastPlayed = self.lastPlayedAt[fileName],
               now.timeIntervalSince(lastPlayed) < self.minimumReplayInterval
            {
                return
            }
            self.lastPlayedAt[fileName] = now

            let url: URL
            if let cachedURL = self.cachedURLs[fileName] {
                url = cachedURL
            } else if let resolvedURL = Bundle.main.url(forResource: fileName, withExtension: fileExtension) {
                self.cachedURLs[fileName] = resolvedURL
                url = resolvedURL
            } else {
                print("Sound file \(fileName).\(fileExtension) not found")
                return
            }

            let player: AVAudioPlayer
            if let prepared = self.preparedPlayers.removeValue(forKey: fileName) {
                player = prepared
            } else {
                guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
                newPlayer.prepareToPlay()
                player = newPlayer
            }
            player.delegate = self
            let key = ObjectIdentifier(player)
            self.activePlayers[key] = (name: fileName, player: player)
            if !player.play() {
                self.activePlayers.removeValue(forKey: key)
                self.reprepareAndCache(player, for: fileName)
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        let key = ObjectIdentifier(player)
        if let entry = activePlayers.removeValue(forKey: key) {
            reprepareAndCache(entry.player, for: entry.name)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        activePlayers.removeValue(forKey: ObjectIdentifier(player))
        if let error { print("Audio decode error: \(error)") }
    }

    private func reprepareAndCache(_ player: AVAudioPlayer, for name: String) {
        guard preparedPlayers[name] == nil else { return }
        player.currentTime = 0
        player.prepareToPlay()
        preparedPlayers[name] = player
    }
}

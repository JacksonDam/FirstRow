import AVFoundation
import Foundation

/// Evens out loudness between iTunes previews, which are mastered loud and played as they are,
/// and the library's songs, which the system player plays at Sound Check's level.
enum LoudnessMeter {
    /// Apple Music's and Sound Check's reference loudness.
    static let target: Double = -16

    /// The volume (at most 1: quiet files are never boosted) that brings `loudness` to `target`.
    static func volume(forLoudness loudness: Double) -> Float {
        Float(max(0.25, min(1, pow(10, (target - loudness) / 20))))
    }

    #if !FIRSTROW_PORTABLE
        /// The integrated loudness of a local audio file in LUFS, measured as ITU-R BS.1770
        /// gates it (400 ms blocks, absolute and relative gates) but without its K-weighting
        /// filter, which moves typical music by a dB or two at most.
        static func loudness(of url: URL) async -> Double? {
            let asset = AVURLAsset(url: url)
            let track: AVAssetTrack?
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                track = try? await asset.loadTracks(withMediaType: .audio).first
            } else {
                track = asset.tracks(withMediaType: .audio).first
            }
            guard let track, let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            var blocks: [Double] = []
            var blockSum = 0.0
            var blockFrames = 0
            var framesPerBlock = 0
            while let buffer = output.copyNextSampleBuffer() {
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      let block = CMSampleBufferGetDataBuffer(buffer)
                else { continue }
                let channels = max(1, Int(description.mChannelsPerFrame))
                if framesPerBlock == 0 { framesPerBlock = max(1, Int(description.mSampleRate * 0.4)) }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer
                else { continue }
                let samples = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: samples) { floats in
                    var index = 0
                    while index + channels <= samples {
                        var frame = 0.0
                        for channel in 0 ..< channels {
                            let sample = Double(floats[index + channel])
                            frame += sample * sample
                        }
                        blockSum += frame
                        blockFrames += 1
                        if blockFrames == framesPerBlock {
                            blocks.append(blockSum / Double(framesPerBlock))
                            blockSum = 0
                            blockFrames = 0
                        }
                        index += channels
                    }
                }
            }
            guard reader.status == .completed, !blocks.isEmpty else { return nil }
            func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-12)) }
            let audible = blocks.filter { lufs($0) > -70 }
            guard !audible.isEmpty else { return nil }
            let threshold = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
            let gated = audible.filter { lufs($0) > threshold }
            guard !gated.isEmpty else { return nil }
            return lufs(gated.reduce(0, +) / Double(gated.count))
        }
    #endif
}

extension MenuView {
    /// The volume a music file should play at: lowered for the previews measured as loud.
    func musicPlaybackVolume(for url: URL) -> Float {
        musicLoudnessVolumeByPath[url.standardizedFileURL.path] ?? 1
    }

    /// Measures a downloaded preview so it plays no louder than the library's songs.
    func levelPreviewLoudness(_ url: URL) async {
        #if FIRSTROW_PORTABLE
            // mpv levels it as it plays (see `normalizesLoudness`), marked by a volume below 1.
            musicLoudnessVolumeByPath[url.standardizedFileURL.path] = 0.999
        #else
            guard let loudness = await LoudnessMeter.loudness(of: url) else { return }
            musicLoudnessVolumeByPath[url.standardizedFileURL.path] = LoudnessMeter.volume(forLoudness: loudness)
        #endif
    }
}

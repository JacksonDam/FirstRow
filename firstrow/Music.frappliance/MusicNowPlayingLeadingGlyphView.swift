import SwiftUI

struct MusicNowPlayingLeadingGlyphView: View {
    let state: MoviePlaybackGlyphState
    let fontSize: CGFloat
    var body: some View {
        switch state {
        case .pause:
            Image(systemName: "pause.fill").font(.system(size: fontSize * 0.92, weight: .bold)).foregroundStyleCompat(.white)
        case let .rewind(requestedCount):
            let count = max(1, min(3, requestedCount))
            HStack(spacing: -7) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Image(systemName: "play.fill").font(.system(size: fontSize * 0.92, weight: .bold)).foregroundStyleCompat(.white).rotationEffect(.degrees(180))
                }
            }.offset(x: 4)
        case let .fastForward(requestedCount):
            let count = max(1, min(3, requestedCount))
            HStack(spacing: -7) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Image(systemName: "play.fill").font(.system(size: fontSize * 0.92, weight: .bold)).foregroundStyleCompat(.white)
                }
            }.offset(x: -4)
        case .play:
            Image(systemName: "pause.fill").font(.system(size: fontSize * 0.92, weight: .bold)).foregroundStyleCompat(.white)
        case .loading:
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(0.9)
            } else {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(0.9)
            }
        }
    }
}

import SwiftUI

enum MoviePlaybackGlyphState: Equatable {
    case pause
    case play
    case loading
    case rewind(Int)
    case fastForward(Int)
}

struct MoviePlaybackControlsOverlay: View {
    let glyphState: MoviePlaybackGlyphState
    let currentTimeSeconds: Double
    let durationSeconds: Double
    let isLoading: Bool
    let loadingProgress: Double

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let barHeight: CGFloat = 72
            let diamondSize: CGFloat = 40
            let timeFontSize = min(max(h * 0.038, 28), 46)
            let leadingTimeWidth = max(80.0, w * 0.068)
            let trailingTimeWidth = max(90.0, w * 0.077)
            let barWidth = max(
                200.0,
                w - 18 - leadingTimeWidth - 18 - 24 - trailingTimeWidth - 24
            )
            let scrubCenterY = h - 80
            let glyphCenterY = scrubCenterY - barHeight * 0.5 - 14 - 25

            let hasValidDuration = durationSeconds.isFinite && durationSeconds > 0.001
            let elapsed = max(0, currentTimeSeconds.isFinite ? currentTimeSeconds : 0)
            let duration = max(0, durationSeconds.isFinite ? durationSeconds : 0)
            let clampedElapsed: Double = duration > 0 ? min(elapsed, duration) : elapsed
            let displayElapsed: Double = {
                guard duration > 0 else { return clampedElapsed }
                return (duration - clampedElapsed) <= 0.02 ? duration : clampedElapsed
            }()
            let displayRemaining = max(0, duration - displayElapsed)
            let rawProgress = isLoading
                ? max(0, min(1, loadingProgress))
                : (duration > 0 ? min(1, max(0, displayElapsed / duration)) : 0)
            let progress = CGFloat(rawProgress)

            let diamondInset: CGFloat = 16
            let minCenter = diamondSize * 0.5 + diamondInset
            let maxCenter = barWidth - diamondSize * 0.5 - diamondInset
            let clampedCenter = minCenter + (maxCenter - minCenter) * progress

            ZStack(alignment: .topLeading) {
                // Glyph — floating above the scrubber
                MoviePlaybackGlyphView(state: glyphState)
                    .frame(width: w, height: 50, alignment: .center)
                    .position(x: w * 0.5, y: glyphCenterY)

                // Music-style scrubber: elapsed | outlined track + diamond | -remaining
                HStack(alignment: .center, spacing: 0) {
                    Color.clear.frame(width: 18)
                    Text(formatPaddedTime(displayElapsed))
                        .font(.firstRowBold(size: timeFontSize))
                        .foregroundStyleCompat(.white.opacity(0.95))
                        .lineLimit(1)
                        .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                        .frame(width: leadingTimeWidth, height: barHeight, alignment: .leading)
                    Color.clear.frame(width: 18)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                            .frame(height: barHeight)
                        RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 6)
                            .frame(height: barHeight)
                        if hasValidDuration && !isLoading {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white)
                                .frame(width: diamondSize, height: diamondSize)
                                .rotationEffect(.degrees(45))
                                .offset(x: clampedCenter - diamondSize * 0.5)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .frame(width: barWidth, height: barHeight)
                    Color.clear.frame(width: 24)
                    Text(hasValidDuration ? "-\(formatPaddedTime(displayRemaining))" : "")
                        .font(.firstRowBold(size: timeFontSize))
                        .foregroundStyleCompat(.white.opacity(0.95))
                        .lineLimit(1)
                        .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                        .frame(width: trailingTimeWidth, height: barHeight, alignment: .trailing)
                    Color.clear.frame(width: 24)
                }
                .frame(width: w, height: barHeight)
                .position(x: w * 0.5, y: scrubCenterY)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func formatPaddedTime(_ seconds: Double) -> String {
        let raw = formatfirstRowPlaybackTime(seconds)
        let parts = raw.components(separatedBy: ":")
        if parts.count == 2, parts[0].count == 1 {
            return "0\(raw)"
        }
        return raw
    }
}

private struct MoviePlaybackGlyphView: View {
    let state: MoviePlaybackGlyphState
    var body: some View {
        glyphContent.shadow(color: .white.opacity(0.45), radius: 1.8, x: 0, y: 0).shadow(color: .white.opacity(0.2), radius: 3.2, x: 0, y: 0)
    }

    @ViewBuilder
    private var glyphContent: some View {
        switch state {
        case .pause:
            Image(systemName: "pause.fill").font(.system(size: 23, weight: .bold)).foregroundStyleCompat(.white)
        case .play:
            Image(systemName: "play.fill").font(.system(size: 23, weight: .bold)).foregroundStyleCompat(.white).offset(x: 1)
        case .loading:
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.05)
            } else {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(1.05)
            }
        case let .rewind(requestedCount):
            let count = max(1, min(3, requestedCount))
            HStack(spacing: -7) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Image(systemName: "play.fill").font(.system(size: 23, weight: .bold)).foregroundStyleCompat(.white).rotationEffect(.degrees(180))
                }
            }.offset(x: 4)
        case let .fastForward(requestedCount):
            let count = max(1, min(3, requestedCount))
            HStack(spacing: -7) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Image(systemName: "play.fill").font(.system(size: 23, weight: .bold)).foregroundStyleCompat(.white)
                }
            }.offset(x: -4)
        }
    }
}

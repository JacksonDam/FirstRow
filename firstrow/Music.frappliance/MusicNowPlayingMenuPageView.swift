import SwiftUI

extension MenuView {
    @ViewBuilder
    func musicNowPlayingMenuPageView(geometry: GeometryProxy) -> some View {
        let w = geometry.size.width
        let h = geometry.size.height
        let contentTopY = submenuDividerTopInset + submenuDividerThickness

        let artSide = min(w * (675.0 / 1920.0), 675)
        let artLeading: CGFloat = 80
        let artTopY = contentTopY + 100
        let artCenterY = artTopY + artSide * 0.5
        let reflectionH: CGFloat = 60

        let metaLeading = artLeading + artSide + w * 0.042 - 13
        let metaWidth = w * 0.42
        let metaCenterY = artTopY + artSide * 0.41

        let titleFontSize = min(max(h * 0.067, 50), 76)
        let artistFontSize = min(max(h * 0.056, 42), 64)
        let timeFontSize = min(max(h * 0.038, 28), 46)

        let playPauseSize: CGFloat = 90
        let playPauseCenterX = w - 42 - playPauseSize * 0.5
        let playPauseCenterY: CGFloat = 36 + playPauseSize * 0.5
        let isPlaybackPaused = musicNowPlayingLeadingGlyphState == .pause

        let elapsed = max(0, musicNowPlayingElapsedSeconds.isFinite ? musicNowPlayingElapsedSeconds : 0)
        let duration = max(0, musicNowPlayingDurationSeconds.isFinite ? musicNowPlayingDurationSeconds : 0)
        let clampedElapsed: Double = duration > 0 ? min(elapsed, duration) : elapsed
        let displayElapsed: Double = {
            guard duration > 0 else { return clampedElapsed }
            let remaining = duration - clampedElapsed
            return remaining <= 0.02 ? duration : clampedElapsed
        }()
        let displayRemaining = max(0, duration - displayElapsed)
        let progress = CGFloat(duration > 0 ? min(1, max(0, displayElapsed / duration)) : 0)

        let barHeight: CGFloat = 72
        let diamondSize: CGFloat = 40
        let leadingTimeWidth = max(80.0, w * 0.068)
        let trailingTimeWidth = max(90.0, w * 0.077)
        let barWidth = max(200.0, w - 18 - leadingTimeWidth - 18 - 24 - trailingTimeWidth - 24)
        let scrubCenterY = h - 80

        ZStack(alignment: .topLeading) {
            artworkView(artSide: artSide)
                .animation(nil, value: musicNowPlayingArtwork)
                .scaleEffect(x: 1, y: -1)
                .frame(width: artSide, height: reflectionH, alignment: .top)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(0.5)
                .position(x: artLeading + artSide * 0.5, y: artTopY + artSide + reflectionH * 0.5)

            artworkView(artSide: artSide)
                .animation(nil, value: musicNowPlayingArtwork)
                .position(x: artLeading + artSide * 0.5, y: artCenterY)

            Image(systemName: isPlaybackPaused ? "pause.fill" : "play.fill")
                .font(.system(size: playPauseSize, weight: .bold))
                .foregroundColor(.white)
                .position(x: playPauseCenterX, y: playPauseCenterY)

            VStack(alignment: .leading, spacing: 50) {
                Text(musicNowPlayingTitle)
                    .font(.firstRowBold(size: titleFontSize))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
                Text(musicNowPlayingArtist)
                    .font(.firstRowBold(size: artistFontSize))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if !musicNowPlayingAlbum.isEmpty {
                    Text(musicNowPlayingAlbum)
                        .font(.firstRowBold(size: artistFontSize))
                        .foregroundColor(.white)
                        .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            .frame(width: metaWidth, alignment: .leading)
            .position(x: metaLeading + metaWidth * 0.5, y: metaCenterY)

            HStack(alignment: .center, spacing: 0) {
                Color.clear.frame(width: 18)
                Text(formatPaddedPlaybackTime(displayElapsed))
                    .font(.firstRowBold(size: timeFontSize))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                    .frame(width: leadingTimeWidth, height: barHeight, alignment: .leading)
                Color.clear.frame(width: 18)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                        .stroke(Color.white.opacity(0.82), lineWidth: 6)
                        .frame(height: barHeight)
                    let diamondInset: CGFloat = 16
                    let minCenter = diamondSize * 0.5 + diamondInset
                    let maxCenter = barWidth - diamondSize * 0.5 - diamondInset
                    let clampedCenter = minCenter + (maxCenter - minCenter) * progress
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white)
                        .frame(width: diamondSize, height: diamondSize)
                        .rotationEffect(.degrees(45))
                        .offset(x: clampedCenter - diamondSize * 0.5)
                }
                .frame(width: barWidth, height: barHeight)
                Color.clear.frame(width: 24)
                Text("-\(formatPaddedPlaybackTime(displayRemaining))")
                    .font(.firstRowBold(size: timeFontSize))
                    .foregroundColor(.white.opacity(0.95))
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

    private func formatPaddedPlaybackTime(_ seconds: Double) -> String {
        let raw = formatfirstRowPlaybackTime(seconds)
        let parts = raw.components(separatedBy: ":")
        if parts.count == 2, parts[0].count == 1 {
            return "0\(raw)"
        }
        return raw
    }

    @ViewBuilder
    private func artworkView(artSide: CGFloat) -> some View {
        if let image = musicNowPlayingArtwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artSide, height: artSide)
                .clipped()
        } else {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.17),
                            Color(red: 0.06, green: 0.06, blue: 0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: artSide, height: artSide)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: artSide * 0.28, weight: .regular))
                        .foregroundColor(.white.opacity(0.72))
                )
        }
    }
}

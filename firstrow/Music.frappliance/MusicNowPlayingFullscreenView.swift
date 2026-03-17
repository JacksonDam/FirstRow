import SwiftUI

struct MusicNowPlayingFullscreenView: View {
    enum LayoutMode {
        case artworkRight
        case artworkLeft
    }

    let artworkImage: NSImage?
    let trackTitle: String
    let artistName: String
    let albumTitle: String
    let trackPositionText: String
    let elapsedSeconds: Double
    let durationSeconds: Double
    let showsShuffleGlyph: Bool
    let leadingGlyphState: MoviePlaybackGlyphState?
    let layoutMode: LayoutMode
    private var clampedElapsed: Double {
        max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
    }

    private var clampedDuration: Double {
        max(0, durationSeconds.isFinite ? durationSeconds : 0)
    }

    private var displayElapsed: Double {
        guard clampedDuration > 0 else { return clampedElapsed }
        let normalized = min(max(clampedElapsed, 0), clampedDuration)
        let remaining = clampedDuration - normalized
        if remaining <= 0.02 {
            return clampedDuration
        }
        return normalized
    }

    private var displayRemaining: Double {
        max(0, clampedDuration - displayElapsed)
    }

    private var progress: CGFloat {
        guard clampedDuration > 0 else { return 0 }
        return CGFloat(max(0, min(1, displayElapsed / clampedDuration)))
    }

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            let baseArtworkSide = min(screenWidth * 0.255, screenHeight * 0.46)
            let artworkScale: CGFloat = 1.14
            let artworkSide = baseArtworkSide * artworkScale
            let globalNowPlayingXOffset = screenWidth * 0.07
            let baseArtworkCenterX = (screenWidth * 0.68) + globalNowPlayingXOffset
            let baseArtworkCenterY = screenHeight * 0.70
            let artworkGrowth = artworkSide - baseArtworkSide
            let globalNowPlayingYOffset = -(screenHeight * 0.05)
            let metadataFollowsTransportYOffset = -(screenHeight * 0.036)
            // Grow from the bottom-right handle (top-left stays visually fixed).
            let rightArtworkCenterX = baseArtworkCenterX + (artworkGrowth * 0.56)
            let artworkCenterY = baseArtworkCenterY + (artworkGrowth * 0.86) + globalNowPlayingYOffset
            let layoutArtworkCenterX = layoutMode == .artworkRight ? rightArtworkCenterX : (screenWidth - rightArtworkCenterX)
            let mirroredArtworkRenderOffsetX = layoutMode == .artworkLeft ? (artworkSide * 0.12) : 0
            let renderedArtworkCenterX = layoutArtworkCenterX + mirroredArtworkRenderOffsetX
            let artworkLeftX = layoutArtworkCenterX - (artworkSide * 0.5)
            let artworkRightX = layoutArtworkCenterX + (artworkSide * 0.5)
            let metadataWidth = min(screenWidth * 0.23, 420)
            let metadataGap = screenWidth * 0.036
            let metadataRightX = artworkLeftX - metadataGap
            let metadataLeftX = artworkRightX + metadataGap
            let metadataCenterX = layoutMode == .artworkRight
                ? (metadataRightX - (metadataWidth * 0.5))
                : (metadataLeftX + (metadataWidth * 0.5))
            let metadataCenterY = artworkCenterY - (screenHeight * 0.045) + metadataFollowsTransportYOffset
            let metadataAlignment: Alignment = layoutMode == .artworkRight ? .trailing : .leading
            let titleFontSize = min(max(screenHeight * 0.050, 38), 56)
            let infoFontSize = min(max(screenHeight * 0.043, 28), 46)
            let positionFontSize = min(max(screenHeight * 0.026, 18), 28)
            let trackPositionVerticalPadding = min(max(screenHeight * 0.006, 4), 10)
            let transportWidth = min(max(screenWidth * 0.5, 720), 960)
            let leadingTimeWidth = min(max(transportWidth * 0.08, 50), 82)
            let trailingTimeWidth = min(max(transportWidth * 0.10, 66), 98)
            let transportGap: CGFloat = 1
            let barWidth = max(420, transportWidth - leadingTimeWidth - trailingTimeWidth - (transportGap * 2))
            let barHeight: CGFloat = 20
            let timeFontSize = min(max(screenHeight * 0.028, 22), 34)
            let shuffleFontSize = 25.0
            let transportCenterX = layoutMode == .artworkRight
                ? (metadataRightX - (transportWidth * 0.5))
                : (metadataLeftX + (transportWidth * 0.5))
            let transportCenterY = metadataCenterY + (screenHeight * 0.125)
            ZStack {
                VStack(alignment: layoutMode == .artworkRight ? .trailing : .leading, spacing: 2) {
                    Text(trackTitle).font(.firstRowBold(size: titleFontSize)).foregroundStyleCompat(.white).lineLimit(1).minimumScaleFactor(0.62)
                    Text(artistName).font(.firstRowRegular(size: infoFontSize)).foregroundStyleCompat(.white.opacity(0.88)).lineLimit(1).minimumScaleFactor(0.62)
                    Text(albumTitle).font(.firstRowRegular(size: infoFontSize)).foregroundStyleCompat(.white.opacity(0.76)).lineLimit(1).minimumScaleFactor(0.62)
                    if !trackPositionText.isEmpty {
                        Text(trackPositionText).font(.firstRowRegular(size: positionFontSize)).foregroundStyleCompat(.white.opacity(0.58)).lineLimit(1).padding(.top, trackPositionVerticalPadding)
                    }
                }.multilineTextAlignment(layoutMode == .artworkRight ? .trailing : .leading).frame(width: metadataWidth, alignment: metadataAlignment).position(x: metadataCenterX, y: metadataCenterY)
                HStack(alignment: .center, spacing: transportGap) {
                    Group {
                        if let leadingGlyphState {
                            MusicNowPlayingLeadingGlyphView(
                                state: leadingGlyphState,
                                fontSize: timeFontSize,
                            )
                        } else {
                            Text(formatTime(displayElapsed)).font(.firstRowBold(size: timeFontSize)).foregroundStyleCompat(.white.opacity(0.95)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }.frame(width: leadingTimeWidth, height: barHeight, alignment: .leading).overlay(
                        Image(systemName: "shuffle").font(.system(size: shuffleFontSize, weight: .regular)).foregroundStyleCompat(.white.opacity(0.56)).shadow(color: .white.opacity(0.14), radius: 0.8).offset(y: -(barHeight * 2.2)).opacity(showsShuffleGlyph && layoutMode == .artworkRight ? 1 : 0),
                        alignment: .topLeading,
                    )
                    ZStack(alignment: .leading) {
                        Rectangle().stroke(Color.white.opacity(0.82), lineWidth: 2.4).frame(height: barHeight)
                        Rectangle().fill(Color.white.opacity(0.5)).frame(width: max(0, barWidth * progress), height: barHeight)
                        let diamondSize: CGFloat = 8
                        let diamondCenterX = max(
                            diamondSize * 0.5,
                            min(barWidth - (diamondSize * 0.5), progress * barWidth),
                        )
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous).fill(Color.white).frame(width: diamondSize, height: diamondSize).rotationEffect(.degrees(45)).offset(x: diamondCenterX - (diamondSize * 0.5))
                    }.frame(width: barWidth, height: barHeight)
                    Text("-\(formatTime(displayRemaining))").font(.firstRowBold(size: timeFontSize)).foregroundStyleCompat(.white.opacity(0.95)).lineLimit(1).minimumScaleFactor(0.8).frame(width: trailingTimeWidth, height: barHeight, alignment: .trailing).overlay(
                        Image(systemName: "shuffle").font(.system(size: shuffleFontSize, weight: .regular)).foregroundStyleCompat(.white.opacity(0.56)).shadow(color: .white.opacity(0.14), radius: 0.8).offset(y: -(barHeight * 2.2)).opacity(showsShuffleGlyph && layoutMode == .artworkLeft ? 1 : 0),
                        alignment: .topTrailing,
                    )
                }.frame(width: transportWidth).position(x: transportCenterX, y: transportCenterY)
                MusicNowPlayingArtworkPreview(
                    image: artworkImage,
                    side: artworkSide,
                    mirrored: layoutMode == .artworkLeft,
                ).position(x: renderedArtworkCenterX, y: artworkCenterY)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        formatfirstRowPlaybackTime(seconds)
    }
}

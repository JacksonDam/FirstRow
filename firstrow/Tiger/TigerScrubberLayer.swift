import QuartzCore

/// How far through a song or a movie is: the time gone, a track with a diamond on it, and
/// the time left, along the foot of the screen.
@MainActor
final class TigerScrubberLayer {
    let layer = SceneLayer()
    private let elapsed = SceneLayer()
    private let remaining = SceneLayer()
    private let track = SceneShapeLayer()
    private let diamond = StillLayer()

    static let barHeight: CGFloat = 72
    /// How far the track's middle is above the foot of the screen.
    static let rise: CGFloat = 80

    init() {
        track.fillColor = CGColor(gray: 0, alpha: 0.25)
        track.strokeColor = CGColor(gray: 1, alpha: 0.82)
        track.lineWidth = 6
        diamond.backgroundColor = CGColor(gray: 1, alpha: 1)
        diamond.cornerRadius = 4
        for part in [elapsed, track, diamond, remaining] {
            layer.addSublayer(part)
        }
    }

    /// `progress` nil leaves the diamond out (nothing to show a place in yet); `remainingSeconds`
    /// nil leaves out the time left.
    func update(elapsedSeconds: Double, remainingSeconds: Double?, progress: CGFloat?, size: CGSize, scale: CGFloat) {
        let width = size.width, height = size.height
        let timeSize = min(max(height * 0.038, 28), 46)
        let diamondSide: CGFloat = 40
        let leadingTimeWidth = max(80, width * 0.068)
        let trailingTimeWidth = max(90, width * 0.077)
        let barWidth = max(200, width - 18 - leadingTimeWidth - 18 - 24 - trailingTimeWidth - 24)
        let barLeft = 18 + leadingTimeWidth + 18
        let middle = height - Self.rise
        withoutLayerActions {
            layer.place(CGRect(origin: .zero, size: size))
            let ink = RGBA(white: 1, alpha: 0.95)
            let elapsedGraphic = TextRenderer.render(TextSpec(text: Self.padded(elapsedSeconds), fontName: firstRowBoldFontName, size: timeSize, color: ink, shadows: TigerTheme.textShadow), scale: scale)
            elapsed.show(elapsedGraphic, at: CGPoint(x: 18, y: (middle - elapsedGraphic.size.height * 0.5).rounded()))
            remaining.isHidden = remainingSeconds == nil
            if let remainingSeconds {
                let graphic = TextRenderer.render(TextSpec(text: "-" + Self.padded(remainingSeconds), fontName: firstRowBoldFontName, size: timeSize, color: ink, shadows: TigerTheme.textShadow), scale: scale)
                remaining.show(graphic, at: CGPoint(x: (width - 24 - graphic.size.width).rounded(), y: (middle - graphic.size.height * 0.5).rounded()))
            }
            let barFrame = CGRect(x: barLeft, y: middle - Self.barHeight * 0.5, width: barWidth, height: Self.barHeight)
            track.place(barFrame)
            track.path = CGPath(roundedRect: CGRect(origin: .zero, size: barFrame.size), cornerWidth: Self.barHeight * 0.5, cornerHeight: Self.barHeight * 0.5, transform: nil)
            diamond.isHidden = progress == nil
            if let progress {
                let low = diamondSide * 0.5 + 16, high = barWidth - diamondSide * 0.5 - 16
                diamond.bounds = CGRect(x: 0, y: 0, width: diamondSide, height: diamondSide)
                diamond.position = CGPoint(x: barLeft + low + (high - low) * min(1, max(0, progress)), y: middle)
                diamond.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
            }
        }
    }

    /// Minutes and seconds, the minutes always two figures.
    static func padded(_ seconds: Double) -> String {
        let plain = formatfirstRowPlaybackTime(seconds)
        let parts = plain.components(separatedBy: ":")
        return parts.count == 2 && parts[0].count == 1 ? "0" + plain : plain
    }
}

/// What shows over a movie when it is paused, moved through or just started: the scrubber,
/// and over its middle what the movie is doing.
@MainActor
final class TigerMovieControlsLayer {
    let layer = SceneLayer()
    private let scrubber = TigerScrubberLayer()
    private let glyph = PlaybackGlyphLayer()

    init() {
        layer.addSublayer(glyph.layer)
        layer.addSublayer(scrubber.layer)
    }

    func update(glyphState: MoviePlaybackGlyphState, currentTime: Double, duration totalSeconds: Double, isLoading: Bool, loadingProgress: Double, size: CGSize, scale: CGFloat) {
        let hasDuration = totalSeconds.isFinite && totalSeconds > 0.001
        let seconds = max(0, currentTime.isFinite ? currentTime : 0)
        let duration = max(0, totalSeconds.isFinite ? totalSeconds : 0)
        let clamped = duration > 0 ? min(seconds, duration) : seconds
        let shownElapsed = duration > 0 && duration - clamped <= 0.02 ? duration : clamped
        let progress = isLoading ? max(0, min(1, loadingProgress)) : (duration > 0 ? min(1, max(0, shownElapsed / duration)) : 0)
        scrubber.update(
            elapsedSeconds: shownElapsed,
            remainingSeconds: hasDuration ? max(0, duration - shownElapsed) : nil,
            progress: hasDuration && !isLoading ? CGFloat(progress) : nil,
            size: size,
            scale: scale,
        )
        let glow = [TextShadow(color: RGBA(white: 1, alpha: 0.45), radius: 1.8), TextShadow(color: RGBA(white: 1, alpha: 0.2), radius: 3.2)]
        withoutLayerActions {
            layer.place(CGRect(origin: .zero, size: size))
            glyph.update(glyphState, pointSize: 23, shadows: glow, scale: scale, showsPlayGlyph: true)
            let centerY = size.height - TigerScrubberLayer.rise - TigerScrubberLayer.barHeight * 0.5 - 14 - 25
            glyph.layer.frame = CGRect(
                x: ((size.width - glyph.size.width) * 0.5).rounded(),
                y: (centerY - glyph.size.height * 0.5).rounded(),
                width: glyph.size.width,
                height: glyph.size.height,
            )
        }
    }
}

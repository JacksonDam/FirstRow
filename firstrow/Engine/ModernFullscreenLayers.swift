import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

// The modern look's playback screens: Now Playing and the movie transport bar.

/// Now Playing in the modern look: the artwork large on the left over a blurred copy of it,
/// the song's details and a thin progress bar on the right. Songs crossfade as they change.
final class ModernNowPlayingSceneLayer: FullscreenContent {
    private let backdrop = SceneLayer()
    private let shade = SceneGradientLayer()
    private let incoming = ModernNowPlayingPanelLayer()
    private let outgoing = ModernNowPlayingPanelLayer()
    private var backdropSource: NSImage?
    private var backdropMissing = true

    override init() {
        super.init()
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.magnificationFilter = .linear
        shade.colors = [CGColor(gray: 0, alpha: 0.15), CGColor(gray: 0, alpha: 0.55)]
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        for sublayer in [backdrop, shade, outgoing.layer, incoming.layer] {
            layer.addSublayer(sublayer)
        }
    }

    /// Where the progress bar is, in canvas points (for pointing at it).
    var progressBarFrame: CGRect { incoming.barFrame }

    override func update(menu: MenuView, scene _: FullscreenScenePresentation, pass: RenderPass, size: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        backdrop.frame = bounds
        shade.frame = bounds
        let snapshot = menu.currentMusicNowPlayingSnapshot
        if snapshot.artworkImage !== backdropSource || backdropMissing {
            backdropSource = snapshot.artworkImage
            let blurred = snapshot.artworkImage.flatMap { ModernBackgroundLayer.blurredAmbient($0) }
            backdropMissing = blurred == nil
            if backdrop.contents != nil {
                backdrop.removeAnimation(forKey: "contents")
                let fade = CABasicAnimation(keyPath: "contents")
                fade.duration = 0.8
                fade.fromValue = backdrop.contents
                fade.toValue = blurred
                backdrop.add(fade, forKey: "contents")
            }
            backdrop.contents = blurred
        }

        let hasTransition = menu.musicSongTransitionSnapshot != nil
        let incomingProgress = min(max(menu.musicSongTransitionIncomingProgress, 0), 1)
        let outgoingProgress = min(max(menu.musicSongTransitionOutgoingOpacityProgress, 0), 1)
        let direction: CGFloat = menu.musicSongTransitionDirection > 0 ? 1 : -1

        incoming.layer.frame = bounds
        incoming.update(snapshot, size: size, scale: scale)
        let inShift = hasTransition ? 60 * direction * (1 - incomingProgress) : 0
        incoming.layer.setTransform(CATransform3DMakeTranslation(inShift, 0, 0), pass.animation)
        incoming.layer.setOpacity(hasTransition ? Double(incomingProgress) : 1, pass.animation)

        if let previous = menu.musicSongTransitionSnapshot {
            outgoing.layer.isHidden = false
            outgoing.layer.frame = bounds
            outgoing.update(previous, size: size, scale: scale)
            outgoing.layer.setTransform(CATransform3DMakeTranslation(-60 * direction * outgoingProgress, 0, 0), pass.animation)
            outgoing.layer.setOpacity(Double(1 - outgoingProgress), pass.animation)
        } else {
            outgoing.layer.isHidden = true
            outgoing.layer.removeAllAnimations()
            outgoing.layer.transform = CATransform3DIdentity
            outgoing.layer.opacity = 1
        }
    }
}

@MainActor
final class ModernNowPlayingPanelLayer {
    let layer = SceneLayer()
    private let artworkShadow = SceneLayer()
    private let artwork = SceneLayer()
    private let title = SceneLayer()
    private let artist = SceneLayer()
    private let album = SceneLayer()
    private let position = SceneLayer()
    private let shuffle = SceneLayer()
    private let track = SceneLayer()
    private let fill = SceneLayer()
    private let elapsed = SceneLayer()
    private let remaining = SceneLayer()
    private let glyph = PlaybackGlyphLayer()
    private(set) var barFrame: CGRect = .zero

    init() {
        artworkShadow.shadowColor = CGColor(gray: 0, alpha: 1)
        artworkShadow.shadowOpacity = 0.6
        artworkShadow.shadowRadius = 30
        artworkShadow.shadowOffset = CGSize(width: 0, height: 20)
        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.backgroundColor = CGColor(gray: 0.15, alpha: 1)
        track.backgroundColor = CGColor(gray: 1, alpha: 0.25)
        track.masksToBounds = true
        fill.backgroundColor = CGColor(gray: 1, alpha: 0.95)
        track.addSublayer(fill)
        for sublayer in [artworkShadow, artwork, title, artist, album, position, shuffle, track, elapsed, remaining, glyph.layer] {
            layer.addSublayer(sublayer)
        }
    }

    func update(_ snapshot: MenuView.MusicNowPlayingSnapshot, size: CGSize, scale: CGFloat) {
        let width = size.width
        let height = size.height
        let side = min(height * 0.56, width * 0.33)
        let artCenter = CGPoint(x: width * 0.31, y: height * 0.48)
        let art = CGRect(x: artCenter.x - side / 2, y: artCenter.y - side / 2, width: side, height: side)
        let radius = side * 0.035
        artworkShadow.frame = art
        artworkShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: art.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        artwork.frame = art
        artwork.cornerRadius = radius
        artwork.contents = LayerImageCache.cgImage(for: snapshot.artworkImage)

        let columnLeft = art.maxX + width * 0.055
        let columnWidth = max(300, width * 0.92 - columnLeft)
        let titleGraphic = TextRenderer.render(TextSpec(text: snapshot.trackTitle, fontName: ModernTheme.boldFontName, size: 54, color: ModernTheme.text, maxWidth: columnWidth, minimumScaleFactor: 0.7), scale: scale)
        let artistGraphic = TextRenderer.render(TextSpec(text: snapshot.artistName, fontName: ModernTheme.mediumFontName, size: 40, color: RGBA(white: 1, alpha: 0.72), maxWidth: columnWidth, minimumScaleFactor: 0.75), scale: scale)
        let albumGraphic = TextRenderer.render(TextSpec(text: snapshot.albumTitle, fontName: ModernTheme.regularFontName, size: 34, color: RGBA(white: 1, alpha: 0.5), maxWidth: columnWidth, minimumScaleFactor: 0.75), scale: scale)
        let positionGraphic = TextRenderer.render(TextSpec(text: snapshot.trackPositionText, fontName: ModernTheme.regularFontName, size: 26, color: RGBA(white: 1, alpha: 0.45), maxWidth: columnWidth), scale: scale)
        let barHeight: CGFloat = 10
        let timesHeight: CGFloat = 40
        let blockHeight = titleGraphic.size.height + 6 + artistGraphic.size.height + 2 + albumGraphic.size.height + 18 + positionGraphic.size.height + 56 + barHeight + 12 + timesHeight
        var y = artCenter.y - blockHeight / 2
        title.show(titleGraphic, at: CGPoint(x: columnLeft, y: y))
        y += titleGraphic.size.height + 6
        artist.show(artistGraphic, at: CGPoint(x: columnLeft, y: y))
        y += artistGraphic.size.height + 2
        album.show(albumGraphic, at: CGPoint(x: columnLeft, y: y))
        y += albumGraphic.size.height + 18
        position.isHidden = snapshot.trackPositionText.isEmpty
        position.show(positionGraphic, at: CGPoint(x: columnLeft, y: y))
        shuffle.isHidden = !snapshot.showsShuffleGlyph
        if snapshot.showsShuffleGlyph {
            let graphic = SymbolRenderer.render("shuffle", pointSize: 24, weight: .semibold, color: RGBA(white: 1, alpha: 0.5), scale: scale)
            let x = snapshot.trackPositionText.isEmpty ? columnLeft : columnLeft + positionGraphic.size.width + 16
            shuffle.show(graphic, at: CGPoint(x: x, y: y + (positionGraphic.size.height - graphic.size.height) / 2))
        }
        y += positionGraphic.size.height + 56

        // Progress: a thin capsule with the times under its ends and the play state between.
        let duration = max(0, snapshot.durationSeconds.isFinite ? snapshot.durationSeconds : 0)
        let elapsedSeconds = min(max(0, snapshot.elapsedSeconds.isFinite ? snapshot.elapsedSeconds : 0), duration > 0 ? duration : .infinity)
        let progress = duration > 0 ? CGFloat(elapsedSeconds / duration) : 0
        barFrame = CGRect(x: columnLeft, y: y, width: columnWidth, height: barHeight)
        track.frame = barFrame
        track.cornerRadius = barHeight / 2
        fill.frame = CGRect(x: 0, y: 0, width: columnWidth * max(0, min(1, progress)), height: barHeight)
        y += barHeight + 12
        let timeColor = RGBA(white: 1, alpha: 0.6)
        let elapsedGraphic = TextRenderer.render(TextSpec(text: formatfirstRowPlaybackTime(elapsedSeconds), fontName: ModernTheme.mediumFontName, size: 26, color: timeColor), scale: scale)
        elapsed.show(elapsedGraphic, at: CGPoint(x: columnLeft, y: y))
        let remainingGraphic = TextRenderer.render(TextSpec(text: "-" + formatfirstRowPlaybackTime(max(0, duration - elapsedSeconds)), fontName: ModernTheme.mediumFontName, size: 26, color: timeColor), scale: scale)
        remaining.show(remainingGraphic, at: CGPoint(x: columnLeft + columnWidth - remainingGraphic.size.width, y: y))
        if let state = snapshot.leadingGlyphState {
            glyph.layer.isHidden = false
            glyph.update(state, pointSize: 26, shadows: [], scale: scale)
            glyph.layer.frame = CGRect(x: columnLeft + (columnWidth - glyph.size.width) / 2, y: y + (elapsedGraphic.size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
        } else {
            glyph.layer.isHidden = true
        }
    }
}

/// The movie transport in the modern look: a dark fade along the bottom, a thin progress
/// capsule with a knob, the times under its ends and the play state above it.
@MainActor
final class ModernMovieControlsLayer {
    let layer = SceneLayer()
    private let scrim = SceneGradientLayer()
    private let track = SceneLayer()
    private let fill = SceneLayer()
    private let knob = SceneLayer()
    private let glyph = PlaybackGlyphLayer()
    private let elapsed = SceneLayer()
    private let remaining = SceneLayer()
    /// Where the progress bar is, in canvas points.
    private(set) var barFrame: CGRect = .zero

    init() {
        scrim.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.7)]
        scrim.startPoint = CGPoint(x: 0.5, y: 0)
        scrim.endPoint = CGPoint(x: 0.5, y: 1)
        track.backgroundColor = CGColor(gray: 1, alpha: 0.3)
        track.masksToBounds = true
        fill.backgroundColor = CGColor(gray: 1, alpha: 0.95)
        track.addSublayer(fill)
        knob.backgroundColor = CGColor(gray: 1, alpha: 1)
        knob.shadowColor = CGColor(gray: 0, alpha: 1)
        knob.shadowOpacity = 0.4
        knob.shadowRadius = 6
        for sublayer in [scrim, track, knob, glyph.layer, elapsed, remaining] {
            layer.addSublayer(sublayer)
        }
        layer.isHidden = true
    }

    func update(glyphState: MoviePlaybackGlyphState, currentTime seconds: Double, duration totalSeconds: Double, isLoading: Bool, loadingProgress: Double, size: CGSize, scale: CGFloat) {
        let margin = max(90, size.width * 0.065)
        let barHeight: CGFloat = 10
        let barY = size.height - 132
        scrim.frame = CGRect(x: 0, y: size.height - 360, width: size.width, height: 360)
        barFrame = CGRect(x: margin, y: barY, width: size.width - margin * 2, height: barHeight)
        track.frame = barFrame
        track.cornerRadius = barHeight / 2
        let hasDuration = totalSeconds.isFinite && totalSeconds > 0.001
        let progress = isLoading ? max(0, min(1, loadingProgress)) : (hasDuration ? max(0, min(1, seconds / totalSeconds)) : 0)
        fill.frame = CGRect(x: 0, y: 0, width: barFrame.width * CGFloat(progress), height: barHeight)
        let knobSide: CGFloat = 24
        knob.isHidden = isLoading
        knob.frame = CGRect(x: barFrame.minX + barFrame.width * CGFloat(progress) - knobSide / 2, y: barFrame.midY - knobSide / 2, width: knobSide, height: knobSide)
        knob.cornerRadius = knobSide / 2

        let timeColor = RGBA(white: 1, alpha: 0.85)
        let timeY = barFrame.maxY + 16
        let elapsedGraphic = TextRenderer.render(TextSpec(text: isLoading ? "" : formatfirstRowPlaybackTime(seconds), fontName: ModernTheme.mediumFontName, size: 28, color: timeColor), scale: scale)
        elapsed.show(elapsedGraphic, at: CGPoint(x: barFrame.minX, y: timeY))
        let remainingText = isLoading || !hasDuration ? "" : "-" + formatfirstRowPlaybackTime(max(0, totalSeconds - seconds))
        let remainingGraphic = TextRenderer.render(TextSpec(text: remainingText, fontName: ModernTheme.mediumFontName, size: 28, color: timeColor), scale: scale)
        remaining.show(remainingGraphic, at: CGPoint(x: barFrame.maxX - remainingGraphic.size.width, y: timeY))

        glyph.update(glyphState, pointSize: 34, shadows: [TextShadow(color: RGBA(white: 0, alpha: 0.5), radius: 4)], scale: scale, showsPlayGlyph: true)
        glyph.layer.frame = CGRect(x: barFrame.minX, y: barFrame.minY - 30 - glyph.size.height, width: glyph.size.width, height: glyph.size.height)
    }
}

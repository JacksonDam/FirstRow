import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A screen-shaped canvas 1080 pt tall and at least 1440 wide, scaled to fill the screen.
/// On a folding screen standing upright it is 1080 wide instead, as the menus' scene is, so the
/// parts above and below the fold are the stance's own.
struct FullscreenCanvas {
    let size: CGSize
    let scale: CGFloat
    let upright: UprightStance?

    init(screenSize: CGSize, upright: UprightStance? = nil) {
        guard screenSize.width > 0, screenSize.height > 0 else {
            size = screenSize
            scale = 1
            self.upright = nil
            return
        }
        self.upright = upright
        if upright != nil {
            scale = screenSize.width / UprightStance.sceneWidth
        } else {
            scale = min(screenSize.height / 1080, screenSize.width / 1440)
        }
        size = CGSize(width: screenSize.width / scale, height: screenSize.height / scale)
    }

    /// A canvas rectangle in the screen's own points.
    func window(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// A canvas point in the screen's own points.
    func window(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// A point of the screen in canvas points.
    func point(_ windowPoint: CGPoint) -> CGPoint {
        let scale = max(scale, 0.0001)
        return CGPoint(x: windowPoint.x / scale, y: windowPoint.y / scale)
    }

    /// Spreads `layer` (anchored at its top left) over the screen in canvas points.
    func apply(to layer: CALayer) {
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = .zero
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    /// Pixels per canvas point, rounded up a little so cached text is shared between passes.
    func pixelScale(backingScale: CGFloat) -> CGFloat {
        max(1, (scale * backingScale * 100).rounded(.up) / 100)
    }
}

/// The scene shown over the whole screen: Now Playing, the screen saver, a photo slideshow,
/// an error or a loading message.
@MainActor
final class FullscreenSceneLayer {
    /// The scene's black backdrop: it fades but never scales, so a scene coming or going in the
    /// modern look has no edges of its own against the menu behind.
    let layer = SceneLayer()
    /// What scales as the modern look moves to and from the scene.
    private let foreground = SceneLayer()
    private var contentKey: String?
    private var content: FullscreenContent?
    /// Now Playing's list and lyrics, over its right side.
    let queue = NowPlayingQueueLayer()
    let lyrics = NowPlayingLyricsLayer()

    init() {
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.opacity = 0
        layer.isHidden = true
        layer.masksToBounds = true
        layer.addSublayer(foreground)
        foreground.addSublayer(lyrics.layer)
        foreground.addSublayer(queue.layer)
    }

    func tearDown() {
        content?.tearDown()
        content = nil
        contentKey = nil
    }

    /// Now Playing's progress bar in canvas points, while it shows one song at rest.
    var nowPlayingProgressBar: CGRect? {
        (content as? NowPlayingSceneLayer)?.progressBar ?? (content as? ModernNowPlayingSceneLayer)?.progressBar
    }

    /// Where that bar sits, in canvas points, songs changing over or not (the new song's): for
    /// the on-screen buttons under it.
    var nowPlayingBarPlace: CGRect? {
        (content as? NowPlayingSceneLayer)?.barPlace ?? (content as? ModernNowPlayingSceneLayer)?.barPlace
    }

    /// How far along the song's details are from where they rest, in canvas points: the buttons
    /// under the bar go with them.
    var nowPlayingDetailsSlide: CGFloat {
        (content as? NowPlayingSceneLayer)?.detailsSlide ?? (content as? ModernNowPlayingSceneLayer)?.detailsSlide ?? 0
    }

    /// How large the song's details show against their full size (smaller with the list or the
    /// words out): the buttons under the bar keep that much closer to it.
    var nowPlayingDetailsScale: CGFloat {
        (content as? NowPlayingSceneLayer)?.detailsScale ?? (content as? ModernNowPlayingSceneLayer)?.detailsScale ?? 1
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat) {
        layer.place(bounds)
        foreground.place(CGRect(origin: .zero, size: bounds.size))
        let depth = ModernTheme.isActive ? menu.fullscreenSceneScale : 1
        foreground.setTransform(MenuSceneRenderer.scale(depth, about: CGPoint(x: bounds.midX, y: bounds.midY)), pass.animation)
        guard let scene = menu.activeFullscreenScene else {
            if content != nil {
                content?.tearDown()
                content?.layer.removeFromSuperlayer()
                content = nil
                contentKey = nil
            }
            layer.isHidden = true
            layer.opacity = 0
            return
        }
        layer.isHidden = false
        let key = scene.key == menu.featureErrorFullscreenKey ? scene.id : scene.key
        if key != contentKey {
            content?.tearDown()
            content?.layer.removeFromSuperlayer()
            content = Self.makeContent(for: scene, menu: menu)
            contentKey = key
            if let content {
                // A scene with a backdrop of its own scales its foreground itself.
                if content.scalesItsOwnForeground {
                    layer.insertSublayer(content.layer, below: foreground)
                } else {
                    foreground.insertSublayer(content.layer, below: lyrics.layer)
                }
            }
        }
        let canvas = FullscreenCanvas(screenSize: bounds.size, upright: menu.upright)
        if let content {
            if let upright = canvas.upright, upright.isBent, content.keepsAboveTheFold {
                // A message has the part above the fold for its screen, while the screen is
                // bent there (flat, it has the middle of the whole of it).
                let pane = upright.upperPane
                content.layer.bounds = CGRect(origin: .zero, size: pane.size)
                content.layer.position = canvas.window(pane).origin
                content.layer.transform = CATransform3DMakeScale(canvas.scale, canvas.scale, 1)
                content.update(menu: menu, scene: scene, pass: pass, size: pane.size, scale: canvas.pixelScale(backingScale: scale))
            } else {
                canvas.apply(to: content.layer)
                content.update(menu: menu, scene: scene, pass: pass, size: canvas.size, scale: canvas.pixelScale(backingScale: scale))
            }
        }
        let isNowPlaying = scene.key == menu.musicNowPlayingFullscreenKey
        queue.layer.isHidden = !isNowPlaying
        if isNowPlaying {
            canvas.apply(to: queue.layer)
            queue.update(menu: menu, pass: pass, size: canvas.size, scale: canvas.pixelScale(backingScale: scale))
            canvas.apply(to: lyrics.layer)
            lyrics.update(menu: menu, pass: pass, size: canvas.size, scale: canvas.pixelScale(backingScale: scale))
        } else {
            lyrics.layer.isHidden = true
        }
        layer.setOpacity(menu.fullscreenSceneOpacity, pass.animation)
    }

    private static func makeContent(for scene: FullscreenScenePresentation, menu: MenuView) -> FullscreenContent {
        switch scene.key {
        case menu.musicNowPlayingFullscreenKey: ModernTheme.isActive ? ModernNowPlayingSceneLayer() : NowPlayingSceneLayer()
        case menu.screenSaverFullscreenKey: ScreenSaverSceneLayer()
        case menu.featureErrorFullscreenKey: FeatureErrorSceneLayer()
        case menu.photoSlideshowFullscreenKey: PhotoSlideshowSceneLayer()
        default: FullscreenContent()
        }
    }
}

@MainActor
class FullscreenContent {
    let layer = SceneLayer()
    /// Keeps its own full-screen backdrop still while the rest of it scales in the modern look's
    /// moves (reading `fullscreenSceneScale` itself), rather than being scaled whole.
    var scalesItsOwnForeground: Bool { false }
    /// Laid out for a screen of its own that a fold mustn't cross: standing upright it gets the
    /// part above the fold.
    var keepsAboveTheFold: Bool { false }
    func update(menu _: MenuView, scene _: FullscreenScenePresentation, pass _: RenderPass, size _: CGSize, scale _: CGFloat) {}
    func tearDown() {}
}

// MARK: - Now Playing

/// Now Playing for music and podcasts: the current song's panel, the previous one zooming
/// away while songs change, and the whole thing flipping round every so often.
final class NowPlayingSceneLayer: FullscreenContent {
    /// Moves aside for the list or the lyrics.
    private let stage = SceneLayer()
    private var shift: (dx: CGFloat, scale: CGFloat) = (0, 1)
    private var size: CGSize = .zero
    private let flip = CALayer()
    private let incoming = NowPlayingPanelLayer()
    private let outgoing = NowPlayingPanelLayer()
    private var isSwitchingSong = false

    /// The progress bar in canvas points, or nil while songs change over.
    var progressBar: CGRect? {
        isSwitchingSong ? nil : barPlace
    }

    /// Where the progress bar sits in canvas points, songs changing over or not.
    var barPlace: CGRect? {
        incoming.progressBar.map { NowPlayingSideLayout.map($0, shift, size: size) }
    }

    var detailsScale: CGFloat { shift.scale * incoming.detailsScale }

    /// How far along the details are from where they rest, in canvas points (standing upright,
    /// while the list or the words come out: see `NowPlayingSideLayout.detailsPlace`).
    var detailsSlide: CGFloat { incoming.detailsSlide }

    override init() {
        super.init()
        flip.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        layer.addSublayer(stage)
        stage.addSublayer(flip)
        incoming.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        outgoing.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        flip.addSublayer(incoming.layer)
        flip.addSublayer(outgoing.layer)
    }

    override func update(menu: MenuView, scene _: FullscreenScenePresentation, pass: RenderPass, size: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        self.size = size
        stage.place(bounds)
        shift = NowPlayingSideLayout.shift(menu: menu, size: size)
        stage.setTransform(NowPlayingSideLayout.transform(shift, size: size), pass.animation)
        flip.bounds = bounds
        flip.position = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        flip.setTransform(yawTransform(degrees: menu.musicNowPlayingFlipRotationDegrees, perspective: 0.9, viewSize: size), pass.animation)

        let hasTransition = menu.musicSongTransitionSnapshot != nil
        isSwitchingSong = hasTransition
        let incomingStart: CGFloat = menu.musicSongTransitionDirection > 0 ? 0.25 : 6
        let outgoingEnd: CGFloat = menu.musicSongTransitionDirection > 0 ? 6 : 0.25
        let outgoingProgress = min(max(menu.musicSongTransitionOutgoingProgress, 0), 1)
        let outgoingOpacityProgress = min(max(menu.musicSongTransitionOutgoingOpacityProgress, 0), 1)
        let incomingProgress = min(max(menu.musicSongTransitionIncomingProgress, 0), 1)
        let incomingScale = hasTransition ? incomingStart + (1 - incomingStart) * incomingProgress : 1
        let outgoingScale = hasTransition ? 1 + (outgoingEnd - 1) * outgoingProgress : 1
        let mirrored = menu.musicNowPlayingUsesAlternateLayout

        let tuck = NowPlayingSideLayout.tuck(menu: menu)
        incoming.layer.bounds = bounds
        incoming.layer.position = flip.position
        incoming.update(menu.currentMusicNowPlayingSnapshot, mirrored: mirrored, size: size, scale: scale, upright: menu.upright, tuck: tuck, animation: pass.animation)
        incoming.layer.setTransform(CATransform3DMakeScale(incomingScale, incomingScale, 1), pass.animation)
        incoming.layer.setOpacity(hasTransition ? Double(incomingProgress) : 1, pass.animation)

        if let snapshot = menu.musicSongTransitionSnapshot {
            // Just brought back, it is laid out where the song is now, not moved there.
            let returning = outgoing.layer.isHidden
            outgoing.layer.isHidden = false
            outgoing.layer.bounds = bounds
            outgoing.layer.position = flip.position
            outgoing.update(snapshot, mirrored: mirrored, size: size, scale: scale, upright: menu.upright, tuck: tuck, animation: returning ? nil : pass.animation)
            outgoing.layer.setTransform(CATransform3DMakeScale(outgoingScale, outgoingScale, 1), pass.animation)
            outgoing.layer.setOpacity(Double(1 - outgoingOpacityProgress), pass.animation)
        } else {
            outgoing.layer.isHidden = true
            outgoing.layer.removeAllAnimations()
            outgoing.layer.transform = CATransform3DIdentity
            outgoing.layer.opacity = 1
        }
    }
}

/// One song's Now Playing layout: title, artist and album beside the artwork, and the
/// progress bar below them.
@MainActor
final class NowPlayingPanelLayer {
    let layer = SceneLayer()
    private let title = SceneLayer()
    private let artist = SceneLayer()
    private let album = SceneLayer()
    private let position = SceneLayer()
    private let leading = SceneLayer()
    private let leadingGlyph = PlaybackGlyphLayer()
    private let trailing = SceneLayer()
    private let shuffle = SceneLayer()
    private let barFrame = SceneShapeLayer()
    private let barFill = SceneLayer()
    private let diamond = SceneLayer()
    private let artwork = NowPlayingArtworkLayer()
    /// Everything but the artwork: standing upright it tucks up beside the cover, smaller, when
    /// the list or the words come out under the fold.
    private let details = SceneLayer()
    /// The progress bar where it shows, in the panel's points.
    private(set) var progressBar: CGRect?
    /// How large the details show against their full size.
    private(set) var detailsScale: CGFloat = 1
    private(set) var detailsSlide: CGFloat = 0
    private var lastMirrored: Bool?

    init() {
        for sublayer in [title, artist, album, position, leading, leadingGlyph.layer, trailing, shuffle, barFrame, barFill, diamond] {
            details.addSublayer(sublayer)
        }
        layer.addSublayer(details)
        layer.addSublayer(artwork.layer)
        barFrame.fillColor = nil
        barFrame.strokeColor = CGColor(gray: 1, alpha: 0.82)
        barFrame.lineWidth = 2.4
        barFill.backgroundColor = CGColor(gray: 1, alpha: 0.5)
        diamond.backgroundColor = CGColor(gray: 1, alpha: 1)
        diamond.cornerRadius = 1.2
        diamond.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        diamond.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
    }

    /// `upright`: standing upright, the cover goes above the fold and the details under it;
    /// `tuck` (0 to 1) brings the details up beside the cover, both smaller, moving with `animation`.
    func update(_ snapshot: MenuView.MusicNowPlayingSnapshot, mirrored: Bool, size: CGSize, scale: CGFloat, upright: UprightStance? = nil, tuck: CGFloat = 0, animation: Animation? = nil) {
        let width = size.width
        let height = size.height
        details.place(CGRect(origin: .zero, size: size))
        // Standing upright, the artwork and the lettering are the size they are lying down.
        let across = upright == nil ? width : max(width, height)
        let down = upright == nil ? height : min(width, height)
        let baseArtworkSide = min(across * 0.255, down * 0.46)
        let artworkSide = baseArtworkSide * 1.14
        let baseArtworkCenterX = width * 0.68 + width * 0.07
        let artworkGrowth = artworkSide - baseArtworkSide
        let rightArtworkCenterX = baseArtworkCenterX + artworkGrowth * 0.56
        let artworkCenterY = height * 0.70 + artworkGrowth * 0.86 - height * 0.05
        let artworkCenterX = mirrored ? width - rightArtworkCenterX : rightArtworkCenterX
        let renderedArtworkCenterX = artworkCenterX + (mirrored ? artworkSide * 0.12 : 0)
        let artworkLeftX = artworkCenterX - artworkSide * 0.5
        let artworkRightX = artworkCenterX + artworkSide * 0.5
        var metadataWidth = min(width * 0.23, 420)
        let metadataGap = width * 0.036
        let metadataRightX = artworkLeftX - metadataGap
        let metadataLeftX = artworkRightX + metadataGap
        var metadataCenterX = mirrored ? metadataLeftX + metadataWidth * 0.5 : metadataRightX - metadataWidth * 0.5
        let metadataCenterY = artworkCenterY - height * 0.045 - height * 0.036
        let titleSize = min(max(down * 0.050, 38), 56)
        let infoSize = min(max(down * 0.043, 28), 46)
        let positionSize = min(max(down * 0.026, 18), 28)
        let positionPadding = min(max(down * 0.006, 4), 10)
        var transportWidth = min(max(width * 0.5, 720), 960)
        var transportCenterX = mirrored ? metadataLeftX + transportWidth * 0.5 : metadataRightX - transportWidth * 0.5
        var transportCenterY = metadataCenterY + height * 0.125
        // The song name gets twice the room before it is cut short.
        var titleWidth = metadataWidth * 2
        // Lined up on the artwork side.
        var alignment: TextAlignment = mirrored ? .leading : .trailing
        if let upright {
            // Standing upright: centred under the fold, over a bar most of the way across.
            metadataWidth = min(width - 180, 900)
            titleWidth = metadataWidth
            metadataCenterX = width / 2
            transportWidth = min(width - 120, 960)
            transportCenterX = width / 2
            transportCenterY = upright.lowerPane.midY + 56
            alignment = .center
        }
        let leadingTimeWidth = min(max(transportWidth * 0.08, 50), 82)
        let trailingTimeWidth = min(max(transportWidth * 0.10, 66), 98)
        let barWidth = max(420, transportWidth - leadingTimeWidth - trailingTimeWidth - 2)
        let barHeight: CGFloat = 20
        let timeSize = min(max(down * 0.028, 22), 34)
        // (Upright it is the bar itself that is centred under the words, not the bar and its times.)
        if upright != nil { transportCenterX += (trailingTimeWidth - leadingTimeWidth) * 0.5 }

        // Title, artist, album and position, stacked 2 points apart.
        let texts: [(SceneLayer, RenderedGraphic, CGFloat)] = {
            var result: [(SceneLayer, RenderedGraphic, CGFloat)] = [
                (title, TextRenderer.render(TextSpec(text: snapshot.trackTitle, fontName: firstRowBoldFontName, size: titleSize, maxWidth: titleWidth, minimumScaleFactor: 0.62), scale: scale), 0),
                (artist, TextRenderer.render(TextSpec(text: snapshot.artistName, fontName: firstRowRegularFontName, size: infoSize, color: RGBA(white: 1, alpha: 0.88), maxWidth: metadataWidth, minimumScaleFactor: 0.62), scale: scale), 0),
                (album, TextRenderer.render(TextSpec(text: snapshot.albumTitle, fontName: firstRowRegularFontName, size: infoSize, color: RGBA(white: 1, alpha: 0.76), maxWidth: metadataWidth, minimumScaleFactor: 0.62), scale: scale), 0),
            ]
            if !snapshot.trackPositionText.isEmpty {
                result.append((position, TextRenderer.render(TextSpec(text: snapshot.trackPositionText, fontName: firstRowRegularFontName, size: positionSize, color: RGBA(white: 1, alpha: 0.58), maxWidth: metadataWidth), scale: scale), positionPadding))
            }
            return result
        }()
        position.isHidden = snapshot.trackPositionText.isEmpty
        // An empty line still takes its height.
        func lineHeight(_ graphic: RenderedGraphic, _ fontName: String, _ size: CGFloat) -> CGFloat {
            graphic.image == nil ? FontMetrics.lineHeight(fontName: fontName, size: size) : graphic.size.height
        }
        let heights = [
            lineHeight(texts[0].1, firstRowBoldFontName, titleSize),
            lineHeight(texts[1].1, firstRowRegularFontName, infoSize),
            lineHeight(texts[2].1, firstRowRegularFontName, infoSize),
        ] + (texts.count > 3 ? [texts[3].1.size.height] : [])
        let blockHeight = heights.reduce(0, +) + CGFloat(heights.count - 1) * 2 + (texts.count > 3 ? positionPadding : 0)
        // Standing upright they end a little above the bar.
        var y = upright == nil ? metadataCenterY - blockHeight * 0.5 : transportCenterY - barHeight * 0.5 - 40 - blockHeight
        let blockLeft = metadataCenterX - metadataWidth * 0.5
        for (index, entry) in texts.enumerated() {
            y += entry.2
            let x: CGFloat = switch alignment {
            case .leading: blockLeft
            case .trailing: blockLeft + metadataWidth - entry.1.size.width
            case .center: blockLeft + (metadataWidth - entry.1.size.width) * 0.5
            }
            entry.0.show(entry.1, at: CGPoint(x: x, y: y + (heights[index] - entry.1.size.height) * 0.5))
            y += heights[index] + 2
        }

        // Progress: elapsed (or a playback glyph), the bar, and the time remaining.
        let duration = max(0, snapshot.durationSeconds.isFinite ? snapshot.durationSeconds : 0)
        let elapsed = max(0, snapshot.elapsedSeconds.isFinite ? snapshot.elapsedSeconds : 0)
        var displayElapsed = elapsed
        if duration > 0 {
            displayElapsed = min(max(elapsed, 0), duration)
            if duration - displayElapsed <= 0.02 { displayElapsed = duration }
        }
        let progress = duration > 0 ? CGFloat(max(0, min(1, displayElapsed / duration))) : 0
        let rowWidth = leadingTimeWidth + 1 + barWidth + 1 + trailingTimeWidth
        let rowLeft = transportCenterX - rowWidth * 0.5
        let rowTop = transportCenterY - barHeight * 0.5
        if let glyphState = snapshot.leadingGlyphState {
            leading.isHidden = true
            leadingGlyph.layer.isHidden = false
            leadingGlyph.update(glyphState, pointSize: timeSize * 0.92, shadows: [], scale: scale)
            leadingGlyph.layer.frame = CGRect(x: rowLeft, y: rowTop + (barHeight - leadingGlyph.size.height) * 0.5, width: leadingGlyph.size.width, height: leadingGlyph.size.height)
        } else {
            leadingGlyph.layer.isHidden = true
            leading.isHidden = false
            let graphic = TextRenderer.render(TextSpec(text: formatfirstRowPlaybackTime(displayElapsed), fontName: firstRowBoldFontName, size: timeSize, color: RGBA(white: 1, alpha: 0.95), maxWidth: leadingTimeWidth, minimumScaleFactor: 0.8), scale: scale)
            leading.show(graphic, at: CGPoint(x: rowLeft, y: rowTop + (barHeight - graphic.size.height) * 0.5))
        }
        let barLeft = rowLeft + leadingTimeWidth + 1
        let bar = CGRect(x: barLeft, y: rowTop, width: barWidth, height: barHeight)
        barFrame.frame = bar
        barFrame.path = CGPath(rect: CGRect(x: 0, y: 0, width: barWidth, height: barHeight), transform: nil)
        barFill.frame = CGRect(x: barLeft, y: rowTop, width: max(0, barWidth * progress), height: barHeight)
        let diamondSize: CGFloat = 8
        let diamondCenterX = max(diamondSize * 0.5, min(barWidth - diamondSize * 0.5, progress * barWidth))
        diamond.bounds = CGRect(x: 0, y: 0, width: diamondSize, height: diamondSize)
        diamond.position = CGPoint(x: barLeft + diamondCenterX, y: rowTop + barHeight * 0.5)
        let remaining = TextRenderer.render(TextSpec(text: formatfirstRowRemainingTime(duration: duration, elapsed: displayElapsed), fontName: firstRowBoldFontName, size: timeSize, color: RGBA(white: 1, alpha: 0.95), maxWidth: trailingTimeWidth, minimumScaleFactor: 0.8), scale: scale)
        let trailingRight = barLeft + barWidth + 1 + trailingTimeWidth
        trailing.show(remaining, at: CGPoint(x: trailingRight - remaining.size.width, y: rowTop + (barHeight - remaining.size.height) * 0.5))

        // Shuffle sign above the end of the bar on the artwork side.
        let shuffleGraphic = SymbolRenderer.render("shuffle", pointSize: 25, weight: .regular, color: RGBA(white: 1, alpha: 0.56), shadows: [TextShadow(color: RGBA(white: 1, alpha: 0.14), radius: 0.8)], scale: scale)
        shuffle.isHidden = !snapshot.showsShuffleGlyph
        let shuffleTop = rowTop - barHeight * 2.2
        shuffle.show(shuffleGraphic, at: CGPoint(x: mirrored ? trailingRight - shuffleGraphic.size.width : rowLeft, y: shuffleTop))

        artwork.update(image: snapshot.artworkImage, side: artworkSide, mirrored: mirrored)
        guard let upright else {
            artwork.layer.position = CGPoint(x: renderedArtworkCenterX - artworkSide * 1.12 * 0.5, y: artworkCenterY - artworkSide * 1.72 * 0.5)
            artwork.layer.setTransform(CATransform3DIdentity, nil)
            details.setTransform(CATransform3DIdentity, nil)
            progressBar = bar
            detailsScale = 1
            detailsSlide = 0
            lastMirrored = mirrored
            return
        }
        // Standing upright. The cover has the middle of the part above the fold, a little
        // larger, with room for its reflection; tucked, it is small at one side there (the side
        // it has lying down) and the details are beside it.
        typealias Place = NowPlayingSideLayout.Place
        let upper = upright.upperPane
        let large = min(upper.height * 0.70, width * 0.46)
        let small = min(330, upper.height * 0.5)
        let margin: CGFloat = 64
        let artMiddle = CGPoint(x: artworkSide * 0.5, y: artworkSide * 0.5)
        let coverPlace = Place.between(
            Place(anchor: artMiddle, scale: large / artworkSide, center: CGPoint(x: width / 2, y: upper.midY - large * 0.08)),
            Place(anchor: artMiddle, scale: small / artworkSide, center: CGPoint(x: mirrored ? margin + small / 2 : width - margin - small / 2, y: upper.midY - small * 0.08)),
            tuck,
        )
        // The room beside the small cover; the on-screen buttons go under the bar there.
        let room = width - margin - small - 40 - 40
        let barMiddle = CGPoint(x: bar.midX, y: bar.midY)
        // On their way there they go round, not across: off one edge and in from another.
        let (detailsPlace, slide) = NowPlayingSideLayout.detailsPlace(
            home: Place(anchor: barMiddle, scale: 1, center: barMiddle),
            tucked: Place(anchor: barMiddle, scale: min(0.66, room / rowWidth), center: CGPoint(x: mirrored ? width - 40 - room / 2 : 40 + room / 2, y: upper.midY + 19)),
            span: min(blockLeft, rowLeft) ... max(blockLeft + metadataWidth, rowLeft + rowWidth),
            width: width,
            tuck: tuck,
        )
        // Turning round, the two change sides out of sight, not across the screen.
        let move = lastMirrored == mirrored ? animation : nil
        lastMirrored = mirrored
        artwork.layer.position = .zero
        artwork.layer.setTransform(coverPlace.transform, move)
        details.setTransform(detailsPlace.transform, move)
        progressBar = detailsPlace.map(bar)
        detailsScale = detailsPlace.scale
        detailsSlide = slide
    }
}

/// The Now Playing artwork, turned slightly, with its reflection below.
@MainActor
final class NowPlayingArtworkLayer {
    let layer = SceneLayer()
    private let preview = CALayer()
    private let reflection = CALayer()
    private let reflectionImage = SceneLayer()
    private var key: String?

    init() {
        for sublayer in [reflection, preview] {
            sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull()]
            layer.addSublayer(sublayer)
        }
        preview.contentsGravity = .resizeAspectFill
        preview.masksToBounds = false
        preview.shadowColor = CGColor(gray: 0, alpha: 1)
        preview.shadowOpacity = 0.45
        preview.shadowRadius = 8
        preview.shadowOffset = CGSize(width: 0, height: 2)
        reflection.addSublayer(reflectionImage)
        reflection.opacity = 0.42
    }

    func update(image: NSImage?, side: CGFloat, mirrored: Bool) {
        let key = "\(image.map { "\(ObjectIdentifier($0))" } ?? "none")|\(side)|\(mirrored)"
        guard key != self.key else { return }
        self.key = key
        layer.bounds = CGRect(x: 0, y: 0, width: side * 1.12, height: side * 1.72)
        let size = CGSize(width: side, height: side)
        let artwork = LayerImageCache.cgImage(for: image) ?? CoverArtPlaceholder.image(side: side)
        let yaw: Double = mirrored ? 9 : -9
        preview.bounds = CGRect(origin: .zero, size: size)
        preview.position = CGPoint(x: side * 0.5, y: side * 0.5)
        preview.contents = artwork
        preview.shadowPath = CGPath(rect: preview.bounds, transform: nil)
        preview.transform = yawTransform(degrees: yaw, perspective: 0.9, viewSize: size)
        let gap = max(8, side * 0.03)
        reflection.bounds = CGRect(origin: .zero, size: size)
        reflection.position = CGPoint(x: side * 0.5, y: side * 0.5 + gap)
        reflection.transform = yawTransform(degrees: yaw, perspective: 0.9, viewSize: size)
        reflectionImage.frame = CGRect(x: 0, y: side, width: side, height: side)
        reflectionImage.contents = artwork.flatMap {
            ReflectionRenderer.reflection(of: $0, size: size, fill: true, stops: [(1, 0), (0.68, 0.05), (0.26, 0.12), (0.08, 0.17), (0, 0.22)])
        }
    }
}

/// Play, pause, rewind and fast-forward glyphs (or a spinner while loading).
@MainActor
final class PlaybackGlyphLayer {
    let layer = SceneLayer()
    private let glyphs = [SceneLayer(), SceneLayer(), SceneLayer()]
    private let spinner = SpinnerLayer()
    /// The glyph's box, from the layer's origin.
    private(set) var size: CGSize = .zero

    init() {
        for glyph in glyphs { layer.addSublayer(glyph) }
        layer.addSublayer(spinner.layer)
    }

    /// `showsPlayGlyph`: whether `.play` draws a play triangle (movies) or the pause bars (music).
    func update(_ state: MoviePlaybackGlyphState, pointSize: CGFloat, shadows: [TextShadow], scale: CGFloat, showsPlayGlyph: Bool = false) {
        for glyph in glyphs { glyph.isHidden = true }
        spinner.layer.isHidden = true
        switch state {
        case .pause, .play:
            let isPlay = state == .play && showsPlayGlyph
            let graphic = SymbolRenderer.render(isPlay ? "play.fill" : "pause.fill", pointSize: pointSize, weight: .bold, shadows: shadows, scale: scale)
            glyphs[0].isHidden = false
            glyphs[0].show(graphic, at: CGPoint(x: isPlay ? 1 : 0, y: 0))
            size = graphic.size
            spinner.stop()
        case let .rewind(count), let .fastForward(count):
            let isRewind = if case .rewind = state { true } else { false }
            let base = SymbolRenderer.render("play.fill", pointSize: pointSize, weight: .bold, shadows: shadows, scale: scale)
            let graphic = isRewind ? Self.turned(base) : base
            let shown = max(1, min(3, count))
            let step = graphic.size.width - 7
            for index in 0 ..< shown {
                glyphs[index].isHidden = false
                glyphs[index].show(graphic, at: CGPoint(x: CGFloat(index) * step + (isRewind ? 4 : -4), y: 0))
            }
            size = CGSize(width: step * CGFloat(shown - 1) + graphic.size.width, height: graphic.size.height)
            spinner.stop()
        case .loading:
            let side = pointSize * 1.1
            spinner.layer.isHidden = false
            spinner.layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
            spinner.start()
            size = CGSize(width: side, height: side)
        }
    }

    private static var turnedCache: [ObjectIdentifier: (CGImage, CGImage)] = [:]

    /// The graphic turned upside down and back to front (a play triangle pointing left).
    private static func turned(_ graphic: RenderedGraphic) -> RenderedGraphic {
        guard let image = graphic.image else { return graphic }
        if let cached = turnedCache[ObjectIdentifier(image)], cached.0 === image {
            return RenderedGraphic(image: cached.1, size: graphic.size, padding: graphic.padding, scale: graphic.scale)
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return graphic }
        context.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
        context.rotate(by: .pi)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let turned = context.makeImage() else { return graphic }
        if turnedCache.count > 40 { turnedCache.removeAll() }
        turnedCache[ObjectIdentifier(image)] = (image, turned)
        return RenderedGraphic(image: turned, size: graphic.size, padding: graphic.padding, scale: graphic.scale)
    }
}

/// The spinning progress indicator.
@MainActor
final class SpinnerLayer {
    let layer = SceneLayer()
    private let replicator = CAReplicatorLayer()
    private let spoke = CALayer()
    private static let spokeCount = 12

    init() {
        layer.addSublayer(replicator)
        replicator.addSublayer(spoke)
        replicator.instanceCount = Self.spokeCount
        replicator.instanceTransform = CATransform3DMakeRotation(2 * .pi / CGFloat(Self.spokeCount), 0, 0, 1)
        replicator.instanceDelay = 1.0 / Double(Self.spokeCount)
        spoke.backgroundColor = CGColor(gray: 1, alpha: 1)
        spoke.opacity = 0.25
    }

    func start() {
        let size = layer.bounds.size
        let length = size.height * 0.28
        let thickness = max(1.5, size.width * 0.085)
        withoutLayerActions {
            replicator.frame = CGRect(origin: .zero, size: size)
            spoke.bounds = CGRect(x: 0, y: 0, width: thickness, height: length)
            spoke.cornerRadius = thickness * 0.5
            spoke.position = CGPoint(x: size.width * 0.5, y: length * 0.5)
        }
        guard spoke.animation(forKey: "fade") == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.25
        fade.duration = 1
        fade.repeatCount = .infinity
        fade.isRemovedOnCompletion = false
        spoke.addAtFullRate(fade, forKey: "fade")
    }

    func stop() {
        spoke.removeAllAnimations()
    }
}

// MARK: - Error and loading

/// "An error occurred." and friends: an alert sign, a headline and an explanation.
final class FeatureErrorSceneLayer: FullscreenContent {
    fileprivate let icon = SceneLayer()
    fileprivate let header = SceneLayer()
    fileprivate let subcaption = SceneLayer()
    private var key: String?

    override var keepsAboveTheFold: Bool { true }

    override init() {
        super.init()
        icon.contentsGravity = .resizeAspect
        layer.addSublayer(icon)
        layer.addSublayer(header)
        layer.addSublayer(subcaption)
    }

    override func update(menu _: MenuView, scene: FullscreenScenePresentation, pass _: RenderPass, size: CGSize, scale: CGFloat) {
        let key = "\(scene.id)|\(size)|\(scale)"
        guard key != self.key else { return }
        self.key = key
        let copy = FeatureErrorCopy.resolve(from: scene.payload)
        if ModernTheme.isActive {
            updateModern(copy, size: size, scale: scale)
            return
        }
        let iconImage = NSImage(named: "ErrorTriangle_v1") ?? NSImage(named: "Alert!")
        let iconSide: CGFloat = iconImage == nil ? 0 : 84
        let iconSpacing: CGFloat = iconImage == nil ? 0 : 24
        // (A narrow screen keeps a margin.)
        let maxWidth = min(1500, size.width - (size.width < 1440 ? 120 : 0))
        // One line if it fits beside the sign, otherwise wrapped (centred) at most 1092 wide.
        let singleLine = TextRenderer.measure(TextSpec(text: copy.headerText, fontName: firstRowBoldFontName, size: 60))
        let headerGraphic: RenderedGraphic = if singleLine.width <= maxWidth - iconSide - iconSpacing {
            TextRenderer.render(TextSpec(text: copy.headerText, fontName: firstRowBoldFontName, size: 60), scale: scale)
        } else {
            TextRenderer.render(TextSpec(text: copy.headerText, fontName: firstRowBoldFontName, size: 60, wrapWidth: min(1092, maxWidth - iconSide - iconSpacing), alignment: .center), scale: scale)
        }
        let trimmedSubcaption = copy.subcaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let subcaptionGraphic: RenderedGraphic? = trimmedSubcaption.isEmpty ? nil : TextRenderer.render(TextSpec(text: copy.subcaptionText, fontName: firstRowBoldFontName, size: 30, wrapWidth: maxWidth, alignment: .center, lineSpacing: 4), scale: scale)
        let rowWidth = iconSide + iconSpacing + headerGraphic.size.width
        let rowHeight = max(iconSide, headerGraphic.size.height)
        let stackHeight = rowHeight + (subcaptionGraphic.map { 15 + $0.size.height } ?? 0)
        // Above the middle, less so on a short screen.
        let top = max(40, (size.height - stackHeight) * 0.5 - (size.height < 1080 ? 60 : 160))
        let rowLeft = (size.width - rowWidth) * 0.5
        icon.isHidden = iconImage == nil
        icon.contents = LayerImageCache.cgImage(for: iconImage)
        icon.frame = CGRect(x: rowLeft, y: top, width: iconSide, height: iconSide)
        header.show(headerGraphic, at: CGPoint(x: rowLeft + iconSide + iconSpacing, y: top - 6))
        subcaption.isHidden = subcaptionGraphic == nil
        if let subcaptionGraphic {
            subcaption.show(subcaptionGraphic, at: CGPoint(x: (size.width - subcaptionGraphic.size.width) * 0.5, y: top + rowHeight + 15))
        }
    }
}

extension FeatureErrorSceneLayer {
    /// The modern look: a sign, the headline and the explanation stacked in the middle.
    fileprivate func updateModern(_ copy: FeatureErrorCopy, size: CGSize, scale: CGFloat) {
        let width = min(1300, size.width - 200)
        let sign = SymbolRenderer.render("exclamationmark.triangle.fill", pointSize: 84, weight: .semibold, color: RGBA(white: 1, alpha: 0.75), scale: scale)
        let headerGraphic = TextRenderer.render(TextSpec(text: copy.headerText, fontName: ModernTheme.boldFontName, size: 52, color: ModernTheme.text, wrapWidth: width, alignment: .center), scale: scale)
        let trimmed = copy.subcaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let subGraphic: RenderedGraphic? = trimmed.isEmpty ? nil : TextRenderer.render(TextSpec(text: trimmed, fontName: ModernTheme.regularFontName, size: 32, color: ModernTheme.secondaryText, wrapWidth: width, alignment: .center, lineSpacing: 4), scale: scale)
        let stack = sign.size.height + 34 + headerGraphic.size.height + (subGraphic.map { 18 + $0.size.height } ?? 0)
        var top = (size.height - stack) * 0.5 - 40
        icon.isHidden = false
        icon.contents = nil
        icon.show(sign, at: CGPoint(x: (size.width - sign.size.width) * 0.5, y: top))
        top += sign.size.height + 34
        header.show(headerGraphic, at: CGPoint(x: (size.width - headerGraphic.size.width) * 0.5, y: top))
        top += headerGraphic.size.height + 18
        subcaption.isHidden = subGraphic == nil
        if let subGraphic {
            subcaption.show(subGraphic, at: CGPoint(x: (size.width - subGraphic.size.width) * 0.5, y: top))
        }
    }
}

// MARK: - Screen saver and slideshow

final class ScreenSaverSceneLayer: FullscreenContent {
    private let space = SceneLayer()
    private let controller = ScreenSaverLayerController()
    private lazy var photos = ScreenSaverPhotoStream.makePhotos()

    override init() {
        super.init()
        #if os(macOS) || FIRSTROW_PORTABLE
            space.isGeometryFlipped = true
        #endif
        layer.addSublayer(space)
        space.addSublayer(controller.rootLayer)
    }

    override func update(menu _: MenuView, scene _: FullscreenScenePresentation, pass _: RenderPass, size: CGSize, scale _: CGFloat) {
        space.frame = CGRect(origin: .zero, size: size)
        controller.rootLayer.frame = space.bounds
        controller.update(.init(photos: photos), bounds: size)
    }

    override func tearDown() {
        controller.tearDown()
    }
}

final class PhotoSlideshowSceneLayer: FullscreenContent {
    private let space = SceneLayer()
    private let controller = PhotoSlideshowLayerController()

    override init() {
        super.init()
        #if os(macOS) || FIRSTROW_PORTABLE
            space.isGeometryFlipped = true
        #endif
        layer.addSublayer(space)
        space.addSublayer(controller.rootLayer)
    }

    override func update(menu: MenuView, scene _: FullscreenScenePresentation, pass _: RenderPass, size: CGSize, scale _: CGFloat) {
        space.frame = CGRect(origin: .zero, size: size)
        controller.rootLayer.frame = space.bounds
        controller.update(.init(
            imageCount: menu.photoSlideshowAssetLocalIdentifiers.count,
            imageForIndex: { [weak menu] index in menu?.photoSlideshowImageCache[index] },
            isPaused: menu.photoSlideshowIsPaused,
            pausedIndex: menu.photoSlideshowPausedIndex,
            playbackStartDate: menu.photoSlideshowPlaybackStartDate,
            playbackElapsedOffset: menu.photoSlideshowPlaybackElapsedOffset,
            displayDuration: menu.photoSlideshowPhotoDisplayDuration,
            crossfadeDuration: menu.photoSlideshowCrossfadeDuration,
            hasAlreadyFinished: menu.photoSlideshowHasFinished,
            onFrameIndicesChanged: { [weak menu] primary, secondary in
                menu?.updatePhotoSlideshowVisibleIndices(primaryIndex: primary, secondaryIndex: secondary)
            },
            onFinished: { [weak menu] in menu?.handlePhotoSlideshowPlaybackFinished() },
        ), bounds: size)
    }

    override func tearDown() {
        controller.tearDown()
    }
}

/// The song playing, shown for a while at the bottom left of the screen saver.
@MainActor
final class ScreenSaverToastLayer {
    /// Covers the screen in full-screen canvas points; the toast itself is `box`.
    let layer = SceneLayer()
    private let box = SceneLayer()
    private let artwork = SceneLayer()
    private let title = SceneLayer()
    private let album = SceneLayer()
    private let artist = SceneLayer()

    init() {
        layer.addSublayer(box)
        box.backgroundColor = CGColor(gray: 0, alpha: 0.5)
        box.opacity = 0
        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.borderColor = CGColor(gray: 1, alpha: 0.16)
        artwork.borderWidth = 1
        for sublayer in [artwork, title, album, artist] { box.addSublayer(sublayer) }
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, backingScale: CGFloat) {
        let showing = menu.activeFullscreenScene?.key == menu.screenSaverFullscreenKey
        layer.isHidden = !showing
        guard showing else {
            box.opacity = 0
            return
        }
        let canvas = FullscreenCanvas(screenSize: bounds.size, upright: menu.upright)
        canvas.apply(to: layer)
        let scale = canvas.pixelScale(backingScale: backingScale)
        let size = menu.screenSaverNowPlayingToastSize
        box.frame = CGRect(x: 42, y: canvas.size.height - 36 - size.height, width: size.width, height: size.height)
        box.setOpacity(menu.screenSaverNowPlayingToastOpacity, pass.animation)
        guard menu.screenSaverNowPlayingToastOpacity > 0 || box.opacity > 0 else { return }
        let image = menu.musicNowPlayingArtwork ?? menu.musicFallbackImage ?? menu.podcastFallbackImage
        let artworkSize: CGFloat = 130
        artwork.contents = LayerImageCache.cgImage(for: image)
        artwork.backgroundColor = image == nil ? CGColor(gray: 0, alpha: 0.35) : nil
        artwork.frame = CGRect(x: 18, y: (size.height - artworkSize) * 0.5, width: artworkSize, height: artworkSize)
        let textWidth = size.width - 36 - artworkSize - 16
        let titleGraphic = TextRenderer.render(TextSpec(text: menu.normalizedScreenSaverToastText(menu.musicNowPlayingTitle, fallback: "Unknown Song"), fontName: firstRowBoldFontName, size: 30, maxWidth: textWidth), scale: scale)
        let albumGraphic = TextRenderer.render(TextSpec(text: menu.normalizedScreenSaverToastText(menu.musicNowPlayingAlbum, fallback: "Unknown Album"), fontName: firstRowRegularFontName, size: 24, color: RGBA(white: 1, alpha: 0.9), maxWidth: textWidth), scale: scale)
        let artistGraphic = TextRenderer.render(TextSpec(text: menu.normalizedScreenSaverToastText(menu.musicNowPlayingArtist, fallback: "Unknown Artist"), fontName: firstRowRegularFontName, size: 24, color: RGBA(white: 1, alpha: 0.9), maxWidth: textWidth), scale: scale)
        let blockHeight = titleGraphic.size.height + albumGraphic.size.height + artistGraphic.size.height + 12
        var y = (size.height - blockHeight) * 0.5
        let x = 18 + artworkSize + 16
        for (target, graphic) in [(title, titleGraphic), (album, albumGraphic), (artist, artistGraphic)] {
            target.show(graphic, at: CGPoint(x: x, y: y))
            y += graphic.size.height + 6
        }
    }
}

/// The modern look's volume display, drawn as macOS 26 draws its own: a speaker that gains
/// waves as the level rises, then sixteen short dashes, white up to the level. In points, for a
/// capsule `size` big (the glass or drawn capsule around it is the caller's).
@MainActor
final class VolumeHUDContent {
    static let size = CGSize(width: 308, height: 66)
    /// How long the fill takes to sweep across one dash.
    static let dashSweep: Double = 0.09
    let layer = SceneLayer()
    private let speaker = SceneLayer()
    private let drawsSpeaker: Bool
    private let dashes: [(track: SceneLayer, fill: SceneLayer)] = (0 ..< 16).map { _ in (SceneLayer(), SceneLayer()) }
    /// The glass's light edge, brightest along the top.
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()
    /// The level shown, in dashes, and the volume it came from.
    private var shownLevel: Double?
    private(set) var volume: Double?
    private var speakerSymbol = ""

    /// `drawsRim`: the light edge, for the drawn capsule (Liquid Glass has its own).
    /// `drawsSpeaker`: off where the speaker is a system image view instead.
    init(drawsRim: Bool = true, drawsSpeaker: Bool = true) {
        self.drawsSpeaker = drawsSpeaker
        rim.isHidden = !drawsRim
        rim.colors = [CGColor(gray: 1, alpha: 0.42), CGColor(gray: 1, alpha: 0.14), CGColor(gray: 1, alpha: 0.2)]
        rim.locations = [0, 0.55, 1]
        rimShape.fillColor = nil
        rimShape.strokeColor = CGColor(gray: 0, alpha: 1)
        rimShape.lineWidth = 1
        rim.mask = rimShape
        layer.addSublayer(rim)
        layer.addSublayer(speaker)
        speaker.isHidden = !drawsSpeaker
        for dash in dashes {
            dash.track.addSublayer(dash.fill)
            layer.addSublayer(dash.track)
        }
    }

    /// The speaker for a volume: a slash at none, then one, two or three waves (up to five,
    /// ten and sixteen dashes).
    static func symbolName(for volume: Double) -> String {
        switch (min(1, max(0, volume)) * 16).rounded() {
        case ...0: "speaker.slash.fill"
        case ...5: "speaker.wave.1.fill"
        case ...10: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    /// The level as it shows right now, part way through a sweep or not, in dashes.
    private var presentedLevel: Double {
        dashes.reduce(0) { total, dash in
            let width = (dash.fill.presentation() ?? dash.fill).bounds.width
            return total + Double(width / 12)
        }
    }

    /// Shows `volume`, the fill sweeping from dash to dash on its way there. `opening`: the
    /// display is coming in, so the sweep is at most the last step (the level may have moved
    /// on while it was away). Returns how long the sweep takes, and whether it ends at either end
    /// of the scale having not been there (when the speaker bounces; pressing on past the end
    /// doesn't).
    @discardableResult
    func update(volume: Double, scale: CGFloat, opening: Bool = false) -> (sweep: Double, reachedEnd: Bool) {
        let volume = min(1, max(0, volume))
        let level = volume * 16
        var from = shownLevel == nil ? level : presentedLevel
        if opening {
            from = min(level + 1, max(level - 1, from))
            // Straight to where the sweep starts.
            for (index, dash) in dashes.enumerated() {
                dash.fill.removeAllAnimations()
                withoutLayerActions {
                    dash.fill.place(CGRect(x: 0, y: 0, width: 12 * CGFloat(min(1, max(0, from - Double(index)))), height: 4))
                }
            }
        }
        let reachedEnd = (volume <= 0 || volume >= 1) && self.volume != nil && self.volume != volume
        self.volume = volume
        shownLevel = level
        let symbol = Self.symbolName(for: volume)
        withoutLayerActions {
            layer.frame = CGRect(origin: .zero, size: Self.size)
            let bounds = CGRect(origin: .zero, size: Self.size)
            rim.frame = bounds
            rimShape.frame = bounds
            let edge = bounds.insetBy(dx: 0.5, dy: 0.5)
            rimShape.path = CGPath(roundedRect: edge, cornerWidth: edge.height / 2, cornerHeight: edge.height / 2, transform: nil)
            if drawsSpeaker, symbol != speakerSymbol {
                // The waves change at once; the speaker stays put as they come and go (its
                // picture has a little room round it, so it starts a touch left of its edge).
                let graphic = SymbolRenderer.render(symbol, pointSize: 26, weight: .semibold, color: .white, scale: scale)
                speaker.show(graphic, at: CGPoint(x: 14, y: ((Self.size.height - graphic.size.height) / 2).rounded()))
            }
            for (index, dash) in dashes.enumerated() {
                dash.track.frame = CGRect(x: 61 + CGFloat(index) * 13.5, y: (Self.size.height - 4) / 2, width: 12, height: 4)
                dash.track.cornerRadius = 1.5
                dash.track.backgroundColor = CGColor(gray: 1, alpha: 0.18)
                dash.track.masksToBounds = true
                dash.fill.backgroundColor = CGColor(gray: 1, alpha: 1)
            }
        }
        speakerSymbol = symbol
        // The fill runs from where it was to the new level a dash at a time, each dash filling
        // left to right on the way up and emptying right to left on the way down.
        let rising = level > from
        for (index, dash) in dashes.enumerated() {
            let was = min(1, max(0, from - Double(index)))
            let now = min(1, max(0, level - Double(index)))
            let target = CGRect(x: 0, y: 0, width: 12 * CGFloat(now), height: 4)
            guard was != now else {
                if dash.fill.animation(forKey: "bounds.size") == nil, dash.fill.frame != target { dash.fill.place(target) }
                continue
            }
            let lead = rising ? max(0, Double(index) - from) : max(0, from - Double(index + 1))
            dash.fill.setFrame(target, .linear(duration: Self.dashSweep * abs(now - was)).delay(Self.dashSweep * lead))
        }
        let sweep = Self.dashSweep * abs(level - from)
        if drawsSpeaker, reachedEnd {
            bounceSpeaker(after: sweep)
        }
        return (sweep, reachedEnd)
    }

    /// The drawn speaker's bounce at either end of the scale: up, a little under, and settled.
    private func bounceSpeaker(after delay: Double) {
        let size = speaker.bounds.size
        func scaled(_ factor: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            transform = CATransform3DScale(transform, factor, factor, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0))
        }
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = [scaled(1), scaled(1.18), scaled(0.95), scaled(1.02), scaled(1)]
        bounce.keyTimes = [0, 0.3, 0.62, 0.84, 1]
        bounce.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        bounce.duration = 0.7
        bounce.beginTime = speaker.convertTime(CACurrentMediaTime(), from: nil) + delay
        bounce.fillMode = .backwards
        speaker.addAtFullRate(bounce, forKey: "bounce")
    }

    /// Where the display goes on a screen `size` big (window points): top right, where macOS
    /// puts its own.
    static func frame(in size: CGSize) -> CGRect {
        CGRect(x: max(16, size.width - 132 - Self.size.width), y: 40, width: Self.size.width, height: Self.size.height)
    }

    /// Coming in: from a little smaller, fading up; going: a little smaller again, fading out.
    static let openScale: CGFloat = 0.89
    static let closeScale: CGFloat = 0.91
    static let openScaleAnimation = Animation.smooth(duration: 0.48)
    static let openFadeAnimation = Animation.smoothInOut(duration: 0.45)
    static let closeAnimation = Animation.smooth(duration: 0.33)
    /// How long it stays after the last change.
    static let linger: Double = 1.0

    /// A scale about the middle of a box `size` big.
    static func scale(_ factor: CGFloat, size: CGSize) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
    }
}

/// The volume overlay. The classic look: a speaker over a level bar, centred near the bottom of
/// the screen, fading three seconds after the last change. The modern look: a capsule at the top
/// right like the system's own, in Liquid Glass where the system has it.
@MainActor
final class VolumeOverlayLayer {
    /// Covers the screen in window points.
    let layer = SceneLayer()
    /// The classic overlay, in full-screen canvas points; the overlay itself is `box`.
    private let classic = SceneLayer()
    private let box = SceneLayer()
    private let speaker = SceneLayer()
    private let leftEnd = SceneLayer()
    private let track = SceneLayer()
    private let rightEnd = SceneLayer()
    private let fill = SceneLayer()
    private let level = SceneLayer()
    /// The modern capsule, where there's no Liquid Glass.
    private let capsule = SceneLayer()
    private let capsuleContent = VolumeHUDContent()
    /// Whether the drawn capsule is up (for whether a change sweeps from where it was).
    private var capsuleShown = false
    private var percent: CGFloat = 0
    private var volume: Double = 0
    private var screenSize: CGSize = .zero
    private var upright: UprightStance?
    private var backingScale: CGFloat = 2
    private var fadeTimer: Timer?
    private var hideTimer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        layer.isHidden = true
        layer.addSublayer(classic)
        classic.addSublayer(box)
        for piece in [speaker, leftEnd, track, rightEnd, fill, level] {
            piece.contentsGravity = .resize
            box.addSublayer(piece)
        }
        capsule.backgroundColor = CGColor(gray: 0.2, alpha: 0.86)
        capsule.borderWidth = 0.5
        capsule.borderColor = CGColor(gray: 1, alpha: 0.2)
        capsule.shadowColor = CGColor(gray: 0, alpha: 1)
        capsule.shadowOpacity = 0.3
        capsule.shadowRadius = 12
        capsule.shadowOffset = .zero
        capsule.addSublayer(capsuleContent.layer)
        layer.addSublayer(capsule)
        observer = NotificationCenter.default.addObserver(forName: .firstRowVolumeChanged, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?["volume"] as? Double ?? 0
            MainActor.assumeIsolatedIfPossible { self?.show(volume: volume) }
        }
    }

    func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        fadeTimer?.invalidate()
        hideTimer?.invalidate()
        #if os(macOS)
            if #available(macOS 26.0, *) { NativeControls.shared?.volumeHUD.hide(animated: false) }
        #endif
    }

    func layout(screenSize: CGSize, upright: UprightStance?, backingScale: CGFloat) {
        self.backingScale = backingScale
        guard screenSize != self.screenSize || upright != self.upright else { return }
        self.screenSize = screenSize
        self.upright = upright
        if !layer.isHidden { place() }
    }

    private func show(volume: Double) {
        self.volume = volume
        percent = CGFloat(min(1, max(0, volume))) * 100
        fadeTimer?.invalidate()
        hideTimer?.invalidate()
        let isModern = ModernTheme.isActive
        #if os(macOS)
            // The system's own glass, which hides itself a moment after the last change.
            if isModern, #available(macOS 26.0, *), let native = NativeControls.shared {
                withoutLayerActions { layer.isHidden = true }
                native.volumeHUD.show(volume: volume, frame: VolumeHUDContent.frame(in: screenSize), scale: backingScale)
                return
            }
        #endif
        let wasShown = !layer.isHidden && layer.opacity > 0.5 && layer.animation(forKey: "opacity") == nil
        withoutLayerActions {
            layer.removeAnimation(forKey: "opacity")
            layer.opacity = 1
            layer.isHidden = false
            place()
        }
        if isModern, !wasShown {
            // In as the system's does: from a little smaller, fading up.
            let size = VolumeHUDContent.size
            withoutLayerActions {
                capsule.transform = VolumeHUDContent.scale(VolumeHUDContent.openScale, size: size)
                capsule.opacity = 0
            }
            capsule.setTransform(CATransform3DIdentity, VolumeHUDContent.openScaleAnimation)
            capsule.setOpacity(1, VolumeHUDContent.openFadeAnimation)
        }
        let fade = Timer(after: isModern ? VolumeHUDContent.linger : 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.fadeOut(modern: isModern) }
        }
        RunLoop.main.add(fade, forMode: .common)
        fadeTimer = fade
    }

    private func fadeOut(modern: Bool) {
        if modern {
            capsule.setTransform(VolumeHUDContent.scale(VolumeHUDContent.closeScale, size: VolumeHUDContent.size), VolumeHUDContent.closeAnimation)
        }
        layer.setOpacity(0, modern ? VolumeHUDContent.closeAnimation : .linear(duration: 1))
        capsuleShown = false
        let hide = Timer(after: modern ? 0.4 : 1.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.layer.isHidden = true }
        }
        RunLoop.main.add(hide, forMode: .common)
        hideTimer = hide
    }

    private func place() {
        let isModern = ModernTheme.isActive
        withoutLayerActions {
            layer.frame = CGRect(origin: .zero, size: screenSize)
            classic.isHidden = isModern
            capsule.isHidden = !isModern
            if isModern {
                capsule.place(VolumeHUDContent.frame(in: screenSize))
                capsule.cornerRadius = capsule.bounds.height / 2
                capsuleContent.update(volume: volume, scale: backingScale, opening: !capsuleShown)
                capsuleShown = true
            }
        }
        if !isModern { placeClassic() }
    }

    /// Lays the classic overlay out as a fraction of the screen's height, and the bar as a
    /// fraction of the overlay, from pieces drawn for a 720-point-tall screen.
    private func placeClassic() {
        let canvas = FullscreenCanvas(screenSize: screenSize, upright: upright)
        canvas.apply(to: classic)
        // Standing upright it keeps its size and sits above the fold.
        let height = upright == nil ? canvas.size.height : UprightStance.sceneWidth
        let ground = upright?.upperPane.maxY ?? height
        let boxHeight = ceil(height * 0.252)
        let boxWidth = ceil(height * 0.23)
        withoutLayerActions {
            box.frame = CGRect(x: ceil((canvas.size.width - boxWidth) * 0.5), y: ground - ceil(height * 0.075) - boxHeight, width: boxWidth, height: boxHeight)
            speaker.frame = box.bounds
            speaker.contents = Self.image(percent > 0 ? "Vol_BKG_v1_ON" : "Vol_BKG_v1_OFF")

            let barWidth = ceil(boxWidth * 0.855)
            let barHeight = ceil(boxWidth * 0.126)
            let bar = CGRect(x: ceil((boxWidth - barWidth) * 0.5), y: boxHeight - ceil(boxHeight * 0.2) - barHeight, width: barWidth, height: barHeight)
            let unit = barHeight / 21
            let endWidth = floor(11 * unit)
            leftEnd.frame = CGRect(x: bar.minX, y: bar.minY, width: endWidth, height: barHeight)
            leftEnd.contents = Self.image(percent > 0 ? "Vol_Blue_LEFT" : "Vol_Black_LEFT")
            rightEnd.frame = CGRect(x: bar.maxX - endWidth, y: bar.minY, width: endWidth, height: barHeight)
            rightEnd.contents = Self.image(percent >= 100 ? "Vol_Blue_RIGHT" : "Vol_Black_RIGHT")

            // Between the ends: the blue fill, the level cap just past it, then the dark track.
            let middleX = bar.minX + endWidth
            let middleWidth = floor(barWidth - endWidth * 2)
            let showsCap = percent >= 5 && percent <= 99
            let gap = showsCap ? 5 * unit : 0
            let fillWidth = max(0, percent > 1 ? ceil(middleWidth * percent / 100 - gap) : 0)
            fill.frame = CGRect(x: middleX, y: bar.minY, width: fillWidth, height: barHeight)
            fill.contents = Self.image("Vol_Blue_CENTER")
            level.frame = CGRect(x: middleX + fillWidth, y: bar.minY, width: showsCap ? 17 * unit : 0, height: barHeight)
            level.contents = Self.image("Vol_Blue_PositionCAP")
            track.frame = CGRect(x: middleX + gap + fillWidth, y: bar.minY, width: max(0, floor(middleWidth - fillWidth) - gap), height: barHeight)
            track.contents = Self.image("Vol_Black_CENTER")
        }
    }

    private static func image(_ name: String) -> CGImage? {
        LayerImageCache.cgImage(for: NSImage(named: name))
    }
}

import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The scene shown over the whole screen: Now Playing, the screen saver, a photo slideshow,
/// an error or a loading message.
@MainActor
final class FullscreenSceneLayer {
    let layer = SceneLayer()
    private var contentKey: String?
    private var content: FullscreenContent?

    init() {
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.opacity = 0
        layer.isHidden = true
        layer.masksToBounds = true
    }

    func tearDown() {
        content?.tearDown()
        content = nil
        contentKey = nil
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat) {
        layer.frame = bounds
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
                layer.addSublayer(content.layer)
            }
        }
        content?.layer.frame = CGRect(origin: .zero, size: bounds.size)
        content?.update(menu: menu, scene: scene, pass: pass, size: bounds.size, scale: scale)
        layer.setOpacity(menu.fullscreenSceneOpacity, pass.animation)
    }

    private static func makeContent(for scene: FullscreenScenePresentation, menu: MenuView) -> FullscreenContent {
        switch scene.key {
        case menu.musicNowPlayingFullscreenKey: NowPlayingSceneLayer()
        case menu.screenSaverFullscreenKey: ScreenSaverSceneLayer()
        case menu.featureErrorFullscreenKey: FeatureErrorSceneLayer()
        case menu.theatricalTrailersLoadingFullscreenKey: LoadingSceneLayer()
        case menu.photoSlideshowFullscreenKey: PhotoSlideshowSceneLayer()
        default: FullscreenContent()
        }
    }
}

@MainActor
class FullscreenContent {
    let layer = SceneLayer()
    func update(menu _: MenuView, scene _: FullscreenScenePresentation, pass _: RenderPass, size _: CGSize, scale _: CGFloat) {}
    func tearDown() {}
}

// MARK: - Now Playing

/// Now Playing for music and podcasts: the current song's panel, the previous one zooming
/// away while songs change, and the whole thing flipping round every so often.
final class NowPlayingSceneLayer: FullscreenContent {
    private let flip = CALayer()
    private let incoming = NowPlayingPanelLayer()
    private let outgoing = NowPlayingPanelLayer()

    override init() {
        super.init()
        flip.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull()]
        layer.addSublayer(flip)
        incoming.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        outgoing.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        flip.addSublayer(incoming.layer)
        flip.addSublayer(outgoing.layer)
    }

    override func update(menu: MenuView, scene _: FullscreenScenePresentation, pass: RenderPass, size: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        flip.bounds = bounds
        flip.position = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        flip.setTransform(yawTransform(degrees: menu.musicNowPlayingFlipRotationDegrees, perspective: 0.9, viewSize: size), pass.animation)

        let hasTransition = menu.musicSongTransitionSnapshot != nil
        let incomingStart: CGFloat = menu.musicSongTransitionDirection > 0 ? 0.25 : 6
        let outgoingEnd: CGFloat = menu.musicSongTransitionDirection > 0 ? 6 : 0.25
        let outgoingProgress = min(max(menu.musicSongTransitionOutgoingProgress, 0), 1)
        let outgoingOpacityProgress = min(max(menu.musicSongTransitionOutgoingOpacityProgress, 0), 1)
        let incomingProgress = min(max(menu.musicSongTransitionIncomingProgress, 0), 1)
        let incomingScale = hasTransition ? incomingStart + (1 - incomingStart) * incomingProgress : 1
        let outgoingScale = hasTransition ? 1 + (outgoingEnd - 1) * outgoingProgress : 1
        let mirrored = menu.musicNowPlayingUsesAlternateLayout

        incoming.layer.bounds = bounds
        incoming.layer.position = flip.position
        incoming.update(menu.currentMusicNowPlayingSnapshot, mirrored: mirrored, size: size, scale: scale)
        incoming.layer.setTransform(CATransform3DMakeScale(incomingScale, incomingScale, 1), pass.animation)
        incoming.layer.setOpacity(hasTransition ? Double(incomingProgress) : 1, pass.animation)

        if let snapshot = menu.musicSongTransitionSnapshot {
            outgoing.layer.isHidden = false
            outgoing.layer.bounds = bounds
            outgoing.layer.position = flip.position
            outgoing.update(snapshot, mirrored: mirrored, size: size, scale: scale)
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

    init() {
        for sublayer in [title, artist, album, position, leading, leadingGlyph.layer, trailing, shuffle, barFrame, barFill, diamond, artwork.layer] {
            layer.addSublayer(sublayer)
        }
        barFrame.fillColor = nil
        barFrame.strokeColor = CGColor(gray: 1, alpha: 0.82)
        barFrame.lineWidth = 2.4
        barFill.backgroundColor = CGColor(gray: 1, alpha: 0.5)
        diamond.backgroundColor = CGColor(gray: 1, alpha: 1)
        diamond.cornerRadius = 1.2
        diamond.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        diamond.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
    }

    func update(_ snapshot: MenuView.MusicNowPlayingSnapshot, mirrored: Bool, size: CGSize, scale: CGFloat) {
        let width = size.width
        let height = size.height
        let baseArtworkSide = min(width * 0.255, height * 0.46)
        let artworkSide = baseArtworkSide * 1.14
        let baseArtworkCenterX = width * 0.68 + width * 0.07
        let artworkGrowth = artworkSide - baseArtworkSide
        let rightArtworkCenterX = baseArtworkCenterX + artworkGrowth * 0.56
        let artworkCenterY = height * 0.70 + artworkGrowth * 0.86 - height * 0.05
        let artworkCenterX = mirrored ? width - rightArtworkCenterX : rightArtworkCenterX
        let renderedArtworkCenterX = artworkCenterX + (mirrored ? artworkSide * 0.12 : 0)
        let artworkLeftX = artworkCenterX - artworkSide * 0.5
        let artworkRightX = artworkCenterX + artworkSide * 0.5
        let metadataWidth = min(width * 0.23, 420)
        let metadataGap = width * 0.036
        let metadataRightX = artworkLeftX - metadataGap
        let metadataLeftX = artworkRightX + metadataGap
        let metadataCenterX = mirrored ? metadataLeftX + metadataWidth * 0.5 : metadataRightX - metadataWidth * 0.5
        let metadataCenterY = artworkCenterY - height * 0.045 - height * 0.036
        let titleSize = min(max(height * 0.050, 38), 56)
        let infoSize = min(max(height * 0.043, 28), 46)
        let positionSize = min(max(height * 0.026, 18), 28)
        let positionPadding = min(max(height * 0.006, 4), 10)
        let transportWidth = min(max(width * 0.5, 720), 960)
        let leadingTimeWidth = min(max(transportWidth * 0.08, 50), 82)
        let trailingTimeWidth = min(max(transportWidth * 0.10, 66), 98)
        let barWidth = max(420, transportWidth - leadingTimeWidth - trailingTimeWidth - 2)
        let barHeight: CGFloat = 20
        let timeSize = min(max(height * 0.028, 22), 34)
        let transportCenterX = mirrored ? metadataLeftX + transportWidth * 0.5 : metadataRightX - transportWidth * 0.5
        let transportCenterY = metadataCenterY + height * 0.125

        // Title, artist, album and position, stacked 2 points apart and lined up on the artwork side.
        let alignment: TextAlignment = mirrored ? .leading : .trailing
        let texts: [(SceneLayer, RenderedGraphic, CGFloat)] = {
            var result: [(SceneLayer, RenderedGraphic, CGFloat)] = [
                (title, TextRenderer.render(TextSpec(text: snapshot.trackTitle, fontName: firstRowBoldFontName, size: titleSize, maxWidth: metadataWidth, minimumScaleFactor: 0.62), scale: scale), 0),
                (artist, TextRenderer.render(TextSpec(text: snapshot.artistName, fontName: firstRowRegularFontName, size: infoSize, color: RGBA(white: 1, alpha: 0.88), maxWidth: metadataWidth, minimumScaleFactor: 0.62), scale: scale), 0),
                (album, TextRenderer.render(TextSpec(text: snapshot.albumTitle, fontName: firstRowRegularFontName, size: infoSize, color: RGBA(white: 1, alpha: 0.76), maxWidth: metadataWidth, minimumScaleFactor: 0.62), scale: scale), 0),
            ]
            if !snapshot.trackPositionText.isEmpty {
                result.append((position, TextRenderer.render(TextSpec(text: snapshot.trackPositionText, fontName: firstRowRegularFontName, size: positionSize, color: RGBA(white: 1, alpha: 0.58), maxWidth: metadataWidth), scale: scale), positionPadding))
            }
            return result
        }()
        position.isHidden = snapshot.trackPositionText.isEmpty
        // An empty line still takes its height, as an empty Text did.
        func lineHeight(_ graphic: RenderedGraphic, _ fontName: String, _ size: CGFloat) -> CGFloat {
            graphic.image == nil ? FontMetrics.lineHeight(fontName: fontName, size: size) : graphic.size.height
        }
        let heights = [
            lineHeight(texts[0].1, firstRowBoldFontName, titleSize),
            lineHeight(texts[1].1, firstRowRegularFontName, infoSize),
            lineHeight(texts[2].1, firstRowRegularFontName, infoSize),
        ] + (texts.count > 3 ? [texts[3].1.size.height] : [])
        let blockHeight = heights.reduce(0, +) + CGFloat(heights.count - 1) * 2 + (texts.count > 3 ? positionPadding : 0)
        var y = metadataCenterY - blockHeight * 0.5
        let blockLeft = metadataCenterX - metadataWidth * 0.5
        for (index, entry) in texts.enumerated() {
            y += entry.2
            let x = alignment == .leading ? blockLeft : blockLeft + metadataWidth - entry.1.size.width
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
        barFrame.frame = CGRect(x: barLeft, y: rowTop, width: barWidth, height: barHeight)
        barFrame.path = CGPath(rect: CGRect(x: 0, y: 0, width: barWidth, height: barHeight), transform: nil)
        barFill.frame = CGRect(x: barLeft, y: rowTop, width: max(0, barWidth * progress), height: barHeight)
        let diamondSize: CGFloat = 8
        let diamondCenterX = max(diamondSize * 0.5, min(barWidth - diamondSize * 0.5, progress * barWidth))
        diamond.bounds = CGRect(x: 0, y: 0, width: diamondSize, height: diamondSize)
        diamond.position = CGPoint(x: barLeft + diamondCenterX, y: rowTop + barHeight * 0.5)
        let remaining = TextRenderer.render(TextSpec(text: "-\(formatfirstRowPlaybackTime(max(0, duration - displayElapsed)))", fontName: firstRowBoldFontName, size: timeSize, color: RGBA(white: 1, alpha: 0.95), maxWidth: trailingTimeWidth, minimumScaleFactor: 0.8), scale: scale)
        let trailingRight = barLeft + barWidth + 1 + trailingTimeWidth
        trailing.show(remaining, at: CGPoint(x: trailingRight - remaining.size.width, y: rowTop + (barHeight - remaining.size.height) * 0.5))

        // Shuffle sign above the end of the bar on the artwork side.
        let shuffleGraphic = SymbolRenderer.render("shuffle", pointSize: 25, weight: .regular, color: RGBA(white: 1, alpha: 0.56), shadows: [TextShadow(color: RGBA(white: 1, alpha: 0.14), radius: 0.8)], scale: scale)
        shuffle.isHidden = !snapshot.showsShuffleGlyph
        let shuffleTop = rowTop - barHeight * 2.2
        shuffle.show(shuffleGraphic, at: CGPoint(x: mirrored ? trailingRight - shuffleGraphic.size.width : rowLeft, y: shuffleTop))

        artwork.update(image: snapshot.artworkImage, side: artworkSide, mirrored: mirrored)
        artwork.layer.position = CGPoint(x: renderedArtworkCenterX - artworkSide * 1.12 * 0.5, y: artworkCenterY - artworkSide * 1.72 * 0.5)
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
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
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
        replicator.frame = CGRect(origin: .zero, size: size)
        let length = size.height * 0.28
        let thickness = max(1.5, size.width * 0.085)
        spoke.bounds = CGRect(x: 0, y: 0, width: thickness, height: length)
        spoke.cornerRadius = thickness * 0.5
        spoke.position = CGPoint(x: size.width * 0.5, y: length * 0.5)
        guard spoke.animation(forKey: "fade") == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.25
        fade.duration = 1
        fade.repeatCount = .infinity
        spoke.add(fade, forKey: "fade")
    }

    func stop() {
        spoke.removeAllAnimations()
    }
}

// MARK: - Error and loading

/// "An error occurred." and friends: an alert sign, a headline and an explanation.
final class FeatureErrorSceneLayer: FullscreenContent {
    private let icon = SceneLayer()
    private let header = SceneLayer()
    private let subcaption = SceneLayer()
    private var key: String?

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
        let iconImage = NSImage(named: "ErrorTriangle_v1") ?? NSImage(named: "Alert!")
        let iconSide: CGFloat = iconImage == nil ? 0 : 84
        let iconSpacing: CGFloat = iconImage == nil ? 0 : 24
        let maxWidth = min(1500, size.width)
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
        let top = (size.height - stackHeight) * 0.5 - 160
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

/// "Loading Theatrical Trailers..." with a spinner below it.
final class LoadingSceneLayer: FullscreenContent {
    private let header = SceneLayer()
    private let spinner = SpinnerLayer()

    override init() {
        super.init()
        layer.addSublayer(header)
        layer.addSublayer(spinner.layer)
    }

    override func update(menu: MenuView, scene: FullscreenScenePresentation, pass _: RenderPass, size: CGSize, scale: CGFloat) {
        let text = scene.payload["header"] ?? "Loading Theatrical Trailers..."
        let graphic = TextRenderer.render(TextSpec(text: text, fontName: firstRowBoldFontName, size: 60, wrapWidth: min(1500, size.width), alignment: .center), scale: scale)
        let stackHeight = graphic.size.height + 42 + 72
        let top = (size.height - stackHeight) * 0.5
        header.show(graphic, at: CGPoint(x: (size.width - graphic.size.width) * 0.5, y: top))
        spinner.layer.isHidden = !menu.theatricalTrailersLoadingShowsSpinner
        spinner.layer.frame = CGRect(x: (size.width - 64) * 0.5, y: top + graphic.size.height + 42 + 4, width: 64, height: 64)
        if menu.theatricalTrailersLoadingShowsSpinner { spinner.start() } else { spinner.stop() }
    }
}

// MARK: - Screen saver and slideshow

final class ScreenSaverSceneLayer: FullscreenContent {
    private let space = SceneLayer()
    private let controller = ScreenSaverLayerController()

    override init() {
        super.init()
        #if os(macOS)
            space.isGeometryFlipped = true
        #endif
        layer.addSublayer(space)
        space.addSublayer(controller.rootLayer)
    }

    override func update(menu _: MenuView, scene _: FullscreenScenePresentation, pass _: RenderPass, size: CGSize, scale _: CGFloat) {
        space.frame = CGRect(origin: .zero, size: size)
        controller.rootLayer.frame = space.bounds
        controller.update(.init(photos: ScreenSaverPhotoStream.photos()), bounds: size)
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
        #if os(macOS)
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
    let layer = SceneLayer()
    private let artwork = SceneLayer()
    private let title = SceneLayer()
    private let album = SceneLayer()
    private let artist = SceneLayer()

    init() {
        layer.backgroundColor = CGColor(gray: 0, alpha: 0.5)
        layer.opacity = 0
        artwork.contentsGravity = .resizeAspectFill
        artwork.masksToBounds = true
        artwork.borderColor = CGColor(gray: 1, alpha: 0.16)
        artwork.borderWidth = 1
        for sublayer in [artwork, title, album, artist] { layer.addSublayer(sublayer) }
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat) {
        let showing = menu.activeFullscreenScene?.key == menu.screenSaverFullscreenKey
        layer.isHidden = !showing
        guard showing else {
            layer.opacity = 0
            return
        }
        let size = menu.screenSaverNowPlayingToastSize
        layer.frame = CGRect(x: 42, y: bounds.height - 36 - size.height, width: size.width, height: size.height)
        layer.setOpacity(menu.screenSaverNowPlayingToastOpacity, pass.animation)
        guard menu.screenSaverNowPlayingToastOpacity > 0 || layer.opacity > 0 else { return }
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

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
        for sublayer in [backdrop, shade, stage] {
            layer.addSublayer(sublayer)
        }
        stage.addSublayer(outgoing.layer)
        stage.addSublayer(incoming.layer)
    }

    /// The song's panels, which move aside for the list or the lyrics, and scale as Now Playing
    /// comes and goes while the blurred backdrop behind them stays put.
    private let stage = SceneLayer()

    override var scalesItsOwnForeground: Bool { true }
    private var shift: (dx: CGFloat, scale: CGFloat) = (0, 1)
    private var size: CGSize = .zero
    private var isSwitchingSong = false
    private var lastFlipAway: CGFloat = 0
    private var lastBarHeld = false

    private static func scale(_ factor: CGFloat, about center: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    /// Where the progress bar is in canvas points, or nil while songs change over.
    var progressBar: CGRect? {
        isSwitchingSong ? nil : barPlace
    }

    /// Where the progress bar sits in canvas points, songs changing over or not (the new song's).
    var barPlace: CGRect? {
        incoming.barFrame.width <= 0 ? nil : NowPlayingSideLayout.map(incoming.barFrame, shift, size: size)
    }

    override func update(menu: MenuView, scene _: FullscreenScenePresentation, pass: RenderPass, size: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        backdrop.frame = bounds
        shade.frame = bounds
        self.size = size
        stage.place(bounds)
        shift = NowPlayingSideLayout.shift(menu: menu, size: size)
        let depth = MenuSceneRenderer.scale(menu.fullscreenSceneScale, about: CGPoint(x: size.width / 2, y: size.height / 2))
        stage.setTransform(CATransform3DConcat(NowPlayingSideLayout.transform(shift, size: size), depth), pass.animation)
        let snapshot = menu.currentMusicNowPlayingSnapshot
        if snapshot.artworkImage !== backdropSource || backdropMissing {
            backdropSource = snapshot.artworkImage
            let blurred = snapshot.artworkImage.flatMap { ModernBackgroundLayer.cachedAmbient($0) }
            backdropMissing = blurred == nil
            if backdrop.contents != nil {
                backdrop.removeAnimation(forKey: "contents")
                let fade = CABasicAnimation(keyPath: "contents").preferringProMotion()
                fade.duration = 0.8
                fade.fromValue = backdrop.contents
                fade.toValue = blurred
                backdrop.add(fade, forKey: "contents")
            }
            backdrop.contents = blurred
        }

        let hasTransition = menu.musicSongTransitionSnapshot != nil
        isSwitchingSong = hasTransition
        let incomingProgress = min(max(menu.musicSongTransitionIncomingProgress, 0), 1)
        let outgoingProgress = min(max(menu.musicSongTransitionOutgoingOpacityProgress, 0), 1)
        let direction: CGFloat = menu.musicSongTransitionDirection > 0 ? 1 : -1
        // The old song eases out as the new one eases in a moment later, on quadratic curves of
        // their own rather than the classic look's slower zoom.
        // Only the moves animate: setting up a change (the new song placed off to the side) is instant.
        let moves = pass.animation != nil
        let leave: Animation? = moves ? .smoothInOut(duration: 0.42) : nil
        let arrive: Animation? = moves ? .smooth(duration: 0.55) : nil

        // Every so often the panel turns round (the artwork moves to the other side), as the
        // classic look's does, but by fading: the artwork shrinks a little as it fades and the
        // details fade, then both come back the other way round, the artwork growing back.
        let mirrored = menu.musicNowPlayingUsesAlternateLayout
        let away = min(1, abs(menu.musicNowPlayingFlipRotationDegrees) / 90)
        let turning = away != lastFlipAway
        lastFlipAway = away
        let flipAnimation = turning ? pass.animation.map { Animation.smoothInOut(duration: $0.duration) } : nil
        defer {
            // After the layout, so the artwork shrinks about where it is now.
            for panel in [incoming, outgoing] {
                let shrink = 1 - 0.16 * away
                panel.cover.setTransform(Self.scale(shrink, about: panel.coverCenter), flipAnimation)
                panel.cover.setOpacity(Double(1 - away), flipAnimation)
                panel.details.setOpacity(Double(1 - away), flipAnimation)
            }
        }

        incoming.layer.place(bounds)
        let barHeld = menu.isMusicProgressBarHeld
        let barAnimation: Animation? = barHeld != lastBarHeld ? (barHeld ? .smooth(duration: 0.28) : .smoothInOut(duration: 0.32)) : nil
        lastBarHeld = barHeld
        incoming.update(snapshot, mirrored: mirrored, barHeld: barHeld, barAnimation: barAnimation, size: size, scale: scale)
        let inShift = hasTransition ? 90 * direction * (1 - incomingProgress) : 0
        incoming.layer.setTransform(CATransform3DMakeTranslation(inShift, 0, 0), arrive)
        incoming.layer.setOpacity(hasTransition ? Double(incomingProgress) : 1, arrive)

        if let previous = menu.musicSongTransitionSnapshot {
            outgoing.layer.isHidden = false
            outgoing.layer.place(bounds)
            outgoing.update(previous, mirrored: mirrored, size: size, scale: scale)
            outgoing.layer.setTransform(CATransform3DMakeTranslation(-90 * direction * outgoingProgress, 0, 0), leave)
            outgoing.layer.setOpacity(Double(1 - outgoingProgress), leave)
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
    /// The artwork, which shrinks and fades as the panel turns round, and the details, which fade.
    let cover = SceneLayer()
    let details = SceneLayer()
    private(set) var coverCenter: CGPoint = .zero
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
        layer.addSublayer(cover)
        layer.addSublayer(details)
        for sublayer in [artworkShadow, artwork] {
            cover.addSublayer(sublayer)
        }
        for sublayer in [title, artist, album, position, shuffle, track, elapsed, remaining, glyph.layer] {
            details.addSublayer(sublayer)
        }
    }

    /// Lays the panel out, the artwork on the left or, `mirrored`, on the right.
    /// A scale about `anchor` (in the layer's own points), then a move.
    private static func scale(_ factor: CGFloat, about anchor: CGPoint, then offset: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(offset.x + anchor.x, offset.y + anchor.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -anchor.x, -anchor.y, 0)
    }

    func update(_ snapshot: MenuView.MusicNowPlayingSnapshot, mirrored: Bool = false, barHeld: Bool = false, barAnimation: Animation? = nil, size: CGSize, scale: CGFloat) {
        cover.place(CGRect(origin: .zero, size: size))
        details.place(CGRect(origin: .zero, size: size))
        let width = size.width
        let height = size.height
        // The artwork and the details beside it are centred together on the screen.
        let side = min(height * 0.56, width * 0.34)
        let gap = (side * 0.17).rounded()
        let columnWidth = min(side * 1.5, width - side - gap - width * 0.12)
        let left = ((width - side - gap - columnWidth) * 0.5).rounded()
        let artLeft = mirrored ? left + columnWidth + gap : left
        let artCenter = CGPoint(x: artLeft + side / 2, y: height * 0.49)
        let art = CGRect(x: artLeft, y: artCenter.y - side / 2, width: side, height: side)
        coverCenter = artCenter
        let radius = side * 0.035
        artworkShadow.frame = art
        artworkShadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: art.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        artwork.frame = art
        artwork.cornerRadius = radius
        artwork.contents = LayerImageCache.cgImage(for: snapshot.artworkImage)

        let columnLeft = mirrored ? left : art.maxX + gap
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
        // Held for scrubbing, the bar swells (taller, a little wider, its fill bright white)
        // and the times come out with its ends, brighter and a touch larger.
        let rest = CGRect(x: columnLeft, y: y, width: columnWidth, height: barHeight)
        let grownBy = CGSize(width: 22, height: 6)
        barFrame = barHeld ? rest.insetBy(dx: -grownBy.width, dy: -grownBy.height) : rest
        track.setFrame(barFrame, barAnimation)
        track.set("cornerRadius", to: barFrame.height / 2, unchanged: track.cornerRadius == barFrame.height / 2, animation: barAnimation)
        // The fill spans the whole bar (and is taller than it ever gets: the bar's rounded clip
        // gives it its shape), so it grows and shrinks with the bar in one animation; how much
        // has played is a squeeze from its left end, which the progress ticks change without
        // cutting that animation short.
        fill.setFrame(CGRect(x: 0, y: 0, width: barFrame.width, height: 60), barAnimation)
        fill.setTransform(CATransform3DMakeScale(max(0.0001, min(1, progress)), 1, 1), nil)
        let fillAlpha: CGFloat = barHeld ? 1 : 0.8
        fill.set("backgroundColor", to: CGColor(gray: 1, alpha: fillAlpha), unchanged: fill.backgroundColor?.alpha == fillAlpha, animation: barAnimation)
        y += barHeight + 12
        let timeColor = RGBA(white: 1, alpha: 1)
        let elapsedGraphic = TextRenderer.render(TextSpec(text: formatfirstRowPlaybackTime(elapsedSeconds), fontName: ModernTheme.mediumFontName, size: 26, color: timeColor), scale: scale)
        elapsed.show(elapsedGraphic, at: CGPoint(x: columnLeft, y: y))
        let remainingGraphic = TextRenderer.render(TextSpec(text: formatfirstRowRemainingTime(duration: duration, elapsed: elapsedSeconds), fontName: ModernTheme.mediumFontName, size: 26, color: timeColor), scale: scale)
        remaining.show(remainingGraphic, at: CGPoint(x: columnLeft + columnWidth - remainingGraphic.size.width, y: y))
        let timeScale: CGFloat = barHeld ? 1.08 : 1
        let drop = barHeld ? grownBy.height + 2 : 0
        let out = barHeld ? grownBy.width : 0
        elapsed.setTransform(Self.scale(timeScale, about: .zero, then: CGPoint(x: -out, y: drop)), barAnimation)
        remaining.setTransform(Self.scale(timeScale, about: CGPoint(x: remainingGraphic.size.width, y: 0), then: CGPoint(x: out, y: drop)), barAnimation)
        for label in [elapsed, remaining] {
            label.setOpacity(barHeld ? 1 : 0.6, barAnimation)
        }
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

    /// The bar and the span the playhead travels, for pointing at it.
    var seekTrack: (frame: CGRect, travel: ClosedRange<CGFloat>)? {
        barFrame.width > 0 ? (barFrame, barFrame.minX ... barFrame.maxX) : nil
    }

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
        let remainingText = isLoading || !hasDuration ? "" : formatfirstRowRemainingTime(duration: totalSeconds, elapsed: seconds)
        let remainingGraphic = TextRenderer.render(TextSpec(text: remainingText, fontName: ModernTheme.mediumFontName, size: 28, color: timeColor), scale: scale)
        remaining.show(remainingGraphic, at: CGPoint(x: barFrame.maxX - remainingGraphic.size.width, y: timeY))

        glyph.update(glyphState, pointSize: 34, shadows: [TextShadow(color: RGBA(white: 0, alpha: 0.5), radius: 4)], scale: scale, showsPlayGlyph: true)
        glyph.layer.frame = CGRect(x: barFrame.minX, y: barFrame.minY - 30 - glyph.size.height, width: glyph.size.width, height: glyph.size.height)
    }
}

/// The movie's subtitles, audio and speed, in one panel: in the modern look it grows out of one
/// options button above the right end of the progress bar, as on iPhone; in the classic look,
/// which has no button, ↓ scales it open. Each row of the panel has its name on the left and its
/// value, with arrows to change it, on the right.
@MainActor
final class MovieOptionsLayer {
    let layer = SceneLayer()
    private let buttons = SceneLayer()
    private let buttonHighlight = SceneLayer()
    private var buttonIcons: [MenuView.MovieOptionRow.Kind: SceneLayer] = [:]
    private var buttonsKey = ""
    private let panel = SceneLayer()
    private let modernFocus = SceneLayer()
    private let classicFocus = SelectionBoxLayer()
    private var rows: [(title: SceneLayer, value: SceneLayer)] = []
    private var lastFocus: Int?
    /// What the panel last showed, kept while it goes back into its buttons.
    private var shownState: MenuView.MovieOptionsState?
    private var wasOpen = false
    /// The panel and its rows in canvas points, for touches and clicks (only while it's open).
    private(set) var panelFrame: CGRect?
    private(set) var rowFrames: [CGRect] = []
    /// Each row's value, "‹" to "›", in canvas points.
    private(set) var valueFrames: [CGRect] = []
    /// The buttons above the bar, in canvas points, while they show.
    private(set) var buttonFrames: [(kind: MenuView.MovieOptionRow.Kind, frame: CGRect)] = []

    static let buttonSlot = CGSize(width: 84, height: 72)

    init() {
        layer.addSublayer(buttons)
        buttons.addSublayer(buttonHighlight)
        buttons.opacity = 0
        layer.addSublayer(panel)
        panel.addSublayer(classicFocus.layer)
        modernFocus.backgroundColor = ModernTheme.focusFill.cgColor
        panel.addSublayer(modernFocus)
        panel.opacity = 0
        panel.isHidden = true
    }

    /// The one button's symbol, for all the options at once.
    static let optionsSymbol = "ellipsis"

    static func symbol(for kind: MenuView.MovieOptionRow.Kind) -> String {
        switch kind {
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .speed: "gauge.with.dots.needle.67percent"
        }
    }

    /// `anchor` is the progress bar (canvas points) while the controls show, nil while they don't.
    /// The system's Liquid Glass for the buttons and panel, where there is some (modern look).
    private var nativeGlass: AnyObject? {
        #if os(iOS) || os(macOS)
            if #available(macOS 26.0, iOS 26.0, *), ModernTheme.isActive {
                return NativeControls.shared?.options
            }
        #endif
        return nil
    }

    /// `canvasScale` is window points per canvas point (for the native glass).
    func update(menu: MenuView, anchor: CGRect?, controlsOpacity: Double, size: CGSize, scale: CGFloat, canvasScale: CGFloat, pass: RenderPass) {
        layer.frame = CGRect(origin: .zero, size: size)
        let isModern = ModernTheme.isActive
        let usesNativeGlass = nativeGlass != nil
        let state = menu.isMoviePlaybackVisible ? menu.movieOptions : nil
        if let state { shownState = state }
        let isOpen = state != nil && menu.movieOptionsReveal > 0.5

        // One button for everything the movie offers (it opens the panel on its first row),
        // picked out while the panel's open. The classic look has none: ↓ opens the panel.
        let kinds = menu.movieOptionKinds.first.map { [$0] } ?? []
        let slot = Self.buttonSlot
        let showsButtons = isModern && anchor != nil && menu.isMoviePlaybackVisible && !kinds.isEmpty
        var clusterFrame = CGRect.zero
        if let anchor {
            let width = slot.width * CGFloat(max(1, kinds.count)) + 12
            clusterFrame = CGRect(x: anchor.maxX - width, y: anchor.minY - 26 - slot.height, width: width, height: slot.height)
        }
        buttonFrames = []
        if showsButtons {
            buttons.place(clusterFrame)
            buttons.cornerRadius = slot.height / 2
            buttons.backgroundColor = isModern ? CGColor(gray: 0.2, alpha: 0.62) : CGColor(gray: 0, alpha: 0.62)
            buttons.borderWidth = isModern ? 0 : 1.5
            buttons.borderColor = CGColor(gray: 1, alpha: 0.3)
            let key = "\(kinds)|\(isModern)|\(scale)"
            if key != buttonsKey {
                buttonsKey = key
                for (_, icon) in buttonIcons { icon.removeFromSuperlayer() }
                buttonIcons = [:]
                for (index, kind) in kinds.enumerated() {
                    let icon = SceneLayer()
                    let graphic = SymbolRenderer.render(Self.optionsSymbol, pointSize: 30, weight: .semibold, color: .white, scale: scale)
                    let center = CGPoint(x: 6 + slot.width * (CGFloat(index) + 0.5), y: slot.height / 2)
                    icon.show(graphic, at: CGPoint(x: (center.x - graphic.size.width / 2).rounded(), y: (center.y - graphic.size.height / 2).rounded()))
                    buttons.addSublayer(icon)
                    buttonIcons[kind] = icon
                }
            }
            for (index, kind) in kinds.enumerated() {
                let local = CGRect(x: 6 + slot.width * CGFloat(index), y: 0, width: slot.width, height: slot.height)
                buttonFrames.append((kind, local.offsetBy(dx: clusterFrame.minX, dy: clusterFrame.minY)))
            }
            // The button wears a soft circle while the panel's open.
            if isOpen, let index = kinds.indices.first {
                let side = slot.height - 14
                let frame = CGRect(x: 6 + slot.width * (CGFloat(index) + 0.5) - side / 2, y: 7, width: side, height: side)
                let appearing = buttonHighlight.opacity < 0.01
                buttonHighlight.setFrame(frame, appearing ? nil : .smooth(duration: 0.22))
                buttonHighlight.cornerRadius = side / 2
                buttonHighlight.backgroundColor = CGColor(gray: 1, alpha: 0.26)
                buttonHighlight.setOpacity(1, .smooth(duration: 0.2))
            } else {
                buttonHighlight.setOpacity(0, .smooth(duration: 0.2))
            }
        }
        buttons.setOpacity(showsButtons && !usesNativeGlass ? controlsOpacity : 0, pass.animation)
        #if os(iOS) || os(macOS)
            if #available(macOS 26.0, iOS 26.0, *), let glass = nativeGlass as? NativeOptionsGlass {
                // The system's glass instead, with the system's symbol, in window points.
                let windowFrame = CGRect(x: clusterFrame.minX * canvasScale, y: clusterFrame.minY * canvasScale, width: clusterFrame.width * canvasScale, height: clusterFrame.height * canvasScale)
                glass.updateCluster(
                    frame: showsButtons && controlsOpacity > 0.5 ? windowFrame : nil,
                    symbols: kinds.map { _ in Self.optionsSymbol },
                    slotWidth: slot.width * canvasScale,
                    focused: isOpen && !kinds.isEmpty ? 0 : nil,
                    iconSize: 30 * canvasScale,
                    animation: pass.animation ?? .smooth(duration: 0.3),
                )
            }
        #endif

        // The panel, grown out of the buttons, or gone back into them.
        guard let content = shownState, !content.rows.isEmpty else {
            panel.isHidden = true
            panelFrame = nil
            rowFrames = []
            valueFrames = []
            return
        }
        // With the system's glass, the panel's rows are hosted inside it; without, the panel
        // draws its own background here.
        #if os(iOS) || os(macOS)
            if #available(macOS 26.0, iOS 26.0, *), let glass = nativeGlass as? NativeOptionsGlass {
                let host = glass.panelLayerHost
                if panel.superlayer !== host {
                    panel.removeAllAnimations()
                    host.addSublayer(panel)
                }
            } else if panel.superlayer !== layer {
                panel.removeAllAnimations()
                layer.addSublayer(panel)
            }
        #endif
        let opening = isOpen && !wasOpen
        let closing = !isOpen && wasOpen
        if opening { panel.isHidden = false }
        let width: CGFloat = 760
        let rowHeight: CGFloat = 72
        let inset: CGFloat = 16
        let height = CGFloat(content.rows.count) * rowHeight + inset * 2
        // Above the right end of the bar, where the button is (or would be).
        let buttonPlace = anchor.map { CGRect(x: $0.maxX - slot.width - 12, y: $0.minY - 26 - slot.height, width: slot.width + 12, height: slot.height) }
        let reference = showsButtons ? clusterFrame : (buttonPlace ?? CGRect(x: size.width - 110 - 260, y: size.height - 240, width: 260, height: slot.height))
        let frame = CGRect(x: max(40, reference.maxX - width), y: reference.minY - 18 - height, width: width, height: height)
        // Grows from (and shrinks back to) the middle of the button; with no button, scales open
        // about its own middle.
        let origin = showsButtons
            ? CGPoint(x: reference.midX - frame.minX, y: reference.midY - frame.minY)
            : CGPoint(x: frame.width / 2, y: frame.height / 2)
        let collapsedScale: CGFloat = showsButtons ? 0.2 : 0.86
        let move: Animation? = opening || closing ? (pass.animation ?? (opening ? .smooth(duration: 0.36) : .smoothInOut(duration: 0.3))) : nil
        if usesNativeGlass {
            #if os(iOS) || os(macOS)
                if #available(macOS 26.0, iOS 26.0, *), let glass = nativeGlass as? NativeOptionsGlass {
                    // Drawn at canvas size inside the glass, which is in window points.
                    panel.backgroundColor = CGColor(gray: 0, alpha: 0)
                    panel.cornerRadius = 0
                    panel.borderWidth = 0
                    panel.isHidden = false
                    panel.setOpacity(1, nil)
                    panel.bounds = CGRect(origin: .zero, size: frame.size)
                    panel.position = .zero
                    panel.setTransform(CATransform3DMakeScale(canvasScale, canvasScale, 1), nil)
                    let windowFrame = CGRect(x: frame.minX * canvasScale, y: frame.minY * canvasScale, width: frame.width * canvasScale, height: frame.height * canvasScale)
                    let pivot = CGPoint(x: origin.x * canvasScale, y: origin.y * canvasScale)
                    var collapsed = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
                    collapsed = CATransform3DScale(collapsed, collapsedScale, collapsedScale, 1)
                    collapsed = CATransform3DTranslate(collapsed, -pivot.x, -pivot.y, 0)
                    glass.updatePanel(frame: windowFrame, open: isOpen, collapsed: collapsed, animation: move)
                }
            #endif
        } else {
            panel.place(frame)
            panel.backgroundColor = CGColor(gray: isModern ? 0.08 : 0, alpha: isModern ? 0.84 : 0.88)
            panel.cornerRadius = isModern ? 34 : 14
            panel.borderWidth = isModern ? 0 : 1.5
            panel.borderColor = CGColor(gray: 1, alpha: 0.22)
            var collapsed = CATransform3DMakeTranslation(origin.x, origin.y, 0)
            collapsed = CATransform3DScale(collapsed, collapsedScale, collapsedScale, 1)
            collapsed = CATransform3DTranslate(collapsed, -origin.x, -origin.y, 0)
            if opening, (panel.presentation()?.opacity ?? panel.opacity) < 0.02 {
                // Starts from the button, or a little smaller (part way back, it turns round
                // where it is instead).
                panel.setTransform(collapsed, nil)
                panel.setOpacity(0, nil)
            }
            panel.setTransform(isOpen ? CATransform3DIdentity : collapsed, move)
            panel.setOpacity(isOpen ? 1 : 0, move)
        }
        wasOpen = isOpen
        if isOpen {
            panelFrame = frame
            rowFrames = content.rows.indices.map { CGRect(x: frame.minX + inset, y: frame.minY + inset + CGFloat($0) * rowHeight, width: width - inset * 2, height: rowHeight) }
        } else {
            panelFrame = nil
            rowFrames = []
        }

        let focus = min(content.focusedRow, content.rows.count - 1)
        let moved = lastFocus != nil && lastFocus != focus
        lastFocus = focus
        let focusFrame = CGRect(x: inset, y: inset + CGFloat(focus) * rowHeight + 4, width: width - inset * 2, height: rowHeight - 8)
        modernFocus.isHidden = !isModern
        classicFocus.layer.isHidden = isModern
        if isModern {
            modernFocus.setFrame(focusFrame, nil)
            modernFocus.cornerRadius = focusFrame.height / 2
        } else {
            // The glow texture reaches past the row as the menus' does, scaled to this row's height.
            let spill = focusFrame.height / 75
            classicFocus.update(frame: focusFrame.insetBy(dx: -40 * spill, dy: -29 * spill), selectionBoxHeight: focusFrame.height, animation: opening || !moved ? nil : .easeInOut(duration: 0.2))
        }

        var values: [CGRect] = []
        while rows.count < content.rows.count {
            let pair = (SceneLayer(), SceneLayer())
            panel.addSublayer(pair.0)
            panel.addSublayer(pair.1)
            rows.append(pair)
        }
        for (index, pair) in rows.enumerated() {
            guard content.rows.indices.contains(index) else {
                pair.title.isHidden = true
                pair.value.isHidden = true
                continue
            }
            pair.title.isHidden = false
            pair.value.isHidden = false
            let row = content.rows[index]
            let focused = index == focus && isModern
            let primary = focused ? ModernTheme.focusedText : RGBA(white: 1, alpha: 0.94)
            let secondary = focused ? ModernTheme.focusedSecondaryText : RGBA(white: 1, alpha: 0.6)
            let titleFont = isModern ? ModernTheme.mediumFontName : firstRowBoldFontName
            let valueFont = isModern ? ModernTheme.regularFontName : firstRowRegularFontName
            let top = inset + CGFloat(index) * rowHeight
            let titleGraphic = TextRenderer.render(TextSpec(text: row.title, fontName: titleFont, size: 32, color: primary), scale: scale)
            pair.title.show(titleGraphic, at: CGPoint(x: inset + 30, y: top + (rowHeight - titleGraphic.size.height) / 2))
            let value = row.values.indices.contains(row.selected) ? row.values[row.selected] : ""
            let canGoBack = row.selected > 0
            let canGoOn = row.selected + 1 < row.values.count
            let text = (canGoBack ? "‹  " : "   ") + value + (canGoOn ? "  ›" : "   ")
            let valueGraphic = TextRenderer.render(TextSpec(text: text, fontName: valueFont, size: 30, color: secondary, maxWidth: width * 0.6, minimumScaleFactor: 0.7), scale: scale)
            let valueOrigin = CGPoint(x: width - inset - 26 - valueGraphic.size.width, y: top + (rowHeight - valueGraphic.size.height) / 2)
            pair.value.show(valueGraphic, at: valueOrigin)
            values.append(CGRect(origin: valueOrigin, size: valueGraphic.size).offsetBy(dx: frame.minX, dy: frame.minY))
        }
        valueFrames = isOpen ? values : []
    }

    /// The button at a canvas point (with a little room around each).
    func button(at point: CGPoint) -> MenuView.MovieOptionRow.Kind? {
        buttonFrames.first { $0.frame.insetBy(dx: -4, dy: -12).contains(point) }?.kind
    }
}

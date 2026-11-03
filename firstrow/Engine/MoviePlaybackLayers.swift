import AVFoundation
import CoreImage
import QuartzCore
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Movie playback: the video itself and the transport bar shown over it.
@MainActor
final class MoviePlaybackLayers {
    let playerLayer = AVPlayerLayer()
    let controls = MovieControlsLayer()

    init() {
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        playerLayer.isHidden = true
        playerLayer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        controls.layer.isHidden = true
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat) {
        let showsPlayer = menu.isMoviePlaybackVisible && menu.moviePlayer != nil
        if playerLayer.player !== menu.moviePlayer, showsPlayer || menu.moviePlayer == nil {
            playerLayer.player = menu.moviePlayer
        }
        playerLayer.isHidden = !showsPlayer
        if !showsPlayer, playerLayer.player != nil, !menu.isMoviePlaybackVisible {
            playerLayer.player = nil
        }
        playerLayer.frame = bounds

        let showsControls = menu.isMoviePlaybackVisible && menu.areMovieControlsVisible
        controls.layer.isHidden = !showsControls
        guard showsControls else { return }
        controls.layer.frame = bounds
        controls.update(
            glyphState: menu.movieControlsGlyphState,
            currentTime: menu.moviePlaybackCurrentSeconds,
            duration: menu.moviePlaybackDurationSeconds,
            isLoading: menu.isMoviePreviewDownloadLoading,
            loadingProgress: menu.moviePreviewDownloadProgress,
            size: bounds.size,
            scale: scale,
        )
        controls.layer.setOpacity(menu.movieControlsOpacity, pass.animation)
    }
}

/// The glossy transport bar: play state on the left, the track with its position diamond,
/// the length on the right and the current time under the diamond.
@MainActor
final class MovieControlsLayer {
    let layer = SceneLayer()
    private let bar = SceneLayer()
    private let base = SceneLayer()
    private let track = SceneLayer()
    private let trackMask = SceneShapeLayer()
    private let trackFill = SceneLayer()
    private let trackFillImage = SceneLayer()
    private let diamond = SceneLayer()
    private let glyph = PlaybackGlyphLayer()
    private let duration = SceneLayer()
    private let currentTime = SceneLayer()
    private var artworkKey: String?

    private static let trackTop = RGBA(red: 70 / 255, green: 140 / 255, blue: 205 / 255)
    private static let trackMid = RGBA(red: 55 / 255, green: 165 / 255, blue: 210 / 255)
    private static let trackBottom = RGBA(red: 60 / 255, green: 218 / 255, blue: 235 / 255)
    private static let trackBlend = RGBA(red: 58 / 255, green: 191 / 255, blue: 223 / 255)

    init() {
        layer.addSublayer(bar)
        bar.addSublayer(base)
        bar.addSublayer(track)
        track.mask = trackMask
        track.addSublayer(trackFill)
        trackFill.masksToBounds = true
        trackFill.addSublayer(trackFillImage)
        diamond.backgroundColor = CGColor(gray: 0, alpha: 1)
        diamond.cornerRadius = 1.8
        diamond.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        diamond.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
        bar.addSublayer(diamond)
        bar.addSublayer(glyph.layer)
        bar.addSublayer(duration)
        bar.shadowColor = CGColor(gray: 0, alpha: 1)
        bar.shadowOpacity = 0.8
        bar.shadowRadius = 5
        bar.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(currentTime)
    }

    func update(glyphState: MoviePlaybackGlyphState, currentTime seconds: Double, duration totalSeconds: Double, isLoading: Bool, loadingProgress: Double, size: CGSize, scale: CGFloat) {
        let controlWidth = min(size.width * 0.94, 1600)
        let trackHeight: CGFloat = 38
        let inset: CGFloat = 4
        let laneWidth = max(0, controlWidth - inset * 2)
        let sideWidth = laneWidth * 0.10
        let centerWidth = max(0, laneWidth - sideWidth * 2)
        let centerHeight = max(0, trackHeight - inset * 2)
        let diamondSize: CGFloat = 18
        let hasDuration = totalSeconds.isFinite && totalSeconds > 0.001
        let progress = hasDuration ? max(0, min(1, seconds / totalSeconds)) : 0
        let displayedProgress = isLoading ? max(0, min(1, loadingProgress)) : progress
        let centerStartX = inset + sideWidth
        let travelStartX = centerStartX + min(16, centerWidth * 0.5)
        let travelWidth = max(0, centerWidth - (travelStartX - centerStartX) * 2)
        let diamondCenterX = travelStartX + travelWidth * CGFloat(progress)
        let barFrame = CGRect(x: (size.width - controlWidth) * 0.5, y: size.height - 52 - 28 - trackHeight, width: controlWidth, height: trackHeight)
        bar.frame = barFrame
        bar.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: controlWidth, height: trackHeight), cornerWidth: trackHeight * 0.5, cornerHeight: trackHeight * 0.5, transform: nil)

        let key = "\(controlWidth)|\(isLoading)|\(scale)"
        if key != artworkKey {
            artworkKey = key
            base.contents = Self.baseImage(width: controlWidth, height: trackHeight, scale: scale)
            base.frame = CGRect(x: 0, y: 0, width: controlWidth, height: trackHeight)
            let trackSize = CGSize(width: centerWidth, height: centerHeight)
            track.frame = CGRect(x: centerStartX, y: inset, width: centerWidth, height: centerHeight)
            trackMask.frame = track.bounds
            trackMask.path = CGPath(roundedRect: track.bounds, cornerWidth: centerHeight * 0.5, cornerHeight: centerHeight * 0.5, transform: nil)
            track.contents = isLoading ? Self.loadingTrackImage(size: trackSize, scale: scale) : Self.trackImage(size: trackSize, scale: scale)
            trackFillImage.contents = Self.trackImage(size: trackSize, scale: scale)
            trackFillImage.frame = CGRect(origin: .zero, size: trackSize)
        }
        track.opacity = (isLoading && displayedProgress >= 0.999) ? 0 : 1
        trackFill.isHidden = !isLoading
        trackFill.frame = CGRect(x: 0, y: 0, width: centerWidth * CGFloat(displayedProgress), height: centerHeight)
        if isLoading, displayedProgress >= 0.999 {
            track.opacity = 1
        }

        diamond.isHidden = isLoading
        diamond.bounds = CGRect(x: 0, y: 0, width: diamondSize, height: diamondSize)
        let diamondLeft = max(inset, min(controlWidth - inset - diamondSize, diamondCenterX - diamondSize * 0.5))
        diamond.position = CGPoint(x: diamondLeft + diamondSize * 0.5, y: trackHeight * 0.5)

        let glow = [TextShadow(color: RGBA(white: 1, alpha: 0.45), radius: 1.8), TextShadow(color: RGBA(white: 1, alpha: 0.2), radius: 3.2)]
        glyph.update(glyphState, pointSize: 23, shadows: glow, scale: scale, showsPlayGlyph: true)
        glyph.layer.frame = CGRect(
            x: inset + (sideWidth - glyph.size.width) * 0.5,
            y: (trackHeight - glyph.size.height) * 0.5,
            width: glyph.size.width,
            height: glyph.size.height,
        )

        let durationText = isLoading || totalSeconds <= 0.001 ? "" : formatfirstRowPlaybackTime(totalSeconds)
        let durationGraphic = TextRenderer.render(TextSpec(text: durationText, fontName: firstRowBoldFontName, size: 30), scale: scale)
        duration.isHidden = durationText.isEmpty
        duration.show(durationGraphic, at: CGPoint(x: inset + laneWidth - sideWidth * 0.5 - durationGraphic.size.width * 0.5, y: (trackHeight - durationGraphic.size.height) * 0.5))

        let timeGraphic = TextRenderer.render(TextSpec(text: formatfirstRowPlaybackTime(seconds), fontName: firstRowBoldFontName, size: 22, shadows: [TextShadow(color: RGBA(white: 0, alpha: 0.8), radius: 2, offset: CGSize(width: 0, height: 1))]), scale: scale)
        currentTime.isHidden = isLoading
        currentTime.show(timeGraphic, at: CGPoint(x: barFrame.minX + diamondCenterX - timeGraphic.size.width * 0.5, y: barFrame.maxY + 16 - timeGraphic.size.height * 0.5))
    }

    // MARK: - Artwork

    private static func baseImage(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        TextRenderer.draw(size: CGSize(width: width, height: height), padding: 0, scale: scale, shadows: []) { context in
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            context.addPath(capsule(full))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            let inner = CGRect(x: 1, y: 0.5, width: width - 2, height: height - 2)
            context.saveGState()
            context.addPath(capsule(inner))
            context.clip()
            gradient(context, in: inner, stops: [(.black, 0), (.black, 0.6), (RGBA(red: 20 / 255, green: 30 / 255, blue: 40 / 255, alpha: 0.92), 1)])
            // Upper gloss, inside a mask with curved lower corners.
            let gloss = upperGlossPath(in: inner)
            context.addPath(gloss)
            context.clip()
            let upper = RGBA(red: 20 / 255, green: 36 / 255, blue: 50 / 255)
            gradient(context, in: inner, stops: [(upper.opacity(0.92), 0), (upper.opacity(0.78), 0.5), (.clear, 1)])
            context.restoreGState()
        }.image
    }

    private static func trackImage(size: CGSize, scale: CGFloat) -> CGImage? {
        TextRenderer.draw(size: size, padding: 0, scale: scale, shadows: []) { context in
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            let rect = CGRect(origin: .zero, size: size)
            gradient(context, in: rect, stops: [(trackTop, 0), (trackMid, 0.42), (trackBlend, 0.56), (trackBottom, 1)])
            gradient(context, in: rect, stops: [(RGBA(white: 1, alpha: 0.22), 0), (RGBA(white: 1, alpha: 0.10), 0.24), (.clear, 0.58)])
            let bandHeight = size.height * 0.26
            let band = CGRect(x: 0, y: (size.height - bandHeight) * 0.5, width: size.width, height: bandHeight)
            gradient(context, in: band, stops: [(trackMid.opacity(0.30), 0), (trackBlend.opacity(0.32), 0.5), (trackBottom.opacity(0.24), 1)])
        }.image
    }

    private static func loadingTrackImage(size: CGSize, scale: CGFloat) -> CGImage? {
        TextRenderer.draw(size: size, padding: 0, scale: scale, shadows: []) { context in
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            let rect = CGRect(origin: .zero, size: size)
            gradient(context, in: rect, stops: [(RGBA(white: 0, alpha: 0.52), 0), (RGBA(white: 0, alpha: 0.64), 1)])
            gradient(context, in: rect, stops: [(RGBA(white: 1, alpha: 0.10), 0), (RGBA(white: 1, alpha: 0.03), 0.42), (.clear, 0.80)])
        }.image
    }

    private static func capsule(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: rect.height * 0.5, cornerHeight: rect.height * 0.5, transform: nil)
    }

    /// Top-to-bottom gradient (the context is set up with y down).
    private static func gradient(_ context: CGContext, in rect: CGRect, stops: [(RGBA, CGFloat)]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(\.0.cgColor) as CFArray, locations: stops.map(\.1)) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func upperGlossPath(in rect: CGRect) -> CGPath {
        let sideCurveWidth = rect.width * 0.016
        let topEdgeY = rect.minY + rect.height * 0.02
        let sideBottomY = rect.minY + rect.height * 0.06
        let flatBottomY = rect.minY + rect.height * 0.50
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: sideBottomY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - sideCurveWidth, y: flatBottomY), control: CGPoint(x: rect.maxX - sideCurveWidth * 0.08, y: flatBottomY))
        path.addLine(to: CGPoint(x: rect.minX + sideCurveWidth, y: flatBottomY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: sideBottomY), control: CGPoint(x: rect.minX + sideCurveWidth * 0.08, y: flatBottomY))
        path.closeSubpath()
        return path
    }
}

/// "Resume Playing / Start from Beginning" over a blurred frame of the movie.
@MainActor
final class MovieResumePromptLayer {
    let layer = SceneLayer()
    private let backdrop = SceneLayer()
    private let dim = SceneLayer()
    private let options = SceneLayer()
    private let selection = SelectionBoxLayer()
    private let pressed = SceneLayer()
    private let labels = [SceneLayer(), SceneLayer()]
    private var lastSelectedIndex: Int?
    private var backdropSource: NSImage?
    private var wasVisible = false

    init() {
        layer.opacity = 0
        layer.isHidden = true
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        backdrop.backgroundColor = CGColor(gray: 0, alpha: 1)
        dim.backgroundColor = CGColor(gray: 0, alpha: 0.33)
        pressed.backgroundColor = CGColor(gray: 0, alpha: 1)
        pressed.cornerRadius = 5
        layer.addSublayer(backdrop)
        layer.addSublayer(dim)
        layer.addSublayer(options)
        options.addSublayer(pressed)
        options.addSublayer(selection.layer)
        for label in labels { options.addSublayer(label) }
    }

    func update(menu: MenuView, pass: RenderPass, sceneSize: CGSize, scale: CGFloat) {
        guard menu.isMovieResumePromptVisible else {
            layer.isHidden = true
            layer.opacity = 0
            wasVisible = false
            lastSelectedIndex = nil
            return
        }
        let appearing = !wasVisible
        wasVisible = true
        layer.isHidden = false
        layer.frame = CGRect(origin: .zero, size: sceneSize)
        backdrop.frame = layer.bounds
        dim.frame = layer.bounds
        if menu.movieResumePromptBackdropImage !== backdropSource {
            backdropSource = menu.movieResumePromptBackdropImage
            backdrop.contents = backdropSource.flatMap { BlurredBackdrop.image(for: $0, size: sceneSize) }
        }
        let optionWidth = min(menu.menuWidthConstrained(sceneSize: sceneSize) * 0.88, 860)
        let optionHeight = menu.selectionBoxHeight
        let visualWidth = optionWidth + menu.selectionTextureVisualWidthDelta + menu.movieResumeSelectionTextureLeadingAdjustment + menu.movieResumeSelectionTextureTrailingAdjustment
        let visualHeight = optionHeight + menu.selectionTextureVisualHeightDelta
        let visualXOffset = -((visualWidth - optionWidth) * 0.5) + ((menu.movieResumeSelectionTextureTrailingAdjustment - menu.movieResumeSelectionTextureLeadingAdjustment) * 0.5)
        let visualYOffset = -((visualHeight - optionHeight) * 0.5)
        let rowSpacing: CGFloat = 10
        let selectedOffset = CGFloat(menu.movieResumePromptSelectedIndex) * (optionHeight + rowSpacing)
        let stackHeight = optionHeight * 2 + rowSpacing
        options.frame = CGRect(x: (sceneSize.width - optionWidth) * 0.5, y: (sceneSize.height - stackHeight) * 0.5, width: optionWidth, height: stackHeight)
        let moved = lastSelectedIndex != nil && lastSelectedIndex != menu.movieResumePromptSelectedIndex
        let slide = appearing ? nil : pass.animation(.easeInOut(duration: menu.movieResumePromptSelectionSlideDuration), when: moved)
        lastSelectedIndex = menu.movieResumePromptSelectedIndex
        pressed.isHidden = !menu.movieResumePromptSolidBlackSelected
        selection.layer.isHidden = menu.movieResumePromptSolidBlackSelected
        pressed.setFrame(CGRect(x: 12, y: selectedOffset, width: max(0, optionWidth - 12), height: optionHeight), slide)
        selection.update(frame: CGRect(x: visualXOffset, y: selectedOffset + visualYOffset, width: visualWidth, height: visualHeight), selectionBoxHeight: menu.selectionBoxHeight, animation: slide)
        for (index, title) in ["Resume Playing", "Start from Beginning"].enumerated() {
            let isSelected = index == menu.movieResumePromptSelectedIndex
            let hidden = (menu.movieResumePromptSolidBlackSelected && isSelected) || (menu.movieResumePromptHideUnselected && !isSelected)
            let graphic = TextRenderer.render(TextSpec(text: title, fontName: firstRowBoldFontName, size: 45, maxWidth: optionWidth, minimumScaleFactor: 0.72), scale: scale)
            labels[index].show(graphic, at: CGPoint(x: 32, y: CGFloat(index) * (optionHeight + rowSpacing) + (optionHeight - graphic.size.height) * 0.5))
            labels[index].opacity = hidden ? 0 : 1
        }
        layer.setOpacity(menu.movieResumePromptOpacity, appearing ? nil : pass.animation)
    }
}

/// A movie frame blurred and slightly desaturated, for behind the resume prompt.
@MainActor
enum BlurredBackdrop {
    private static var cache: [ObjectIdentifier: (NSImage, CGImage)] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(for source: NSImage, size: CGSize) -> CGImage? {
        if let cached = cache[ObjectIdentifier(source)], cached.0 === source {
            return cached.1
        }
        guard let cgImage = LayerImageCache.cgImage(for: source) else { return nil }
        // Work at half the scene's size: the result is a soft blur either way.
        let workScale: CGFloat = 0.5
        let target = CGSize(width: size.width * workScale, height: size.height * workScale)
        var image = CIImage(cgImage: cgImage)
        let fill = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let crop = CGRect(
            x: image.extent.midX - target.width * 0.5,
            y: image.extent.midY - target.height * 0.5,
            width: target.width,
            height: target.height,
        )
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.92])
        // Cropped first and blurred without clamping, so the edges soften into the black behind.
        image = image.cropped(to: crop).applyingGaussianBlur(sigma: 28 * workScale).cropped(to: crop)
        guard let blurred = context.createCGImage(image, from: crop) else { return nil }
        if cache.count > 4 { cache.removeAll() }
        cache[ObjectIdentifier(source)] = (source, blurred)
        return blurred
    }
}

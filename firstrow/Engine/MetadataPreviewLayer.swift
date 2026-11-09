import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A poster or cover with its details underneath (iTunes Top items, podcasts, songs).
/// After a delay the turned poster straightens, shrinks and rises as the details fade in.
final class MetadataPreviewLayer: GapItemLayer {
    private let unit = CALayer()
    private let poster = SceneLayer()
    private let reflectionClip = SceneLayer()
    private let reflectionImage = SceneLayer()
    private let reflectionMask = SceneGradientLayer()
    /// Masks the reflection away as the poster settles, since a coplanar overlay would z-fight.
    private let sweep = SceneGradientLayer()
    private let details = SceneLayer()
    private var identity: String?
    private var layoutKey: String?
    /// Start of the current move, so a re-layout part way through continues it.
    private var transitionBegin: CFTimeInterval?
    private static let sampleCount = 40

    override init() {
        super.init()
        unit.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "anchorPoint": NSNull()]
        unit.anchorPoint = CGPoint(x: 0.5, y: 0.25)
        layer.addSublayer(unit)
        poster.contentsGravity = .resizeAspectFill
        poster.masksToBounds = true
        unit.addSublayer(poster)
        reflectionClip.masksToBounds = true
        unit.addSublayer(reflectionClip)
        reflectionImage.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        reflectionImage.contentsGravity = .resizeAspectFill
        reflectionImage.masksToBounds = true
        reflectionImage.opacity = 0.44
        reflectionImage.mask = reflectionMask
        reflectionClip.addSublayer(reflectionImage)
        reflectionMask.colors = [0.82, 0.42, 0.14, 0].map { CGColor(gray: 0, alpha: $0) }
        reflectionMask.locations = [0, 0.18, 0.42, 1]
        sweep.colors = Self.sweepColors(hidden: 1)
        sweep.locations = [0, 0.505, 0.525, 1]
        reflectionClip.mask = sweep
        layer.addSublayer(details)
    }

    override func accepts(_ kind: GapItemKind) -> Bool {
        if case .metadata = kind { return true }
        return false
    }

    override func update(_ kind: GapItemKind, context: GapItemContext) {
        guard case let .metadata(spec) = kind else { return }
        let restarts = spec.identity != identity
        identity = spec.identity
        let layoutKey = "\(ObjectIdentifier(spec.image))|\(spec.title)|\(spec.description ?? "")|\(spec.lines.map { "\($0.label)=\($0.value)" })|\(context.boxFrame)|\(context.sceneSize)|\(context.scale)|\(spec.offsetX)|\(spec.offsetY)"
        guard restarts || layoutKey != self.layoutKey else { return }
        self.layoutKey = layoutKey
        if restarts {
            transitionBegin = spec.animatesTransition ? CACurrentMediaTime() + spec.transitionDelay : nil
        } else if let begin = transitionBegin, CACurrentMediaTime() > begin + 0.62 + 0.3 {
            transitionBegin = nil
        }
        layout(spec, context: context, transitionBegin: transitionBegin)
    }

    // MARK: - Layout

    private struct Geometry {
        var origin: CGPoint
        var initialWidth: CGFloat
        var initialHeight: CGFloat
        var unitSize: CGSize
        var startCenter: CGPoint
        var metadataTop: CGFloat
        var sceneMetadataTop: CGFloat
        var finalCoverCenterX: CGFloat
        var targetScale: CGFloat
    }

    private func layout(_ spec: MetadataPreviewSpec, context: GapItemContext, transitionBegin: CFTimeInterval?) {
        let scale = context.scale
        // The box less its 100 pt bottom padding, offset as a whole.
        let origin = CGPoint(x: spec.offsetX, y: spec.offsetY)
        let size = CGSize(width: context.boxSize.width, height: context.boxSize.height - 100)
        let sceneMinX = context.boxFrame.minX + spec.offsetX
        let sceneMinY = context.boxFrame.minY + spec.offsetY
        let compact = context.sceneSize.width <= MenuVirtualScenePreset.iPad.width
        let description = Self.cappedDescription(spec.description)
        let baseMetadataWidth = min(compact ? 680 : 760, max(compact ? 520 : 560, size.width * (compact ? 0.48 : 0.56)))
        let metadataWidth = baseMetadataWidth + 380
        // Equal trims keep the details centred on the cover and clear of the list.
        let trimLeft: CGFloat = 165
        let trimRight: CGFloat = 125
        let displayWidth = max(220, metadataWidth - (trimLeft + trimRight))
        let block = DetailsBlock(spec: spec, description: description, width: displayWidth, scale: scale)
        let metadataHeight = block.height
        let localLeft = max(0, 192 - sceneMinX)
        let sceneMetadataTop = max(0, context.sceneSize.height - 108 - metadataHeight)
        let metadataTop = max(0, sceneMetadataTop - sceneMinY)
        let startCoverCenterX = size.width * 0.5
        let metadataCenterX = compact
            ? startCoverCenterX + (trimLeft - trimRight) * 0.5
            : localLeft + metadataWidth * 0.5 - (metadataWidth - baseMetadataWidth) * 0.5 + (trimLeft - trimRight) * 0.5

        let initialWidth = spec.baseIconSize * 1.74 * max(0.05, spec.sizeScale)
        let aspect = max(0.4, min(3.0, spec.forcedPreviewAspectRatio ?? spec.aspectRatio))
        let initialHeight = initialWidth / aspect
        let gap: CGFloat = 18
        let targetScale = max(0.45, min(1.0, max(0, (metadataTop - gap) / max(1, initialHeight)), max(0, (sceneMetadataTop - gap - 105) / max(1, initialHeight))))
        let geometry = Geometry(
            origin: origin,
            initialWidth: initialWidth,
            initialHeight: initialHeight,
            unitSize: CGSize(width: initialWidth + 8, height: initialHeight * 2),
            startCenter: CGPoint(x: startCoverCenterX, y: size.height * 0.5),
            metadataTop: metadataTop,
            sceneMetadataTop: sceneMetadataTop,
            finalCoverCenterX: compact ? startCoverCenterX : localLeft + baseMetadataWidth * 0.5 + 21,
            targetScale: targetScale,
        )

        // Poster and reflection, in the unit that moves.
        let unitSize = geometry.unitSize
        unit.bounds = CGRect(origin: .zero, size: unitSize)
        let artwork = LayerImageCache.cgImage(for: spec.image)
        poster.contents = artwork
        poster.frame = CGRect(x: 4, y: 0, width: initialWidth, height: initialHeight)
        reflectionClip.frame = CGRect(x: 0, y: initialHeight, width: unitSize.width, height: initialHeight)
        reflectionImage.contents = artwork
        reflectionImage.transform = CATransform3DMakeScale(1, -1, 1)
        reflectionImage.bounds = CGRect(x: 0, y: 0, width: initialWidth, height: initialHeight)
        reflectionImage.position = CGPoint(x: 4 + initialWidth * 0.5, y: initialHeight * 0.5)
        reflectionMask.frame = CGRect(x: -4, y: 0, width: unitSize.width, height: initialHeight)
        // The mask is drawn in the flipped picture's space: its top is the picture's bottom.
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 1)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: 0)
        // Twice the reflection's height: clear above the sweep line, then fading out below it.
        sweep.bounds = CGRect(x: 0, y: 0, width: unitSize.width, height: initialHeight * 2)
        sweep.anchorPoint = .zero

        // Details.
        details.sublayers?.forEach { $0.removeFromSuperlayer() }
        block.install(in: details)
        details.frame = CGRect(
            x: origin.x + metadataCenterX - displayWidth * 0.5,
            y: origin.y + geometry.metadataTop + metadataHeight * 0.5 - block.height * 0.5,
            width: displayWidth,
            height: block.height,
        )

        // Final state as the model; the transition, if any, plays from the start state.
        let final = state(at: 1, geometry)
        unit.removeAllAnimations()
        sweep.removeAllAnimations()
        details.removeAllAnimations()
        unit.position = final.position
        unit.transform = final.transform
        sweep.position = CGPoint(x: 0, y: final.sweepOffset - initialHeight)
        sweep.colors = Self.sweepColors(hidden: 1)
        details.opacity = 1
        guard let begin = transitionBegin else { return }

        let samples = (0 ... Self.sampleCount).map { index -> Double in
            RootCarouselLayerController.easeInEaseOut(Double(index) / Double(Self.sampleCount))
        }
        let states = samples.map { state(at: CGFloat($0), geometry) }
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath).preferringProMotion()
            animation.values = values
            animation.duration = 0.62
            animation.beginTime = begin
            animation.fillMode = .backwards
            animation.calculationMode = .linear
            return animation
        }
        unit.add(keyframes("position", states.map { NSValue.layerPoint($0.position) }), forKey: "move")
        unit.add(keyframes("transform", states.map { NSValue(caTransform3D: $0.transform) }), forKey: "turn")
        sweep.add(keyframes("position", states.map { NSValue.layerPoint(CGPoint(x: 0, y: $0.sweepOffset - initialHeight)) }), forKey: "sweep")
        sweep.add(keyframes("colors", samples.map { Self.sweepColors(hidden: CGFloat($0)) }), forKey: "sweepFade")
        let reveal = CABasicAnimation(keyPath: "opacity").preferringProMotion()
        reveal.fromValue = 0
        reveal.toValue = 1
        reveal.duration = 0.3
        reveal.beginTime = begin + 0.22
        reveal.fillMode = .backwards
        reveal.timingFunction = Animation.easeInOut(duration: 0.3).timingFunction
        details.add(reveal, forKey: "reveal")
    }

    /// The sweep mask's stops: fully shown above the line, `hidden` (0 to 1) of the way gone below it.
    private static func sweepColors(hidden: CGFloat) -> [CGColor] {
        let below = CGColor(gray: 0, alpha: 1 - min(max(hidden, 0), 1))
        return [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), below, below]
    }

    private struct State {
        var position: CGPoint
        var transform: CATransform3D
        var sweepOffset: CGFloat
    }

    /// Everything about the poster at transition progress `p` (0: large and turned, 1: settled).
    private func state(at p: CGFloat, _ g: Geometry) -> State {
        let unitScale = 1 + (g.targetScale - 1) * p
        let scaledCoverHeight = g.initialHeight * unitScale
        let finalCoverCenterY = g.metadataTop - 18 - scaledCoverHeight * 0.5
        let coverCenterX = g.startCenter.x + (g.finalCoverCenterX - g.startCenter.x) * p
        let coverCenterY = g.startCenter.y + (finalCoverCenterY - g.startCenter.y) * p
        let yaw = Double(20 * (1 - p))
        // Placed as if scaled about the unit's centre, while turning about the poster's centre.
        let unitCenter = CGPoint(x: coverCenterX, y: coverCenterY + scaledCoverHeight * 0.5)
        let anchorPosition = CGPoint(x: g.origin.x + unitCenter.x, y: g.origin.y + unitCenter.y - unitScale * 0.25 * g.unitSize.height)
        let transform = CATransform3DConcat(
            CATransform3DMakeScale(unitScale, unitScale, 1),
            yawTransform(degrees: yaw, perspective: 0.75, viewSize: g.unitSize),
        )
        return State(position: anchorPosition, transform: transform, sweepOffset: g.initialHeight * 0.24 * (1 - p))
    }

    // MARK: - Details text

    /// Title, rules, description and label/value lines, stacked 8 points apart.
    private struct DetailsBlock {
        struct Piece {
            enum Kind {
                case text(RenderedGraphic, x: CGFloat)
                case rule
                case line(label: RenderedGraphic, labelRight: CGFloat, value: RenderedGraphic, valueX: CGFloat)
            }

            let kind: Kind
            let top: CGFloat
            let height: CGFloat
        }

        var pieces: [Piece] = []
        var height: CGFloat = 0
        let width: CGFloat

        @MainActor
        init(spec: MetadataPreviewSpec, description: String?, width: CGFloat, scale: CGFloat) {
            self.width = width
            var y: CGFloat = 0
            var first = true
            func add(_ kind: Piece.Kind, height: CGFloat) {
                if !first { y += 8 }
                first = false
                pieces.append(Piece(kind: kind, top: y, height: height))
                y += height
            }
            let title = TextRenderer.render(TextSpec(text: spec.title, fontName: firstRowBoldFontName, size: 30, maxWidth: width), scale: scale)
            add(.text(title, x: 0), height: title.size.height)
            let hasDescription = description != nil
            let hasLines = !spec.lines.isEmpty
            if hasDescription || hasLines { add(.rule, height: 1) }
            if let description {
                let text = TextRenderer.render(TextSpec(text: description, fontName: firstRowRegularFontName, size: 24, wrapWidth: width, lineSpacing: 1), scale: scale)
                add(.text(text, x: 0), height: text.size.height)
            }
            if hasDescription, hasLines { add(.rule, height: 1) }
            if hasLines {
                let labelWidth = spec.lines.map { FontMetrics.width("\($0.label):", fontName: firstRowRegularFontName, size: 21) }.max() ?? 0
                let rowHeight = FontMetrics.lineHeight(fontName: firstRowRegularFontName, size: 21)
                // The rows are one block (2 points apart inside it).
                if !first { y += 8 }
                first = false
                for (index, line) in spec.lines.enumerated() {
                    if index > 0 { y += 2 }
                    let label = TextRenderer.render(TextSpec(text: "\(line.label):", fontName: firstRowRegularFontName, size: 21, color: RGBA(white: 1, alpha: 0.5)), scale: scale)
                    let value = TextRenderer.render(TextSpec(text: line.value, fontName: firstRowRegularFontName, size: 21, maxWidth: max(1, width - labelWidth - 8)), scale: scale)
                    pieces.append(Piece(kind: .line(label: label, labelRight: labelWidth, value: value, valueX: labelWidth + 8), top: y, height: rowHeight))
                    y += rowHeight
                }
                add(.rule, height: 1)
            } else if hasDescription {
                add(.rule, height: 1)
            }
            height = y
        }

        @MainActor
        func install(in container: CALayer) {
            for piece in pieces {
                switch piece.kind {
                case let .text(graphic, x):
                    let layer = SceneLayer()
                    layer.show(graphic, at: CGPoint(x: x, y: piece.top))
                    container.addSublayer(layer)
                case .rule:
                    let layer = SceneLayer()
                    layer.backgroundColor = CGColor(gray: 1, alpha: 0.18)
                    layer.frame = CGRect(x: 0, y: piece.top, width: width, height: 1)
                    container.addSublayer(layer)
                case let .line(label, labelRight, value, valueX):
                    let labelLayer = SceneLayer()
                    labelLayer.show(label, at: CGPoint(x: labelRight - label.size.width, y: piece.top + (piece.height - label.size.height) * 0.5))
                    let valueLayer = SceneLayer()
                    valueLayer.show(value, at: CGPoint(x: valueX, y: piece.top + (piece.height - value.size.height) * 0.5))
                    container.addSublayer(labelLayer)
                    container.addSublayer(valueLayer)
                }
            }
        }
    }

    /// Long descriptions are cut short (newlines count heavily, as they take whole lines).
    static func cappedDescription(_ source: String?) -> String? {
        guard let source else { return nil }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var weighted = 0
        var truncated = false
        var built = ""
        for character in normalized {
            let weight = character == "\n" ? 100 : 1
            if weighted + weight > 1000 {
                truncated = true
                break
            }
            built.append(character)
            weighted += weight
        }
        guard truncated else { return normalized }
        let trimmed = built.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : "\(trimmed)..."
    }
}

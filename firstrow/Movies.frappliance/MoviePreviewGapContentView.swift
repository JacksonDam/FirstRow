import SwiftUI

private struct PreviewTransitionTask: ViewModifier {
    let identity: String
    let animatePreviewTransition: Bool
    let transitionDelay: Double
    @Binding var transitionProgress: CGFloat
    @Binding var metadataOpacity: Double

    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.task(id: identity) { await run() }
        } else {
            content
                .onAppear { Task { await run() } }
                .onChange(of: identity, perform: { _ in Task { await run() } })
        }
    }

    private func run() async {
        var instant = Transaction()
        instant.disablesAnimations = true
        await MainActor.run {
            withTransaction(instant) {
                if animatePreviewTransition {
                    transitionProgress = 0
                    metadataOpacity = 0
                } else {
                    transitionProgress = 1
                    metadataOpacity = 1
                }
            }
        }
        guard animatePreviewTransition else { return }
        let delayNanoseconds = UInt64(max(0, transitionDelay) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.62)) {
                transitionProgress = 1
            }
            withAnimation(.easeInOut(duration: 0.3).delay(0.22)) {
                metadataOpacity = 1
            }
        }
    }
}

struct MoviePreviewGapContentView: View {
    let image: NSImage
    let aspectRatio: CGFloat
    let sizeScale: CGFloat
    let baseIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let previewYawDegrees: Double
    let reflectionYawDegrees: Double
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let previewYaw: Angle
    let reflectionYaw: Angle
    let perspective: CGFloat = 0.75
    init(
        image: NSImage,
        aspectRatio: CGFloat,
        sizeScale: CGFloat,
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        previewYawDegrees: Double = 36,
        reflectionYawDegrees: Double = 35.8,
    ) {
        self.image = image
        self.aspectRatio = aspectRatio
        self.sizeScale = sizeScale
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.previewYawDegrees = previewYawDegrees
        self.reflectionYawDegrees = reflectionYawDegrees
        let safeScale = max(0.05, sizeScale)
        let calculatedWidth = baseIconSize * 1.74 * safeScale
        let safeAspect = max(0.4, min(3.0, aspectRatio))
        previewWidth = calculatedWidth
        previewHeight = calculatedWidth / safeAspect
        previewYaw = Angle(degrees: previewYawDegrees)
        reflectionYaw = Angle(degrees: reflectionYawDegrees)
    }

    var body: some View {
        ZStack {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: previewWidth, height: previewHeight).clipped().overlay(
                Rectangle().stroke(Color.clear, lineWidth: 1),
            ).mask(
                LinearGradient(
                    gradient: Gradient(stops: [.init(color: .white, location: 0.0), .init(color: .white.opacity(0.68), location: 0.05), .init(color: .white.opacity(0.26), location: 0.12), .init(color: .white.opacity(0.08), location: 0.17), .init(color: .clear, location: 0.22)]),
                    startPoint: .bottom,
                    endPoint: .top,
                ),
            ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).opacity(0.44).rotation3DEffect(
                reflectionYaw,
                axis: (x: 0, y: 1, z: 0),
                perspective: perspective,
            ).blur(radius: 0.5)
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: previewWidth, height: previewHeight).clipped().overlay(
                Rectangle().stroke(Color.clear, lineWidth: 1),
            ).rotation3DEffect(
                previewYaw,
                axis: (x: 0, y: 1, z: 0),
                perspective: perspective,
            )
        }.offset(x: horizontalOffset, y: verticalOffset).padding(.bottom, 100)
    }
}

struct MoviePreviewSlideshowGapContentView: View {
    let descriptors: [MenuView.MovieGapPreviewDescriptor]
    let baseIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let previewYawDegrees: Double
    let reflectionYawDegrees: Double
    let cycleDuration: TimeInterval
    let crossfadeDuration: TimeInterval
    @State private var phaseOriginReferenceTime = Date.timeIntervalSinceReferenceDate
    init(
        descriptors: [MenuView.MovieGapPreviewDescriptor],
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        previewYawDegrees: Double = 36,
        reflectionYawDegrees: Double = 35.8,
        cycleDuration: TimeInterval = 3.0,
        crossfadeDuration: TimeInterval = 0.55,
    ) {
        self.descriptors = descriptors
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.previewYawDegrees = previewYawDegrees
        self.reflectionYawDegrees = reflectionYawDegrees
        self.cycleDuration = cycleDuration
        self.crossfadeDuration = crossfadeDuration
    }

    var body: some View {
        Group {
            if descriptors.isEmpty {
                EmptyView()
            } else if descriptors.count == 1, let descriptor = descriptors.first {
                moviePreview(descriptor)
            } else {
                slideshowView
            }
        }
    }

    private var slideshowView: some View {
        FirstRowTimelineView(minimumInterval: 1.0 / 60.0) { currentDate in
            let state = slideshowState(at: currentDate)
            ZStack {
                moviePreview(state.current).opacity(1 - state.crossfadeProgress)
                moviePreview(state.next).opacity(state.crossfadeProgress)
            }
        }.onAppear {
            phaseOriginReferenceTime = Date.timeIntervalSinceReferenceDate
        }.onChange(of: slideshowIdentityKey, perform: { _ in
            phaseOriginReferenceTime = Date.timeIntervalSinceReferenceDate
        })
    }

    private var slideshowIdentityKey: String {
        descriptors.map(\.id).joined(separator: "|")
    }

    private func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = index % count
        return remainder >= 0 ? remainder : (remainder + count)
    }

    private func moviePreview(_ descriptor: MenuView.MovieGapPreviewDescriptor) -> some View {
        MoviePreviewGapContentView(
            image: descriptor.image,
            aspectRatio: descriptor.aspectRatio,
            sizeScale: descriptor.sizeScale,
            baseIconSize: baseIconSize,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset,
            previewYawDegrees: previewYawDegrees,
            reflectionYawDegrees: reflectionYawDegrees,
        ).id(descriptor.id)
    }

    private func slideshowState(at date: Date) -> (
        current: MenuView.MovieGapPreviewDescriptor,
        next: MenuView.MovieGapPreviewDescriptor,
        crossfadeProgress: Double,
    ) {
        let safeCycleDuration = max(0.001, cycleDuration)
        let safeCrossfadeDuration = min(max(0.001, crossfadeDuration), safeCycleDuration)
        let elapsed = max(0, date.timeIntervalSinceReferenceDate - phaseOriginReferenceTime)
        let cycleIndex = Int(floor(elapsed / safeCycleDuration))
        let localTime = elapsed.truncatingRemainder(dividingBy: safeCycleDuration)
        let fadeStartTime = safeCycleDuration - safeCrossfadeDuration
        let currentIndex = wrappedIndex(cycleIndex, count: descriptors.count)
        let nextIndex = wrappedIndex(cycleIndex + 1, count: descriptors.count)
        let progress: Double = if localTime <= fadeStartTime {
            0
        } else {
            min(1, (localTime - fadeStartTime) / safeCrossfadeDuration)
        }
        return (
            current: descriptors[currentIndex],
            next: descriptors[nextIndex],
            crossfadeProgress: progress,
        )
    }
}

struct AnimatedMetadataGapContentView: View {
    struct MetadataLine: Identifiable, Equatable {
        let label: String
        let value: String
        let id: String
        init(label: String, value: String) {
            self.label = label
            self.value = value
            id = "\(label)::\(value)"
        }
    }

    let image: NSImage
    let aspectRatio: CGFloat
    let forcedPreviewAspectRatio: CGFloat?
    let sizeScale: CGFloat
    let titleText: String
    let descriptionText: String?
    let metadataLines: [MetadataLine]
    let baseIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let transitionIdentity: String
    let transitionDelay: TimeInterval
    let sceneSize: CGSize
    let animatePreviewTransition: Bool
    let resolvedPosterCGImage: CGImage?
    @State private var transitionProgress: CGFloat = 0
    @State private var metadataOpacity: Double = 0
    init(
        image: NSImage,
        aspectRatio: CGFloat,
        forcedPreviewAspectRatio: CGFloat? = nil,
        sizeScale: CGFloat,
        titleText: String,
        descriptionText: String? = nil,
        metadataLines: [MetadataLine] = [],
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        transitionIdentity: String,
        transitionDelay: TimeInterval = 3.0,
        animatePreviewTransition: Bool = true,
        sceneSize: CGSize = CGSize(width: 1920, height: 1080),
    ) {
        self.image = image
        self.aspectRatio = aspectRatio
        self.forcedPreviewAspectRatio = forcedPreviewAspectRatio
        self.sizeScale = sizeScale
        self.titleText = titleText
        self.descriptionText = descriptionText
        self.metadataLines = metadataLines
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.transitionIdentity = transitionIdentity
        self.transitionDelay = transitionDelay
        self.animatePreviewTransition = animatePreviewTransition
        self.sceneSize = sceneSize
        resolvedPosterCGImage = Self.makeResolvedCGImage(from: image)
    }

    var body: some View {
        GeometryReader { geometry in
            let limitedDescriptionText = cappedDescriptionText(descriptionText)
            let hasDescriptionText = limitedDescriptionText != nil
            let hasMetadataLines = !metadataLines.isEmpty
            let metadataLabelColumnWidth = measuredMetadataLabelColumnWidth()
            let effectiveTransitionProgress = animatePreviewTransition ? transitionProgress : 1
            let effectiveMetadataOpacity = animatePreviewTransition ? metadataOpacity : 1
            let safeScale = max(0.05, sizeScale)
            let initialWidth = baseIconSize * 1.74 * safeScale
            let effectiveAspectRatio = forcedPreviewAspectRatio ?? aspectRatio
            let safeAspect = max(0.4, min(3.0, effectiveAspectRatio))
            let initialHeight = initialWidth / safeAspect
            let frameInScene = geometry.frame(in: .named("menuSceneSpace"))
            let usesCompactMetadataLayout = sceneSize.width <= MenuVirtualScenePreset.iPad.width
            let metadataLeftInset: CGFloat = 192
            let metadataBottomInset: CGFloat = 108
            let baseMetadataWidth = min(
                usesCompactMetadataLayout ? 680 : 760,
                max(
                    usesCompactMetadataLayout ? 520 : 560,
                    geometry.size.width * (usesCompactMetadataLayout ? 0.48 : 0.56),
                ),
            )
            let metadataWidth = baseMetadataWidth + 380
            let metadataTrimLeft: CGFloat = 105
            let metadataTrimRight: CGFloat = 65
            let metadataDisplayWidth = max(220, metadataWidth - (metadataTrimLeft + metadataTrimRight))
            let startCoverCenterX = geometry.size.width * 0.5
            let metadataHeight = measuredMetadataHeight(
                width: metadataDisplayWidth,
                descriptionText: limitedDescriptionText,
                hasMetadataLines: hasMetadataLines,
            )
            let localMetadataLeft = max(0, metadataLeftInset - frameInScene.minX)
            let sceneMetadataTop = max(0, sceneSize.height - metadataBottomInset - metadataHeight)
            let localMetadataTop = max(0, sceneMetadataTop - frameInScene.minY)
            let metadataTopY = localMetadataTop
            let metadataOriginX = localMetadataLeft
            let metadataCenterX =
                usesCompactMetadataLayout
                    ? (startCoverCenterX + ((metadataTrimLeft - metadataTrimRight) * 0.5))
                    : (metadataOriginX
                        + (metadataWidth * 0.5)
                        - ((metadataWidth - baseMetadataWidth) * 0.5)
                        + ((metadataTrimLeft - metadataTrimRight) * 0.5))
            let metadataCenterY = metadataTopY + (metadataHeight * 0.5)
            let metadataGap: CGFloat = 18
            let minimumPosterTopGap: CGFloat = 105
            let maxScaleToFitMetadata = max(
                0,
                (metadataTopY - metadataGap) / max(1, initialHeight),
            )
            let maxScaleForTopGap = max(
                0,
                (sceneMetadataTop - metadataGap - minimumPosterTopGap) / max(1, initialHeight),
            )
            let targetScale = max(
                0.45,
                min(1.0, maxScaleToFitMetadata, maxScaleForTopGap),
            )
            let unitScale = lerp(from: 1.0, to: targetScale, progress: effectiveTransitionProgress)
            let scaledCoverHeight = initialHeight * unitScale
            let finalCoverCenterX = usesCompactMetadataLayout
                ? startCoverCenterX
                : (metadataOriginX + (baseMetadataWidth * 0.5) + 21)
            let finalCoverCenterY = metadataTopY - metadataGap - (scaledCoverHeight * 0.5)
            let startCoverCenterY = geometry.size.height * 0.5
            let coverCenterX = lerp(from: startCoverCenterX, to: finalCoverCenterX, progress: effectiveTransitionProgress)
            let coverCenterY = lerp(from: startCoverCenterY, to: finalCoverCenterY, progress: effectiveTransitionProgress)
            let previewYaw = Double(20 * (1 - effectiveTransitionProgress))
            let reflectionOpacity: CGFloat = 0.44
            let reflectionSweepOpacity = effectiveTransitionProgress
            let posterUnitWidth = initialWidth + 8
            let posterUnitHeight = initialHeight * 2
            let reflectionSweepTravel = lerp(
                from: initialHeight * 0.24,
                to: 0,
                progress: effectiveTransitionProgress,
            )
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    posterArtwork(width: initialWidth, height: initialHeight).frame(width: posterUnitWidth, height: initialHeight, alignment: .top)
                    ZStack(alignment: .top) {
                        if reflectionOpacity > 0.001 {
                            posterArtwork(width: initialWidth, height: initialHeight).scaleEffect(x: 1.0, y: -1.0, anchor: .center).opacity(reflectionOpacity).blur(radius: 0.5).mask(
                                LinearGradient(
                                    gradient: Gradient(stops: [.init(color: Color.white.opacity(0.82), location: 0.0), .init(color: Color.white.opacity(0.42), location: 0.18), .init(color: Color.white.opacity(0.14), location: 0.42), .init(color: .clear, location: 1.0)]),
                                    startPoint: .top,
                                    endPoint: .bottom,
                                ).frame(width: posterUnitWidth, height: initialHeight),
                            ).overlay(Group {
                                if reflectionSweepOpacity > 0.001 {
                                    LinearGradient(
                                        gradient: Gradient(stops: [.init(color: .clear, location: 0.0), .init(color: .clear, location: 0.01), .init(color: Color.black.opacity(1.0), location: 0.05), .init(color: Color.black.opacity(1.0), location: 1.0)]),
                                        startPoint: .top,
                                        endPoint: .bottom,
                                    ).frame(width: posterUnitWidth, height: initialHeight).offset(y: reflectionSweepTravel).opacity(reflectionSweepOpacity).allowsHitTesting(false)
                                }
                            }, alignment: .top)
                        }
                    }.frame(width: posterUnitWidth, height: initialHeight).clipped()
                }.frame(width: posterUnitWidth, height: posterUnitHeight).compositingGroup().scaleEffect(unitScale, anchor: .center).rotation3DEffect(.degrees(previewYaw),
                                                                                                                                                      axis: (x: 0, y: 1, z: 0),
                                                                                                                                                      anchor: UnitPoint(x: 0.5, y: 0.25),
                                                                                                                                                      perspective: 0.75).position(x: coverCenterX, y: coverCenterY + (scaledCoverHeight * 0.5))
                VStack(alignment: .leading, spacing: 8) {
                    Text(titleText).font(.firstRowBold(size: 30)).foregroundStyleCompat(.white).lineLimit(1).truncationMode(.tail).allowsTightening(true)
                    if hasDescriptionText || hasMetadataLines {
                        Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    }
                    if let limitedDescriptionText, hasDescriptionText {
                        Text(limitedDescriptionText).font(.firstRowRegular(size: 24)).foregroundStyleCompat(.white).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                    }
                    if hasDescriptionText, hasMetadataLines {
                        Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    }
                    if hasMetadataLines {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(metadataLines) { metadataLine in
                                metadataLineRow(
                                    label: metadataLine.label,
                                    value: metadataLine.value,
                                    labelColumnWidth: metadataLabelColumnWidth,
                                )
                            }
                        }
                        Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    } else if hasDescriptionText {
                        Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    }
                }.frame(width: metadataDisplayWidth, alignment: .leading).opacity(effectiveMetadataOpacity).position(x: metadataCenterX, y: metadataCenterY)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }.offset(x: horizontalOffset, y: verticalOffset).padding(.bottom, 100).modifier(PreviewTransitionTask(
            identity: transitionIdentity,
            animatePreviewTransition: animatePreviewTransition,
            transitionDelay: transitionDelay,
            transitionProgress: $transitionProgress,
            metadataOpacity: $metadataOpacity,
        ))
    }

    func posterArtwork(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let cgImage = resolvedPosterCGImage {
                Image(decorative: cgImage, scale: 1.0).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }.frame(width: width, height: height).clipped().overlay(
            Rectangle().stroke(Color.clear, lineWidth: 1),
        )
    }

    static func makeResolvedCGImage(from source: NSImage) -> CGImage? {
        #if os(iOS) || os(tvOS)
            if let direct = source.cgImage {
                return direct
            }
            let size = source.size
            guard size.width > 0, size.height > 0 else { return nil }
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            defer { UIGraphicsEndImageContext() }
            source.draw(in: CGRect(origin: .zero, size: size))
            return UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        #else
            if let direct = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return direct
            }
            let size = source.size
            guard size.width > 0, size.height > 0 else { return nil }
            let pixelWidth = max(1, Int(round(size.width)))
            let pixelHeight = max(1, Int(round(size.height)))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0,
            ) else {
                return nil
            }
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current = context
            source.draw(
                in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: size),
                operation: .copy,
                fraction: 1.0,
            )
            context?.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.cgImage
        #endif
    }

    func measuredMetadataHeight(width: CGFloat) -> CGFloat {
        measuredMetadataHeight(
            width: width,
            descriptionText: cappedDescriptionText(descriptionText),
            hasMetadataLines: !metadataLines.isEmpty,
        )
    }

    func measuredMetadataHeight(width: CGFloat, descriptionText: String?, hasMetadataLines: Bool) -> CGFloat {
        let trimmedDescriptionText = descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDescriptionText = !(trimmedDescriptionText?.isEmpty ?? true)
        let titleFont = NSFont(name: firstRowBoldFontName, size: 30) ?? NSFont.boldSystemFont(ofSize: 30)
        let descriptionFont = NSFont(name: firstRowRegularFontName, size: 24) ?? NSFont.systemFont(ofSize: 24)
        let titleHeight = measuredTextHeight(
            titleText,
            width: width,
            font: titleFont,
        )
        let descriptionHeight: CGFloat = if let trimmedDescriptionText, hasDescriptionText {
            measuredTextHeight(
                trimmedDescriptionText,
                width: width,
                font: descriptionFont,
            )
        } else {
            0
        }
        var total = titleHeight
        if hasDescriptionText || hasMetadataLines {
            // Divider directly under title and breathing room before first block.
            total += 8 + 1 + 8
        }
        if hasDescriptionText {
            total += descriptionHeight
        }
        if hasDescriptionText, hasMetadataLines {
            // Space and divider between description and metadata rows.
            total += 8 + 1 + 8
        }
        if hasMetadataLines {
            total += measuredMetadataLinesHeight(width: width)
            // Bottom divider.
            total += 8 + 1
        } else if hasDescriptionText {
            total += 8 + 1
        }
        return total
    }

    func measuredMetadataLinesHeight(width: CGFloat) -> CGFloat {
        guard !metadataLines.isEmpty else { return 0 }
        let metadataFont = NSFont(name: firstRowRegularFontName, size: 21) ?? NSFont.systemFont(ofSize: 21)
        let rowHeight = measuredTextHeight(
            "Ag",
            width: width,
            font: metadataFont,
        )
        let spacing = CGFloat(max(0, metadataLines.count - 1)) * 2
        return (rowHeight * CGFloat(metadataLines.count)) + spacing
    }

    func measuredMetadataLabelColumnWidth() -> CGFloat {
        guard !metadataLines.isEmpty else { return 0 }
        let metadataFont = NSFont(name: firstRowRegularFontName, size: 21) ?? NSFont.systemFont(ofSize: 21)
        return metadataLines.map { measuredTextWidth("\($0.label):", font: metadataFont) }.max() ?? 0
    }

    func measuredTextHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
        let measuredRect = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil,
        )
        return ceil(measuredRect.height)
    }

    func measuredTextWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func cappedDescriptionText(_ source: String?) -> String? {
        guard let source else { return nil }
        let normalizedText = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let maxWeightedCharacters = 1000
        let newlineWeight = 100
        var weightedCount = 0
        var truncated = false
        var builtText = ""
        for character in normalizedText {
            let characterWeight = character == "\n" ? newlineWeight : 1
            if weightedCount + characterWeight > maxWeightedCharacters {
                truncated = true
                break
            }
            builtText.append(character)
            weightedCount += characterWeight
        }
        guard truncated else { return normalizedText }
        let trimmedResult = builtText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedResult.isEmpty {
            return "..."
        }
        return "\(trimmedResult)..."
    }

    func lerp(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * progress)
    }

    func metadataLineRow(label: String, value: String, labelColumnWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text("\(label):").font(.firstRowRegular(size: 21)).foregroundStyleCompat(.white.opacity(0.5)).frame(width: labelColumnWidth, alignment: .trailing)
            Text(value).font(.firstRowRegular(size: 21)).foregroundStyleCompat(.white).lineLimit(1).truncationMode(.tail)
        }
    }
}

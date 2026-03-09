import SwiftUI

struct MusicTopLevelCarouselGapContentView: View {
    let artworkImages: [NSImage?]
    let baseIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let preserveArtworkAspectRatio: Bool
    let exitOverlayOpacity: Double
    @State private var phaseOriginReferenceTime = Date.timeIntervalSinceReferenceDate
    // we render 4 album covers so one can spawn in off-screen while 3 stay visible.
    private let laneCount = 4
    private let coversPerSecond: Double = 0.075
    init(
        artworkImages: [NSImage?],
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        preserveArtworkAspectRatio: Bool = false,
        exitOverlayOpacity: Double = 0,
    ) {
        self.artworkImages = artworkImages
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.preserveArtworkAspectRatio = preserveArtworkAspectRatio
        self.exitOverlayOpacity = exitOverlayOpacity
    }

    var body: some View {
        Group {
            if artworkImages.isEmpty {
                EmptyView()
            } else {
                ZStack {
                    FirstRowTimelineView(minimumInterval: 1.0 / 60.0) { currentDate in
                        let elapsed = max(0, currentDate.timeIntervalSinceReferenceDate - phaseOriginReferenceTime)
                        let absolutePhase = elapsed * coversPerSecond
                        let slotSpacing = 1.0 / Double(laneCount)
                        let renderedCovers = (0 ..< laneCount).map { slot -> RenderedCover in
                            let lanePosition = absolutePhase - (Double(slot) * slotSpacing)
                            let progress = lanePosition - floor(lanePosition)
                            let wrapCount = Int(floor(lanePosition))
                            let serial = (wrapCount * laneCount) + slot
                            let imageIndex = artworkIndexForSerial(serial, artworkCount: artworkImages.count)
                            let state = coverState(progress: progress)
                            return RenderedCover(
                                slot: slot,
                                image: artworkImages[imageIndex],
                                progress: progress,
                                serial: serial,
                                state: state,
                            )
                        }.sorted { $0.state.depth < $1.state.depth }
                        ZStack {
                            ForEach(renderedCovers, id: \.slot) { renderedCover in
                                MusicPreviewGapContentView(
                                    image: renderedCover.image,
                                    baseIconSize: baseIconSize,
                                    horizontalOffset: 0,
                                    verticalOffset: 0,
                                    showPreview: false,
                                    showReflection: true,
                                    forcedAspectRatio: preserveArtworkAspectRatio ? nil : 1.0,
                                    previewYawDegrees: renderedCover.state.previewYawDegrees,
                                    reflectionYawDegrees: renderedCover.state.reflectionYawDegrees,
                                    reflectionOpacity: 0.30,
                                    reflectionFadeEnd: 0.44,
                                    reflectionBlurRadius: 0.35,
                                ).scaleEffect(renderedCover.state.scale, anchor: .center).rotation3DEffect(.degrees(renderedCover.state.rotationDegrees),
                                                                                                           axis: (x: 0, y: 0, z: 1),
                                                                                                           anchor: .center,
                                                                                                           perspective: 0).offset(
                                    x: horizontalOffset + renderedCover.state.x,
                                    y: verticalOffset + renderedCover.state.y,
                                ).zIndex(renderedCover.state.depth - 0.35).opacity(renderedCover.state.opacity)
                            }
                            ForEach(renderedCovers, id: \.slot) { renderedCover in
                                MusicPreviewGapContentView(
                                    image: renderedCover.image,
                                    baseIconSize: baseIconSize,
                                    horizontalOffset: 0,
                                    verticalOffset: 0,
                                    showPreview: true,
                                    showReflection: false,
                                    forcedAspectRatio: preserveArtworkAspectRatio ? nil : 1.0,
                                    previewYawDegrees: renderedCover.state.previewYawDegrees,
                                    reflectionYawDegrees: renderedCover.state.reflectionYawDegrees,
                                    reflectionOpacity: 0.30,
                                    reflectionFadeEnd: 0.44,
                                    reflectionBlurRadius: 0.35,
                                ).scaleEffect(renderedCover.state.scale, anchor: .center).rotation3DEffect(.degrees(renderedCover.state.rotationDegrees),
                                                                                                           axis: (x: 0, y: 0, z: 1),
                                                                                                           anchor: .center,
                                                                                                           perspective: 0).offset(
                                    x: horizontalOffset + renderedCover.state.x,
                                    y: verticalOffset + renderedCover.state.y,
                                ).zIndex(renderedCover.state.depth + 0.35).opacity(renderedCover.state.opacity)
                            }
                        }
                    }
                    Rectangle().fill(Color.black).frame(
                        width: max(baseIconSize * 3.75, 1500),
                        height: max(baseIconSize * 4.0, 1200),
                    ).offset(x: horizontalOffset, y: verticalOffset).allowsHitTesting(false).opacity(exitOverlayOpacity).zIndex(10000)
                }.onChange(of: artworkIdentityKey, perform: { _ in
                    phaseOriginReferenceTime = Date.timeIntervalSinceReferenceDate
                }).onAppear {
                    phaseOriginReferenceTime = Date.timeIntervalSinceReferenceDate
                }
            }
        }
    }

    private var artworkIdentityKey: String {
        artworkImages.enumerated().map { index, image in
            if let image {
                return "\(index):\(ObjectIdentifier(image).hashValue)"
            }
            return "\(index):nil"
        }.joined(separator: "|")
    }

    private func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = index % count
        return remainder >= 0 ? remainder : (remainder + count)
    }

    private func artworkIndexForSerial(_ serial: Int, artworkCount: Int) -> Int {
        guard artworkCount > 0 else { return 0 }
        if artworkCount == 1 {
            return 0
        }
        if artworkCount == 2 {
            let repeatingTriplet = [0, 0, 1]
            return repeatingTriplet[wrappedIndex(serial, count: repeatingTriplet.count)]
        }
        return wrappedIndex(serial, count: artworkCount)
    }

    private func coverState(progress: Double) -> CoverState {
        let u = min(max(progress, 0), 1)
        let previewSide = baseIconSize * 1.12
        let xHidden = previewSide * 0.40
        let xPeak = previewSide * 1.24
        let xExit = -previewSide * 1.18
        let x: CGFloat
        if u < 0.30 {
            let t = u / 0.30
            let eased = 1.0 - pow(1.0 - t, 2.0) // ease-out to the peak
            x = xHidden + ((xPeak - xHidden) * CGFloat(eased))
        } else {
            let t = (u - 0.30) / 0.70
            let eased = t * t // accelerate toward exit (no end slow-down)
            x = xPeak + ((xExit - xPeak) * CGFloat(eased))
        }
        let y: CGFloat = previewSide * 0.12
        let scaleProgress = pow(u, 1.85)
        let scale = (0.34 + (CGFloat(scaleProgress) * 1.72)) * 1.4
        let rotationDegrees: Double = 0
        let previewYawDegrees = -20.0 + (90.0 * u)
        let reflectionYawDegrees = -20.0 + (90.0 * u)
        let depth = u
        let opacity: CGFloat = 1
        return CoverState(
            x: x,
            y: y,
            scale: scale,
            opacity: opacity,
            rotationDegrees: rotationDegrees,
            previewYawDegrees: previewYawDegrees,
            reflectionYawDegrees: reflectionYawDegrees,
            depth: depth,
        )
    }
}

private struct RenderedCover {
    let slot: Int
    let image: NSImage?
    let progress: Double
    let serial: Int
    let state: CoverState
}

private struct CoverState {
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
    let opacity: CGFloat
    let rotationDegrees: Double
    let previewYawDegrees: Double
    let reflectionYawDegrees: Double
    let depth: Double
}

import SwiftUI

struct PhotoSlideshowFullscreenView: View {
    let imageCount: Int
    let imageForIndex: (Int) -> NSImage?
    let isPaused: Bool
    let pausedIndex: Int
    let playbackStartDate: Date
    let playbackElapsedOffset: TimeInterval
    let displayDuration: TimeInterval
    let crossfadeDuration: TimeInterval
    let hasAlreadyFinished: Bool
    let onFrameIndicesChanged: (_ primaryIndex: Int, _ secondaryIndex: Int?) -> Void
    let onFinished: () -> Void
    private var transitionBlockDuration: TimeInterval {
        displayDuration + crossfadeDuration
    }

    private var totalDuration: TimeInterval {
        guard imageCount > 0 else { return 0 }
        return (Double(max(0, imageCount - 1)) * transitionBlockDuration) + displayDuration
    }

    var body: some View {
        slideshowBody
    }

    private var slideshowBody: some View {
        GeometryReader { proxy in
            FirstRowTimelineView(minimumInterval: 1.0 / 60.0) { currentDate in
                let elapsed = resolvedElapsed(at: currentDate)
                let frameState = frameState(for: elapsed)
                let frameIndicesKey = PhotoSlideshowFrameIndicesKey(
                    primaryIndex: frameState.primaryIndex,
                    secondaryIndex: frameState.secondaryIndex,
                )
                ZStack {
                    Color.black
                    if frameState.primaryIndex >= 0,
                       frameState.primaryIndex < imageCount,
                       let primaryImage = imageForIndex(frameState.primaryIndex)
                    {
                        kenBurnsImage(
                            primaryImage,
                            index: frameState.primaryIndex,
                            progress: frameState.primaryKenBurnsProgress,
                            canvasSize: proxy.size,
                        ).opacity(frameState.primaryOpacity)
                    }
                    if let secondaryIndex = frameState.secondaryIndex,
                       secondaryIndex >= 0,
                       secondaryIndex < imageCount,
                       let secondaryImage = imageForIndex(secondaryIndex)
                    {
                        kenBurnsImage(
                            secondaryImage,
                            index: secondaryIndex,
                            progress: frameState.secondaryKenBurnsProgress,
                            canvasSize: proxy.size,
                        ).opacity(frameState.secondaryOpacity)
                    }
                }.ignoresSafeArea().modifier(
                    PhotoSlideshowFrameIndicesUpdateModifier(
                        frameIndicesKey: frameIndicesKey,
                        onUpdate: {
                            onFrameIndicesChanged(frameState.primaryIndex, frameState.secondaryIndex)
                        },
                    ),
                )
            }
        }.background(Color.black.ignoresSafeArea())
    }

    private func resolvedElapsed(at date: Date) -> TimeInterval {
        if isPaused {
            return max(0, playbackElapsedOffset)
        }
        return max(0, playbackElapsedOffset + date.timeIntervalSince(playbackStartDate))
    }

    private func frameState(for elapsed: TimeInterval) -> PhotoSlideshowFrameState {
        guard imageCount > 0 else {
            return PhotoSlideshowFrameState(
                primaryIndex: 0,
                secondaryIndex: nil,
                primaryOpacity: 0,
                secondaryOpacity: 0,
                primaryKenBurnsProgress: 0,
                secondaryKenBurnsProgress: 0,
            )
        }
        if isPaused {
            let clampedIndex = min(max(0, pausedIndex), imageCount - 1)
            return PhotoSlideshowFrameState(
                primaryIndex: clampedIndex,
                secondaryIndex: nil,
                primaryOpacity: 1,
                secondaryOpacity: 0,
                primaryKenBurnsProgress: 0.25,
                secondaryKenBurnsProgress: 0,
            )
        }
        let clampedElapsed = min(max(0, elapsed), totalDuration)
        if !hasAlreadyFinished, clampedElapsed >= totalDuration {
            DispatchQueue.main.async {
                onFinished()
            }
        }
        if imageCount == 1 {
            let progress = min(1, clampedElapsed / max(0.001, displayDuration))
            return PhotoSlideshowFrameState(
                primaryIndex: 0,
                secondaryIndex: nil,
                primaryOpacity: 1,
                secondaryOpacity: 0,
                primaryKenBurnsProgress: progress,
                secondaryKenBurnsProgress: 0,
            )
        }
        let block = max(0.001, transitionBlockDuration)
        let lastIndex = imageCount - 1
        let segment = min(lastIndex, Int(clampedElapsed / block))
        if segment >= lastIndex {
            let local = clampedElapsed - (Double(lastIndex) * block)
            let progress = min(1, (1 + local) / block)
            return PhotoSlideshowFrameState(
                primaryIndex: lastIndex,
                secondaryIndex: nil,
                primaryOpacity: 1,
                secondaryOpacity: 0,
                primaryKenBurnsProgress: progress,
                secondaryKenBurnsProgress: 0,
            )
        }
        let local = clampedElapsed - (Double(segment) * block)
        let primaryBase = segment == 0 ? 0.0 : 1.0
        let primaryProgress = min(1, (primaryBase + local) / block)
        if local < displayDuration {
            return PhotoSlideshowFrameState(
                primaryIndex: segment,
                secondaryIndex: nil,
                primaryOpacity: 1,
                secondaryOpacity: 0,
                primaryKenBurnsProgress: primaryProgress,
                secondaryKenBurnsProgress: 0,
            )
        }
        let crossfadeProgress = min(1, (local - displayDuration) / max(0.001, crossfadeDuration))
        let secondaryProgress = min(1, crossfadeProgress / block)
        return PhotoSlideshowFrameState(
            primaryIndex: segment,
            secondaryIndex: min(lastIndex, segment + 1),
            primaryOpacity: 1 - crossfadeProgress,
            secondaryOpacity: crossfadeProgress,
            primaryKenBurnsProgress: primaryProgress,
            secondaryKenBurnsProgress: secondaryProgress,
        )
    }

    private func kenBurnsImage(
        _ image: NSImage,
        index: Int,
        progress: TimeInterval,
        canvasSize: CGSize,
    ) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let directionX: CGFloat = (index % 2 == 0) ? 1 : -1
        let directionY: CGFloat = (index % 3 == 0) ? -1 : 1
        let zoomStart = 1.04 + (CGFloat(index % 5) * 0.01)
        let zoomEnd = zoomStart + 0.16
        let zoom = zoomStart + ((zoomEnd - zoomStart) * CGFloat(clampedProgress))
        let maxPanX = canvasSize.width * 0.06
        let maxPanY = canvasSize.height * 0.045
        let centeredProgress = CGFloat(clampedProgress - 0.5)
        return Image(nsImage: image).resizable().interpolation(.high).antialiased(true).scaledToFit().scaleEffect(zoom).offset(
            x: directionX * maxPanX * centeredProgress,
            y: directionY * maxPanY * centeredProgress,
        ).frame(width: canvasSize.width, height: canvasSize.height).clipped()
    }
}

private struct PhotoSlideshowFrameState {
    let primaryIndex: Int
    let secondaryIndex: Int?
    let primaryOpacity: Double
    let secondaryOpacity: Double
    let primaryKenBurnsProgress: TimeInterval
    let secondaryKenBurnsProgress: TimeInterval
}

private struct PhotoSlideshowFrameIndicesKey: Hashable {
    let primaryIndex: Int
    let secondaryIndex: Int?
}

private struct PhotoSlideshowFrameIndicesUpdateModifier: ViewModifier {
    let frameIndicesKey: PhotoSlideshowFrameIndicesKey
    let onUpdate: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.task(id: frameIndicesKey) {
                onUpdate()
            }
        } else {
            content
                .onAppear {
                    onUpdate()
                }
                .onChange(of: frameIndicesKey, perform: { _ in
                    onUpdate()
                })
        }
    }
}

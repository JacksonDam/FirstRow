import QuartzCore
import SwiftUI

/// The full-screen photo slideshow: each photo slowly pans and zooms (the Ken Burns effect)
/// and crossfades into the next.
///
/// Drawn with Core Animation. Every photo's pan, zoom and fades are animations with absolute
/// start times, so the render server plays the whole show; the app only wakes at each photo
/// change to swap in the next photos (the SwiftUI version redrew 60 times a second).
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

    var body: some View {
        LayerHost<PhotoSlideshowLayerController>(configuration: .init(
            imageCount: imageCount,
            imageForIndex: imageForIndex,
            isPaused: isPaused,
            pausedIndex: pausedIndex,
            playbackStartDate: playbackStartDate,
            playbackElapsedOffset: playbackElapsedOffset,
            displayDuration: displayDuration,
            crossfadeDuration: crossfadeDuration,
            hasAlreadyFinished: hasAlreadyFinished,
            onFrameIndicesChanged: onFrameIndicesChanged,
            onFinished: onFinished,
        ))
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
    }
}

@MainActor
final class PhotoSlideshowLayerController: LayerController {
    struct Configuration {
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
    }

    let rootLayer: CALayer = StillLayer()
    private var configuration: Configuration?
    private var bounds: CGSize = .zero
    private var layersByIndex: [Int: StillLayer] = [:]
    private var imagesByIndex: [Int: NSImage] = [:]
    private var scheduleKey: String?
    /// Media time at which the show's elapsed time was zero.
    private var originMediaTime: CFTimeInterval = 0
    private var timer: Timer?
    private var lastReportedIndices: (Int, Int?)?
    private var didReportFinish = false

    init() {
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.masksToBounds = true
    }

    func update(_ configuration: Configuration, bounds: CGSize) {
        self.configuration = configuration
        self.bounds = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let key = [
            "\(configuration.imageCount)", "\(configuration.isPaused)", "\(configuration.pausedIndex)",
            "\(configuration.playbackStartDate.timeIntervalSinceReferenceDate)", "\(configuration.playbackElapsedOffset)",
            "\(Int(bounds.width))x\(Int(bounds.height))",
        ].joined(separator: "|")
        if key != scheduleKey {
            scheduleKey = key
            let elapsed = currentElapsed(configuration)
            originMediaTime = CACurrentMediaTime() - elapsed
            didReportFinish = configuration.hasAlreadyFinished
            for layer in layersByIndex.values { layer.removeFromSuperlayer() }
            layersByIndex = [:]
            imagesByIndex = [:]
        }
        refresh()
    }

    func tearDown() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Timeline

    private var block: Double {
        guard let configuration else { return 4 }
        return max(0.001, configuration.displayDuration + configuration.crossfadeDuration)
    }

    private func currentElapsed(_ configuration: Configuration) -> TimeInterval {
        if configuration.isPaused {
            return max(0, configuration.playbackElapsedOffset)
        }
        return max(0, configuration.playbackElapsedOffset + Date().timeIntervalSince(configuration.playbackStartDate))
    }

    private func totalDuration(_ configuration: Configuration) -> Double {
        guard configuration.imageCount > 0 else { return 0 }
        return Double(configuration.imageCount - 1) * block + configuration.displayDuration
    }

    /// When photo `index` starts fading in (the first photo is there from the start).
    private func appearTime(_ index: Int, _ configuration: Configuration) -> Double {
        index == 0 ? 0 : Double(index) * block - configuration.crossfadeDuration
    }

    /// Photos on screen at `elapsed`: the current one, and the next while they crossfade.
    private func visibleIndices(at elapsed: Double, _ configuration: Configuration) -> (Int, Int?) {
        let last = configuration.imageCount - 1
        let segment = min(last, max(0, Int(elapsed / block)))
        let local = elapsed - Double(segment) * block
        if segment < last, local >= configuration.displayDuration {
            return (segment, segment + 1)
        }
        return (segment, nil)
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        guard let configuration, configuration.imageCount > 0 else {
            for layer in layersByIndex.values { layer.removeFromSuperlayer() }
            layersByIndex = [:]
            return
        }
        if configuration.isPaused {
            showPaused(configuration)
            return
        }
        let elapsed = CACurrentMediaTime() - originMediaTime
        let total = totalDuration(configuration)
        let (primary, secondary) = visibleIndices(at: min(elapsed, total), configuration)
        reportIndicesIfChanged(primary, secondary, configuration)
        if elapsed >= total, !didReportFinish {
            didReportFinish = true
            // Not from inside SwiftUI's update of this view: it changes menu state.
            let onFinished = configuration.onFinished
            DispatchQueue.main.async { onFinished() }
        }
        // Keep layers for the photo before, the visible ones and the one coming next.
        let wanted = Set((primary - 1) ... (primary + 2)).filter { $0 >= 0 && $0 < configuration.imageCount }
        for (index, layer) in layersByIndex where !wanted.contains(index) {
            layer.removeFromSuperlayer()
            layersByIndex[index] = nil
            imagesByIndex[index] = nil
        }
        for index in wanted.sorted() {
            let image = configuration.imageForIndex(index)
            if let layer = layersByIndex[index] {
                if let image, imagesByIndex[index] !== image {
                    imagesByIndex[index] = image
                    withoutLayerActions { layer.contents = LayerImageCache.cgImage(for: image) }
                }
                continue
            }
            let layer = makePhotoLayer(index: index, image: image, configuration: configuration)
            layersByIndex[index] = layer
            imagesByIndex[index] = image
        }
        // Later photos sit on top of earlier ones, so a crossfade brings the next one in over the last.
        for index in layersByIndex.keys.sorted() {
            if let layer = layersByIndex[index], layer.superlayer !== rootLayer || rootLayer.sublayers?.last !== layer {
                rootLayer.addSublayer(layer)
            }
        }
        // Wake at the next change of photos (start or end of a crossfade), or soon if a photo
        // we need hasn't loaded yet.
        let missingImage = wanted.contains { imagesByIndex[$0] == nil }
        let boundaries = [Double(primary + 1) * block - configuration.crossfadeDuration, Double(primary + 1) * block, total]
        let next = boundaries.filter { $0 > elapsed + 0.001 }.min() ?? (elapsed + block)
        let delay = missingImage ? min(0.25, next - elapsed) : next - elapsed + 0.01
        scheduleRefresh(after: max(0.02, delay))
    }

    private func scheduleRefresh(after delay: Double) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func reportIndicesIfChanged(_ primary: Int, _ secondary: Int?, _ configuration: Configuration) {
        if let last = lastReportedIndices, last.0 == primary, last.1 == secondary { return }
        lastReportedIndices = (primary, secondary)
        let onFrameIndicesChanged = configuration.onFrameIndicesChanged
        DispatchQueue.main.async { onFrameIndicesChanged(primary, secondary) }
    }

    // MARK: - Layers

    /// The pan and zoom for photo `index` at Ken Burns progress `progress` (0...1).
    private func kenBurnsTransform(index: Int, progress: Double) -> CATransform3D {
        let p = CGFloat(min(max(progress, 0), 1))
        let directionX: CGFloat = index % 2 == 0 ? 1 : -1
        let directionY: CGFloat = index % 3 == 0 ? -1 : 1
        let zoomStart = 1.04 + CGFloat(index % 5) * 0.01
        let zoom = zoomStart + 0.16 * p
        let panX = directionX * bounds.width * 0.06 * (p - 0.5)
        var panY = directionY * bounds.height * 0.045 * (p - 0.5)
        #if os(macOS)
            panY = -panY
        #endif
        return CATransform3DConcat(CATransform3DMakeScale(zoom, zoom, 1), CATransform3DMakeTranslation(panX, panY, 0))
    }

    private func makePhotoLayer(index: Int, image: NSImage?, configuration: Configuration) -> StillLayer {
        let layer = StillLayer()
        layer.bounds = CGRect(origin: .zero, size: bounds)
        layer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        layer.contentsGravity = .resizeAspectFill
        layer.contents = LayerImageCache.cgImage(for: image)
        let appear = originMediaTime + appearTime(index, configuration)
        let fadeOutStart = originMediaTime + Double(index + 1) * block - configuration.crossfadeDuration

        // Pan and zoom over one block from when the photo appears, then hold.
        layer.transform = kenBurnsTransform(index: index, progress: 1)
        let kenBurns = CABasicAnimation(keyPath: "transform")
        kenBurns.fromValue = NSValue(caTransform3D: kenBurnsTransform(index: index, progress: 0))
        kenBurns.toValue = NSValue(caTransform3D: kenBurnsTransform(index: index, progress: 1))
        kenBurns.duration = block
        kenBurns.fillMode = .both
        kenBurns.isRemovedOnCompletion = false
        // A start in the past (for example after resuming) picks up part way through; no
        // timeOffset, which on a one-shot animation wraps round to the beginning.
        kenBurns.beginTime = layer.convertTime(appear, from: nil)
        layer.add(kenBurns, forKey: "kenBurns")

        // Fade in over the crossfade (not the first photo), and out over the next one's.
        let isLast = index == configuration.imageCount - 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let fadeInEnd = appear + (index == 0 ? 0 : configuration.crossfadeDuration)
        let fadeOutEnd = isLast ? fadeInEnd + 3600 : fadeOutStart + configuration.crossfadeDuration
        let times = [appear, fadeInEnd, isLast ? fadeOutEnd : fadeOutStart, fadeOutEnd]
        let span = max(0.001, fadeOutEnd - appear)
        fade.values = index == 0 ? [1, 1, 1, isLast ? 1 : 0] : [0, 1, 1, isLast ? 1 : 0]
        fade.keyTimes = times.map { NSNumber(value: ($0 - appear) / span) }
        fade.duration = span
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        fade.beginTime = layer.convertTime(appear, from: nil)
        layer.opacity = isLast ? 1 : 0
        layer.add(fade, forKey: "fade")
        return layer
    }

    /// Paused: the paused photo alone, standing still a quarter of the way through its pan.
    private func showPaused(_ configuration: Configuration) {
        let index = min(max(0, configuration.pausedIndex), configuration.imageCount - 1)
        for (other, layer) in layersByIndex where other != index {
            layer.removeFromSuperlayer()
            layersByIndex[other] = nil
            imagesByIndex[other] = nil
        }
        let image = configuration.imageForIndex(index)
        let layer = layersByIndex[index] ?? StillLayer()
        withoutLayerActions {
            layer.removeAllAnimations()
            layer.bounds = CGRect(origin: .zero, size: bounds)
            layer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            layer.contentsGravity = .resizeAspectFill
            layer.contents = LayerImageCache.cgImage(for: image)
            layer.opacity = 1
            layer.transform = kenBurnsTransform(index: index, progress: 0.25)
        }
        if layer.superlayer == nil {
            rootLayer.addSublayer(layer)
        }
        layersByIndex[index] = layer
        imagesByIndex[index] = image
        reportIndicesIfChanged(index, nil, configuration)
        if image == nil {
            scheduleRefresh(after: 0.25)
        }
    }
}

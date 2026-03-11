import SwiftUI

struct ScreenSaverFullscreenView: View {
    @StateObject private var model = ScreenSaverPhotoStreamModel()
    @State private var startTime = Date()
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        screenSaverBody
    }

    private var screenSaverBody: some View {
        GeometryReader { proxy in
            FirstRowTimelineView(minimumInterval: 1.0 / 144.0) { currentDate in
                let elapsed = max(0, currentDate.timeIntervalSince(startTime))
                let spinState = SpinCycleState(elapsed: elapsed)
                ZStack {
                    Color.black
                    ForEach(model.photos) { photo in
                        let snapshot = projectedSnapshot(
                            for: photo,
                            elapsed: elapsed,
                            canvasSize: proxy.size,
                            spinState: spinState,
                        )
                        if snapshot.isVisible {
                            ZStack {
                                Image(nsImage: photo.image).resizable().interpolation(.high).antialiased(true).frame(width: snapshot.size.width, height: snapshot.size.height).opacity(snapshot.showsFrontFace ? 1 : 0)
                                Image(nsImage: photo.image).resizable().interpolation(.high).antialiased(true).frame(width: snapshot.size.width, height: snapshot.size.height).scaleEffect(x: -1, y: 1).rotation3DEffect(.degrees(180),
                                                                                                                                                                                                                         axis: (x: 0, y: 1, z: 0),
                                                                                                                                                                                                                         perspective: 0).opacity(snapshot.showsFrontFace ? 0 : 1)
                            }.rotation3DEffect(.degrees(snapshot.cardRotationDegrees),
                                               axis: (x: 0, y: 1, z: 0),
                                               perspective: 0).shadow(
                                color: Color.black.opacity(0.55),
                                radius: min(26, max(8, snapshot.size.width * 0.03)),
                                x: 0,
                                y: min(16, max(4, snapshot.size.height * 0.025)),
                            ).position(snapshot.position).opacity(snapshot.opacity)
                        }
                    }
                }.scaleEffect(1 - (0.08 * spinState.zoomOutAmount), anchor: .center).ignoresSafeArea()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onAppear {
            startTime = Date()
            model.loadIfNeeded()
        }
    }

    private func projectedSnapshot(
        for photo: ScreenSaverPhotoEntry,
        elapsed: TimeInterval,
        canvasSize: CGSize,
        spinState: SpinCycleState,
    ) -> ProjectedPhotoSnapshot {
        let initialEmptyDuration: TimeInterval = 3

        let motionElapsed = max(0, elapsed - initialEmptyDuration)
        let streamHeight = canvasSize.height * 2.25
        let baseStartY = -canvasSize.height * 0.9
        let lowerY = baseStartY - streamHeight
        let upperY = canvasSize.height * 1.2
        let wrapSpan = max(1, upperY - lowerY)
        let baseY = baseStartY - (photo.normalizedY * streamHeight)
        let unwrappedY = baseY + (photo.riseSpeed * CGFloat(motionElapsed))
        let wrappedY = lowerY + positiveModulo(unwrappedY - lowerY, wrapSpan)
        let worldY = wrappedY
        let initialWrappedY = lowerY + positiveModulo(baseY - lowerY, wrapSpan)
        let worldWidth = canvasSize.width * 1.25
        let worldX = (photo.normalizedX - 0.5) * worldWidth
        let worldZ = (photo.normalizedZ - 0.5) * 620
        let cosTheta = CGFloat(cos(spinState.orbitRotationRadians))
        let sinTheta = CGFloat(sin(spinState.orbitRotationRadians))
        let rotatedX = (worldX * cosTheta) + (worldZ * sinTheta)
        let rotatedZ = (worldZ * cosTheta) - (worldX * sinTheta)
        let cameraDistance: CGFloat = 760
        let perspective = cameraDistance / max(180, cameraDistance - rotatedZ)
        let projectedX = (canvasSize.width * 0.5) + (rotatedX * perspective)
        let projectedY = (canvasSize.height * 0.5) - (worldY * perspective)
        let initialProjectedY = (canvasSize.height * 0.5) - (initialWrappedY * perspective)
        let pixelToPoint: CGFloat = 0.34
        let rawScale = pixelToPoint * perspective * photo.sizeMultiplier
        var projectedWidth = max(70, photo.imageSize.width * rawScale)
        var projectedHeight = max(70, photo.imageSize.height * rawScale)
        let maxWidth = canvasSize.width * 0.9
        let maxHeight = canvasSize.height * 0.95
        let clampScale = min(1, maxWidth / projectedWidth, maxHeight / projectedHeight)
        projectedWidth *= clampScale
        projectedHeight *= clampScale
        let verticalVisibilityPadding = projectedHeight * 0.8
        let initialCycle = floor((baseY - lowerY) / wrapSpan)
        let currentCycle = floor((unwrappedY - lowerY) / wrapSpan)
        let hasWrappedSinceStart = currentCycle > initialCycle
        let startedBelowBottom = initialProjectedY >= canvasSize.height
        let startupRevealAllowed = startedBelowBottom || hasWrappedSinceStart
        let isVisible = elapsed >= initialEmptyDuration
            && startupRevealAllowed
            && projectedY > -verticalVisibilityPadding
            && projectedY < (canvasSize.height + verticalVisibilityPadding)
        let opacity: CGFloat = isVisible ? 1 : 0
        return ProjectedPhotoSnapshot(
            isVisible: isVisible,
            position: CGPoint(x: projectedX, y: projectedY),
            size: CGSize(width: projectedWidth, height: projectedHeight),
            opacity: opacity,
            cardRotationDegrees: spinState.cardRotationDegrees,
            showsFrontFace: cos(spinState.orbitRotationRadians) >= 0,
        )
    }

    private func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }
}

private struct ProjectedPhotoSnapshot {
    let isVisible: Bool
    let position: CGPoint
    let size: CGSize
    let opacity: CGFloat
    let cardRotationDegrees: Double
    let showsFrontFace: Bool
}

private struct SpinCycleState {
    let orbitRotationRadians: Double
    let cardRotationDegrees: Double
    let zoomOutAmount: CGFloat
    init(elapsed: TimeInterval) {
        guard elapsed >= 60 else {
            orbitRotationRadians = 0
            cardRotationDegrees = 0
            zoomOutAmount = 0
            return
        }
        let cycleTime = (elapsed - 60).truncatingRemainder(dividingBy: 60)
        let rotationDuration: TimeInterval = 3.0
        if cycleTime < rotationDuration {
            let progress = cycleTime / rotationDuration
            let eased = SpinCycleState.easeInOutQuad(progress)

            orbitRotationRadians = 2 * Double.pi * eased
            cardRotationDegrees = 360 * eased

            if progress < 0.75 {
                let zoomOutProgress = progress / 0.75
                zoomOutAmount = CGFloat(SpinCycleState.easeInOutQuad(zoomOutProgress))
            } else {
                let zoomInProgress = (progress - 0.75) / 0.25
                zoomOutAmount = CGFloat(1 - SpinCycleState.easeInOutQuad(zoomInProgress))
            }
        } else {
            orbitRotationRadians = 0
            cardRotationDegrees = 0
            zoomOutAmount = 0
        }
    }

    private static func easeInOutQuad(_ t: TimeInterval) -> TimeInterval {
        let x = min(max(t, 0), 1)
        if x < 0.5 {
            return 2 * x * x
        }
        return 1 - (pow(-2 * x + 2, 2) / 2)
    }
}

private struct ScreenSaverPhotoEntry: Identifiable {
    let id: Int
    let image: NSImage
    let imageSize: CGSize
    let sizeMultiplier: CGFloat
    let normalizedX: CGFloat
    let normalizedY: CGFloat
    let normalizedZ: CGFloat
    let riseSpeed: CGFloat
}

@MainActor
private final class ScreenSaverPhotoStreamModel: ObservableObject {
    @Published private(set) var photos: [ScreenSaverPhotoEntry] = []
    private var hasLoaded = false
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let imageURLs = loadScreenSaverImageURLs()
        let loadedImages = imageURLs.compactMap { url -> NSImage? in
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image
        }
        guard !loadedImages.isEmpty else {
            return
        }
        var rng = SystemRandomNumberGenerator()

        let total = max(loadedImages.count * 2, 48)
        let bandCount = 2
        let slotsPerBand = max(1, total / bandCount)

        let halfWrapOffsetInStreamUnits: CGFloat = 0.9666666667
        photos = (0 ..< total).map { index in
            let image = loadedImages[index % loadedImages.count]
            let band = index % bandCount
            let slot = index / bandCount

            let laneProgress = (CGFloat(slot) + 0.5) / CGFloat(slotsPerBand)
            let laneJitter = CGFloat.random(in: -0.02 ... 0.02, using: &rng) / CGFloat(slotsPerBand)
            let verticalPhase = laneProgress + laneJitter + (CGFloat(band) * halfWrapOffsetInStreamUnits)

            let xPhase = fractional(CGFloat(index) * 0.61803398875 + 0.17)
            let zPhase = fractional(CGFloat(index) * 0.75487766625 + 0.41)
            let isHero = index % 11 == 0
            return ScreenSaverPhotoEntry(
                id: index,
                image: image,
                imageSize: image.size,
                sizeMultiplier: isHero
                    ? CGFloat.random(in: 2.0 ... 2.9, using: &rng)
                    : CGFloat.random(in: 1.2 ... 1.9, using: &rng),
                normalizedX: 0.06 + (xPhase * 0.88),
                normalizedY: verticalPhase,
                normalizedZ: isHero
                    ? (0.72 + (zPhase * 0.26))
                    : (0.24 + (zPhase * 0.68)),

                riseSpeed: 62,
            )
        }
    }

    private func fractional(_ value: CGFloat) -> CGFloat {
        value - floor(value)
    }

    private func loadScreenSaverImageURLs() -> [URL] {
        let fileManager = FileManager.default
        let fullImageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp"])
        let fallbackRootExtensions = Set(["jpg", "jpeg", "heic", "heif"])
        func images(in directory: URL?, extensions: Set<String>) -> [URL] {
            guard let directory else { return [] }
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
            ) else {
                return []
            }
            return urls.filter { url in
                extensions.contains(url.pathExtension.lowercased())
            }
        }
        var urls: [URL] = []
        if let bundledFolder = Bundle.main.resourceURL?.appendingPathComponent("ScreenSaverDefaultPhotos", isDirectory: true) {
            urls.append(contentsOf: images(in: bundledFolder, extensions: fullImageExtensions))
        }
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let localFolders = [
            currentDirectory.appendingPathComponent("ScreenSaverDefaultPhotos", isDirectory: true),
            currentDirectory.appendingPathComponent("firstRow/ScreenSaverDefaultPhotos", isDirectory: true),
        ]
        for folder in localFolders {
            urls.append(contentsOf: images(in: folder, extensions: fullImageExtensions))
        }
        if urls.isEmpty {
            urls.append(contentsOf: images(in: Bundle.main.resourceURL, extensions: fallbackRootExtensions))
        }
        var seen: Set<String> = []
        let deduped = urls.filter { url in
            let key = url.standardizedFileURL.path
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
        return deduped.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

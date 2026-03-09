import SwiftUI

struct MusicPreviewGapContentView: View {
    let image: NSImage?
    let baseIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let showPreview: Bool
    let showReflection: Bool
    let forcedAspectRatio: CGFloat?
    let previewYawDegrees: Double
    let reflectionYawDegrees: Double
    let reflectionOpacity: CGFloat
    let reflectionFadeEnd: CGFloat
    let reflectionBlurRadius: CGFloat
    init(
        image: NSImage?,
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        showPreview: Bool = true,
        showReflection: Bool = true,
        forcedAspectRatio: CGFloat? = 1.0,
        previewYawDegrees: Double = 24,
        reflectionYawDegrees: Double = 23.8,
        reflectionOpacity: CGFloat = 0.44,
        reflectionFadeEnd: CGFloat = 0.25,
        reflectionBlurRadius: CGFloat = 0.5,
    ) {
        self.image = image
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.showPreview = showPreview
        self.showReflection = showReflection
        self.forcedAspectRatio = forcedAspectRatio
        self.previewYawDegrees = previewYawDegrees
        self.reflectionYawDegrees = reflectionYawDegrees
        self.reflectionOpacity = reflectionOpacity
        self.reflectionFadeEnd = reflectionFadeEnd
        self.reflectionBlurRadius = reflectionBlurRadius
    }

    var body: some View {
        let previewSide: CGFloat = baseIconSize * 1.2
        let previewSize = previewContentSize(side: previewSide)
        let previewYaw = Angle(degrees: previewYawDegrees)
        let reflectionYaw = Angle(degrees: reflectionYawDegrees)
        let perspective: CGFloat = 0.75
        let reflectionGap: CGFloat = 0
        return ZStack {
            if showReflection {
                previewContent(side: previewSide, size: previewSize).mask(
                    LinearGradient(
                        gradient: Gradient(stops: [.init(color: .white, location: 0.0), .init(color: .clear, location: reflectionFadeEnd)]),
                        startPoint: .bottom,
                        endPoint: .top,
                    ),
                ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).opacity(reflectionOpacity).rotation3DEffect(
                    reflectionYaw,
                    axis: (x: 0, y: 1, z: 0),
                    perspective: perspective,
                ).blur(radius: reflectionBlurRadius).offset(y: reflectionGap)
            }
            if showPreview {
                previewContent(side: previewSide, size: previewSize).rotation3DEffect(
                    previewYaw,
                    axis: (x: 0, y: 1, z: 0),
                    perspective: perspective,
                )
            }
        }.offset(x: horizontalOffset, y: verticalOffset).padding(.bottom, 100)
    }

    @ViewBuilder
    private func previewContent(side: CGFloat, size: CGSize) -> some View {
        if let image {
            ZStack {
                Color.black
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }.frame(width: size.width, height: size.height).clipped()
        } else {
            Rectangle().fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.13, blue: 0.17),
                        Color(red: 0.06, green: 0.06, blue: 0.08),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing,
                ),
            ).frame(width: size.width, height: size.height).overlay(
                Image(systemName: "music.note").font(.system(size: side * 0.26, weight: .regular)).foregroundColor(.white.opacity(0.72)),
            ).clipped()
        }
    }

    private func previewContentSize(side: CGFloat) -> CGSize {
        let aspect = resolvedAspectRatio()
        if aspect >= 1 {
            return CGSize(width: side, height: side / aspect)
        }
        return CGSize(width: side * aspect, height: side)
    }

    private func resolvedAspectRatio() -> CGFloat {
        if let forcedAspectRatio {
            return clampedAspectRatio(forcedAspectRatio)
        }
        guard let image else { return 1.0 }
        let width = image.size.width
        let height = image.size.height
        guard width > 1, height > 1 else { return 1.0 }
        return clampedAspectRatio(width / height)
    }

    private func clampedAspectRatio(_ rawRatio: CGFloat) -> CGFloat {
        max(0.4, min(3.0, rawRatio))
    }
}

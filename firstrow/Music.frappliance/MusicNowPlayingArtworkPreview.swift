import SwiftUI

struct MusicNowPlayingArtworkPreview: View {
    let image: NSImage?
    let side: CGFloat
    let mirrored: Bool
    private var previewYaw: Angle {
        Angle(degrees: mirrored ? 9 : -9)
    }

    private var reflectionYaw: Angle {
        Angle(degrees: mirrored ? 9 : -9)
    }

    private let perspective: CGFloat = 0.9
    var body: some View {
        let reflectionGap = max(8, side * 0.03)
        ZStack(alignment: .topLeading) {
            previewImage.frame(width: side, height: side).shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 2).rotation3DEffect(
                previewYaw,
                axis: (x: 0, y: 1, z: 0),
                perspective: perspective,
            )
            previewImage.frame(width: side, height: side).mask(
                LinearGradient(
                    gradient: Gradient(stops: [.init(color: .white, location: 0.0), .init(color: .white.opacity(0.68), location: 0.05), .init(color: .white.opacity(0.26), location: 0.12), .init(color: .white.opacity(0.08), location: 0.17), .init(color: .clear, location: 0.22)]),
                    startPoint: .bottom,
                    endPoint: .top,
                ),
            ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).opacity(0.42).rotation3DEffect(
                reflectionYaw,
                axis: (x: 0, y: 1, z: 0),
                perspective: perspective,
            ).blur(radius: 0.55).offset(y: reflectionGap)
        }.frame(width: side * 1.12, height: side * 1.72, alignment: .topLeading)
    }

    @ViewBuilder
    private var previewImage: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: side, height: side).clipped()
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
            ).frame(width: side, height: side).overlay(
                Image(systemName: "music.note").font(.system(size: side * 0.26, weight: .regular)).foregroundStyleCompat(.white.opacity(0.72)),
            ).clipped()
        }
    }
}

import SwiftUI

enum MoviePlaybackGlyphState: Equatable {
    case pause
    case play
    case loading
    case rewind(Int)
    case fastForward(Int)
}

struct MoviePlaybackControlsOverlay: View {
    let glyphState: MoviePlaybackGlyphState
    let currentTimeSeconds: Double
    let durationSeconds: Double
    let isLoading: Bool
    let loadingProgress: Double
    private let baseColor = Color.black
    private let lowerGlossBottomColor = Color(red: 20 / 255, green: 30 / 255, blue: 40 / 255)
    private let upperGlossColor = Color(red: 20 / 255, green: 36 / 255, blue: 50 / 255)
    private let centerTrackTop = Color(red: 70 / 255, green: 140 / 255, blue: 205 / 255)
    private let centerTrackMid = Color(red: 55 / 255, green: 165 / 255, blue: 210 / 255)
    private let centerTrackBottom = Color(red: 60 / 255, green: 218 / 255, blue: 235 / 255)
    private let centerTrackBlend = Color(red: 58 / 255, green: 191 / 255, blue: 223 / 255)
    var body: some View {
        GeometryReader { geometry in
            let controlWidth = min(geometry.size.width * 0.94, 1600)
            let trackHeight: CGFloat = 38
            let innerInset: CGFloat = 4
            let sideSectionFraction: CGFloat = 0.10
            let laneWidth = max(0, controlWidth - (innerInset * 2))
            let sideSectionWidth = laneWidth * sideSectionFraction
            let centerSectionWidth = max(0, laneWidth - (sideSectionWidth * 2))
            let centerTrackHeight = max(0, trackHeight - (innerInset * 2))
            let diamondSize: CGFloat = 18
            let diamondTravelInset: CGFloat = 16
            let hasValidDuration = durationSeconds.isFinite && durationSeconds > 0.001
            let progress = hasValidDuration
                ? max(0, min(1, currentTimeSeconds / durationSeconds))
                : 0
            let clampedLoadingProgress = max(0, min(1, loadingProgress))
            let displayedProgress = isLoading ? clampedLoadingProgress : progress
            let centerTrackStartX = innerInset + sideSectionWidth
            let diamondTravelStartX = centerTrackStartX + min(diamondTravelInset, centerSectionWidth * 0.5)
            let diamondTravelWidth = max(0, centerSectionWidth - ((diamondTravelStartX - centerTrackStartX) * 2))
            let diamondCenterX = diamondTravelStartX + (diamondTravelWidth * progress)
            let centerFillWidth = centerSectionWidth * CGFloat(displayedProgress)
            VStack {
                Spacer()
                VStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(baseColor)
                        Capsule(style: .continuous).fill(
                            LinearGradient(
                                gradient: Gradient(stops: [.init(color: .black, location: 0.60), .init(color: lowerGlossBottomColor.opacity(0.92), location: 1.0)]),
                                startPoint: .top,
                                endPoint: .bottom,
                            ),
                        ).frame(width: controlWidth - 2, height: trackHeight - 2).offset(x: 1, y: -0.5)
                        Capsule(style: .continuous).fill(
                            LinearGradient(
                                colors: [
                                    upperGlossColor.opacity(0.92),
                                    upperGlossColor.opacity(0.78), .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom,
                            ),
                        ).frame(width: controlWidth - 2, height: trackHeight - 2).offset(x: 1, y: -0.5).mask(
                            PlaybackBaseUpperGlossMask().fill(Color.white).blur(radius: 0.9),
                        )
                        Group {
                            if isLoading {
                                Capsule(style: .continuous).fill(
                                    LinearGradient(
                                        gradient: Gradient(stops: [.init(color: .black.opacity(0.52), location: 0.0), .init(color: .black.opacity(0.64), location: 1.0)]),
                                        startPoint: .top,
                                        endPoint: .bottom,
                                    ),
                                ).overlay(Rectangle().fill(LinearGradient(gradient: Gradient(stops: [.init(color: .white.opacity(0.10), location: 0.0), .init(color: .white.opacity(0.03), location: 0.42), .init(color: .clear, location: 0.80)]), startPoint: .top, endPoint: .bottom)), alignment: .top).frame(width: centerSectionWidth, height: centerTrackHeight).clipShape(Capsule(style: .continuous)).offset(x: innerInset + sideSectionWidth).opacity(displayedProgress < 0.999 ? 1 : 0)
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(
                                        LinearGradient(
                                            gradient: Gradient(stops: [.init(color: centerTrackTop, location: 0.0), .init(color: centerTrackMid, location: 0.42), .init(color: centerTrackBlend, location: 0.56), .init(color: centerTrackBottom, location: 1.0)]),
                                            startPoint: .top,
                                            endPoint: .bottom,
                                        ),
                                    ).overlay(Rectangle().fill(LinearGradient(gradient: Gradient(stops: [.init(color: .white.opacity(0.22), location: 0.0), .init(color: .white.opacity(0.10), location: 0.24), .init(color: .clear, location: 0.58)]), startPoint: .top, endPoint: .bottom)), alignment: .top).overlay(Rectangle().fill(LinearGradient(gradient: Gradient(stops: [.init(color: centerTrackMid.opacity(0.30), location: 0.0), .init(color: centerTrackBlend.opacity(0.32), location: 0.5), .init(color: centerTrackBottom.opacity(0.24), location: 1.0)]), startPoint: .top, endPoint: .bottom)).frame(height: centerTrackHeight * 0.26).blur(radius: 1.4), alignment: .center).frame(width: centerFillWidth, height: centerTrackHeight, alignment: .leading).transaction { transaction in
                                        transaction.animation = nil
                                    }
                                }.frame(width: centerSectionWidth, height: centerTrackHeight, alignment: .leading).clipShape(Capsule(style: .continuous)).offset(x: innerInset + sideSectionWidth)
                            } else {
                                Capsule(style: .continuous).fill(
                                    LinearGradient(
                                        gradient: Gradient(stops: [.init(color: centerTrackTop, location: 0.0), .init(color: centerTrackMid, location: 0.42), .init(color: centerTrackBlend, location: 0.56), .init(color: centerTrackBottom, location: 1.0)]),
                                        startPoint: .top,
                                        endPoint: .bottom,
                                    ),
                                ).overlay(Rectangle().fill(LinearGradient(gradient: Gradient(stops: [.init(color: .white.opacity(0.22), location: 0.0), .init(color: .white.opacity(0.10), location: 0.24), .init(color: .clear, location: 0.58)]), startPoint: .top, endPoint: .bottom)), alignment: .top).overlay(Rectangle().fill(LinearGradient(gradient: Gradient(stops: [.init(color: centerTrackMid.opacity(0.30), location: 0.0), .init(color: centerTrackBlend.opacity(0.32), location: 0.5), .init(color: centerTrackBottom.opacity(0.24), location: 1.0)]), startPoint: .top, endPoint: .bottom)).frame(height: centerTrackHeight * 0.26).blur(radius: 1.4), alignment: .center).frame(width: centerSectionWidth, height: centerTrackHeight).clipShape(Capsule(style: .continuous)).offset(x: innerInset + sideSectionWidth)
                            }
                        }
                        if !isLoading {
                            RoundedRectangle(cornerRadius: 1.8, style: .continuous).fill(baseColor).overlay(
                                RoundedRectangle(cornerRadius: 0, style: .continuous).stroke(baseColor),
                            ).frame(width: diamondSize, height: diamondSize).rotationEffect(.degrees(45)).offset(
                                x: max(
                                    innerInset,
                                    min(controlWidth - innerInset - diamondSize, diamondCenterX - (diamondSize * 0.5)),
                                ),
                            )
                        }
                        HStack(spacing: 0) {
                            Color.clear.frame(width: sideSectionWidth, height: trackHeight).overlay(MoviePlaybackGlyphView(state: glyphState), alignment: .center)
                            Spacer(minLength: centerSectionWidth)
                            Text(isLoading || durationSeconds <= 0.001 ? "" : formatTime(durationSeconds)).font(.firstRowBold(size: 30)).foregroundColor(.white).frame(width: sideSectionWidth, alignment: .center)
                        }.frame(width: laneWidth, height: trackHeight).offset(x: innerInset)
                    }.frame(width: controlWidth, height: trackHeight).overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0), lineWidth: 1)).shadow(color: .black.opacity(0.8), radius: 5, x: 0, y: 2)
                    Text(formatTime(currentTimeSeconds)).font(.firstRowBold(size: 22)).foregroundColor(.white).shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1).opacity(isLoading ? 0 : 1).position(x: diamondCenterX, y: 16).frame(width: controlWidth, height: 28, alignment: .leading)
                }.frame(width: controlWidth, alignment: .leading).padding(.bottom, 52)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.ignoresSafeArea().allowsHitTesting(false)
    }

    private func formatTime(_ seconds: Double) -> String {
        formatfirstRowPlaybackTime(seconds)
    }
}

private struct PlaybackBaseUpperGlossMask: Shape {
    func path(in rect: CGRect) -> Path {
        let sideCurveWidth = rect.width * 0.016
        let topEdgeY = rect.minY + rect.height * 0.02
        let sideBottomY = rect.minY + rect.height * 0.06
        let flatBottomY = rect.minY + rect.height * 0.50
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: sideBottomY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - sideCurveWidth, y: flatBottomY),
            control: CGPoint(x: rect.maxX - (sideCurveWidth * 0.08), y: flatBottomY),
        )
        path.addLine(to: CGPoint(x: rect.minX + sideCurveWidth, y: flatBottomY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: sideBottomY),
            control: CGPoint(x: rect.minX + (sideCurveWidth * 0.08), y: flatBottomY),
        )
        path.closeSubpath()
        return path
    }
}

private struct MoviePlaybackGlyphView: View {
    let state: MoviePlaybackGlyphState
    var body: some View {
        glyphContent.shadow(color: .white.opacity(0.45), radius: 1.8, x: 0, y: 0).shadow(color: .white.opacity(0.2), radius: 3.2, x: 0, y: 0)
    }

    @ViewBuilder
    private var glyphContent: some View {
        switch state {
        case .pause:
            Image(systemName: "pause.fill").font(.system(size: 23, weight: .bold)).foregroundColor(.white)
        case .play:
            Image(systemName: "play.fill").font(.system(size: 23, weight: .bold)).foregroundColor(.white).offset(x: 1)
        case .loading:
            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(1.05)
        case let .rewind(requestedCount):
            let count = max(1, min(3, requestedCount))
            LazyHStack(spacing: -7) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Image(systemName: "play.fill").font(.system(size: 23, weight: .bold)).foregroundColor(.white).rotationEffect(.degrees(180))
                }
            }.offset(x: 4)
        case let .fastForward(requestedCount):
            let count = max(1, min(3, requestedCount))
            LazyHStack(spacing: -7) {
                ForEach(0 ..< count, id: \.self) { _ in
                    Image(systemName: "play.fill").font(.system(size: 23, weight: .bold)).foregroundColor(.white)
                }
            }.offset(x: -4)
        }
    }
}

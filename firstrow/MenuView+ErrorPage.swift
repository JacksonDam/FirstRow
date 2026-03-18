import SwiftUI

extension MenuView {
    @ViewBuilder
    func errorPageMenuView(geometry: GeometryProxy) -> some View {
        let w = geometry.size.width
        let h = geometry.size.height
        let transitionProgress = smoothStep(submenuTransitionProgress)
        let dividerTopEdge = interpolatedCGFloat(
            from: h,
            to: submenuDividerTopInset,
            progress: transitionProgress,
        )
        let settledContentTopY = submenuDividerTopInset + submenuDividerThickness
        let errorOffsetFromDivider = submenuDividerThickness + (h - settledContentTopY) * 0.45
        let errorCenterY = dividerTopEdge + errorOffsetFromDivider

        VStack(spacing: 40) {
            Text(errorPageHeaderText)
                .font(.firstRowBold(size: 72))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: w * 0.8)

            if !errorPageSubcaptionText.isEmpty {
                Text(errorPageSubcaptionText)
                    .font(.firstRowBold(size: 38))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: w * 0.7)
            }
        }
        .position(x: w * 0.5, y: errorCenterY)
        .frame(width: w, height: h)
    }
}

import SwiftUI

struct FeatureErrorFullscreenView: View {
    let headerText: String
    let subcaptionText: String
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 15) {
                HStack(spacing: 8) {
                    if let icon = NSImage(named: "ErrorTriangle_v1") ?? NSImage(named: "Alert!") {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 84, height: 84)
                    }
                    Text(headerText).font(.firstRowBold(size: 60)).foregroundColor(.white).multilineTextAlignment(.leading).offset(y: -12)
                }
                if !subcaptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subcaptionText).font(.firstRowBold(size: 30)).foregroundColor(.white).multilineTextAlignment(.center).lineSpacing(4)
                }
            }.frame(maxWidth: 1500).offset(y: -160)
        }
    }
}

struct FeatureLoadingFullscreenView: View {
    let headerText: String
    let showsSpinner: Bool
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 42) {
                Text(headerText).font(.firstRowBold(size: 60)).foregroundColor(.white).multilineTextAlignment(.center)
                if showsSpinner {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(2.0).frame(width: 72, height: 72)
                } else {
                    Color.clear.frame(width: 72, height: 72)
                }
            }.frame(maxWidth: 1500, maxHeight: .infinity, alignment: .center)
        }
    }
}

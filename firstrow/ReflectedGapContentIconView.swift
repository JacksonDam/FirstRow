import SwiftUI

struct PlainGapContentIconView: View {
    let image: NSImage
    let adjustedIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    var body: some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).offset(x: horizontalOffset, y: verticalOffset).padding(.bottom, 100)
    }
}

struct ReflectedGapContentIconView: View {
    let image: NSImage
    let adjustedIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let reflectionYOffset: CGFloat
    init(
        image: NSImage,
        adjustedIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        reflectionYOffset: CGFloat = 0,
    ) {
        self.image = image
        self.adjustedIconSize = adjustedIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.reflectionYOffset = reflectionYOffset
    }

    var body: some View {
        ZStack {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).mask(
                LinearGradient(
                    gradient: Gradient(stops: [.init(color: .white, location: 0.0), .init(color: .clear, location: 0.6)]),
                    startPoint: .bottom,
                    endPoint: .top,
                ),
            ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).opacity(0.34).offset(y: -(adjustedIconSize * 0.215) + reflectionYOffset)
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize)
        }.offset(x: horizontalOffset, y: verticalOffset).padding(.bottom, 100)
    }
}

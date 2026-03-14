import SwiftUI

let firstRowRegularFontName = "Lucida Grande"
let firstRowBoldFontName = "Lucida Grande Bold"
extension Font {
    static func firstRowRegular(size: CGFloat) -> Font {
        .custom(firstRowRegularFontName, size: size)
    }

    static func firstRowBold(size: CGFloat) -> Font {
        .custom(firstRowBoldFontName, size: size)
    }
}

struct FirstRowTimelineView<Content: View>: View {
    let minimumInterval: TimeInterval
    let content: (Date) -> Content
    @State private var fallbackDate = Date()

    init(
        minimumInterval: TimeInterval,
        @ViewBuilder content: @escaping (Date) -> Content,
    ) {
        self.minimumInterval = minimumInterval
        self.content = content
    }

    var body: some View {
        if #available(macOS 12.0, *) {
            TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { timeline in
                content(timeline.date)
            }
        } else {
            content(fallbackDate)
                .onAppear {
                    fallbackDate = Date()
                }
                .onReceive(Timer.publish(every: minimumInterval, on: .main, in: .common).autoconnect()) { currentDate in
                    fallbackDate = currentDate
                }
        }
    }
}

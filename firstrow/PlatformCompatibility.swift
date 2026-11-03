import Foundation

#if os(iOS) || os(tvOS)
    let firstRowRegularFontName = "Helvetica Neue"
    let firstRowBoldFontName = "Helvetica Neue Bold"
#else
    let firstRowRegularFontName = "Lucida Grande"
    let firstRowBoldFontName = "Lucida Grande Bold"
#endif

func firstRowSleep(_ seconds: Double) async throws {
    if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
        try await Task.sleep(for: .seconds(seconds))
    } else {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

#if os(iOS) || os(tvOS)
    import UIKit

    typealias NSImage = UIImage
    typealias NSSize = CGSize
    typealias NSFont = UIFont
    extension NSImage {
        convenience init?(contentsOf url: URL) {
            self.init(contentsOfFile: url.path)
        }

        convenience init?(cgImage: CGImage, size _: NSSize) {
            self.init(cgImage: cgImage)
        }
    }
#endif

import SwiftUI

private let featureErrorKindPayloadKey = "featureErrorKind"
private let featureErrorHeaderPayloadKey = "header"
private let featureErrorSubcaptionPayloadKey = "subcaption"

struct FeatureErrorCopy {
    let headerText: String
    let subcaptionText: String

    static let fallback = FeatureErrorCopy(
        headerText: "First Row cannot complete this request.",
        subcaptionText: "",
    )

    static func resolve(from payload: [String: String]) -> FeatureErrorCopy {
        if let rawKind = payload[featureErrorKindPayloadKey],
           let kind = FeatureErrorKind(rawValue: rawKind)
        {
            return kind.copy
        }
        return FeatureErrorCopy(
            headerText: payload[featureErrorHeaderPayloadKey] ?? fallback.headerText,
            subcaptionText: payload[featureErrorSubcaptionPayloadKey] ?? fallback.subcaptionText,
        )
    }
}

enum FeatureErrorKind: String {
    case genericOperationFailed
    case noSharedPhotos
    case noContentFound
    case protectedVideoUnsupported
    case noMoviesInFolder
    case noPhotosInLibrary
    case noPodcasts
    case noAudiobooks
    case noMusicVideos
    case noSongs
    case noPlaylists

    var copy: FeatureErrorCopy {
        switch self {
        case .genericOperationFailed:
            FeatureErrorCopy(
                headerText: "An error occurred.",
                subcaptionText: "",
            )
        case .noSharedPhotos:
            FeatureErrorCopy(
                headerText: "First Row cannot find any shared photos.",
                subcaptionText: "Use Photos to set up Shared Albums.",
            )
        case .noContentFound:
            FeatureErrorCopy(
                headerText: "No content was found.",
                subcaptionText: "",
            )
        case .protectedVideoUnsupported:
            FeatureErrorCopy(
                headerText: "This video cannot be played in First Row.",
                subcaptionText: "It appears to be protected media. Open it in Apple TV or Music.",
            )
        case .noMoviesInFolder:
            FeatureErrorCopy(
                headerText: "There are no movies to play in your Movies folder.",
                subcaptionText: "Make sure movies you create or download are in your Movies folder in your home folder.",
            )
        case .noPhotosInLibrary:
            FeatureErrorCopy(
                headerText: "There are no photos in your iPhoto library.",
                subcaptionText: "",
            )
        case .noPodcasts:
            FeatureErrorCopy(
                headerText: "First Row cannot find any podcasts.",
                subcaptionText: "Use iTunes to subscribe to podcasts from the iTunes Store.",
            )
        case .noAudiobooks:
            FeatureErrorCopy(
                headerText: "First Row cannot find any audiobooks.",
                subcaptionText: "Use iTunes to purchase audiobooks from the iTunes Store.",
            )
        case .noMusicVideos:
            FeatureErrorCopy(
                headerText: "First Row cannot find any music videos.",
                subcaptionText: "Use iTunes to purchase music videos from the iTunes Store.",
            )
        case .noSongs:
            FeatureErrorCopy(
                headerText: "First Row cannot find any songs.",
                subcaptionText: "Use iTunes to import songs or purchase songs from the iTunes Store.",
            )
        case .noPlaylists:
            FeatureErrorCopy(
                headerText: "First Row cannot find any playlists.",
                subcaptionText: "Use iTunes to create and manage your playlists.",
            )
        }
    }

    var payload: [String: String] {
        [featureErrorKindPayloadKey: rawValue]
    }
}

extension MenuView {
    func presentFeatureErrorScreen(_ kind: FeatureErrorKind, usingExistingBlackout: Bool = false) {
        presentFullscreenScene(
            key: featureErrorFullscreenKey,
            payload: kind.payload,
            usingExistingBlackout: usingExistingBlackout && isMenuFolderSwapTransitioning,
        )
    }
}

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
                    Text(headerText)
                        .font(.firstRowBold(size: 60))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1200, alignment: .center)
                        .offset(y: -12)
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

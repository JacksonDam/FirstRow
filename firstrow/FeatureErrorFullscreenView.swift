import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

private let featureErrorKindPayloadKey = "featureErrorKind"
private let featureErrorHeaderPayloadKey = "header"
private let featureErrorSubcaptionPayloadKey = "subcaption"

struct FeatureErrorCopy {
    let headerText: String
    let subcaptionText: String

    static let fallback = FeatureErrorCopy(
        headerText: L("First Row cannot complete this request."),
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
    case noSharedPhotos
    case noContentFound
    case protectedVideoUnsupported
    case noMoviesInFolder
    case noPhotosInLibrary
    case noPodcasts
    case podcastEpisodeUnavailable
    case noAudiobooks
    case noMusicVideos
    case noSongs
    case noPlaylists

    var copy: FeatureErrorCopy {
        switch self {
        case .noSharedPhotos:
            FeatureErrorCopy(
                headerText: L("First Row cannot find any shared photos."),
                subcaptionText: L("Use Photos to set up Shared Albums."),
            )
        case .noContentFound:
            FeatureErrorCopy(
                headerText: L("No content was found."),
                subcaptionText: "",
            )
        case .protectedVideoUnsupported:
            FeatureErrorCopy(
                headerText: L("This video cannot be played in First Row."),
                subcaptionText: L("It appears to be protected media. Open it in Apple TV or Music."),
            )
        case .noMoviesInFolder:
            FeatureErrorCopy(
                headerText: L("There are no movies to play in your Movies folder."),
                subcaptionText: L("Make sure movies you create or download are in your Movies folder in your home folder."),
            )
        case .noPhotosInLibrary:
            FeatureErrorCopy(
                headerText: L("There are no photos in your iPhoto library."),
                subcaptionText: "",
            )
        case .noPodcasts:
            FeatureErrorCopy(
                headerText: L("First Row cannot find any podcasts."),
                subcaptionText: L("Use iTunes to subscribe to podcasts from the iTunes Store."),
            )
        case .podcastEpisodeUnavailable:
            FeatureErrorCopy(
                headerText: L("This episode can't be played right now."),
                subcaptionText: L("First Row can't open the Podcasts app's download or find the episode online. Check your internet connection, or give First Row Full Disk Access in System Settings > Privacy & Security."),
            )
        case .noAudiobooks:
            FeatureErrorCopy(
                headerText: L("First Row cannot find any audiobooks."),
                subcaptionText: L("Use iTunes to purchase audiobooks from the iTunes Store."),
            )
        case .noMusicVideos:
            FeatureErrorCopy(
                headerText: L("First Row cannot find any music videos."),
                subcaptionText: L("Use iTunes to purchase music videos from the iTunes Store."),
            )
        case .noSongs:
            FeatureErrorCopy(
                headerText: L("First Row cannot find any songs."),
                subcaptionText: L("Use iTunes to import songs or purchase songs from the iTunes Store."),
            )
        case .noPlaylists:
            FeatureErrorCopy(
                headerText: L("First Row cannot find any playlists."),
                subcaptionText: L("Use iTunes to create and manage your playlists."),
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

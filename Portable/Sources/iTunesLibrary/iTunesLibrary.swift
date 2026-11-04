import FirstRowPortable
import Foundation

// Linux and Windows have no Music app library, so opening one fails as it does on a Mac
// without access to Music. The Mac's own code then reads music from folders and iTunes
// library files instead.

public struct ITLibraryUnavailableError: Error, CustomStringConvertible {
    public var description: String { "There is no Music library on this system." }
}

public enum ITLibMediaItemMediaKind: Int, Sendable {
    case kindUnknown = 1, kindSong, kindMovie, kindPodcast, kindAudiobook, kindPDFBooklet, kindMusicVideo, kindTVShow
    case kindInteractiveBooklet, kindHomeVideo, kindRingtone, kindDigitalBooklet, kindiOSApplication, kindVoiceMemo, kindiTunesU
    case kindBook, kindPDFBook, kindAlertTone
}

public enum ITLibMediaItemLocationType: Int, Sendable {
    case unknown, file, url, remote
}

public enum ITLibPlaylistKind: Int, Sendable {
    case regular, smart, genius, folder, geniusMix
}

public enum ITLibDistinguishedPlaylistKind: Int, Sendable {
    case kindNone, kindMovies, kindTVShows, kindMusic, kindAudiobooks, kindBooks, kindRingtones, kindPodcasts
}

public final class ITLibArtist: NSObject, @unchecked Sendable {
    public let name: String? = nil
    public let sortName: String? = nil
    public let persistentID = NSNumber(value: 0)
}

public final class ITLibAlbum: NSObject, @unchecked Sendable {
    public let title: String? = nil
    public let sortTitle: String? = nil
    public let albumArtist: String? = nil
    public let isCompilation = false
    public let discNumber = 0
    public let discCount = 0
    public let trackCount = 0
    public let persistentID = NSNumber(value: 0)
}

public final class ITLibArtwork: NSObject, @unchecked Sendable {
    public let image: NSImage? = nil
    public let imageData: Data? = nil
}

public final class ITLibMediaItemVideoInfo: NSObject, @unchecked Sendable {
    public let series: String? = nil
    public let sortSeries: String? = nil
    public let season = 0
    public let episode: String? = nil
    public let episodeOrder = 0
}

public final class ITLibMediaItem: NSObject, @unchecked Sendable {
    public let persistentID = NSNumber(value: 0)
    public let title = ""
    public let sortTitle: String? = nil
    public let artist: ITLibArtist? = nil
    public let album = ITLibAlbum()
    public let composer = ""
    public let genre = ""
    public let comments: String? = nil
    public let kind: String? = nil
    public let mediaKind: ITLibMediaItemMediaKind = .kindUnknown
    public let location: URL? = nil
    public let locationType: ITLibMediaItemLocationType = .unknown
    public let totalTime = 0
    public let trackNumber = 0
    public let year = 0
    public let releaseDate: Date? = nil
    public let addedDate: Date? = nil
    public let lastPlayedDate: Date? = nil
    public let playCount = 0
    public let artwork: ITLibArtwork? = nil
    public let hasArtworkAvailable = false
    public let isDRMProtected = false
    public let isCloud = false
    public let isPurchased = false
    public let isUserDisabled = false
    public let isVideo = false
    public let videoInfo: ITLibMediaItemVideoInfo? = nil
}

public final class ITLibPlaylist: NSObject, @unchecked Sendable {
    public let name = ""
    public let persistentID = NSNumber(value: 0)
    public let parentID: NSNumber? = nil
    public let items: [ITLibMediaItem] = []
    public let kind: ITLibPlaylistKind = .regular
    public let distinguishedKind: ITLibDistinguishedPlaylistKind = .kindNone
    public let isVisible = true
    public let isMaster = false
    public let isPrimary = false
}

public final class ITLibrary: NSObject, @unchecked Sendable {
    public let allMediaItems: [ITLibMediaItem] = []
    public let allPlaylists: [ITLibPlaylist] = []
    public let musicFolderLocation: URL? = nil
    public let applicationVersion = ""
    public let apiMajorVersion = 1
    public let apiMinorVersion = 0

    public init(apiVersion _: String) throws {
        throw ITLibraryUnavailableError()
    }

    public static func library(withAPIVersion apiVersion: String) throws -> ITLibrary {
        try ITLibrary(apiVersion: apiVersion)
    }

    public func reloadData() -> Bool { false }
    public func unloadData() {}
}

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Talking to YouTube: lists, search, a video's details and comments, where its picture and sound
// come from, and captions. YouTube has no public way in for an app like this, so
// these are the requests its own apps make, and every answer is read expecting pieces of it to
// be missing or to have moved.

// MARK: - Reading answers

/// A piece of an answer: a dictionary, a list, text or a number. Looking into one never fails;
/// what isn't there comes back empty.
struct YouTubeJSON {
    let value: Any?

    init(_ value: Any?) {
        self.value = value is NSNull ? nil : value
    }

    subscript(key: String) -> YouTubeJSON {
        YouTubeJSON((value as? [String: Any])?[key])
    }

    subscript(index: Int) -> YouTubeJSON {
        guard let list = value as? [Any], list.indices.contains(index) else { return YouTubeJSON(nil) }
        return YouTubeJSON(list[index])
    }

    var exists: Bool { value != nil }
    var array: [YouTubeJSON] { (value as? [Any])?.map { YouTubeJSON($0) } ?? [] }
    var dictionary: [String: Any] { value as? [String: Any] ?? [:] }
    var string: String? { value as? String }
    var bool: Bool? { value as? Bool }

    var int: Int? {
        if let number = value as? NSNumber { return number.intValue }
        return (value as? String).flatMap { Int($0) }
    }

    var double: Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return (value as? String).flatMap { Double($0) }
    }

    /// Text, in whichever of its three shapes YouTube has written it.
    var text: String? {
        if let plain = self["simpleText"].string { return plain }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        if !runs.isEmpty { return runs.joined() }
        return self["content"].string ?? string
    }

    /// Every object held under `key`, anywhere inside, in the order lists give them. Objects
    /// under the keys in `skipping` aren't looked into.
    func all(_ keys: Set<String>, skipping: Set<String> = []) -> [(key: String, value: YouTubeJSON)] {
        var found: [(key: String, value: YouTubeJSON)] = []
        func walk(_ node: Any?) {
            if let list = node as? [Any] {
                for element in list { walk(element) }
            } else if let object = node as? [String: Any] {
                for (key, inner) in object {
                    if skipping.contains(key) { continue }
                    if keys.contains(key) {
                        found.append((key, YouTubeJSON(inner)))
                    } else {
                        walk(inner)
                    }
                }
            }
        }
        walk(value)
        return found
    }
}

// MARK: - What comes back

struct YouTubeVideo: Equatable, Codable, Sendable {
    var id: String
    var title: String
    var channel: String
    var channelID: String?
    /// As YouTube words them: "10:35", "37,398,126 views", "11 years ago".
    var durationText: String?
    var viewsText: String?
    var publishedText: String?
    var summary: String?
    var isLive = false

    /// A small picture for a list row, and the largest there is for the preview.
    var rowThumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
    var largeThumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hq720.jpg") }
    /// For a video with no large picture: its other large one, then the small one every video
    /// has. (Not "hqdefault": that one has black bands above and below the picture.)
    var fallbackThumbnailURLs: [URL] {
        ["maxresdefault", "mqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg") }
    }
}

struct YouTubePage: Sendable {
    var videos: [YouTubeVideo] = []
    var continuation: YouTubeContinuation?
}

/// Where the next page of a list comes from.
enum YouTubeContinuation: Equatable, Sendable {
    case search(String)
    case browse(String)
    case related(String)
    case playlist(String)
}

struct YouTubeVideoDetails: Sendable {
    var title: String?
    var viewsText: String?
    var dateText: String?
    var likesText: String?
    var channel: String?
    var channelID: String?
    var subscribersText: String?
    /// The round picture of who the video is from.
    var channelPictureURL: URL?
    var description: String?
    var related = YouTubePage()
    var commentsToken: String?
}

/// One of a channel's playlists.
struct YouTubePlaylist: Equatable, Sendable {
    var id: String
    var title: String
    /// What YouTube says with it: how many videos it holds.
    var notes: [String] = []
    var pictureURL: URL?
}

struct YouTubeComment: Equatable, Sendable {
    var id: String
    var author: String
    var text: String
    var publishedText: String
    var likesText: String
    var replyCountText: String
    var isPinned = false
    var isByCreator = false
    var isHearted = false
    var avatarURL: URL?
    /// Where its replies come from, if it has any.
    var repliesToken: String?
}

struct YouTubeCommentsPage: Sendable {
    var totalText: String?
    var comments: [YouTubeComment] = []
    var continuation: String?
}

struct YouTubeCaptionTrack: Equatable, Sendable {
    var name: String
    var languageCode: String
    var isAutoGenerated: Bool
    var baseURL: URL
}

struct YouTubeCaptionCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// What a video plays from.
struct YouTubePlayback: Sendable {
    var videoID: String
    var title: String
    var channel: String
    var durationSeconds: Double
    var isLive: Bool
    /// Every size of the picture in one playlist, with the sound beside it.
    var manifestURL: URL
    var captions: [YouTubeCaptionTrack]
    /// The whole description, as it was written.
    var description: String?
}

/// One size of a video's picture in its playlist, and the sound that goes with it.
struct YouTubeStreamVariant: Equatable, Sendable {
    var height: Int
    var framesPerSecond: Double
    var codec: String
    var bandwidth: Int
    var url: URL
    var audioURL: URL?
    var isHighDynamicRange: Bool
}

/// The lists the YouTube menu offers.
enum YouTubeList: Equatable, Sendable {
    case music
    case trailers
    case gaming
    case news
    case sports
    case live
    case channel(id: String, name: String)

    var title: String {
        switch self {
        case .music: "Music"
        case .trailers: "Trailers"
        case .gaming: "Gaming"
        case .news: "News"
        case .sports: "Sports"
        case .live: "Live"
        case let .channel(_, name): name
        }
    }
}

enum YouTubeError: LocalizedError {
    case unreachable
    case badResponse(Int)
    case unexpectedAnswer
    case notPlayable(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .unreachable: "Can't Reach YouTube"
        case let .badResponse(code): "YouTube Error (\(code))"
        case .unexpectedAnswer: "YouTube Gave an Answer First Row Can't Read"
        case let .notPlayable(reason): reason
        case .refused: "YouTube Isn't Playing Videos on This Network Right Now"
        }
    }
}

// MARK: - The client

actor YouTubeClient {
    static let shared = YouTubeClient()

    /// The apps First Row speaks as. YouTube answers each of its own apps differently: the
    /// web site's lists and comments are open to anyone, the headset app is given addresses a
    /// player can open as they are, and the television app is given a playlist as a plain list.
    private enum App {
        case web
        case headset
        case television
        case charts

        var name: String {
            switch self {
            case .web: "WEB"
            case .headset: "VISIONOS"
            case .television: "TVHTML5"
            case .charts: "WEB_MUSIC_ANALYTICS"
            }
        }

        var number: String {
            switch self {
            case .web: "1"
            case .headset: "101"
            case .television: "7"
            case .charts: "31"
            }
        }

        var version: String {
            switch self {
            case .web: "2.20261106.00.00"
            case .headset: "1.04"
            case .television: "7.20261102.18.00"
            case .charts: "2.0"
            }
        }

        var userAgent: String {
            switch self {
            case .web, .charts:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
            case .headset:
                "com.google.visionos.youtube/1.04(RealityDevice17,1; U; CPU visionOS 26_6_0 like Mac OS X; GB)"
            case .television:
                "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
            }
        }
    }

    private var visitor: String?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// The language lists and counts are worded in, and the country they're chosen for.
    private static var language: String {
        // The system's first language as "en" or "en-GB". Anything else it may say ("C",
        // "en_001", "en_US.UTF-8") is put into that shape or passed over: YouTube refuses a
        // request whose language it doesn't know.
        let tag = (Locale.preferredLanguages.first ?? "").split(whereSeparator: { ".@".contains($0) }).first.map(String.init) ?? ""
        let parts = tag.split(whereSeparator: { "-_".contains($0) }).map(String.init)
        guard let language = parts.first?.lowercased(), (2 ... 3).contains(language.count), language.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "en-US" }
        if let region = parts.dropFirst().last, region.count == 2, region.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return language + "-" + region.uppercased()
        }
        return language
    }

    private static var country: String {
        let code = Locale.current.regionCode ?? ""
        return code.count == 2 ? code.uppercased() : "US"
    }

    // MARK: Requests

    private func context(for app: App, language: String? = nil) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": app.name,
            "clientVersion": app.version,
            "hl": language ?? Self.language,
            "gl": Self.country,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        switch app {
        case .web:
            client["platform"] = "DESKTOP"
            client["originalUrl"] = "https://www.youtube.com"
        case .headset:
            client["clientScreen"] = "WATCH"
            client["platform"] = "MOBILE"
            client["deviceMake"] = "Apple"
            client["deviceModel"] = "RealityDevice17,1"
            client["osName"] = "visionOS"
            client["osVersion"] = "26.6.0.23O770"
        case .television, .charts:
            break
        }
        if let visitor, app != .charts { client["visitorData"] = visitor }
        return [
            "client": client,
            "request": ["internalExperimentFlags": [Any](), "useSsl": true],
            "user": ["lockedSafetyMode": false],
        ]
    }

    /// Sends one request and reads the answer, trying once more if the network let it down.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0 ..< 2 {
            do {
                let (data, response) = try await Self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw YouTubeError.unreachable }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as YouTubeError {
                throw error
            } catch {
                if attempt == 1 { throw YouTubeError.unreachable }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw YouTubeError.unreachable
    }

    private func call(
        _ endpoint: String,
        as app: App,
        _ fields: [String: Any],
        language: String? = nil,
    ) async throws -> YouTubeJSON {
        let host = app == .charts ? "charts.youtube.com" : "www.youtube.com"
        guard let url = URL(string: "https://\(host)/youtubei/v1/\(endpoint)?prettyPrint=false\(app == .charts ? "&alt=json" : "")") else {
            throw YouTubeError.unexpectedAnswer
        }
        var body = fields
        body["context"] = context(for: app, language: language)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(app.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(app.number, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(app.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitor, app != .charts { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        switch app {
        case .web:
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
            request.setValue("SOCS=CAE=", forHTTPHeaderField: "Cookie")
        case .charts:
            request.setValue("https://charts.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://charts.youtube.com", forHTTPHeaderField: "Referer")
        case .headset:
            request.setValue("2", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        case .television:
            break
        }
        let (data, response) = try await send(request)
        guard (200 ..< 300).contains(response.statusCode) else { throw YouTubeError.badResponse(response.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw YouTubeError.unexpectedAnswer }
        return YouTubeJSON(object)
    }

    /// YouTube's name for this visitor, which it wants with every request for something to
    /// play (without one it asks for a sign-in "to confirm you're not a bot").
    private func ensureVisitor(fresh: Bool = false) async throws {
        if visitor != nil, !fresh { return }
        visitor = nil
        let answer = try await call("visitor_id", as: .web, [:])
        guard let value = answer["responseContext"]["visitorData"].string, !value.isEmpty else { throw YouTubeError.unexpectedAnswer }
        visitor = value
    }

    // MARK: Lists

    private static let videoKeys: Set<String> = ["videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "lockupViewModel", "tileRenderer"]
    /// Rows of Shorts, adverts and the like, which hold things that look like videos.
    private static let skippedKeys: Set<String> = [
        "reelShelfRenderer", "gridShelfViewModel", "shortsLockupViewModel", "adSlotRenderer", "promotedSparklesWebRenderer",
        "searchPyvRenderer", "playlistRenderer", "channelRenderer", "showRenderer", "postRenderer", "horizontalCardListRenderer",
    ]

    /// The videos anywhere inside a piece of an answer, in order, each once; and where more come from.
    private func page(in node: YouTubeJSON, more: (String) -> YouTubeContinuation, channel: String? = nil) -> YouTubePage {
        var page = YouTubePage()
        var seen = Set<String>()
        for (key, value) in node.all(Self.videoKeys.union(["continuationItemRenderer", "nextContinuationData"]), skipping: Self.skippedKeys) {
            switch key {
            case "continuationItemRenderer":
                if let token = value["continuationEndpoint"]["continuationCommand"]["token"].string { page.continuation = more(token) }
            case "nextContinuationData":
                if let token = value["continuation"].string { page.continuation = more(token) }
            default:
                guard var video = Self.video(from: value, shape: key), seen.insert(video.id).inserted else { continue }
                if video.channel.isEmpty, let channel { video.channel = channel }
                page.videos.append(video)
            }
        }
        return page
    }

    private static func video(from item: YouTubeJSON, shape: String) -> YouTubeVideo? {
        switch shape {
        case "lockupViewModel":
            guard item["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO", let id = item["contentId"].string, !id.isEmpty else { return nil }
            let metadata = item["metadata"]["lockupMetadataViewModel"]
            let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].array.map { row in
                row["metadataParts"].array.compactMap { $0["text"]["content"].string }
            }.filter { !$0.isEmpty }
            var video = YouTubeVideo(id: id, title: metadata["title"]["content"].string ?? "", channel: "")
            if rows.count > 1 { video.channel = rows[0].first ?? "" }
            if let last = rows.last {
                video.viewsText = rows.count > 1 || last.count > 1 ? last.first : nil
                if last.count > 1 { video.publishedText = last.last }
            }
            let badges = item["contentImage"]["thumbnailViewModel"].all(["thumbnailBadgeViewModel"]).map(\.value)
            video.isLive = badges.contains { $0["badgeStyle"].string == "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE" }
            video.durationText = badges.compactMap { $0["text"].string }.first { $0.contains(":") }
            video.channelID = metadata["image"]["decoratedAvatarViewModel"]["rendererContext"]["commandContext"]["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].string
            return video.title.isEmpty ? nil : video
        case "tileRenderer":
            guard item["contentType"].string == "TILE_CONTENT_TYPE_VIDEO",
                  let id = item["contentId"].string ?? item["onSelectCommand"]["watchEndpoint"]["videoId"].string, !id.isEmpty
            else { return nil }
            let metadata = item["metadata"]["tileMetadataRenderer"]
            let lines = metadata["lines"].array.map { line in
                line["lineRenderer"]["items"].array.compactMap { $0["lineItemRenderer"]["text"].text }.filter { $0 != "•" && !$0.isEmpty }
            }
            var video = YouTubeVideo(id: id, title: metadata["title"].text ?? "", channel: lines.first?.first ?? "")
            if lines.count > 1 {
                video.viewsText = lines[1].first
                if lines[1].count > 1 { video.publishedText = lines[1].last }
            }
            let overlays = item["header"]["tileHeaderRenderer"]["thumbnailOverlays"].array
            video.durationText = overlays.compactMap { $0["thumbnailOverlayTimeStatusRenderer"]["text"].text }.first { $0.contains(":") }
            video.isLive = overlays.contains { $0["thumbnailOverlayTimeStatusRenderer"]["style"].string == "LIVE" }
            return video.title.isEmpty ? nil : video
        default:
            guard let id = item["videoId"].string, !id.isEmpty, let title = item["title"].text, !title.isEmpty else { return nil }
            if title == "[Private video]" || title == "[Deleted video]" { return nil }
            let byline = item["longBylineText"].exists ? item["longBylineText"] : (item["ownerText"].exists ? item["ownerText"] : item["shortBylineText"])
            var video = YouTubeVideo(id: id, title: title, channel: byline.text ?? "")
            video.channelID = byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
            let overlays = item["thumbnailOverlays"].array.map { $0["thumbnailOverlayTimeStatusRenderer"] }
            video.durationText = item["lengthText"].text ?? overlays.compactMap { $0["text"].text }.first { $0.contains(":") }
            video.viewsText = item["viewCountText"].text ?? item["shortViewCountText"].text
            video.publishedText = item["publishedTimeText"].text
            video.isLive = item["badges"].array.contains { $0["metadataBadgeRenderer"]["style"].string == "BADGE_STYLE_TYPE_LIVE_NOW" }
                || overlays.contains { $0["style"].string == "LIVE" }
            let snippet = item["detailedMetadataSnippets"][0]["snippetText"].text ?? item["descriptionSnippet"].text
            video.summary = snippet.flatMap { $0.isEmpty ? nil : $0 }
            return video
        }
    }

    func search(_ query: String) async throws -> YouTubePage {
        // (Videos only: no channels, playlists or rows of Shorts to pick through.)
        let answer = try await call("search", as: .web, ["query": query, "params": "EgIQAQ%3D%3D"])
        return page(in: answer["contents"], more: { .search($0) })
    }

    func videos(in list: YouTubeList) async throws -> YouTubePage {
        switch list {
        case .music:
            return try await chart("TRENDING_VIDEOS")
        case .trailers:
            return try await chart("TRENDING_MOVIES")
        case .gaming:
            return try await browse(["browseId": "UCOpNcN46UbXVtpKMrmU4Abg", "params": "Egh0cmVuZGluZw%3D%3D"])
        case .news:
            return try await browse(["browseId": "UCYfdidRxbB8Qhf0Nx7ioOYw"])
        case .sports:
            return try await browse(["browseId": "UCEgdi0XIXXZ-qJOFPf4JSKw"])
        case .live:
            return try await browse(["browseId": "UC4R8DWoMoI7CAwX8_LjQHig", "params": "EgdsaXZldGFikgEDCKEK"])
        case let .channel(id, name):
            let answer = try await call("browse", as: .web, ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
            let title = answer["metadata"]["channelMetadataRenderer"]["title"].string ?? name
            return page(in: answer["contents"], more: { .browse($0) }, channel: title)
        }
    }

    private func browse(_ fields: [String: Any]) async throws -> YouTubePage {
        // (The pages after the first only come to a visitor YouTube has a name for.)
        try? await ensureVisitor()
        let answer = try await call("browse", as: .web, fields)
        return page(in: answer["contents"], more: { .browse($0) })
    }

    /// One of YouTube's charts: the music videos or the film trailers most watched this week.
    private func chart(_ kind: String) async throws -> YouTubePage {
        func fetch(country: String) async throws -> YouTubePage {
            let answer = try await call("browse", as: .charts, [
                "browseId": "FEmusic_analytics_charts_home",
                "query": "perspective=CHART_DETAILS&chart_params_country_code=\(country)&chart_params_chart_type=\(kind)",
            ])
            let entries = answer["contents"]["sectionListRenderer"]["contents"][0]["musicAnalyticsSectionRenderer"]["content"]["videos"][0]["videoViews"].array
            var page = YouTubePage()
            for entry in entries {
                guard let id = entry["id"].string, let title = entry["title"].string else { continue }
                var video = YouTubeVideo(id: id, title: title, channel: entry["channelName"].string ?? entry["artists"][0]["name"].string ?? "")
                video.channelID = entry["externalChannelId"].string
                if let seconds = entry["videoDuration"].double, seconds > 0 { video.durationText = Self.durationText(seconds) }
                page.videos.append(video)
            }
            return page
        }
        // (The charts are made for some countries only.)
        if let page = try? await fetch(country: Self.country), !page.videos.isEmpty { return page }
        return try await fetch(country: "US")
    }

    func more(_ continuation: YouTubeContinuation) async throws -> YouTubePage {
        switch continuation {
        case let .search(value):
            let answer = try await call("search", as: .web, ["continuation": value])
            return page(in: answer["onResponseReceivedCommands"], more: { .search($0) })
        case let .browse(value):
            try? await ensureVisitor()
            let answer = try await call("browse", as: .web, ["continuation": value])
            return page(in: answer["onResponseReceivedActions"], more: { .browse($0) })
        case let .related(value):
            let answer = try await call("next", as: .web, ["continuation": value])
            return page(in: answer["onResponseReceivedEndpoints"], more: { .related($0) })
        case let .playlist(value):
            let answer = try await call("browse", as: .television, ["continuation": value])
            return page(in: answer["continuationContents"], more: { .playlist($0) })
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    // MARK: A video's details and comments

    func details(of videoID: String) async throws -> YouTubeVideoDetails {
        let answer = try await call("next", as: .web, ["videoId": videoID, "contentCheckOk": true, "racyCheckOk": true])
        let columns = answer["contents"]["twoColumnWatchNextResults"]
        var details = YouTubeVideoDetails()
        for item in columns["results"]["results"]["contents"].array {
            let primary = item["videoPrimaryInfoRenderer"]
            if primary.exists {
                details.title = primary["title"].text
                details.viewsText = primary["viewCount"]["videoViewCountRenderer"]["viewCount"].text
                details.dateText = primary["dateText"].text
                details.likesText = primary.all(["likeButtonViewModel"]).first?.value
                    .all(["defaultButtonViewModel"]).first?.value["buttonViewModel"]["title"].string
            }
            let secondary = item["videoSecondaryInfoRenderer"]
            if secondary.exists {
                let owner = secondary["owner"]["videoOwnerRenderer"]
                details.channel = owner["title"].text
                details.channelID = owner["title"]["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
                details.subscribersText = owner["subscriberCountText"].text
                details.channelPictureURL = owner["thumbnail"]["thumbnails"].array.last?["url"].string.flatMap(Self.pictureURL)
                details.description = secondary["attributedDescription"]["content"].string ?? secondary["description"].text
            }
            let section = item["itemSectionRenderer"]
            if section["targetId"].string == "comments-section" {
                details.commentsToken = section["contents"][0]["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string
            }
        }
        details.related = page(in: columns["secondaryResults"], more: { .related($0) })
        return details
    }

    /// A page of comments: the first from a video's details, the rest from the page before.
    func comments(_ token: String) async throws -> YouTubeCommentsPage {
        let answer = try await call("next", as: .web, ["continuation": token])
        var page = YouTubeCommentsPage()
        // What a comment says is kept apart from where it stands in the list, under a key.
        var entities: [String: YouTubeJSON] = [:]
        for mutation in answer["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array {
            if let key = mutation["entityKey"].string { entities[key] = mutation["payload"] }
        }
        for endpoint in answer["onResponseReceivedEndpoints"].array {
            let command = endpoint["reloadContinuationItemsCommand"].exists ? endpoint["reloadContinuationItemsCommand"] : endpoint["appendContinuationItemsAction"]
            for item in command["continuationItems"].array {
                if let total = item["commentsHeaderRenderer"]["countText"].text { page.totalText = total }
                let thread = item["commentThreadRenderer"]
                let model = thread.exists ? thread["commentViewModel"]["commentViewModel"] : item["commentViewModel"]
                if model.exists, let key = model["commentKey"].string, let payload = entities[key]?["commentEntityPayload"] {
                    let properties = payload["properties"]
                    var comment = YouTubeComment(
                        id: properties["commentId"].string ?? key,
                        author: payload["author"]["displayName"].string ?? "",
                        text: properties["content"]["content"].string ?? "",
                        publishedText: properties["publishedTime"].string ?? "",
                        likesText: payload["toolbar"]["likeCountNotliked"].string ?? "",
                        replyCountText: payload["toolbar"]["replyCount"].string ?? "",
                    )
                    comment.isPinned = model["pinnedText"].exists
                    comment.isByCreator = payload["author"]["isCreator"].bool ?? false
                    comment.avatarURL = payload["author"]["avatarThumbnailUrl"].string.flatMap { URL(string: $0) }
                    if let toolbar = model["toolbarStateKey"].string {
                        comment.isHearted = entities[toolbar]?["engagementToolbarStateEntityPayload"]["heartState"].string == "TOOLBAR_HEART_STATE_HEARTED"
                    }
                    let replies = thread["replies"]["commentRepliesRenderer"]
                    comment.repliesToken = replies["contents"][0]["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].string
                        ?? replies.all(["continuationCommand"]).first?.value["token"].string
                    if !comment.text.isEmpty { page.comments.append(comment) }
                }
                let next = item["continuationItemRenderer"]
                if next.exists {
                    page.continuation = next["continuationEndpoint"]["continuationCommand"]["token"].string
                        ?? next["button"]["buttonRenderer"]["command"]["continuationCommand"]["token"].string
                }
            }
        }
        return page
    }

    // MARK: Playing

    /// Where a video plays from. YouTube is asked once for each play: what it hands out is
    /// tied to this network address and good for six hours.
    func playback(of videoID: String) async throws -> YouTubePlayback {
        try await ensureVisitor()
        for attempt in 0 ..< 2 {
            // (In English, to tell its reasons for refusing apart.)
            let answer = try await call("player", as: .headset, [
                "videoId": videoID,
                "contentCheckOk": true,
                "racyCheckOk": true,
            ], language: "en")
            let status = answer["playabilityStatus"]
            let details = answer["videoDetails"]
            let isRightVideo = details["videoId"].string == videoID
            if status["status"].string == "OK", isRightVideo {
                guard let manifest = answer["streamingData"]["hlsManifestUrl"].string.flatMap({ URL(string: $0) }) else {
                    throw YouTubeError.notPlayable("This video can't be played in First Row.")
                }
                let tracks = answer["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array.compactMap { track -> YouTubeCaptionTrack? in
                    guard let url = track["baseUrl"].string.flatMap({ URL(string: $0) }) else { return nil }
                    return YouTubeCaptionTrack(
                        name: track["name"].text ?? track["languageCode"].string ?? "Captions",
                        languageCode: track["languageCode"].string ?? "",
                        isAutoGenerated: track["kind"].string == "asr",
                        baseURL: url,
                    )
                }
                return YouTubePlayback(
                    videoID: videoID,
                    title: details["title"].string ?? "",
                    channel: details["author"].string ?? "",
                    durationSeconds: details["lengthSeconds"].double ?? 0,
                    isLive: details["isLive"].bool ?? false,
                    manifestURL: manifest,
                    captions: tracks,
                    description: details["shortDescription"].string,
                )
            }
            let reason = status["reason"].string ?? status["messages"][0].string ?? ""
            // YouTube doubting the visitor (or answering about another video) is put right,
            // when it can be, by asking as a new one.
            let doubtsVisitor = reason.contains("not a bot") || reason.contains("needs to be reloaded") || (status["status"].string == "OK" && !isRightVideo)
            if doubtsVisitor, attempt == 0 {
                try await ensureVisitor(fresh: true)
                continue
            }
            if doubtsVisitor { throw YouTubeError.refused }
            throw YouTubeError.notPlayable(reason.isEmpty ? "This video can't be played in First Row." : reason)
        }
        throw YouTubeError.refused
    }

    /// The sizes a video's picture comes in, largest first, read from its playlist.
    func variants(of manifest: URL) async throws -> [YouTubeStreamVariant] {
        try await self.manifest(of: manifest).variants
    }

    /// A video's playlist as it is sent (it names a playlist for each size of the picture),
    /// and those sizes.
    func manifest(of manifest: URL) async throws -> (text: String, variants: [YouTubeStreamVariant]) {
        var request = URLRequest(url: manifest)
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        guard (200 ..< 300).contains(response.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw YouTubeError.badResponse(response.statusCode)
        }
        return (text, Self.variants(inPlaylist: text))
    }

    /// The fields of a playlist's line: `#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="a,b"`.
    private static func playlistFields(_ line: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = line.drop { $0 != ":" }.dropFirst()
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { break }
            let key = String(rest[..<equals])
            rest = rest[rest.index(after: equals)...]
            var value: Substring
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let end = rest.firstIndex(of: "\"") ?? rest.endIndex
                value = rest[..<end]
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end]
                rest = rest[end...]
            }
            result[key] = String(value)
            if rest.first == "," { rest = rest.dropFirst() }
        }
        return result
    }

    /// The height a stream's line gives its picture. (An upright video's size is its shorter
    /// side, as "1080p" is for a wide one.)
    private static func pictureHeight(_ fields: [String: String]) -> Int? {
        let size = (fields["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
        return size.count == 2 ? min(size[0], size[1]) : nil
    }

    /// A video's playlist with only the streams of one size of picture left in, so that a
    /// player given it plays that size and no other (given the whole playlist it picks for
    /// itself as it goes). Nil if the video has no stream of that size.
    static func playlist(_ text: String, keepingHeight height: Int) -> String? {
        var kept: [Substring] = []
        var streams = 0
        var dropsAddress = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                dropsAddress = pictureHeight(playlistFields(line)) != height
                if !dropsAddress {
                    kept.append(line)
                    streams += 1
                }
            } else if dropsAddress, !line.isEmpty, !line.hasPrefix("#") {
                // (The address of a stream that was left out.)
                dropsAddress = false
            } else {
                kept.append(line)
            }
        }
        return streams > 0 ? kept.joined(separator: "\n") : nil
    }

    static func variants(inPlaylist text: String) -> [YouTubeStreamVariant] {
        let attributes = playlistFields
        let lines = text.split(whereSeparator: \.isNewline)
        var audio: [String: URL] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let fields = attributes(line)
            if fields["TYPE"] == "AUDIO", let group = fields["GROUP-ID"], let url = fields["URI"].flatMap({ URL(string: $0) }) { audio[group] = url }
        }
        var variants: [YouTubeStreamVariant] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard lines.indices.contains(index + 1), let url = URL(string: String(lines[index + 1])) else { continue }
            let fields = attributes(line)
            guard let height = pictureHeight(fields) else { continue }
            variants.append(YouTubeStreamVariant(
                height: height,
                framesPerSecond: Double(fields["FRAME-RATE"] ?? "") ?? 30,
                codec: String((fields["CODECS"] ?? "").split(separator: ",").first ?? ""),
                bandwidth: Int(fields["BANDWIDTH"] ?? "") ?? 0,
                url: url,
                audioURL: fields["AUDIO"].flatMap { audio[$0] },
                isHighDynamicRange: (fields["VIDEO-RANGE"] ?? "SDR") != "SDR",
            ))
        }
        return variants.sorted { ($0.height, $0.bandwidth) > ($1.height, $1.bandwidth) }
    }

    /// A caption track's lines and when each shows.
    func cues(of track: YouTubeCaptionTrack) async throws -> [YouTubeCaptionCue] {
        guard var parts = URLComponents(url: track.baseURL, resolvingAgainstBaseURL: false) else { throw YouTubeError.unexpectedAnswer }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "fmt" && $0.name != "tlang" } + [URLQueryItem(name: "fmt", value: "json3")]
        guard let url = parts.url else { throw YouTubeError.unexpectedAnswer }
        let (data, response) = try await send(URLRequest(url: url))
        guard (200 ..< 300).contains(response.statusCode), let object = try? JSONSerialization.jsonObject(with: data) else {
            throw YouTubeError.badResponse(response.statusCode)
        }
        var cues: [YouTubeCaptionCue] = []
        for event in YouTubeJSON(object)["events"].array {
            // (Events with no words set a window up; "append" events are the line breaks of
            // captions that roll.)
            guard event["segs"].exists, event["aAppend"].int != 1, let start = event["tStartMs"].double else { continue }
            let text = event["segs"].array.compactMap { $0["utf8"].string }.joined()
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            let length = event["dDurationMs"].double ?? 3000
            cues.append(YouTubeCaptionCue(start: start / 1000, end: (start + length) / 1000, text: text))
        }
        cues.sort { $0.start < $1.start }
        // Captions made by machine come a few words at a time, each event overlapping the
        // next: each is shown until the next begins.
        if track.isAutoGenerated {
            for index in cues.indices.dropLast() where cues[index].end > cues[index + 1].start {
                cues[index].end = cues[index + 1].start
            }
        }
        return cues
    }

    // MARK: Playlists

    /// A channel's playlists.
    func channelPlaylists(_ channelID: String) async throws -> [YouTubePlaylist] {
        try? await ensureVisitor()
        let answer = try await call("browse", as: .web, ["browseId": channelID, "params": "EglwbGF5bGlzdHPyBgQKAkIA"])
        var playlists: [YouTubePlaylist] = []
        for (_, item) in answer["contents"].all(["lockupViewModel"]) {
            guard let kind = item["contentType"].string, kind == "LOCKUP_CONTENT_TYPE_PLAYLIST" || kind == "LOCKUP_CONTENT_TYPE_PODCAST",
                  let id = item["contentId"].string, !id.isEmpty,
                  let title = item["metadata"]["lockupMetadataViewModel"]["title"]["content"].string, !title.isEmpty,
                  !playlists.contains(where: { $0.id == id })
            else { continue }
            var playlist = YouTubePlaylist(id: id, title: title)
            let picture = item["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]
            playlist.notes = Array(picture.all(["thumbnailBadgeViewModel"]).compactMap { $0.value["text"].string }.prefix(1))
            playlist.pictureURL = picture["image"]["sources"].array.last?["url"].string.flatMap(Self.pictureURL)
            playlists.append(playlist)
        }
        return playlists
    }

    /// A playlist's videos, read as the television app reads them: a plain list.
    func playlistVideos(_ id: String) async throws -> YouTubePage {
        let answer = try await call("browse", as: .television, ["browseId": "VL" + id])
        let list = answer["contents"].all(["playlistVideoListRenderer"]).first?.value
        return page(in: list ?? answer["contents"], more: { .playlist($0) })
    }

    /// A picture's address as YouTube writes them (some without the "https:").
    private static func pictureURL(_ text: String) -> URL? {
        URL(string: text.hasPrefix("//") ? "https:" + text : text)
    }
}

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(FoundationXML)
    import FoundationXML
#endif

/// A UPnP media server (DLNA): Windows Media Center and Windows Media Player's sharing, most
/// network drives, Kodi's and Plex's own UPnP sides, MiniDLNA and the like. It is asked for
/// what a folder of its holds, and says where each movie and song is.
struct UPnPClient: MediaServerClient {
    let controlURL: URL

    init?(record: MediaServerRecord) {
        guard let control = record.details?["control"], let url = URL(string: control) else { return nil }
        controlURL = url
    }

    // MARK: Finding servers

    private static let searchQuestion = [
        "M-SEARCH * HTTP/1.1",
        "HOST: 239.255.255.250:1900",
        "MAN: \"ssdp:discover\"",
        "MX: 2",
        "ST: urn:schemas-upnp-org:device:MediaServer:1",
        "", "",
    ].joined(separator: "\r\n")

    /// The media servers on the local network.
    static func discover(timeout: TimeInterval = 3) async -> [FoundMediaServer] {
        let replies = await LocalNetwork.ask(searchQuestion, port: 1900, group: "239.255.255.250", timeout: timeout, testTarget: "FIRSTROW_UPNP_DISCOVERY_EXTRA")
        return await servers(inReplies: replies)
    }

    /// The server at an address someone typed: a device's address, or the address of its
    /// description.
    static func find(at typed: String) async throws -> FoundMediaServer {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MediaServerError.notAServer(.upnp) }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://"), let url = URL(string: text), url.path.count > 1 {
            if let found = await describe(url) { return found }
            throw MediaServerError.notAServer(.upnp)
        }
        var host = text
        if let url = URL(string: text), let named = url.host { host = named }
        if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 { host = String(host[..<colon]) }
        // Asked by itself, as it would be with everyone else.
        let replies = await LocalNetwork.ask(searchQuestion, port: 1900, host: host, timeout: 2.5, testTarget: "FIRSTROW_UPNP_DISCOVERY_EXTRA")
        if let found = await servers(inReplies: replies).first { return found }
        // Where the usual servers keep their descriptions.
        let usual = [
            "8200/rootDesc.xml", "32469/DeviceDescription.xml", "50001/desc/device.xml", "49152/description.xml", "9000/dev0/desc.xml",
            "8895/deviceDescription/MediaServer", "1900/description.xml", "5001/desc/device.xml",
        ]
        for place in usual {
            guard let url = URL(string: "http://\(host):\(place)") else { continue }
            if let found = await describe(url, timeout: 2) { return found }
        }
        throw MediaServerError.notAServer(.upnp)
    }

    private static func servers(inReplies replies: [String]) async -> [FoundMediaServer] {
        var locations: [URL] = []
        for reply in replies {
            // (One reply's lines may have been run together.)
            guard let range = reply.range(of: "location:", options: .caseInsensitive) else { continue }
            let rest = reply[range.upperBound...].drop { $0 == " " || $0 == "\t" }
            let address = String(rest.prefix { !$0.isWhitespace })
            if let url = URL(string: address), !locations.contains(url) { locations.append(url) }
        }
        var found: [FoundMediaServer] = []
        for location in locations {
            guard let server = await describe(location), !found.contains(where: { $0.address == server.address }) else { continue }
            found.append(server)
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads a device's description: its name, and where its list of contents is asked for.
    private static func describe(_ location: URL, timeout: TimeInterval = 5) async -> FoundMediaServer? {
        var request = URLRequest(url: location)
        request.timeoutInterval = timeout
        guard let (data, _) = try? await ServerHTTP.data(request) else { return nil }
        let reader = DescriptionReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let control = reader.control else { return nil }
        let base = reader.base.flatMap { URL(string: $0) } ?? location
        guard let controlURL = URL(string: control, relativeTo: base)?.absoluteURL else { return nil }
        let name = reader.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FoundMediaServer(
            kind: .upnp,
            name: name.isEmpty ? (location.host ?? "Media Server") : name,
            address: controlURL.absoluteString,
            details: ["control": controlURL.absoluteString],
        )
    }

    private final class DescriptionReader: NSObject, XMLParserDelegate {
        var name = ""
        var base: String?
        var control: String?
        private var text = ""
        private var service: (type: String, control: String) = ("", "")
        private var depth = 0
        private var deviceDepth = 0

        func parser(_: XMLParser, didStartElement element: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
            text = ""
            depth += 1
            if element == "device" { deviceDepth += 1 }
            if element == "service" { service = ("", "") }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "friendlyName" where deviceDepth == 1 && name.isEmpty: name = value
            case "URLBase": base = value
            case "serviceType": service.type = value
            case "controlURL": service.control = value
            case "service":
                if control == nil, service.type.contains("ContentDirectory"), !service.control.isEmpty { control = service.control }
            case "device": deviceDepth -= 1
            default: break
            }
            depth -= 1
            text = ""
        }
    }

    // MARK: Looking in the server

    func top() async throws -> [ServerItem] {
        try await browse("0")
    }

    func children(of item: ServerItem) async throws -> [ServerItem] {
        try await browse(item.id)
    }

    func video(for item: ServerItem) async throws -> ServerVideo {
        guard let address = item.details["url"], let url = URL(string: address) else { throw MediaServerError.nothingPlayable }
        var video = ServerVideo(url: url)
        if let subtitles = item.details["subtitles"], let file = URL(string: subtitles) {
            video.subtitleFiles = [MovieSubtitleFile(url: file, language: nil, name: nil)]
        }
        return video
    }

    /// What a folder of the server's holds, asked for a few hundred at a time.
    private func browse(_ id: String) async throws -> [ServerItem] {
        var items: [ServerItem] = []
        var start = 0
        while start < 5000 {
            let page = try await browse(id, from: start, count: 400)
            items += page.items
            start += page.returned
            if page.returned == 0 || start >= page.total { break }
        }
        return items
    }

    private func browse(_ id: String, from start: Int, count: Int) async throws -> (items: [ServerItem], returned: Int, total: Int) {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
        <ObjectID>\(Self.escaped(id))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>
        <StartingIndex>\(start)</StartingIndex><RequestedCount>\(count)</RequestedCount><SortCriteria></SortCriteria>
        </u:Browse></s:Body></s:Envelope>
        """
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await ServerHTTP.data(request)
        let answer = AnswerReader()
        let outer = XMLParser(data: data)
        outer.delegate = answer
        guard outer.parse() else { throw MediaServerError.notAServer(.upnp) }
        let list = ListReader(base: controlURL)
        let inner = XMLParser(data: Data(answer.result.utf8))
        inner.delegate = list
        _ = inner.parse()
        return (list.items, answer.returned ?? list.count, answer.total ?? list.count)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The answer to a request for a folder's contents: the list, as text, and how many.
    private final class AnswerReader: NSObject, XMLParserDelegate {
        var result = ""
        var returned: Int?
        var total: Int?
        private var text = ""

        func parser(_: XMLParser, didStartElement _: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
            text = ""
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            switch element {
            case "Result": result = text
            case "NumberReturned": returned = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "TotalMatches": total = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            default: break
            }
            text = ""
        }
    }

    /// The list itself: folders, and movies, songs and pictures with where each is.
    private final class ListReader: NSObject, XMLParserDelegate {
        let base: URL
        var items: [ServerItem] = []
        /// Everything listed, shown or not, so paging through a folder keeps count.
        var count = 0
        private var text = ""
        private var current: ServerItem?
        private var isFolder = false
        private var kindOfThing = ""
        private var places: [(protocolInfo: String, duration: String, address: String)] = []
        private var placeAttributes: [String: String] = [:]
        private var captions: String?

        init(base: URL) {
            self.base = base
        }

        func parser(_: XMLParser, didStartElement element: String, namespaceURI _: String?, qualifiedName _: String?, attributes: [String: String] = [:]) {
            text = ""
            switch element {
            case "container", "item":
                current = ServerItem(id: attributes["id"] ?? "", kind: .folder, title: "")
                isFolder = element == "container"
                kindOfThing = ""
                places = []
                captions = nil
            case "res":
                placeAttributes = attributes
            default:
                break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard var item = current else { return }
            defer { if current != nil { current = item } }
            switch element {
            case "dc:title": item.title = value
            case "upnp:class": kindOfThing = value
            case "upnp:albumArtURI", "upnp:icon":
                if item.imageURL == nil, let url = URL(string: value, relativeTo: base)?.absoluteURL { item.imageURL = url }
            case "upnp:artist", "dc:creator":
                if item.artist == nil, !value.isEmpty { item.artist = value }
            case "upnp:album": item.album = value
            case "upnp:originalTrackNumber": item.trackNumber = Int(value) ?? 0
            case "dc:date": item.year = Int(value.prefix(4))
            case "dc:description", "upnp:longDescription":
                if !value.isEmpty, (item.overview ?? "").count < value.count { item.overview = value }
            case "res":
                places.append((placeAttributes["protocolInfo"] ?? "", placeAttributes["duration"] ?? "", value))
            case "sec:CaptionInfoEx", "sec:CaptionInfo":
                if captions == nil, !value.isEmpty { captions = value }
            case "container", "item":
                count += 1
                current = nil
                finish(&item)
            default:
                break
            }
        }

        private func finish(_ item: inout ServerItem) {
            if item.title.isEmpty { item.title = "Untitled" }
            if isFolder {
                if kindOfThing.contains("musicAlbum") {
                    item.kind = .album
                } else if kindOfThing.contains("musicArtist") {
                    item.kind = .artist
                } else if kindOfThing.contains("playlist") {
                    item.kind = .playlist
                }
                items.append(item)
                return
            }
            func place(_ kind: String) -> (protocolInfo: String, duration: String, address: String)? {
                // (The file as it is, ahead of a copy the server would make of it.)
                places.first { $0.protocolInfo.contains(":\(kind)/") && !$0.protocolInfo.contains("DLNA.ORG_CI=1") } ?? places.first { $0.protocolInfo.contains(":\(kind)/") }
            }
            let isVideo = kindOfThing.contains("videoItem") || (kindOfThing.isEmpty && place("video") != nil)
            let isSong = kindOfThing.contains("audioItem") || (kindOfThing.isEmpty && place("audio") != nil)
            if isVideo, let found = place("video") ?? places.first, let url = URL(string: found.address, relativeTo: base)?.absoluteURL {
                item.kind = .video
                item.durationSeconds = Self.seconds(found.duration)
                item.details["url"] = url.absoluteString
                let words = captions ?? places.first { $0.protocolInfo.contains(":text/") }?.address
                if let words, let file = URL(string: words, relativeTo: base)?.absoluteURL { item.details["subtitles"] = file.absoluteString }
                items.append(item)
            } else if isSong, let found = place("audio") ?? places.first, let url = URL(string: found.address, relativeTo: base)?.absoluteURL {
                item.kind = .song
                item.durationSeconds = Self.seconds(found.duration)
                item.mediaURL = url
                items.append(item)
            }
            // (Pictures and anything else are left out.)
        }

        /// "1:02:03.500" as seconds.
        private static func seconds(_ text: String) -> Double {
            let parts = text.split(separator: ":").map { Double($0) ?? 0 }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
    }
}

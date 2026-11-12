import Foundation

/// Finds Jellyfin and Emby servers on the local network: they answer a question sent to
/// everyone on port 7359 with their name, id and address.
enum JellyfinDiscovery {
    static func discover(timeout: TimeInterval = 2.5) async -> [JellyfinServerInfo] {
        async let jellyfin = LocalNetwork.ask("who is JellyfinServer?", port: 7359, timeout: timeout, testTarget: "FIRSTROW_JELLYFIN_DISCOVERY_EXTRA")
        async let emby = LocalNetwork.ask("who is EmbyServer?", port: 7359, timeout: timeout, testTarget: "FIRSTROW_EMBY_DISCOVERY_EXTRA")
        var servers: [JellyfinServerInfo] = []
        for reply in await jellyfin + emby {
            guard let data = reply.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["Id"] as? String,
                  let address = object["Address"] as? String
            else { continue }
            let name = (object["Name"] as? String) ?? address
            if !servers.contains(where: { $0.id == id }) {
                servers.append(JellyfinServerInfo(id: id, name: name, url: address))
            }
        }
        return servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

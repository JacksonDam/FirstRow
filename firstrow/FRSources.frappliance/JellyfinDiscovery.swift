import Foundation
#if FIRSTROW_PORTABLE
    import CPortable
#elseif canImport(Darwin)
    import Darwin
#endif

/// Finds Jellyfin servers on the local network: they answer a UDP broadcast on port 7359
/// with their name, id and address.
enum JellyfinDiscovery {
    private static let port: UInt16 = 7359
    private static let question = "who is JellyfinServer?"

    static func discover(timeout: TimeInterval = 2.5) async -> [JellyfinServerInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: discoverBlocking(timeout: timeout))
            }
        }
    }

    /// Another address to ask besides the broadcast (`host:port`), for testing.
    private static var extraTarget: (host: String, port: UInt16)? {
        guard FirstRowHarness.isActive,
              let value = ProcessInfo.processInfo.environment["FIRSTROW_JELLYFIN_DISCOVERY_EXTRA"],
              let colon = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: colon)...])
        else { return nil }
        return (String(value[..<colon]), port)
    }

    private static func discoverBlocking(timeout: TimeInterval) -> [JellyfinServerInfo] {
        let replies = sendAndCollect(timeout: timeout)
        var servers: [JellyfinServerInfo] = []
        for reply in replies {
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

    #if FIRSTROW_PORTABLE
        private static func sendAndCollect(timeout: TimeInterval) -> [String] {
            var buffer = [CChar](repeating: 0, count: 65536)
            let extra = extraTarget
            let count = (extra?.host ?? "").withCString { host in
                fr_udp_discover(question, extra == nil ? nil : host, Int32(extra?.port ?? 0), Int32(port), Int32(timeout * 1000), &buffer, Int32(buffer.count))
            }
            guard count > 0 else { return [] }
            return String(cString: buffer).split(separator: "\n").map(String.init)
        }
    #else
        private static func sendAndCollect(timeout: TimeInterval) -> [String] {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

            var targets: [in_addr_t] = [INADDR_BROADCAST]
            // Each network's own broadcast address too, since the general one only leaves by one interface.
            var interfaces: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&interfaces) == 0 {
                var cursor = interfaces
                while let entry = cursor?.pointee {
                    let flags = Int32(entry.ifa_flags)
                    if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                       let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                       let broadcast = entry.ifa_dstaddr
                    {
                        let value = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                        if !targets.contains(value) { targets.append(value) }
                    }
                    cursor = entry.ifa_next
                }
                freeifaddrs(interfaces)
            }

            func send(to address: in_addr_t, port: UInt16) {
                var target = sockaddr_in()
                target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = port.bigEndian
                target.sin_addr.s_addr = address
                let bytes = Array(question.utf8)
                _ = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if let extra = extraTarget {
                // Tests ask only the given address, so the Mac never asks about the local network.
                send(to: inet_addr(extra.host), port: extra.port)
            } else {
                for target in targets {
                    send(to: target, port: port)
                }
            }

            var replies: [String] = []
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(remaining * 1000))
                guard ready > 0 else { break }
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { continue }
                replies.append(String(decoding: buffer[0 ..< count], as: UTF8.self))
            }
            return replies
        }
    #endif
}

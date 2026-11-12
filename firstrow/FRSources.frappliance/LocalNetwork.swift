import Foundation
#if FIRSTROW_PORTABLE
    import CPortable
#elseif canImport(Darwin)
    import Darwin
    import dnssd
#endif

/// Asking the devices on the local network who they are: media servers of several kinds
/// answer a short question sent to everyone at once.
enum LocalNetwork {
    /// Sends `question` to every device on the local network at `port` (and to `group`, an
    /// address that devices of some kinds listen on together), and returns the answers that
    /// come before the time is up.
    ///
    /// Under the test harness only the address in the environment variable `testTarget` is
    /// asked (`host:port`), and nothing at all without one: a test never asks about the
    /// network the Mac is on.
    ///
    /// With `host`, only that one device is asked.
    static func ask(_ question: String, port: UInt16, group: String? = nil, host: String? = nil, timeout: TimeInterval = 2.5, testTarget: String? = nil) async -> [String] {
        var only: (host: String, port: UInt16)? = host.map { ($0, port) }
        if FirstRowHarness.isActive {
            guard let testTarget, let value = ProcessInfo.processInfo.environment[testTarget], let colon = value.lastIndex(of: ":"),
                  let port = UInt16(value[value.index(after: colon)...])
            else { return [] }
            only = (String(value[..<colon]), port)
        }
        let target = only
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: askBlocking(question, port: port, group: group, timeout: timeout, only: target))
            }
        }
    }

    #if FIRSTROW_PORTABLE
        private static func askBlocking(_ question: String, port: UInt16, group: String?, timeout: TimeInterval, only: (host: String, port: UInt16)?) -> [String] {
            var buffer = [CChar](repeating: 0, count: 262_144)
            let extraHost = only?.host ?? group ?? ""
            let extraPort = only?.port ?? port
            let count = extraHost.withCString { host in
                fr_udp_discover(question, extraHost.isEmpty ? nil : host, Int32(extraPort), Int32(port), Int32(timeout * 1000), &buffer, Int32(buffer.count))
            }
            guard count > 0 else { return [] }
            return String(cString: buffer).split(separator: "\n").map(String.init)
        }
    #else
        private static func askBlocking(_ question: String, port: UInt16, group: String?, timeout: TimeInterval, only: (host: String, port: UInt16)?) -> [String] {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

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

            if let only {
                send(to: inet_addr(only.host), port: only.port)
            } else {
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
                if let group { targets.append(inet_addr(group)) }
                for target in targets {
                    send(to: target, port: port)
                }
            }

            var replies: [String] = []
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 8192)
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

#if !FIRSTROW_PORTABLE
    /// A service a device on the local network announces by name (Bonjour): where it is.
    struct AnnouncedService: Sendable {
        var name: String
        var host: String
        var port: Int
    }

    extension LocalNetwork {
        /// The devices announcing a kind of service ("_smb._tcp"), each with where to reach
        /// it. Under the test harness nothing is looked for.
        static func services(ofType type: String, timeout: TimeInterval = 2.5) async -> [AnnouncedService] {
            guard !FirstRowHarness.isActive else { return [] }
            let names = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                ServiceSearch.shared.browse(type: type, timeout: timeout) { continuation.resume(returning: $0) }
            }
            var found: [AnnouncedService] = []
            for name in names.prefix(24) {
                let place = await withCheckedContinuation { (continuation: CheckedContinuation<(host: String, port: Int)?, Never>) in
                    ServiceSearch.shared.resolve(name: name, type: type, timeout: 2) { continuation.resume(returning: $0) }
                }
                if let place { found.append(AnnouncedService(name: name, host: place.host, port: place.port)) }
            }
            return found
        }
    }

    /// Runs the system's own searches for announced services, each for a short while.
    private final class ServiceSearch: @unchecked Sendable {
        static let shared = ServiceSearch()
        private let queue = DispatchQueue(label: "firstrow.services")

        /// What one search has found so far, handed to the system as the search's context.
        private final class Finds {
            var names: [String] = []
            var place: (host: String, port: Int)?
        }

        func browse(type: String, timeout: TimeInterval, then done: @escaping @Sendable ([String]) -> Void) {
            let finds = Finds()
            var search: DNSServiceRef?
            let context = Unmanaged.passRetained(finds)
            let status = DNSServiceBrowse(&search, 0, 0, type, "local.", { _, flags, _, error, name, _, _, context in
                guard error == kDNSServiceErr_NoError, let name, let context, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 else { return }
                let finds = Unmanaged<Finds>.fromOpaque(context).takeUnretainedValue()
                let text = String(cString: name)
                if !finds.names.contains(text) { finds.names.append(text) }
            }, context.toOpaque())
            guard status == kDNSServiceErr_NoError, let search else {
                context.release()
                done([])
                return
            }
            DNSServiceSetDispatchQueue(search, queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                DNSServiceRefDeallocate(search)
                let names = finds.names
                context.release()
                done(names)
            }
        }

        func resolve(name: String, type: String, timeout: TimeInterval, then done: @escaping @Sendable ((host: String, port: Int)?) -> Void) {
            let finds = Finds()
            var search: DNSServiceRef?
            let context = Unmanaged.passRetained(finds)
            let status = DNSServiceResolve(&search, 0, 0, name, type, "local.", { _, _, _, error, _, host, port, _, _, context in
                guard error == kDNSServiceErr_NoError, let host, let context else { return }
                let finds = Unmanaged<Finds>.fromOpaque(context).takeUnretainedValue()
                var text = String(cString: host)
                if text.hasSuffix(".") { text.removeLast() }
                if finds.place == nil { finds.place = (text, Int(UInt16(bigEndian: port))) }
            }, context.toOpaque())
            guard status == kDNSServiceErr_NoError, let search else {
                context.release()
                done(nil)
                return
            }
            DNSServiceSetDispatchQueue(search, queue)
            // (Looked at every tenth of a second, so one that answers at once is done at once.)
            var waited = 0.0
            func look() {
                if finds.place != nil || waited >= timeout {
                    DNSServiceRefDeallocate(search)
                    let place = finds.place
                    context.release()
                    done(place)
                    return
                }
                waited += 0.1
                queue.asyncAfter(deadline: .now() + 0.1) { look() }
            }
            queue.async { look() }
        }
    }
#endif

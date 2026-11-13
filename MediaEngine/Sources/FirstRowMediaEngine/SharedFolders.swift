import Foundation
import SMBClient

/// Looking in the folders that computers and network drives share (SMB), for First Row's
/// menus. Playing a file from one is the engine's own doing (see `MediaSources`).
enum SharedFolders {
    /// Signs in to a computer: as `user` if there is one, as a guest if not.
    private static func signIn(server: String, user: String?, password: String?) async throws -> SMBClient {
        var host = server
        var port: Int?
        if let colon = server.lastIndex(of: ":"), server.filter({ $0 == ":" }).count == 1, let number = Int(server[server.index(after: colon)...]) {
            host = String(server[..<colon])
            port = number
        }
        let client = port.map { SMBClient(host: host, port: $0) } ?? SMBClient(host: host)
        do {
            if let user, !user.isEmpty {
                try await client.login(username: user, password: password ?? "")
            } else {
                do {
                    try await client.login(username: "guest", password: nil)
                } catch {
                    try await client.login(username: nil, password: nil)
                }
            }
        } catch {
            client.session.disconnect()
            throw error
        }
        return client
    }

    private static func signOut(_ client: SMBClient) async {
        _ = try? await client.logoff()
        client.session.disconnect()
    }

    /// The names of the folders a computer shares (not its printers, nor the hidden ones).
    /// Among them are the ones a Mac offers to whoever has signed in, for as long as they
    /// are signed in: their own home folder, and its disks if they run the Mac.
    static func shares(server: String, user: String?, password: String?) async throws -> [String] {
        let client = try await signIn(server: server, user: user, password: password)
        do {
            let found = try await client.listShares()
            await signOut(client)
            return found
                .filter { $0.type.subtracting(.temporary) == .diskTree && !$0.name.hasSuffix("$") }
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            await signOut(client)
            throw error
        }
    }

    /// What a folder of a share holds: each thing's name, whether it's a folder, and its size.
    static func contents(server: String, share: String, path: String, user: String?, password: String?) async throws -> [[String: Any]] {
        let client = try await signIn(server: server, user: user, password: password)
        do {
            try await client.connectShare(share)
            let found = try await client.listDirectory(path: path)
            _ = try? await client.disconnectShare()
            await signOut(client)
            return found
                .filter { $0.name != "." && $0.name != ".." && !$0.isHidden && !$0.name.hasPrefix(".") }
                .map { [MediaEngineKey.name: $0.name, MediaEngineKey.isFolder: $0.isDirectory, MediaEngineKey.size: Double($0.size)] }
        } catch {
            await signOut(client)
            throw error
        }
    }

    /// A small file from a shared folder (a subtitle file), fetched whole to a file of its own
    /// here, or nil if it can't be had or is too big to be one.
    static func copy(of url: URL, user: String?, password: String?) async -> URL? {
        guard let host = url.host else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let server = url.port.map { "\(host):\($0)" } ?? host
        let path = parts.dropFirst().joined(separator: "/")
        guard let client = try? await signIn(server: server, user: user ?? url.user, password: password ?? url.password) else { return nil }
        defer { Task { await signOut(client) } }
        guard (try? await client.connectShare(parts[0])) != nil,
              let stat = try? await client.fileStat(path: path), stat.size > 0, stat.size < 8_000_000,
              let data = try? await client.download(path: path)
        else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FirstRowSubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let place = folder.appendingPathComponent(UUID().uuidString + "-" + (parts.last ?? "subtitles"))
        guard (try? data.write(to: place)) != nil else { return nil }
        return place
    }

    /// Runs a question and turns what goes wrong into words, saying when it was the sign-in.
    static func answer(_ work: () async throws -> [String: Any]) async -> [String: Any] {
        do {
            return try await work()
        } catch let refusal as ErrorResponse {
            // (Refused for who is asking: 0xC000006D the name or password, 0xC0000022 not allowed.)
            let status = refusal.header.status
            let isSignIn = status == 0xC000_006D || status == 0xC000_0022 || status == 0xC000_006E || status == 0xC000_0072
            return [MediaEngineKey.error: refusal.errorDescription ?? "The computer refused.", MediaEngineKey.needsSignIn: isSignIn]
        } catch {
            return [MediaEngineKey.error: (error as? LocalizedError)?.errorDescription ?? "\(error)"]
        }
    }
}

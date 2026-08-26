import Foundation
import Darwin

struct WebDAVSyncBackend: SyncBackend {
    let identifier = "webdav"
    static let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/webdav-state.json")
    static let lockURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/webdav-sync.lock")

    private struct PeerState: Codable {
        var etag: String?
        var fetched_at: Int
    }
    private struct State: Codable {
        var peers: [String: PeerState] = [:]
    }

    func synchronize(config: SyncConfig,
                     snapshotCommand: SyncCommand,
                     completion: @escaping (SyncResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Self.withLock {
                Self.perform(config: config, snapshotCommand: snapshotCommand)
            } ?? SyncResult(code: .busy, output: "已有 WebDAV 同步任务正在运行")
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func probe(settings: WebDAVSettings, password: String) throws -> String {
        try makeClient(settings: settings, password: password).probe()
    }

    static func perform(config: SyncConfig, snapshotCommand: SyncCommand,
                        passwordOverride: String? = nil,
                        stateURLOverride: URL? = nil) -> SyncResult {
        guard let settings = config.webdav,
              let deviceID = SyncManager.validDeviceID(config.device_id),
              let password = passwordOverride ?? KeychainStore.read(account: settings.username),
              !password.isEmpty else {
            return SyncResult(code: .invalidConfiguration,
                              output: "WebDAV 配置或密码不完整")
        }
        do {
            let directory = URL(fileURLWithPath: SyncManager.resolvedSyncDir(config), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshotResult = run(snapshotCommand)
            guard snapshotResult.status == 0 else {
                return SyncResult(code: .snapshotFailed, output: snapshotResult.output)
            }
            let localURL = directory.appendingPathComponent(deviceID + ".json")
            var payload = try Data(contentsOf: localURL)
            if settings.remove_project_names {
                payload = try removingProjectNames(from: payload)
            }
            let remoteSuffix: String
            if settings.compress {
                guard let compressed = GzipCodec.compress(payload) else {
                    return SyncResult(code: .unknown, output: "快照压缩失败")
                }
                payload = compressed
                remoteSuffix = ".json.gz"
            } else {
                remoteSuffix = ".json"
            }

            let client = try makeClient(settings: settings, password: password)
            try client.ensureDirectory()
            try client.put(name: deviceID + remoteSuffix, data: payload)

            let stateURL = stateURLOverride ?? Self.stateURL
            var state = loadState(from: stateURL)
            var downloaded = 0
            var issues: [String] = []
            for entry in try client.list() where !entry.isDirectory {
                guard let peer = remotePeerName(entry.name),
                      peer.caseInsensitiveCompare(deviceID) != .orderedSame else { continue }
                if let etag = entry.etag, state.peers[peer]?.etag == etag { continue }
                do {
                    let remote = try client.get(name: entry.name)
                    guard let json = entry.name.hasSuffix(".gz") ? GzipCodec.decompress(remote) : remote,
                          (try? JSONSerialization.jsonObject(with: json)) is [String: Any] else {
                        issues.append("\(entry.name) 内容损坏")
                        continue
                    }
                    try atomicWrite(json, to: directory.appendingPathComponent(peer + ".json"))
                    state.peers[peer] = PeerState(etag: entry.etag,
                                                  fetched_at: Int(Date().timeIntervalSince1970))
                    downloaded += 1
                } catch {
                    issues.append("\(entry.name)：\(error.localizedDescription)")
                }
            }
            try saveState(state, to: stateURL)
            var message = "WebDAV 上传成功，更新了 \(downloaded) 台设备"
            if !issues.isEmpty { message += "；跳过：" + issues.joined(separator: "；") }
            return SyncResult(code: .success, output: message)
        } catch {
            return result(for: error)
        }
    }

    private static func makeClient(settings: WebDAVSettings, password: String) throws -> WebDAVClient {
        guard let url = URL(string: settings.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              !settings.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebDAVError.badResponse("地址或用户名为空")
        }
        return try WebDAVClient(config: WebDAVConfig(baseURL: url, directory: settings.path,
                                                      username: settings.username, password: password))
    }

    private static func remotePeerName(_ name: String) -> String? {
        let peer: String
        if name.hasSuffix(".json.gz") { peer = String(name.dropLast(8)) }
        else if name.hasSuffix(".json") { peer = String(name.dropLast(5)) }
        else { return nil }
        return SyncManager.validDeviceID(peer)
    }

    private static func removingProjectNames(from data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var dashboard = root["_dashboard"] as? [String: Any],
              var wrapped = dashboard["wrapped"] as? [String: Any] else { return data }
        for key in wrapped.keys {
            guard var period = wrapped[key] as? [String: Any] else { continue }
            period["projects"] = []
            wrapped[key] = period
        }
        dashboard["wrapped"] = wrapped
        root["_dashboard"] = dashboard
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func run(_ command: SyncCommand) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run(); process.waitUntilExit() }
        catch { return (-1, error.localizedDescription) }
        return (process.terminationStatus,
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private static func withLock<T>(_ body: () -> T) -> T? {
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard Darwin.lockf(fd, F_TLOCK, 0) == 0 else { return nil }
        defer { _ = Darwin.lockf(fd, F_ULOCK, 0) }
        return body()
    }

    private static func loadState(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private static func saveState(_ state: State, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try atomicWrite(JSONEncoder().encode(state), to: url)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".tokei-webdav-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary,
                                                      backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func result(for error: Error) -> SyncResult {
        let code: SyncCode
        switch error as? WebDAVError {
        case .auth?: code = .authFailed
        case .quotaExceeded?: code = .quotaExceeded
        case .notFound?: code = .notFound
        case .network?: code = .networkFailed
        default: code = .unknown
        }
        return SyncResult(code: code, output: error.localizedDescription)
    }
}

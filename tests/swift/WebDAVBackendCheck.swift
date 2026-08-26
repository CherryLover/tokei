import Foundation

struct DailyCost: Codable {}
struct WrappedData: Codable {}

@main
struct WebDAVBackendCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let baseURL = URL(string: CommandLine.arguments[1]) else { throw CheckError.arguments }
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let sync = root.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let settings = WebDAVSettings(url: baseURL.absoluteString, path: "tokei",
                                      username: "user", compress: true,
                                      remove_project_names: false)
        let client = try WebDAVClient(config: WebDAVConfig(baseURL: baseURL, directory: "tokei",
                                                           username: "user", password: "pass"))
        try client.ensureDirectory()
        let peerJSON = Data("{\"_device\":\"远端设备\",\"_ts\":123,\"value\":9}".utf8)
        try client.put(name: "远端设备.json.gz", data: GzipCodec.compress(peerJSON)!)

        let ownJSON = "{\"_device\":\"本机\",\"_ts\":456,\"_dashboard\":{\"wrapped\":{}}}"
        let command = SyncCommand(executable: "/bin/sh", arguments: ["-c",
            "printf '%s' '\(ownJSON)' > '\(sync.appendingPathComponent("本机.json").path)'"])
        let config = SyncConfig(device_id: "本机", sync_dir: sync.path, auto_sync: false,
                                sync_interval: 5, sync_backend: "webdav", webdav: settings)
        let state = root.appendingPathComponent("state.json")
        let first = WebDAVSyncBackend.perform(config: config, snapshotCommand: command,
                                              passwordOverride: "pass", stateURLOverride: state)
        guard first.succeeded else { throw CheckError.sync(first.output) }
        guard try Data(contentsOf: sync.appendingPathComponent("远端设备.json")) == peerJSON else {
            throw CheckError.peer
        }
        let second = WebDAVSyncBackend.perform(config: config, snapshotCommand: command,
                                               passwordOverride: "pass", stateURLOverride: state)
        guard second.succeeded, second.output.contains("更新了 0 台设备") else {
            throw CheckError.etag(second.output)
        }
        try client.put(name: "远端设备.json.gz", data: Data("damaged payload with a new etag".utf8))
        let third = WebDAVSyncBackend.perform(config: config, snapshotCommand: command,
                                              passwordOverride: "pass", stateURLOverride: state)
        guard third.succeeded, third.output.contains("内容损坏") else {
            throw CheckError.corrupt(third.output)
        }
        guard try Data(contentsOf: sync.appendingPathComponent("远端设备.json")) == peerJSON else {
            throw CheckError.peer
        }
        print("webdav backend checks passed")
    }

    enum CheckError: Error { case arguments, sync(String), peer, etag(String), corrupt(String) }
}

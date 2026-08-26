import Foundation

@main
struct WebDAVClientCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let baseURL = URL(string: CommandLine.arguments[1]) else { throw CheckError.arguments }
        let config = WebDAVConfig(baseURL: baseURL, directory: "tokei/设备",
                                  username: "user", password: "pass")
        let client = try WebDAVClient(config: config)
        let result = try client.probe()
        guard result.contains("连接成功") else { throw CheckError.probe }
        let payload = Data("unicode payload".utf8)
        try client.put(name: "办公室 Mac.json", data: payload)
        guard try client.get(name: "办公室 Mac.json") == payload else { throw CheckError.roundTrip }
        guard try client.list().contains(where: { $0.name == "办公室 Mac.json" }) else { throw CheckError.list }
        try client.delete(name: "办公室 Mac.json")

        do {
            _ = try WebDAVClient(config: WebDAVConfig(baseURL: baseURL, directory: "tokei",
                                                       username: "user", password: "wrong")).probe()
            throw CheckError.auth
        } catch WebDAVError.auth {
        }
        print("webdav client checks passed")
    }

    enum CheckError: Error { case arguments, probe, roundTrip, list, auth }
}

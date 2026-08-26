import Foundation

/// WebDAV 连接配置。
///
/// 密码只在内存里传递，不由这里负责持久化——Mac 端应当存钥匙串，
/// 无头节点用环境变量或权限 600 的密钥文件。
struct WebDAVConfig {
    /// 服务商给的 WebDAV 根地址，例如 `https://dav.jianguoyun.com/dav/`。
    /// 有没有尾斜杠都可以，内部会统一补齐。
    var baseURL: URL
    /// 根地址下面存放快照的目录，例如 `tokei`。允许多级（`a/b`），前后斜杠可有可无。
    var directory: String
    var username: String
    var password: String
}

/// 列目录返回的一条记录。
struct WebDAVEntry {
    /// 文件名（已做百分号解码，例如 `我的 Mac.json.gz`）。
    var name: String
    /// 服务器给的 ETag。**原样保存，不做任何解析**——各家格式不统一，
    /// 有的带引号、有的带 `W/` 弱校验前缀，只能整串比对。
    var etag: String?
    var lastModified: Date?
    var isDirectory: Bool
}

/// WebDAV 操作失败的分类。
///
/// 这里只区分「上层需要区别对待」的几种情况：认证错要立刻停下并提示用户改配置，
/// 配额超了要暂停自动同步，网络错可以下一轮再试。其余一律归到 `server`/`badResponse`。
enum WebDAVError: Error, LocalizedError {
    /// 地址不是 https（localhost 除外）。
    case notHTTPS
    /// 401 / 403：用户名或密码不对。
    case auth
    /// 404：目录或文件不存在。
    case notFound
    /// 507 或返回体里明示存储空间不足。
    case quotaExceeded
    /// 连不上、超时、DNS 失败等传输层问题。
    case network(String)
    /// 连上了，但返回的内容不是预期的（XML 解析不了、读回的内容对不上等）。
    case badResponse(String)
    /// 其他未归类的 HTTP 状态码。
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .notHTTPS:
            return "WebDAV 地址必须使用 https（仅 localhost 可以用 http）"
        case .auth:
            return "用户名或密码错误。坚果云这类服务需要填「应用密码」，不是账号主密码"
        case .notFound:
            return "远端目录或文件不存在"
        case .quotaExceeded:
            return "远端存储空间或流量配额已用尽，建议降低同步频率"
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .badResponse(let detail):
            return "服务器返回内容异常：\(detail)"
        case .server(let status):
            return "服务器返回 HTTP \(status)"
        }
    }
}

/// 零依赖的 WebDAV 客户端，只用 Foundation。
///
/// 所有方法都是**同步阻塞**的：内部用信号量把 `URLSession` 的回调等回来。
/// 这样写是因为调用方（同步后端）本来就跑在自己的后台队列上，串行执行几个
/// HTTP 请求比铺开一堆回调好读得多。**不要在主线程上直接调用。**
///
/// 这里刻意不碰压缩、不碰 ETag 语义、不碰状态文件：它只管发请求和解返回，
/// 「哪些文件要下载」「下载完存哪」由上层决定。
struct WebDAVClient {
    /// 单个请求的超时。WebDAV 的列目录在文件多时会慢一些，30 秒足够宽松。
    static let timeout: TimeInterval = 30

    let config: WebDAVConfig

    /// 补齐尾斜杠、拼上目标目录之后的完整目录地址。
    private let directoryURL: URL
    /// 目录在服务器上的路径（已解码），用来在列目录结果里认出「目录自己」那一条。
    private let directoryPath: String
    private let authorizationHeader: String

    /// - Throws: 地址不是 https 时抛 `WebDAVError.notHTTPS`，拼不出合法 URL 时抛 `badResponse`。
    init(config: WebDAVConfig) throws {
        try Self.requireSecureScheme(config.baseURL)
        guard !config.directory.split(separator: "/").contains("..") else {
            throw WebDAVError.badResponse("远端目录不能包含 ..")
        }
        self.config = config
        self.directoryURL = try Self.makeDirectoryURL(base: config.baseURL, directory: config.directory)
        self.directoryPath = Self.decodedPath(of: self.directoryURL)
        let raw = "\(config.username):\(config.password)"
        self.authorizationHeader = "Basic " + Data(raw.utf8).base64EncodedString()
    }

    // MARK: - 对外方法

    /// 建目录。**已存在时服务器返回 405，要当成成功**，不是错误。
    ///
    /// 目录写成多级（`a/b`）时逐级创建：有的服务器父目录不存在会直接返回 409，
    /// 一层层建过去最省事。
    func ensureDirectory() throws {
        for url in intermediateDirectoryURLs() {
            var request = makeRequest(method: "MKCOL", url: url)
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            let (data, response) = try send(request)
            switch response.statusCode {
            case 200, 201, 204, 405:
                // 405 = Method Not Allowed，几乎所有实现都用它表示「目录已经在了」。
                continue
            default:
                throw Self.mapFailure(status: response.statusCode, body: data)
            }
        }
    }

    /// 列出目录下的一层内容。
    ///
    /// **必须显式带 `Depth: 1`**：有的服务器默认按 `infinity` 处理，会把整棵子树都吐回来。
    /// 返回结果里不包含目录自身那一条（PROPFIND 按规范会把被查询的集合也列进去）。
    func list() throws -> [WebDAVEntry] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:getetag/>
            <D:getlastmodified/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """
        var request = makeRequest(method: "PROPFIND", url: directoryURL)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try send(request)
        // 规范是 207 Multi-Status，但见过返回 200 的实现，一并接受。
        guard response.statusCode == 207 || response.statusCode == 200 else {
            throw Self.mapFailure(status: response.statusCode, body: data)
        }
        guard !data.isEmpty else {
            throw WebDAVError.badResponse("列目录返回了空内容")
        }

        let parser = MultiStatusParser()
        guard parser.parse(data) else {
            throw WebDAVError.badResponse("列目录返回的 XML 无法解析")
        }

        var entries: [WebDAVEntry] = []
        for item in parser.responses {
            let path = Self.decodedPath(ofHref: item.href)
            // 目录自己那一条跳过。两边都补齐尾斜杠再比，绕开尾斜杠的服务器差异。
            if Self.normalizedDirectoryPath(path) == Self.normalizedDirectoryPath(directoryPath),
               item.isDirectory {
                continue
            }
            guard let name = Self.lastComponent(of: path), !name.isEmpty else { continue }
            entries.append(WebDAVEntry(
                name: name,
                etag: item.etag,
                lastModified: item.lastModified.flatMap(Self.parseHTTPDate),
                isDirectory: item.isDirectory
            ))
        }
        return entries
    }

    /// 上传一个文件，同名直接覆盖。
    func put(name: String, data: Data) throws {
        var request = makeRequest(method: "PUT", url: try fileURL(name: name))
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseBody, response) = try send(request)
        switch response.statusCode {
        case 200, 201, 204:
            return
        default:
            throw Self.mapFailure(status: response.statusCode, body: responseBody)
        }
    }

    /// 下载一个文件。
    func get(name: String) throws -> Data {
        let request = makeRequest(method: "GET", url: try fileURL(name: name))
        let (data, response) = try send(request)
        switch response.statusCode {
        case 200, 206:
            return data
        default:
            throw Self.mapFailure(status: response.statusCode, body: data)
        }
    }

    /// 删除一个文件。`probe()` 用它清理探测文件；文件本来就不在时不算失败。
    func delete(name: String) throws {
        let request = makeRequest(method: "DELETE", url: try fileURL(name: name))
        let (data, response) = try send(request)
        switch response.statusCode {
        case 200, 202, 204, 404:
            return
        default:
            throw Self.mapFailure(status: response.statusCode, body: data)
        }
    }

    /// 连通性自检，供设置界面的「测试连接」用。
    ///
    /// WebDAV 的配置错误基本都是静默失败（地址少了一段、目录不存在、用了账号主密码
    /// 而不是应用密码），不实际跑一遍写读删，用户根本看不出问题在哪。
    /// 顺序：建目录 → 写探测文件 → 列目录 → 读回校验 → 删除。
    ///
    /// - Returns: 一句可以直接显示给用户的成功描述。
    func probe() throws -> String {
        try ensureDirectory()

        let name = ".tokei-probe-\(UUID().uuidString).txt"
        let payload = Data("tokei webdav probe \(Int(Date().timeIntervalSince1970))".utf8)
        try put(name: name, data: payload)

        // 探测文件删掉之前先把要报告的信息收集完，出错也要尽量清理干净。
        var entryCount = 0
        var failure: Error?
        do {
            entryCount = try list().filter { !$0.isDirectory }.count
            let echo = try get(name: name)
            guard echo == payload else {
                throw WebDAVError.badResponse("写上去的探测文件读回来内容对不上")
            }
        } catch {
            failure = error
        }
        try? delete(name: name)
        if let failure { throw failure }

        // 探测文件本身也被算进去了，报告时减掉。
        let existing = max(entryCount - 1, 0)
        let host = directoryURL.host ?? config.baseURL.absoluteString
        return "连接成功：\(host) 上的 \(directoryPath) 可创建、可写入、可读回、可列目录（现有 \(existing) 个文件）"
    }

    // MARK: - URL 拼接

    /// 目标目录下某个文件的完整地址。
    ///
    /// 设备名允许空格和中文（见 `SyncManager.validDeviceID`），直接往 URL 里拼会坏，
    /// 必须逐段做百分号编码。
    func fileURL(name: String) throws -> URL {
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed),
              !escaped.isEmpty else {
            throw WebDAVError.badResponse("文件名无法编码进 URL：\(name)")
        }
        guard let url = URL(string: directoryURL.absoluteString + escaped) else {
            throw WebDAVError.badResponse("无法拼出文件地址：\(name)")
        }
        return url
    }

    /// 一段路径里的每一级目录地址（含最终目录），用来逐级 MKCOL。
    private func intermediateDirectoryURLs() -> [URL] {
        let base = Self.withTrailingSlash(config.baseURL.absoluteString)
        var urls: [URL] = []
        var accumulated = base
        for segment in Self.escapedSegments(of: config.directory) {
            accumulated += segment + "/"
            if let url = URL(string: accumulated) {
                urls.append(url)
            }
        }
        // 目录留空时直接使用服务商给出的根地址，不尝试创建它。
        return urls
    }

    /// 内部一律把目录地址补成带尾斜杠的形式再拼路径——尾斜杠是各家行为差异最大的地方。
    private static func makeDirectoryURL(base: URL, directory: String) throws -> URL {
        var text = withTrailingSlash(base.absoluteString)
        for segment in escapedSegments(of: directory) {
            text += segment + "/"
        }
        guard let url = URL(string: text) else {
            throw WebDAVError.badResponse("无法拼出目录地址：\(base.absoluteString) + \(directory)")
        }
        return url
    }

    private static func withTrailingSlash(_ text: String) -> String {
        text.hasSuffix("/") ? text : text + "/"
    }

    private static func escapedSegments(of directory: String) -> [String] {
        directory
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) }
    }

    /// 单个路径段允许的字符集：在 `urlPathAllowed` 基础上去掉分隔符，
    /// 保证设备名里的 `/`、`?`、`#` 之类不会把 URL 结构撑破。`%` 本来就不在白名单里，会被转成 `%25`。
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]")
        return set
    }()

    // MARK: - 请求

    private func makeRequest(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 认证走固定的 Basic 头，不用 URLCredential 的挑战回调：
        // 那套要等服务器先返回 401 再补发，多一轮往返，而且有的实现根本不发挑战。
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("Tokei", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.timeout
        // 同步数据必须拿最新的，不能吃缓存。
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// 把 `URLSession` 的异步回调等成同步返回。
    private func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }
        task.resume()
        // URLSession 自己有超时，这里再留一点余量兜底，避免极端情况下永久挂住调用线程。
        if semaphore.wait(timeout: .now() + Self.timeout + 10) == .timedOut {
            task.cancel()
            throw WebDAVError.network("请求超时")
        }
        if let error = box.error {
            throw Self.mapTransport(error)
        }
        guard let response = box.response as? HTTPURLResponse else {
            throw WebDAVError.badResponse("没有拿到 HTTP 响应")
        }
        return (box.data ?? Data(), response)
    }

    /// 承接回调里写入的结果。用引用类型是为了不在闭包里捕获可变局部变量。
    private final class ResultBox {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    // MARK: - 错误映射

    private static func requireSecureScheme(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return }
        // 唯一的例外是本机：自建服务（rclone serve webdav 之类）在本机调试时用 http 是合理的。
        let host = url.host?.lowercased()
        if scheme == "http", host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return
        }
        throw WebDAVError.notHTTPS
    }

    private static func mapTransport(_ error: Error) -> WebDAVError {
        guard let urlError = error as? URLError else {
            return .network(error.localizedDescription)
        }
        switch urlError.code {
        case .userAuthenticationRequired:
            return .auth
        default:
            return .network(urlError.localizedDescription)
        }
    }

    private static func mapFailure(status: Int, body: Data) -> WebDAVError {
        let text = String(data: body.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        // 配额判断放在认证前面：坚果云超额时返回的是 403 而不是 507，
        // 只看状态码会把「流量用完了」误报成「密码错了」。
        if status == 507
            || text.contains("insufficient storage")
            || text.contains("quota")
            || text.contains("空间不足")
            || text.contains("超出") {
            return .quotaExceeded
        }
        switch status {
        case 401, 403:
            return .auth
        case 404, 410:
            return .notFound
        default:
            return .server(status: status)
        }
    }

    // MARK: - 路径与日期

    private static func decodedPath(of url: URL) -> String {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return raw.removingPercentEncoding ?? raw
    }

    /// href 可能是完整 URL，也可能只是绝对路径，两种都要认。
    private static func decodedPath(ofHref href: String) -> String {
        var raw = href
        if let components = URLComponents(string: href), !components.percentEncodedPath.isEmpty {
            raw = components.percentEncodedPath
        }
        return raw.removingPercentEncoding ?? raw
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private static func lastComponent(of path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }

    /// WebDAV 的 `getlastmodified` 按规范是 RFC 1123，但见过塞 ISO 8601 的实现，两种都试。
    private static func parseHTTPDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let date = rfc1123Formatter.date(from: trimmed) { return date }
        return iso8601Formatter.date(from: trimmed)
    }

    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - multistatus 解析

/// PROPFIND 返回的 `multistatus` 解析器。
///
/// 两件事必须按规范来，否则会踩到各家实现的差异：
/// 一是**按命名空间取属性**（`DAV:`），不能只看标签名——各家的前缀五花八门，
/// `D:`、`d:`、`lp1:`，还有混进来的自定义命名空间同名标签；
/// 二是只采纳 `propstat` 里状态为 200 的那一组属性，
/// 服务器会把查不到的属性单独放进一个 404 的 `propstat`。
private final class MultiStatusParser: NSObject, XMLParserDelegate {
    struct Item {
        var href: String
        var etag: String?
        var lastModified: String?
        var isDirectory: Bool
    }

    private static let davNamespace = "DAV:"

    private(set) var responses: [Item] = []

    private var current: Item?
    private var propETag: String?
    private var propLastModified: String?
    private var propIsDirectory = false
    private var propstatStatus = ""
    private var insideResourceType = false
    private var insidePropstat = false
    private var text = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        // 打开命名空间处理之后，回调里的 elementName 就是本地名，namespaceURI 才是判据。
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        text = ""
        guard namespaceURI == Self.davNamespace else { return }
        switch elementName {
        case "response":
            current = Item(href: "", etag: nil, lastModified: nil, isDirectory: false)
        case "propstat":
            insidePropstat = true
            propETag = nil
            propLastModified = nil
            propIsDirectory = false
            propstatStatus = ""
        case "resourcetype":
            insideResourceType = true
        case "collection":
            if insideResourceType { propIsDirectory = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { text = "" }
        guard namespaceURI == Self.davNamespace else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            // propstat 内部也可能出现 href（比如 owner 属性里），只取 response 一级的那个。
            if !insidePropstat, current != nil, !value.isEmpty {
                current?.href = value
            }
        case "getetag":
            // 原样存，不去引号也不剥 W/ 前缀：ETag 只做整串比对。
            if !value.isEmpty { propETag = value }
        case "getlastmodified":
            if !value.isEmpty { propLastModified = value }
        case "resourcetype":
            insideResourceType = false
        case "status":
            if insidePropstat { propstatStatus = value }
        case "propstat":
            insidePropstat = false
            if Self.isSuccessStatus(propstatStatus) {
                if let etag = propETag { current?.etag = etag }
                if let modified = propLastModified { current?.lastModified = modified }
                if propIsDirectory { current?.isDirectory = true }
            }
        case "response":
            if let item = current, !item.href.isEmpty {
                responses.append(item)
            }
            current = nil
        default:
            break
        }
    }

    /// 状态行形如 `HTTP/1.1 200 OK`，只认中间那个三位数。
    private static func isSuccessStatus(_ line: String) -> Bool {
        if line.isEmpty { return true }
        for field in line.split(separator: " ") {
            if let code = Int(field), code >= 100, code < 600 {
                return (200..<300).contains(code)
            }
        }
        return false
    }
}

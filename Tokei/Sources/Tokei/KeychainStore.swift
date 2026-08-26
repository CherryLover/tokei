import Foundation
import Security

/// 钥匙串封装：专门存放 WebDAV 同步用的密码。
///
/// 项目里其余配置都是明文写在 `~/.tokei/config.json` 和 `UserDefaults` 里的，
/// 密码不能走同一条路，所以单独用系统钥匙串来存，配置文件里只保留用户名。
///
/// 存储形态是泛型密码（`kSecClassGenericPassword`）：
/// - service 固定为 `com.tokei.app.webdav`，把本应用的条目和别人的隔开；
/// - account 由调用方传入（一般就是 WebDAV 用户名），
///   这样换账号时是两条互不相干的记录，不会读到上一个账号的密码。
///
/// 所有方法都不打印、不返回密码内容；失败时只带出 `OSStatus` 数字码，
/// 避免密码顺着日志泄漏出去。
enum KeychainStore {

    /// 钥匙串条目的 service 名，全应用共用一个。
    static let service = "com.tokei.app.webdav"

    // MARK: - 写入

    /// 保存或更新指定账号的密码。
    ///
    /// 采用「先 `SecItemUpdate`，报 `errSecItemNotFound` 再 `SecItemAdd`」的顺序，
    /// 而不是「先删后加」。理由：
    /// 1. 先删后加中间存在一个空窗，如果 add 这一步失败（比如钥匙串被锁、
    ///    进程恰好被杀），旧密码已经没了、新密码也没写进去，用户直接丢凭据；
    ///    update 是原地覆盖，失败时旧值仍然完好。
    /// 2. update 会保留条目原有的创建时间和访问控制关系，不会让系统
    ///    把它当成一条全新的凭据重新向用户确认。
    ///
    /// - Parameters:
    ///   - account: 账号标识，通常是 WebDAV 用户名，不能为空。
    ///   - password: 明文密码，不能为空。
    /// - Returns: 成功写入返回 `true`；参数非法或钥匙串报错返回 `false`。
    @discardableResult
    static func save(account: String, password: String) -> Bool {
        // 空账号或空密码一律拒绝：写进去也只是一条读出来没用的垃圾记录，
        // 反而会让后面的 read 误以为凭据已配置好。
        guard let account = validAccount(account), !password.isEmpty else { return false }
        guard let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // 更新时一并把 kSecAttrAccessible 写进去，
        // 让早期版本存下的旧条目也能迁移到同一套可访问性策略。
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else {
            logFailure("更新", status: updateStatus)
            return false
        }

        // 条目不存在，改为新增。
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // kSecAttrAccessibleAfterFirstUnlock：应用会在后台按定时器同步，
        // 触发时用户不一定正坐在电脑前交互，甚至可能屏幕已锁。
        // 用这一档可以保证开机后用户解锁过一次，之后后台任务就能读到密码；
        // 同时它不随 iCloud 钥匙串同步、也不会在锁屏时可读，
        // 比 kSecAttrAccessibleAlways 之类更克制。
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logFailure("写入", status: addStatus)
            return false
        }
        return true
    }

    // MARK: - 读取

    /// 读取指定账号的密码。
    ///
    /// - Parameter account: 账号标识，不能为空。
    /// - Returns: 存在且能解码为 UTF-8 时返回密码；没有记录或出错时返回 `nil`。
    static func read(account: String) -> String? {
        guard let account = validAccount(account) else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            // 查不到不算异常（还没配置过），不必记一笔。
            if status != errSecItemNotFound {
                logFailure("读取", status: status)
            }
            return nil
        }

        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 删除

    /// 删除指定账号的密码。
    ///
    /// - Parameter account: 账号标识，不能为空。
    /// - Returns: 删除成功、或本来就没有这条记录时返回 `true`；
    ///   参数非法或钥匙串报错返回 `false`。
    @discardableResult
    static func delete(account: String) -> Bool {
        guard let account = validAccount(account) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        // 本来就不存在视为已达成目的，调用方不需要为此分支写额外处理。
        if status == errSecSuccess || status == errSecItemNotFound { return true }

        logFailure("删除", status: status)
        return false
    }

    // MARK: - 内部

    /// 账号标识合法性校验：去掉首尾空白后不能为空。
    private static func validAccount(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 只输出操作名和 `OSStatus` 数字码。
    /// 这里刻意不带 account、更不带密码，日志里不留任何凭据痕迹。
    private static func logFailure(_ operation: String, status: OSStatus) {
        FileHandle.standardError.write(
            Data("[Keychain] \(operation)失败，OSStatus=\(status)\n".utf8)
        )
    }
}

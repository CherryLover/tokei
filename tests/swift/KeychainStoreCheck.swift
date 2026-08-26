import Foundation

@main
struct KeychainStoreCheck {
    static func main() throws {
        let account = "tokei-test-" + UUID().uuidString
        defer { _ = KeychainStore.delete(account: account) }
        guard KeychainStore.read(account: account) == nil else { throw CheckError.initial }
        guard KeychainStore.save(account: account, password: "first-secret"),
              KeychainStore.read(account: account) == "first-secret" else { throw CheckError.save }
        guard KeychainStore.save(account: account, password: "second-secret"),
              KeychainStore.read(account: account) == "second-secret" else { throw CheckError.update }
        guard KeychainStore.delete(account: account),
              KeychainStore.read(account: account) == nil else { throw CheckError.delete }
        guard !KeychainStore.save(account: "", password: "secret"),
              !KeychainStore.save(account: account, password: "") else { throw CheckError.invalid }
        print("keychain store checks passed")
    }

    enum CheckError: Error { case initial, save, update, delete, invalid }
}

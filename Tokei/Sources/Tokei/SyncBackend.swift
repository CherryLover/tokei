import Foundation

/// 同步结果的状态码。
///
/// 前六项是与传输方式无关的通用状态，任何后端都可能返回。
/// 其余是 Git 后端专有的失败细分，保留是为了不改变现有的错误提示；
/// 新增后端不应复用它们，而应补充自己的分类。
enum SyncCode: String {
    // 通用
    case success
    case busy
    case invalidConfiguration
    case snapshotFailed
    case timedOut
    case unknown

    // Git 专有
    case invalidRepository
    case foreignOperation
    case detachedHead
    case dirtyRepository
    case fetchFailed
    case commitFailed
    case rebaseFailed
    case recoveryFailed
    case pushFailed
}

struct SyncResult {
    var code: SyncCode
    var output: String

    var succeeded: Bool { code == .success }
}

/// 同步后端：负责把本机快照送出去，并把同伴的快照取回本地同步目录。
///
/// 这一层刻意只管「搬运」。读取和展示同伴数据的是 `SyncManager.loadPeers()`，
/// 它只是列出同步目录下的 `<设备名>.json` 并解析，完全不关心文件是怎么来的。
/// 因此新增一种传输方式不需要改动任何展示逻辑——只要把文件放进那个目录即可。
///
/// 后端本身不持有配置状态：每次调用都把 `SyncConfig` 传进来，
/// 这样同一个后端实例可以安全地被复用，也便于测试时构造不同配置。
protocol SyncBackend {
    /// 后端标识，对应配置里的 `sync_backend` 字段。
    var identifier: String { get }

    /// 执行一次完整同步：采集本机快照、推送、拉取同伴数据。
    ///
    /// - Parameters:
    ///   - config: 本次同步使用的配置（设备名、同步目录等）。
    ///   - snapshotCommand: 采集本机快照的命令，由 `DataLoader` 构造。
    ///   - completion: 回调保证在主线程执行。
    func synchronize(config: SyncConfig,
                     snapshotCommand: SyncCommand,
                     completion: @escaping (SyncResult) -> Void)
}

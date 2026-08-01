import Foundation
import Darwin

struct SyncConfig: Codable {
    var device_id: String
    var sync_dir: String
    var auto_sync: Bool?
    var sync_interval: Int?     // minutes
}

struct SyncCommand {
    var executable: String
    var arguments: [String]
    var supervisorExecutable: String? = nil
    var supervisorArguments: [String] = []
    var transactionTimeout: TimeInterval = 240
}


struct PeerDevice: Identifiable {
    var id: String { deviceId }
    var deviceId: String
    var lastSync: Date
    var usage: Usage
    var dashboard: PeerDashboardSnapshot?
    var rangeBounds: [String: RangeBoundary]
}

struct PeerDashboardSnapshot: Codable {
    var daily: [DailyCost] = []
    var wrapped: [String: WrappedData] = [:]
}

struct RangeBoundary: Codable, Equatable {
    var start: String?
    var end: String?
}

enum PeerLoadStage: String {
    case configuration = "配置"
    case read = "读取"
    case json = "JSON"
    case timestamp = "时间戳"
    case usage = "用量结构"
    case dashboard = "面板数据"
    case rangeBounds = "时间范围"
}

struct PeerLoadIssue: Identifiable {
    var id: String { "\(file)|\(stage.rawValue)|\(detail)" }
    var file: String
    var stage: PeerLoadStage
    var detail: String

    var summary: String { "\(file)：\(stage.rawValue)失败，\(detail)" }
}

struct PeerLoadReport {
    var peers: [PeerDevice]
    var issues: [PeerLoadIssue]
}

final class SyncManager {
    static let supportedSyncIntervals = [30, 60, 120]
    static let defaultSyncInterval = 30
    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/config.json")
    private static let configLockPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/config.lock")
    static let syncDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tokei/sync").path

    var config: SyncConfig?

    init() { config = Self.loadConfig() }

    static func normalizedSyncInterval(_ value: Int?) -> Int {
        guard let value, supportedSyncIntervals.contains(value) else {
            return defaultSyncInterval
        }
        return value
    }

    static func resolvedSyncDir(_ cfg: SyncConfig) -> String {
        let raw = cfg.sync_dir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Self.syncDir }
        return (raw as NSString).expandingTildeInPath
    }

    // MARK: - Config

    static func normalizedDeviceID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设备名合法性校验。同步目录里的文件名直接由它决定，
    /// 因此保存配置和各个同步后端都要用同一套规则。
    static func validDeviceID(_ value: String) -> String? {
        let trimmed = normalizedDeviceID(value)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", trimmed.count <= 128 else {
            return nil
        }
        guard !trimmed.unicodeScalars.contains(where: {
            $0.value < 32 || $0.value == 47 || $0.value == 92 || $0.value == 0
        }) else {
            return nil
        }
        return trimmed
    }

    static func loadConfig() -> SyncConfig? {
        guard let data = try? Data(contentsOf: configPath) else { return nil }
        guard var cfg = try? JSONDecoder().decode(SyncConfig.self, from: data) else { return nil }
        cfg.device_id = normalizedDeviceID(cfg.device_id)
        return cfg
    }

    private static func withConfigLock<T>(_ body: () throws -> T) -> T? {
        let directory = configPath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        let descriptor = Darwin.open(
            configLockPath.path,
            O_CREAT | O_RDWR,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fchmod(descriptor, mode_t(0o600))
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { return nil }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try? body()
    }

    private static func writeConfigDictionary(_ dictionary: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configPath, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configPath.path
        )
    }

    @discardableResult
    func saveConfig(_ cfg: SyncConfig) -> Bool {
        var normalized = cfg
        normalized.device_id = Self.normalizedDeviceID(cfg.device_id)
        guard Self.validDeviceID(normalized.device_id) != nil else {
            return false
        }
        let memoryDeviceID = config.flatMap {
            Self.validDeviceID(Self.normalizedDeviceID($0.device_id))
        }
        let saved: SyncConfig? = Self.withConfigLock {
            // 锁内重读磁盘，保证多个 Tokei 进程无法覆盖已经绑定的合法设备标识。
            var dictionary: [String: Any] = [:]
            if let data = try? Data(contentsOf: Self.configPath),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dictionary = object
            }
            let diskDeviceID = (dictionary["device_id"] as? String).flatMap {
                Self.validDeviceID(Self.normalizedDeviceID($0))
            }
            if let stableDeviceID = diskDeviceID ?? memoryDeviceID,
               normalized.device_id != stableDeviceID {
                throw CocoaError(.fileWriteNoPermission)
            }
            dictionary["device_id"] = normalized.device_id
            dictionary["sync_dir"] = normalized.sync_dir
            if let value = normalized.auto_sync {
                dictionary["auto_sync"] = value
            } else {
                dictionary.removeValue(forKey: "auto_sync")
            }
            if let value = normalized.sync_interval {
                dictionary["sync_interval"] = value
            } else {
                dictionary.removeValue(forKey: "sync_interval")
            }
            try Self.writeConfigDictionary(dictionary)
            return normalized
        }
        guard let saved else { return false }
        config = saved
        return true
    }

    @discardableResult
    static func setQoderIdeEnabled(_ enabled: Bool) -> Bool {
        withConfigLock {
            var dictionary: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: configPath.path) {
                let data = try Data(contentsOf: configPath)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                dictionary = object
            }
            dictionary["qoder_ide_enabled"] = enabled
            try writeConfigDictionary(dictionary)
            return true
        } ?? false
    }

    /// Grok 实时额度：默认关闭，只写 config 字段，不改动同步相关配置。
    @discardableResult
    static func setGrokLiveQuotaEnabled(_ enabled: Bool) -> Bool {
        withConfigLock {
            var dictionary: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: configPath.path) {
                let data = try Data(contentsOf: configPath)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                dictionary = object
            }
            dictionary["grok_live_quota_enabled"] = enabled
            try writeConfigDictionary(dictionary)
            return true
        } ?? false
    }

    // MARK: - Read peers

    func loadPeers() -> PeerLoadReport {
        guard let cfg = config else {
            return PeerLoadReport(
                peers: [],
                issues: [PeerLoadIssue(
                    file: Self.configPath.path,
                    stage: .configuration,
                    detail: "同步配置缺失或无法解析"
                )]
            )
        }
        let dir = Self.resolvedSyncDir(cfg)
        guard FileManager.default.fileExists(atPath: dir) else {
            return PeerLoadReport(
                peers: [],
                issues: [PeerLoadIssue(file: dir, stage: .read, detail: "同步目录不存在")]
            )
        }
        var peers: [PeerDevice] = []
        var issues: [PeerLoadIssue] = []
        let fm = FileManager.default
        let files: [String]
        do {
            files = try fm.contentsOfDirectory(atPath: dir).sorted()
        } catch {
            return PeerLoadReport(
                peers: [],
                issues: [PeerLoadIssue(file: dir, stage: .read, detail: error.localizedDescription)]
            )
        }
        for file in files where file.hasSuffix(".json") {
            let deviceId = String(file.dropLast(5)) // remove .json
            if deviceId.caseInsensitiveCompare(Self.normalizedDeviceID(cfg.device_id)) == .orderedSame {
                continue
            }
            let path = (dir as NSString).appendingPathComponent(file)
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                issues.append(PeerLoadIssue(file: file, stage: .read, detail: error.localizedDescription))
                continue
            }
            let raw: [String: Any]
            do {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    issues.append(PeerLoadIssue(file: file, stage: .json, detail: "顶层不是对象"))
                    continue
                }
                raw = value
            } catch {
                issues.append(PeerLoadIssue(file: file, stage: .json, detail: error.localizedDescription))
                continue
            }
            guard let ts = raw["_ts"] as? Int else {
                issues.append(PeerLoadIssue(file: file, stage: .timestamp, detail: "缺少 _ts"))
                continue
            }
            var cleaned = raw
            for key in cleaned.keys where key.hasPrefix("_") { cleaned.removeValue(forKey: key) }
            let usage: Usage
            do {
                let cleanData = try JSONSerialization.data(withJSONObject: cleaned)
                usage = try JSONDecoder().decode(Usage.self, from: cleanData)
            } catch {
                issues.append(PeerLoadIssue(file: file, stage: .usage, detail: error.localizedDescription))
                continue
            }
            var dashboard: PeerDashboardSnapshot?
            if let rawDashboard = raw["_dashboard"] {
                do {
                    guard JSONSerialization.isValidJSONObject(rawDashboard) else {
                        throw NSError(domain: "TokeiPeer", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "不是有效 JSON 对象"])
                    }
                    let dashboardData = try JSONSerialization.data(withJSONObject: rawDashboard)
                    dashboard = try JSONDecoder().decode(PeerDashboardSnapshot.self, from: dashboardData)
                } catch {
                    issues.append(PeerLoadIssue(file: file, stage: .dashboard,
                                                detail: error.localizedDescription))
                }
            }
            var rangeBounds: [String: RangeBoundary] = [:]
            if let rawBounds = raw["_range_bounds"] {
                do {
                    guard JSONSerialization.isValidJSONObject(rawBounds) else {
                        throw NSError(domain: "TokeiPeer", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "不是有效 JSON 对象"])
                    }
                    let boundsData = try JSONSerialization.data(withJSONObject: rawBounds)
                    rangeBounds = try JSONDecoder().decode([String: RangeBoundary].self, from: boundsData)
                } catch {
                    issues.append(PeerLoadIssue(file: file, stage: .rangeBounds,
                                                detail: error.localizedDescription))
                }
            }
            if rangeBounds.isEmpty {
                rangeBounds = Self.currentRangeBounds(now: Date(timeIntervalSince1970: TimeInterval(ts)))
                    .reduce(into: [String: RangeBoundary]()) { out, item in
                        out[item.key.rawValue] = item.value
                    }
            }
            peers.append(PeerDevice(
                deviceId: deviceId,
                lastSync: Date(timeIntervalSince1970: TimeInterval(ts)),
                usage: usage,
                dashboard: dashboard,
                rangeBounds: rangeBounds
            ))
        }
        return PeerLoadReport(peers: peers, issues: issues)
    }

    // MARK: - Merge

    static func merge(local: Usage, peers: [PeerDevice]) -> Usage {
        var u = local
        for peer in peers {
            let pairs = rangePairs(for: peer)
            mergeRanges(&u.claude.ranges, peer.usage.claude.ranges, pairs)
            mergeRanges(&u.codex.ranges, peer.usage.codex.ranges, pairs)
            mergeRanges(&u.gemini.ranges, peer.usage.gemini.ranges, pairs)
            mergeRanges(&u.grok.ranges, peer.usage.grok.ranges, pairs)
            u.grok.model = mergeModelName(u.grok.model, peer.usage.grok.model)
            mergeRanges(&u.qoderwork.ranges, peer.usage.qoderwork.ranges, pairs)
            mergeRanges(&u.qoder.ranges, peer.usage.qoder.ranges, pairs)
            mergeRanges(&u.hermes.ranges, peer.usage.hermes.ranges, pairs)
            mergeRanges(&u.zcode.ranges, peer.usage.zcode.ranges, pairs)
            mergeRanges(&u.mimocode.ranges, peer.usage.mimocode.ranges, pairs)
            mergeRanges(&u.openclaw.ranges, peer.usage.openclaw.ranges, pairs)
            mergeRanges(&u.pi.ranges, peer.usage.pi.ranges, pairs)
            mergeRanges(&u.workbuddy.ranges, peer.usage.workbuddy.ranges, pairs)
            mergeRanges(&u.opencode.ranges, peer.usage.opencode.ranges, pairs)
            mergeRanges(&u.qwencode.ranges, peer.usage.qwencode.ranges, pairs)
        }
        return u
    }

    private static func rangePairs(for peer: PeerDevice, now: Date = Date()) -> [(src: RangeKey, dst: RangeKey)] {
        let local = currentRangeBounds(now: now)
        var pairs: [(src: RangeKey, dst: RangeKey)] = []
        for src in RangeKey.allCases {
            guard let peerBoundary = peer.rangeBounds[src.rawValue] else { continue }
            if src == .all {
                pairs.append((.all, .all))
                continue
            }
            if let dst = RangeKey.allCases.first(where: { local[$0] == peerBoundary }) {
                pairs.append((src, dst))
            }
        }
        return pairs
    }

    static func currentRangeBounds(now: Date = Date()) -> [RangeKey: RangeBoundary] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let localWeek = weekStart(for: today, calendar: cal)
        let localLastWeek = cal.date(byAdding: .day, value: -7, to: localWeek) ?? localWeek
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: monthStart) ?? monthStart
        let yearStart = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        let nextYear = cal.date(byAdding: DateComponents(year: 1), to: yearStart) ?? yearStart

        return [
            .today: RangeBoundary(start: dayString(today), end: dayString(cal.date(byAdding: .day, value: 1, to: today) ?? today)),
            .yesterday: RangeBoundary(start: dayString(yesterday), end: dayString(today)),
            .week: RangeBoundary(start: dayString(localWeek), end: dayString(cal.date(byAdding: .day, value: 7, to: localWeek) ?? localWeek)),
            .lastWeek: RangeBoundary(start: dayString(localLastWeek), end: dayString(localWeek)),
            .month: RangeBoundary(start: dayString(monthStart), end: dayString(nextMonth)),
            .year: RangeBoundary(start: dayString(yearStart), end: dayString(nextYear)),
            .all: RangeBoundary(start: nil, end: nil),
        ]
    }

    private static func weekStart(for date: Date, calendar cal: Calendar) -> Date {
        let weekday = cal.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7
        return cal.date(byAdding: .day, value: -daysFromMonday, to: date) ?? date
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    private static func mergeRanges(_ dst: inout ClaudeRanges, _ src: ClaudeRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            d.in += s.in; d.out += s.out; d.cr += s.cr; d.cw += s.cw
            d.cost += s.cost; d.sessions += s.sessions
            d.hit = hitRate(cached: d.cr, input: d.in, cacheWrite: d.cw)
            mergeClaudeModels(&d.models, s.models)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout CodexRanges, _ src: CodexRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            d.in += s.in; d.out += s.out; d.cached += s.cached
            d.reason += s.reason; d.cost += s.cost; d.sessions += s.sessions
            d.hit = hitRate(cached: d.cached, input: d.in)
            mergeTokenModels(&d.models, s.models)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout GeminiRanges, _ src: GeminiRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            d.in += s.in; d.out += s.out; d.cached += s.cached
            d.thoughts += s.thoughts; d.cost += s.cost; d.sessions += s.sessions
            d.hit = hitRate(cached: d.cached, input: d.in)
            mergeGeminiModels(&d.models, s.models)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout GrokRanges, _ src: GrokRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            let originalLatencyWeight = max(d.turns ?? 0, d.sessions)
            let sourceLatencyWeight = max(s.turns ?? 0, s.sessions)
            let hadRealUsage = d.usage_available
            d.in += s.in; d.out += s.out; d.cr += s.cr; d.reason += s.reason
            d.cost += s.cost
            d.usage_available = d.usage_available || s.usage_available
            d.usage_calls += s.usage_calls; d.usage_sessions += s.usage_sessions
            if d.usage_available {
                d.tokens = d.in + d.out + d.cr + d.reason
            } else if !hadRealUsage {
                d.tokens += s.tokens
            }
            d.hit = hitRate(cached: d.cr, input: d.in)
            mergeTokenModels(&d.models, s.models)
            d.sessions += s.sessions
            d.turns = add(d.turns, s.turns)
            d.tools = add(d.tools, s.tools)
            d.duration = add(d.duration, s.duration)
            d.ctx_used = add(d.ctx_used, s.ctx_used)
            d.ctx_window = add(d.ctx_window, s.ctx_window)
            d.errors = add(d.errors, s.errors)
            d.cancellations = add(d.cancellations, s.cancellations)
            d.ttft = weightedAverage(d.ttft, originalLatencyWeight, s.ttft, sourceLatencyWeight)
            d.response = weightedAverage(d.response, originalLatencyWeight, s.response, sourceLatencyWeight)
            let ctxUsed = d.ctx_used ?? 0
            let ctxWindow = d.ctx_window ?? 0
            d.ctx = ctxWindow > 0 ? Double(ctxUsed) / Double(ctxWindow) * 100 : 0
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout QoderRanges, _ src: QoderRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            let originalSessions = d.sessions
            d.in += s.in; d.out += s.out
            d.sessions += s.sessions
            d.calls += s.calls; d.sub_agents += s.sub_agents
            d.turns += s.turns; d.duration += s.duration
            d.ctx = weightedAverage(d.ctx, originalSessions, s.ctx, s.sessions)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout QoderIdeRanges, _ src: QoderIdeRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            let originalSessions = d.sessions
            d.in += s.in; d.out += s.out; d.cached += s.cached
            d.sessions += s.sessions
            d.sub_agents += s.sub_agents; d.calls += s.calls
            d.messages += s.messages; d.duration += s.duration
            d.ctx = weightedAverage(d.ctx, originalSessions, s.ctx, s.sessions)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout HermesRanges, _ src: HermesRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            d.in += s.in; d.out += s.out; d.cr += s.cr; d.cw += s.cw
            d.reason += s.reason; d.cost += s.cost; d.sessions += s.sessions
            d.hit = hitRate(cached: d.cr, input: d.in, cacheWrite: d.cw)
            mergeTokenModels(&d.models, s.models)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout OpenClawRanges, _ src: OpenClawRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            d.tasks += s.tasks; d.completed += s.completed; d.failed += s.failed
            d.in += s.in; d.out += s.out; d.cr += s.cr; d.cw += s.cw
            d.cost += s.cost; d.sessions += s.sessions
            d.hit = hitRate(cached: d.cr, input: d.in, cacheWrite: d.cw)
            mergeTokenModels(&d.models, s.models)
            dst.set(pair.dst, d)
        }
    }

    private static func mergeRanges(_ dst: inout TokenUsageRanges, _ src: TokenUsageRanges, _ pairs: [(src: RangeKey, dst: RangeKey)]) {
        for pair in pairs {
            var d = dst.get(pair.dst), s = src.get(pair.src)
            d.in += s.in; d.out += s.out; d.cr += s.cr; d.cw += s.cw
            d.reason += s.reason; d.cost += s.cost; d.sessions += s.sessions
            d.hit = hitRate(cached: d.cr, input: d.in, cacheWrite: d.cw)
            mergeTokenModels(&d.models, s.models)
            dst.set(pair.dst, d)
        }
    }

    private static func hitRate(cached: Int, input: Int, cacheWrite: Int = 0) -> Double {
        let denom = cached + input + cacheWrite
        return denom > 0 ? Double(cached) / Double(denom) * 100 : 0
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        let sum = (lhs ?? 0) + (rhs ?? 0)
        return sum > 0 ? sum : 0
    }

    private static func weightedAverage(_ lhs: Int?, _ lhsWeight: Int, _ rhs: Int?, _ rhsWeight: Int) -> Int? {
        let totalWeight = lhsWeight + rhsWeight
        guard totalWeight > 0 else { return 0 }
        return (((lhs ?? 0) * lhsWeight) + ((rhs ?? 0) * rhsWeight)) / totalWeight
    }

    private static func weightedAverage(_ lhs: Double, _ lhsWeight: Int, _ rhs: Double, _ rhsWeight: Int) -> Double {
        let totalWeight = lhsWeight + rhsWeight
        guard totalWeight > 0 else { return 0 }
        return ((lhs * Double(lhsWeight)) + (rhs * Double(rhsWeight))) / Double(totalWeight)
    }

    private static func mergeClaudeModels(_ dst: inout [ClaudeModelStat], _ src: [ClaudeModelStat]) {
        for m in src {
            if let idx = dst.firstIndex(where: { $0.name == m.name }) {
                dst[idx].in += m.in
                dst[idx].out += m.out
                dst[idx].cr += m.cr
                dst[idx].cw += m.cw
                dst[idx].cost += m.cost
            } else {
                dst.append(m)
            }
        }
        dst.sort { $0.cost > $1.cost }
    }

    private static func mergeGeminiModels(_ dst: inout [GeminiModelStat], _ src: [GeminiModelStat]) {
        for m in src {
            if let idx = dst.firstIndex(where: { $0.name == m.name }) {
                dst[idx].in += m.in
                dst[idx].out += m.out
                dst[idx].cached += m.cached
                dst[idx].thoughts += m.thoughts
                dst[idx].cost += m.cost
            } else {
                dst.append(m)
            }
        }
        dst.sort { $0.cost > $1.cost }
    }

    private static func mergeTokenModels(_ dst: inout [TokenModelStat], _ src: [TokenModelStat]) {
        for m in src {
            if let idx = dst.firstIndex(where: { $0.name == m.name }) {
                dst[idx].in += m.in
                dst[idx].out += m.out
                dst[idx].cr += m.cr
                dst[idx].cw += m.cw
                dst[idx].reason += m.reason
                dst[idx].cost += m.cost
            } else {
                dst.append(m)
            }
        }
        dst.sort { $0.cost > $1.cost }
    }

    private static func mergeModelName(_ lhs: String?, _ rhs: String?) -> String? {
        var names: [String] = []
        for value in [lhs, rhs] {
            guard let value else { continue }
            for part in value.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: - Sync backend

    /// 按配置挑选同步后端。
    ///
    /// 目前只有 Git 一种。接入别的传输方式时只需在这里按 `sync_backend`
    /// 字段分发，调用方（`Store.doSync`）和展示层都不用改。
    static func makeBackend(for cfg: SyncConfig) -> SyncBackend {
        GitSyncBackend()
    }

    func synchronize(snapshotCommand: SyncCommand,
                     completion: @escaping (SyncResult) -> Void) {
        guard let cfg = config else {
            completion(SyncResult(code: .invalidConfiguration, output: "同步配置不可用"))
            return
        }
        Self.makeBackend(for: cfg).synchronize(config: cfg,
                                               snapshotCommand: snapshotCommand,
                                               completion: completion)
    }
}

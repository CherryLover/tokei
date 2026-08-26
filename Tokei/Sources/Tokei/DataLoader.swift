import Foundation
import CZstd
import TokeiUpdateSecurity

final class DataLoader {
    struct ScriptResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var elapsed: TimeInterval
        var timedOut: Bool
    }

    static var scriptPath: String = {
        let userScript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokei/usage.30s.py").path
        if let bundled = Bundle.main.resourcePath {
            let bundledScript = (bundled as NSString).appendingPathComponent("usage.30s.py")
            if FileManager.default.fileExists(atPath: bundledScript) {
                syncToUserDir(from: bundled)
            }
        }
        return userScript
    }()

    private static func syncToUserDir(from resourceDir: String) {
        let dest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tokei")
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let markerPath = dest.appendingPathComponent("script.version").path
        let bundledTag = Updater.releaseTag
        for name in ["usage.30s.py", "pricing.json", "pricing_overrides.json"] {
            let src = (resourceDir as NSString).appendingPathComponent(name)
            let dst = dest.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: src) else { continue }
            if name == "usage.30s.py" {
                // 只升不降:旧版 app 启动不得用旧脚本覆盖新版脚本
                if FileManager.default.fileExists(atPath: dst),
                   let recorded = try? String(contentsOfFile: markerPath, encoding: .utf8)
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !recorded.isEmpty,
                   UpdateSecurity.isNewerVersion(recorded, than: bundledTag) {
                    continue
                }
                try? FileManager.default.removeItem(atPath: dst)
                try? FileManager.default.copyItem(atPath: src, toPath: dst)
                try? bundledTag.write(toFile: markerPath, atomically: true, encoding: .utf8)
            } else if !FileManager.default.fileExists(atPath: dst) {
                try? FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }
    }

    // 首次全量定位 /usage，之后只检查变化项并复用最近一次有效候选。
    private struct ClaudeCacheRecord {
        let url: URL
        let modified: TimeInterval
        let size: Int

        var signature: String {
            "\(url.path)|\(modified.bitPattern)|\(size)"
        }
    }

    private struct ClaudeQuotaCandidate: Codable, Equatable {
        var path: String
        var modified: TimeInterval
        var size: Int
    }

    private struct ClaudeQuotaSnapshot: Codable, Equatable {
        var q5: Double?
        var q5Reset: Int?
        var q7: Double?
        var q7Reset: Int?
        var qf: Double?
        var qfReset: Int?
        var updated: Int
    }

    private struct ClaudeQuotaState: Codable, Equatable {
        var version = 2
        var candidate: ClaudeQuotaCandidate?
        var snapshot: ClaudeQuotaSnapshot?
        var scanModified: TimeInterval = -1
        var scanBoundary: [String] = []
        var lastFullScan = 0
    }

    private static let claudeQuotaStaleTTL = 30 * 60
    private static let claudeQuotaFullScanInterval = 6 * 60 * 60
    private static let claudeQuotaRetryScanInterval = 5 * 60
    private static let claudeCacheFileLimit = 16 * 1024 * 1024
    private static let zstdMagic = Data([0x28, 0xb5, 0x2f, 0xfd])

    private static var claudeQuotaStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokei/claude_quota_swift_cache.json")
    }

    private static func claudeCacheRecords() -> [ClaudeCacheRecord] {
        let cacheDir: URL
        if let configured = ProcessInfo.processInfo.environment["TOKEI_CLAUDE_CACHE_DIR"],
           !configured.isEmpty {
            cacheDir = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        } else {
            cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            return ClaudeCacheRecord(
                url: url.resolvingSymlinksInPath(),
                modified: modified.timeIntervalSince1970,
                size: size
            )
        }.sorted {
            if $0.modified == $1.modified { return $0.url.path > $1.url.path }
            return $0.modified > $1.modified
        }
    }

    private static func loadClaudeQuotaState() -> ClaudeQuotaState {
        guard let data = try? Data(contentsOf: claudeQuotaStateURL),
              let state = try? JSONDecoder().decode(ClaudeQuotaState.self, from: data),
              state.version == 2 else { return ClaudeQuotaState() }
        return state
    }

    private static func saveClaudeQuotaState(_ state: ClaudeQuotaState) {
        let directory = claudeQuotaStateURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: claudeQuotaStateURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: claudeQuotaStateURL.path
            )
        } catch {
            fputs("Tokei Claude quota cache write failed: \(error)\n", stderr)
        }
    }

    private static func parseClaudeQuota(_ record: ClaudeCacheRecord) -> ClaudeQuotaSnapshot? {
        guard record.size > 0, record.size <= claudeCacheFileLimit,
              let data = try? Data(contentsOf: record.url, options: .mappedIfSafe) else { return nil }
        let organization = Data("organizations/".utf8)
        let usage = Data("/usage".utf8)
        guard data.range(of: organization) != nil,
              data.range(of: usage) != nil,
              let magicRange = data.range(of: zstdMagic) else { return nil }
        let compressed = Data(data[magicRange.lowerBound...])
        guard let decompressed = zstdDecompress(compressed),
              let json = try? JSONSerialization.jsonObject(with: decompressed) as? [String: Any]
        else { return nil }
        let fiveHour = json["five_hour"] as? [String: Any] ?? [:]
        let sevenDay = json["seven_day"] as? [String: Any] ?? [:]
        let fableLimit = (json["limits"] as? [[String: Any]])?.first { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let displayName = model["display_name"] as? String
            else { return false }
            return displayName.caseInsensitiveCompare("Fable") == .orderedSame
        } ?? [:]
        let q5 = (fiveHour["utilization"] as? NSNumber)?.doubleValue
        let q7 = (sevenDay["utilization"] as? NSNumber)?.doubleValue
        let qf = (fableLimit["percent"] as? NSNumber)?.doubleValue
        guard q5 != nil || q7 != nil || qf != nil else { return nil }
        return ClaudeQuotaSnapshot(
            q5: q5,
            q5Reset: isoToEpoch(fiveHour["resets_at"] as? String),
            q7: q7,
            q7Reset: isoToEpoch(sevenDay["resets_at"] as? String),
            qf: qf,
            qfReset: isoToEpoch(fableLimit["resets_at"] as? String),
            updated: Int(record.modified)
        )
    }

    private static func claudeQuotaDictionary(
        _ snapshot: ClaudeQuotaSnapshot,
        now: Int
    ) -> [String: Any] {
        var result: [String: Any] = ["q_updated": snapshot.updated]
        if let q5 = snapshot.q5 { result["q5"] = q5 }
        if let reset = snapshot.q5Reset { result["q5_reset"] = reset }
        if let q7 = snapshot.q7 { result["q7"] = q7 }
        if let reset = snapshot.q7Reset { result["q7_reset"] = reset }
        if let qf = snapshot.qf { result["qf"] = qf }
        if let reset = snapshot.qfReset { result["qf_reset"] = reset }
        let age = now - snapshot.updated
        let invalidSourceTime = snapshot.updated <= 0 || age < -300
        func isQuotaStale(reset: Int?) -> Bool {
            if invalidSourceTime { return true }
            if let reset { return reset <= now }
            return age > claudeQuotaStaleTTL
        }
        result["q5_stale"] = snapshot.q5 != nil && isQuotaStale(reset: snapshot.q5Reset)
        result["q7_stale"] = snapshot.q7 != nil && isQuotaStale(reset: snapshot.q7Reset)
        result["qf_stale"] = snapshot.qf != nil && isQuotaStale(reset: snapshot.qfReset)
        return result
    }

    static func scanClaudeQuota(now: Date = Date()) -> [String: Any]? {
        let nowEpoch = Int(now.timeIntervalSince1970)
        let records = claudeCacheRecords()
        var recordsByPath: [String: ClaudeCacheRecord] = [:]
        for record in records { recordsByPath[record.url.path] = record }
        let original = loadClaudeQuotaState()
        var state = original
        let initialScan = state.scanModified < 0
        let boundary = Set(state.scanBoundary)
        let changed = records.filter {
            $0.modified > state.scanModified ||
                ($0.modified == state.scanModified && !boundary.contains($0.signature))
        }
        var inspected = Set<String>()
        var selected: (ClaudeCacheRecord, ClaudeQuotaSnapshot)?

        func inspect(_ record: ClaudeCacheRecord) -> (ClaudeCacheRecord, ClaudeQuotaSnapshot)? {
            inspected.insert(record.url.path)
            guard let snapshot = parseClaudeQuota(record) else { return nil }
            return (record, snapshot)
        }

        for record in changed {
            if let value = inspect(record) {
                selected = value
                break
            }
        }

        var candidateInvalid = false
        let candidateRecord = state.candidate.flatMap { recordsByPath[$0.path] }
        if selected == nil, let candidate = state.candidate {
            if let record = candidateRecord {
                let changedCandidate = record.modified != candidate.modified || record.size != candidate.size
                if changedCandidate {
                    if !inspected.contains(record.url.path) {
                        selected = inspect(record)
                    }
                    candidateInvalid = selected == nil
                }
            } else {
                candidateInvalid = true
            }
        }

        return finishClaudeQuotaScan(
            records: records,
            original: original,
            state: &state,
            selected: &selected,
            inspected: &inspected,
            candidateInvalid: candidateInvalid,
            initialScan: initialScan,
            nowEpoch: nowEpoch
        )
    }

    private static func finishClaudeQuotaScan(
        records: [ClaudeCacheRecord],
        original: ClaudeQuotaState,
        state: inout ClaudeQuotaState,
        selected: inout (ClaudeCacheRecord, ClaudeQuotaSnapshot)?,
        inspected: inout Set<String>,
        candidateInvalid: Bool,
        initialScan: Bool,
        nowEpoch: Int
    ) -> [String: Any]? {
        if initialScan { state.lastFullScan = nowEpoch }
        let retryInterval = state.snapshot == nil
            ? claudeQuotaRetryScanInterval
            : claudeQuotaFullScanInterval
        let needsFullScan = candidateInvalid || nowEpoch - state.lastFullScan >= retryInterval
        if selected == nil && needsFullScan {
            for record in records where !inspected.contains(record.url.path) {
                inspected.insert(record.url.path)
                if let snapshot = parseClaudeQuota(record) {
                    selected = (record, snapshot)
                    break
                }
            }
            state.lastFullScan = nowEpoch
        }

        if let (record, snapshot) = selected {
            state.candidate = ClaudeQuotaCandidate(
                path: record.url.path,
                modified: record.modified,
                size: record.size
            )
            state.snapshot = snapshot
        } else if candidateInvalid {
            state.candidate = nil
        }

        if let newest = records.first {
            state.scanModified = newest.modified
            state.scanBoundary = records.prefix { $0.modified == newest.modified }.map(\.signature)
        } else {
            state.scanModified = 0
            state.scanBoundary = []
        }
        if state != original { saveClaudeQuotaState(state) }
        guard let snapshot = state.snapshot else { return nil }
        return claudeQuotaDictionary(snapshot, now: nowEpoch)
    }

    private static func zstdDecompress(_ src: Data) -> Data? {
        let bufSize = src.count
        let frameSize = src.withUnsafeBytes { ptr -> Int in
            ZSTD_findFrameCompressedSize(ptr.baseAddress, bufSize)
        }
        guard ZSTD_isError(frameSize) == 0 else { return nil }
        let bound = src.withUnsafeBytes { ptr -> UInt64 in
            ZSTD_getFrameContentSize(ptr.baseAddress, frameSize)
        }
        let dstSize = (bound == ZSTD_CONTENTSIZE_ERROR || bound == ZSTD_CONTENTSIZE_UNKNOWN)
            ? max(frameSize * 20, 4096)
            : Int(bound)
        var dst = [UInt8](repeating: 0, count: dstSize)
        let ret = src.withUnsafeBytes { srcPtr -> Int in
            ZSTD_decompress(&dst, dstSize, srcPtr.baseAddress, frameSize)
        }
        guard ZSTD_isError(ret) == 0 else { return nil }
        return Data(dst.prefix(ret))
    }

    private static func isoToEpoch(_ s: String?) -> Int? {
        guard let s = s else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return Int(d.timeIntervalSince1970) }
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: s) { return Int(d.timeIntervalSince1970) }
        return nil
    }

    static func loadSync() -> Usage? { runScript() }

    static func load(_ completion: @escaping (Usage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let usage = runScript()
            DispatchQueue.main.async { completion(usage) }
        }
    }

    static func runScript(args: [String] = ["--json", "--no-sync-snapshot"]) -> Usage? {
        let result = runScriptRaw(args: args, timeout: 90)
        guard !result.timedOut, result.exitCode == 0 else {
            fputs("Tokei script failed: exit=\(result.exitCode) timeout=\(result.timedOut)\n\(result.stderr)\n", stderr)
            return nil
        }
        let data = Data(result.stdout.utf8)
        do {
            guard var raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for key in raw.keys where key.hasPrefix("_") { raw.removeValue(forKey: key) }
            if var claude = raw["claude"] as? [String: Any] {
                let scriptHasQuota = numberValue(claude["q5"]) != nil ||
                    numberValue(claude["q7"]) != nil ||
                    numberValue(claude["qf"]) != nil
                let scriptUpdated = intValue(claude["q_updated"]) ?? 0
                if let nativeQuota = scanClaudeQuota() {
                    let nativeHasQuota = numberValue(nativeQuota["q5"]) != nil ||
                        numberValue(nativeQuota["q7"]) != nil ||
                        numberValue(nativeQuota["qf"]) != nil
                    let nativeUpdated = intValue(nativeQuota["q_updated"]) ?? 0
                    if nativeHasQuota && (!scriptHasQuota || nativeUpdated >= scriptUpdated) {
                        for key in [
                            "q5", "q5_reset", "q7", "q7_reset", "qf", "qf_reset",
                            "q_updated", "q5_stale", "q7_stale", "qf_stale",
                        ] {
                            if let value = nativeQuota[key] {
                                claude[key] = value
                            } else {
                                claude.removeValue(forKey: key)
                            }
                        }
                    }
                }
                normalizeClaudeQuota(&claude)
                raw["claude"] = claude
            }
            let cleaned = try JSONSerialization.data(withJSONObject: raw)
            return try JSONDecoder().decode(Usage.self, from: cleaned)
        } catch {
            fputs("Tokei decode error: \(error)\n", stderr)
            return nil
        }
    }

    private static func numberValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func normalizeClaudeQuota(_ claude: inout [String: Any]) {
        let now = Int(Date().timeIntervalSince1970)
        let updated = intValue(claude["q_updated"]) ?? 0
        let age = now - updated
        let invalidSourceTime = updated <= 0 || age < -300
        for (valueKey, resetKey, staleKey) in [
            ("q5", "q5_reset", "q5_stale"),
            ("q7", "q7_reset", "q7_stale"),
            ("qf", "qf_reset", "qf_stale"),
        ] {
            guard numberValue(claude[valueKey]) != nil else {
                claude.removeValue(forKey: staleKey)
                continue
            }
            if invalidSourceTime {
                claude[staleKey] = true
            } else if let reset = intValue(claude[resetKey]) {
                claude[staleKey] = reset <= now
            } else {
                claude[staleKey] = age > claudeQuotaStaleTTL
            }
        }
    }

    static func writeSyncSnapshot(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = runScriptRaw(args: ["--write-sync"], timeout: 120)
            let ok = !result.timedOut && result.exitCode == 0
            if !ok {
                fputs("Tokei sync snapshot failed: exit=\(result.exitCode) timeout=\(result.timedOut)\n\(result.stderr)\n", stderr)
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private static let pythonPath: String = {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "/usr/bin/env"
    }()

    private static let syncSnapshotPython = """
    import importlib.util
    import sys

    script_path, device_id, sync_dir = sys.argv[1:4]
    spec = importlib.util.spec_from_file_location("tokei_usage_sync", script_path)
    if spec is None or spec.loader is None:
        raise SystemExit(1)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module._load_tokei_config = lambda: {
        "device_id": device_id,
        "sync_dir": sync_dir,
    }
    raise SystemExit(module.write_sync_snapshot())
    """

    static func syncSnapshotCommand(deviceID: String, syncDir: String) -> SyncCommand {
        if pythonPath == "/usr/bin/env" {
            return SyncCommand(
                executable: "/usr/bin/env",
                arguments: ["python3", "-c", syncSnapshotPython, scriptPath, deviceID, syncDir],
                supervisorExecutable: "/usr/bin/env",
                supervisorArguments: ["python3"]
            )
        }
        return SyncCommand(
            executable: pythonPath,
            arguments: ["-c", syncSnapshotPython, scriptPath, deviceID, syncDir],
            supervisorExecutable: pythonPath
        )
    }

    static func runScriptRaw(args: [String] = ["--json", "--no-sync-snapshot"], timeout: TimeInterval = 8) -> ScriptResult {
        let proc = Process()
        if pythonPath == "/usr/bin/env" {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", scriptPath] + args
        } else {
            proc.executableURL = URL(fileURLWithPath: pythonPath)
            proc.arguments = [scriptPath] + args
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let started = Date()
        do {
            try proc.run()
        } catch {
            return ScriptResult(stdout: "", stderr: error.localizedDescription, exitCode: -1,
                                elapsed: Date().timeIntervalSince(started), timedOut: false)
        }

        var timedOut = false
        let killer = DispatchWorkItem {
            if proc.isRunning {
                timedOut = true
                proc.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()

        return ScriptResult(stdout: String(data: outData, encoding: .utf8) ?? "",
                            stderr: String(data: errData, encoding: .utf8) ?? "",
                            exitCode: proc.terminationStatus,
                            elapsed: Date().timeIntervalSince(started),
                            timedOut: timedOut)
    }
}

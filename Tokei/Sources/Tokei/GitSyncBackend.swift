import Foundation

/// 基于 Git 仓库的同步后端。
///
/// 这里的实现是从 `SyncManager` 原样搬过来的，行为没有任何改动。
/// 之所以要把它挪到协议后面，是因为 Git 传输本身很重：为了应付多台设备
/// 往同一分支推送而互相顶掉，需要抢锁、变基、审计变基结果、失败重试，
/// 这些逻辑占了原文件的大半。把它隔离出来之后，新增别的传输方式就不必
/// 再理解或改动这一整套。
///
/// 注意：同步目录里的文件布局与后端无关，`SyncManager.loadPeers()` 只认
/// 目录下的 `<设备名>.json`。任何后端只要把文件放到那里即可。
struct GitSyncBackend: SyncBackend {
    let identifier = "git"

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func transactionScript(snapshotCommand: SyncCommand, deviceID: String) -> String {
        let snapshot = ([snapshotCommand.executable] + snapshotCommand.arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        let quotedDevice = Self.shellQuote(deviceID)
        return """
        set -u
        set -o pipefail

        fail() {
          code="$1"
          shift
          printf 'Tokei sync error: %s\\n' "$*" >&2
          exit "$code"
        }

        sync_git() {
          /usr/bin/git \
            -c core.hooksPath=/dev/null \
            -c core.fsmonitor=false \
            -c commit.gpgSign=false \
            -c rebase.updateRefs=false \
            -c rebase.autoStash=false \
            -c push.gpgSign=false \
            -c push.followTags=false \
            -c remote.origin.mirror=false \
            "$@"
        }

        git_dir=$(sync_git rev-parse --absolute-git-dir 2>/dev/null) \
          || fail 20 "同步目录不是有效的 Git 仓库"
        declared_root=$(sync_git rev-parse --show-toplevel 2>/dev/null) \
          || fail 20 "无法读取同步仓库工作树"
        declared_root=$(cd -- "$declared_root" 2>/dev/null && /bin/pwd -P) \
          || fail 20 "无法解析同步仓库工作树"
        current_root=$(/bin/pwd -P)
        [ "$declared_root" = "$current_root" ] \
          || fail 20 "同步仓库 core.worktree 指向其他目录，已停止"
        marker="$git_dir/tokei-sync-rebase"
        rebase_merge="$git_dir/rebase-merge"
        rebase_apply="$git_dir/rebase-apply"
        audit_commits="$git_dir/tokei-sync-audit.$$"
        device_id=\(quotedDevice)
        device_pathspec=":(icase,literal)$device_id.json"
        exclude_pathspec=":(exclude,icase,literal)$device_id.json"
        junk_pathspec=":(exclude,icase)*.ds_store"
        peer_json_pathspec=":(top,glob)*.json"

        cleanup_temporary_files() {
          /bin/rm -f "$audit_commits"
        }
        trap cleanup_temporary_files EXIT

        validate_marker() {
          [ -f "$marker" ] || return 1
          [ "$(/usr/bin/sed -n '1p' "$marker" 2>/dev/null)" = "tokei-sync-rebase-v2" ] || return 1
          [ "$(/usr/bin/sed -n '2p' "$marker" 2>/dev/null)" = "refs/heads/main" ] || return 1
          [ "$(/usr/bin/sed -n '4p' "$marker" 2>/dev/null)" = "origin/main" ] || return 1
          marker_onto=$(/usr/bin/sed -n '5p' "$marker" 2>/dev/null)
          case "$marker_onto" in
            ''|*[!0-9a-f]*) return 1 ;;
          esac
          [ "${#marker_onto}" -eq 40 ] || [ "${#marker_onto}" -eq 64 ] || return 1
        }

        if [ -d "$rebase_merge" ] || [ -d "$rebase_apply" ]; then
          if validate_marker; then
            fail 21 "检测到上次 Tokei 遗留的 rebase，已保留现场且禁止跨进程自动 abort"
          fi
          fail 21 "检测到未完成的外部 rebase，已停止且未改动仓库"
        elif [ -f "$marker" ]; then
          validate_marker || fail 21 "发现格式异常的 Tokei rebase 标记，已停止"
          current_branch=$(sync_git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
          [ "$current_branch" = "main" ] \
            || fail 21 "发现遗留 rebase 标记且当前分支异常，已停止"
          /bin/rm -f "$marker"
        fi

        for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_START; do
          operation_path=$(sync_git rev-parse --git-path "$operation")
          [ ! -e "$operation_path" ] \
            || fail 21 "检测到未完成的 $operation，已停止且未改动仓库"
        done
        sequencer_path=$(sync_git rev-parse --git-path sequencer)
        [ ! -d "$sequencer_path" ] \
          || fail 21 "检测到未完成的 Git sequencer 操作，已停止且未改动仓库"
        unmerged_state=$(sync_git ls-files -u) \
          || fail 21 "无法检查同步仓库的冲突状态"
        [ -z "$unmerged_state" ] \
          || fail 21 "同步仓库含有未解决冲突，已停止且未改动仓库"

        branch=$(sync_git symbolic-ref --quiet --short HEAD 2>/dev/null) \
          || fail 22 "同步仓库处于 detached HEAD，已停止"
        [ "$branch" = "main" ] || fail 22 "同步仓库必须位于 main 分支，当前为 $branch"

        sync_git remote get-url origin >/dev/null 2>&1 \
          || fail 20 "同步仓库缺少 origin 远端"
        sync_git fetch origin main || fail 25 "拉取 origin/main 失败"
        sync_git show-ref --verify --quiet refs/remotes/origin/main \
          || fail 25 "origin/main 不存在"
        tracked_peer_files=$(sync_git ls-files --cached -- \
          "$peer_json_pathspec" "$exclude_pathspec") \
          || fail 23 "无法枚举其他设备快照"
        if [ -n "$tracked_peer_files" ]; then
          sync_git restore --source=HEAD --staged --worktree -- \
            "$peer_json_pathspec" "$exclude_pathspec" \
            || fail 23 "无法恢复其他设备快照"
        fi
        other_changes=$(sync_git status --porcelain=v1 --untracked-files=all \
          -- . "$exclude_pathspec" "$junk_pathspec") \
          || fail 23 "无法检查同步仓库的工作区状态"
        [ -z "$other_changes" ] \
          || fail 23 "同步仓库包含本机快照以外的未提交改动"

        audit_local_history() {
          audit_base="$1"
          audit_head="$2"
          sync_git rev-list --reverse "$audit_base..$audit_head" > "$audit_commits" \
            || fail 23 "无法读取本地待推送提交"
          while IFS= read -r commit; do
            [ -n "$commit" ] || continue
            parent_count=$(sync_git rev-list --parents -n 1 "$commit" \
              | /usr/bin/awk '{ print NF - 1 }') \
              || fail 23 "无法检查本地提交 $commit"
            [ "$parent_count" -eq 1 ] \
              || fail 23 "本地待推送历史包含 merge 或根提交，已停止"
            own_history_changes=$(sync_git diff-tree --no-commit-id --name-only -r \
              "$commit" -- "$device_pathspec") \
              || fail 23 "无法检查本地提交 $commit 的本机快照"
            [ -n "$own_history_changes" ] \
              || fail 23 "本地待推送提交未修改本机快照，已停止"
            other_history_changes=$(sync_git diff-tree --no-commit-id --name-only -r \
              "$commit" -- . "$exclude_pathspec") \
              || fail 23 "无法检查本地提交 $commit 的文件范围"
            [ -z "$other_history_changes" ] \
              || fail 23 "本地待推送提交修改了其他设备数据，已停止"
          done < "$audit_commits"
          /bin/rm -f "$audit_commits"
        }

        pre_snapshot_base=$(sync_git rev-parse origin/main) \
          || fail 23 "无法固定快照前远端提交"
        pre_snapshot_head=$(sync_git rev-parse HEAD) \
          || fail 23 "无法固定快照前本地提交"
        audit_local_history "$pre_snapshot_base" "$pre_snapshot_head"
        verified_pre_snapshot_head=$(sync_git rev-parse HEAD 2>/dev/null || true)
        [ "$verified_pre_snapshot_head" = "$pre_snapshot_head" ] \
          || fail 23 "历史审计期间 HEAD 发生变化，已停止"

        \(snapshot) || fail 24 "生成本机数据快照失败"

        matches=$(sync_git ls-files --cached --others --exclude-standard -- "$device_pathspec")
        match_count=$(printf '%s\\n' "$matches" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
        [ "$match_count" -eq 1 ] \
          || fail 24 "本机设备快照缺失或存在大小写重名文件"

        other_changes=$(sync_git status --porcelain=v1 --untracked-files=all \
          -- . "$exclude_pathspec" "$junk_pathspec") \
          || fail 23 "无法检查生成快照后的工作区状态"
        [ -z "$other_changes" ] \
          || fail 23 "生成快照时检测到其他文件被修改"

        sync_git add -- "$device_pathspec" || fail 26 "暂存本机快照失败"
        if ! sync_git diff --cached --quiet -- "$device_pathspec"; then
          sync_git commit --no-gpg-sign --only -m "tokei sync $device_id" -- "$device_pathspec" \
            || fail 26 "提交本机快照失败"
        fi
        post_commit_changes=$(sync_git status --porcelain=v1 --untracked-files=all \
          -- . "$junk_pathspec") \
          || fail 23 "无法检查提交后的工作区状态"
        [ -z "$post_commit_changes" ] \
          || fail 23 "提交后工作区仍有改动，已停止"

        write_marker() {
          marker_head="$1"
          marker_onto="$2"
          marker_tmp="$marker.tmp.$$"
          umask 077
          {
            printf 'tokei-sync-rebase-v2\\n'
            printf 'refs/heads/main\\n'
            printf '%s\\n' "$marker_head"
            printf 'origin/main\\n'
            printf '%s\\n' "$marker_onto"
            printf 'pid=%s\\n' "$$"
            /bin/date -u '+started_at=%Y-%m-%dT%H:%M:%SZ'
          } > "$marker_tmp" || fail 28 "无法写入 rebase 恢复标记"
          /bin/mv -f "$marker_tmp" "$marker" || fail 28 "无法保存 rebase 恢复标记"
        }

        rebase_onto_origin() {
          if sync_git merge-base --is-ancestor origin/main HEAD; then
            return 0
          fi
          pre_rebase_head=$(sync_git rev-parse HEAD) \
            || fail 27 "无法读取 rebase 前提交"
          pre_rebase_onto=$(sync_git rev-parse origin/main) \
            || fail 27 "无法读取 rebase 目标提交"
          write_marker "$pre_rebase_head" "$pre_rebase_onto"
          if sync_git rebase --merge origin/main; then
            /bin/rm -f "$marker"
            return 0
          fi
          if [ -d "$rebase_merge" ] || [ -d "$rebase_apply" ]; then
            fail 27 "rebase 未完成，已保留现场且禁止自动 abort，请人工检查同步仓库"
          fi
          /bin/rm -f "$marker"
          fail 27 "本机快照无法安全 rebase 到 origin/main"
        }

        attempt=1
        while [ "$attempt" -le 3 ]; do
          rebase_onto_origin
          audit_base=$(sync_git rev-parse origin/main) \
            || fail 23 "无法固定审计基线"
          candidate_head=$(sync_git rev-parse HEAD) \
            || fail 23 "无法固定待审计的本地提交"
          audit_local_history "$audit_base" "$candidate_head"
          verified_candidate_head=$(sync_git rev-parse HEAD 2>/dev/null || true)
          [ "$verified_candidate_head" = "$candidate_head" ] \
            || fail 23 "历史审计期间 HEAD 发生变化，已停止"
          audited_head="$candidate_head"
          audited_branch=$(sync_git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
          [ "$audited_branch" = "main" ] \
            || fail 23 "审计后 main 分支发生变化，已停止"
          push_changes=$(sync_git status --porcelain=v1 --untracked-files=all) \
            || fail 23 "无法检查 push 前的工作区状态"
          [ -z "$push_changes" ] \
            || fail 23 "push 前工作区出现改动，已停止"
          current_head=$(sync_git rev-parse HEAD) \
            || fail 23 "无法复核 push 前提交"
          [ "$current_head" = "$audited_head" ] \
            || fail 23 "审计后 HEAD 发生变化，已停止"
          if sync_git push origin "${audited_head}:refs/heads/main"; then
            pushed_head=$(sync_git rev-parse HEAD 2>/dev/null || true)
            [ "$pushed_head" = "$audited_head" ] \
              || fail 23 "push 期间 HEAD 发生变化，请检查外部 Git 操作"
            printf '多设备同步完成\\n'
            exit 0
          fi

          sync_git fetch origin main || fail 25 "push 失败后重新拉取 origin/main 失败"
          retry_head=$(sync_git rev-parse HEAD 2>/dev/null || true)
          [ "$retry_head" = "$audited_head" ] \
            || fail 23 "push 重试前 HEAD 发生变化，已停止"
          if sync_git merge-base --is-ancestor "$audited_head" origin/main; then
            printf '远端已包含本机同步提交\\n'
            exit 0
          fi
          if sync_git merge-base --is-ancestor origin/main "$audited_head"; then
            fail 29 "远端没有竞争更新，push 仍失败，请检查认证或分支权限"
          fi
          [ "$attempt" -lt 3 ] || fail 29 "远端持续更新，三次同步重试均失败"
          /bin/sleep "$attempt"
          attempt=$((attempt + 1))
          printf '检测到其他设备同时更新，正在重试 %s/3\\n' "$attempt"
        done

        fail 29 "push 失败"
        """
    }

    private static let transactionSupervisorScript = """
    import errno
    import fcntl
    import os
    import signal
    import subprocess
    import sys
    import time

    lock_path = sys.argv[1]
    timeout = float(sys.argv[2])
    command = sys.argv[3:]
    lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno in (errno.EACCES, errno.EAGAIN):
            print("Tokei sync busy: another transaction holds the repository lock", file=sys.stderr)
            raise SystemExit(75)
        raise

    process = None

    def process_group_exists():
        if process is None:
            return False
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def stop_process_group():
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 3
        while process_group_exists() and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
        if process_group_exists():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while process_group_exists() and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.05)
        if process.poll() is None:
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass

    def handle_signal(signum, _frame):
        print(f"Tokei sync error: supervisor received signal {signum}", file=sys.stderr)
        stop_process_group()
        raise SystemExit(30)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    process = subprocess.Popen(
        command,
        start_new_session=True,
        pass_fds=(lock_fd,),
    )
    try:
        raise SystemExit(process.wait(timeout=timeout))
    except subprocess.TimeoutExpired:
        print(f"Tokei sync error: transaction timed out after {int(timeout)} seconds", file=sys.stderr)
        stop_process_group()
        raise SystemExit(30)
    """

    private static func resultCode(for status: Int32) -> SyncCode {
        switch status {
        case 0: return .success
        case 20: return .invalidRepository
        case 21: return .foreignOperation
        case 22: return .detachedHead
        case 23: return .dirtyRepository
        case 24: return .snapshotFailed
        case 25: return .fetchFailed
        case 26: return .commitFailed
        case 27: return .rebaseFailed
        case 28: return .recoveryFailed
        case 29: return .pushFailed
        case 30: return .timedOut
        case 75: return .busy
        default: return .unknown
        }
    }

    func synchronize(config cfg: SyncConfig,
                     snapshotCommand: SyncCommand,
                     completion: @escaping (SyncResult) -> Void) {
        guard let deviceID = SyncManager.validDeviceID(cfg.device_id) else {
            completion(SyncResult(code: .invalidConfiguration, output: "设备名不合法"))
            return
        }
        let dir = SyncManager.resolvedSyncDir(cfg)
        let gitDirectory = (dir as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            completion(SyncResult(
                code: .invalidRepository,
                output: "同步目录不是普通 Git 仓库：\(dir)"
            ))
            return
        }
        let lockPath = (gitDirectory as NSString).appendingPathComponent("tokei-sync.lock")
        let script = Self.transactionScript(snapshotCommand: snapshotCommand, deviceID: deviceID)
        let transactionTimeout = String(Int(max(1, min(snapshotCommand.transactionTimeout, 3600))))
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            let outputPipe = Pipe()
            if let supervisorExecutable = snapshotCommand.supervisorExecutable {
                proc.executableURL = URL(fileURLWithPath: supervisorExecutable)
                proc.arguments = snapshotCommand.supervisorArguments + [
                    "-c", Self.transactionSupervisorScript,
                    lockPath, transactionTimeout, "/bin/zsh", "-f", "-c", script,
                ]
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
                proc.arguments = ["-k", "-t", "0", lockPath, "/bin/zsh", "-f", "-c", script]
            }
            proc.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
            proc.standardOutput = outputPipe
            proc.standardError = outputPipe
            proc.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            let redirectedGitEnvironmentKeys = [
                "GIT_DIR",
                "GIT_WORK_TREE",
                "GIT_COMMON_DIR",
                "GIT_INDEX_FILE",
                "GIT_OBJECT_DIRECTORY",
                "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                "GIT_NAMESPACE",
                "GIT_PREFIX",
                "GIT_EXEC_PATH",
                "GIT_SHALLOW_FILE",
                "GIT_GRAFT_FILE",
                "GIT_QUARANTINE_PATH",
                "GIT_CEILING_DIRECTORIES",
                "GIT_DISCOVERY_ACROSS_FILESYSTEM",
                "GIT_CONFIG",
                "GIT_CONFIG_GLOBAL",
                "GIT_CONFIG_SYSTEM",
                "GIT_CONFIG_NOSYSTEM",
                "GIT_CONFIG_PARAMETERS",
                "GIT_ASKPASS",
                "SSH_ASKPASS",
                "GIT_SSH_VARIANT",
                "ZDOTDIR",
            ]
            for key in redirectedGitEnvironmentKeys {
                environment.removeValue(forKey: key)
            }
            for key in Array(environment.keys)
                where key == "GIT_CONFIG_COUNT"
                    || key.hasPrefix("GIT_CONFIG_KEY_")
                    || key.hasPrefix("GIT_CONFIG_VALUE_") {
                environment.removeValue(forKey: key)
            }
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_ASKPASS"] = "/usr/bin/false"
            environment["SSH_ASKPASS"] = "/usr/bin/false"
            environment["GCM_INTERACTIVE"] = "Never"
            environment["GIT_EDITOR"] = "true"
            environment["GIT_SEQUENCE_EDITOR"] = "true"
            environment["GIT_NO_REPLACE_OBJECTS"] = "1"
            environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=2 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
            environment["GIT_SSH_VARIANT"] = "ssh"
            environment["SSH_ASKPASS_REQUIRE"] = "never"
            proc.environment = environment
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async {
                    completion(SyncResult(code: .unknown, output: error.localizedDescription))
                }
                return
            }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = Self.resultCode(for: proc.terminationStatus)
            let fallback: String
            switch code {
            case .success: fallback = "GitHub 已同步"
            case .busy: fallback = "另一同步任务正在运行"
            default: fallback = "同步失败，退出码 \(proc.terminationStatus)"
            }
            let result = SyncResult(
                code: code,
                output: output.isEmpty ? fallback : output
            )
            DispatchQueue.main.async { completion(result) }
        }
    }
}

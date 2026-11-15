import Foundation
import AppKit

/// 只读展示用:折叠进父卡片的后台任务摘要(名称/status/jobId)。
struct BackgroundTaskInfo: Identifiable, Hashable {
    let jobId: String
    let name: String?
    let status: String?
    var id: String { jobId }
    var displayName: String { name ?? AppL10n.tr("后台任务") }
}

struct ClaudeCodeSession: Identifiable, Hashable {
    let id: String          // sessionId
    let pid: Int
    let cwd: String
    let name: String?
    let entrypoint: String  // "cli" or "claude-vscode"
    let startedAt: Date
    var tty: String?
    var hostApp: String?    // e.g. "/Applications/Ghostty.app"
    var isAlive: Bool = true
    var kind: String = "interactive"          // "interactive" | "bg"
    var jobId: String? = nil
    var parentSessionId: String? = nil
    var backgroundTasks: [BackgroundTaskInfo] = []
    var isBackgroundOrphan: Bool = false       // bg 但找不到父 → 顶层保留、禁直通

    var displayName: String {
        if let name { return name }
        let dir = (cwd as NSString).lastPathComponent
        let app = hostAppName ?? entrypoint
        return "\(dir) (\(app))"
    }

    var hostAppName: String? {
        guard let hostApp else { return nil }
        return ((hostApp as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ClaudeCodeSession, rhs: ClaudeCodeSession) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ClaudeCodeSessionManager: ObservableObject {
    @Published var sessions: [ClaudeCodeSession] = []

    private var timer: Timer?
    private let sessionsDir = NSHomeDirectory() + "/.claude/sessions"

    // Cache: pid -> hostApp path (avoid repeated ps forks)
    private var hostAppCache: [Int: String] = [:]

    /// REQ-022:日志路径标准化。开发机(旧目录存在)沿用原路径,工具链/文档不变;
    /// 其他机器落 ~/Library/Logs/QuickVibeHost/(建中间目录,消灭"目录不存在 →
    /// createFile 静默失败 → 全部文件日志丢失"的老问题,BUG-003 排障教训)。
    nonisolated static let logFile: String = {
        let legacyDir = NSHomeDirectory() + "/Documents/Projects/VibeEverything"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacyDir, isDirectory: &isDir), isDir.boolValue {
            return legacyDir + "/quickvibe.log"
        }
        let dir = NSHomeDirectory() + "/Library/Logs/QuickVibeHost"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/quickvibe.log"
    }()

    /// REQ-022:轮转上限。超过后当前文件挪到 .1(覆盖旧 .1),磁盘占用有界(~2×10MB),
    /// 因此常驻开启、不设开关(评估结论见 REQ-022 文档)。
    nonisolated private static let logMaxBytes = 10_000_000
    nonisolated private static let logLock = NSLock()

    nonisolated static func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        logLock.lock()
        defer { logLock.unlock() }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile),
           let size = attrs[.size] as? Int, size > logMaxBytes {
            try? FileManager.default.removeItem(atPath: logFile + ".1")
            try? FileManager.default.moveItem(atPath: logFile, toPath: logFile + ".1")
        }
        if let fh = FileHandle(forWritingAtPath: logFile) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logFile, contents: line.data(using: .utf8))
        }
    }

    var activeSession: ClaudeCodeSession? {
        sessions
            .filter { $0.isAlive && $0.tty != nil && $0.tty != "??" }
            .sorted { $0.startedAt > $1.startedAt }
            .first
            ?? sessions.filter(\.isAlive).sorted { $0.startedAt > $1.startedAt }.first
    }

    func startPolling() {
        refreshAsync()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshAsync() {
        let dir = sessionsDir
        let cache = hostAppCache
        let oldIDs = Set(sessions.map(\.id))
        DispatchQueue.global(qos: .utility).async {
            let result = Self.doRefresh(sessionsDir: dir, hostAppCache: cache)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let newIDs = Set(result.sessions.map(\.id))
                if newIDs != oldIDs {
                    Self.log("[refreshAsync] Sessions changed: \(result.sessions.map { "\($0.displayName) pid=\($0.pid)" })")
                }
                self.sessions = result.sessions
                self.hostAppCache = result.cache
            }
        }
    }

    nonisolated private static func doRefresh(sessionsDir: String, hostAppCache: [Int: String]) -> (sessions: [ClaudeCodeSession], cache: [Int: String]) {
        reapDeadVibeptySidecars()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
            log("[doRefresh] Cannot list directory: \(sessionsDir)")
            return ([], hostAppCache)
        }

        // Read session files and check alive (no subprocess needed)
        var entries: [(pid: Int, sessionId: String, cwd: String, name: String?, entrypoint: String, startedAt: Double, kind: String, jobId: String?, parentSessionId: String?)] = []
        for file in files where file.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String else { continue }

            if kill(Int32(pid), 0) != 0 {
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            if isUnstartedBackgroundSession(json) {
                log("[doRefresh] hide unstarted bg session pid=\(pid) file=\(file)")
                continue
            }

            entries.append((pid, sessionId, json["cwd"] as? String ?? "", json["name"] as? String, json["entrypoint"] as? String ?? "unknown", json["startedAt"] as? Double ?? 0, json["kind"] as? String ?? "interactive", json["jobId"] as? String, json["parentSessionId"] as? String))
        }

        guard !entries.isEmpty else { return ([], hostAppCache) }

        let pids = entries.map(\.pid)

        // Single ps call for TTY
        let ttyMap = batchPS(args: ["-o", "pid=,tty=", "-p", pids.map(String.init).joined(separator: ",")])

        // Single ps call for process tree (only if we need host apps)
        var newCache = hostAppCache
        let uncachedPids = pids.filter { hostAppCache[$0] == nil }
        if !uncachedPids.isEmpty {
            let processTree = buildProcessTree()
            for pid in uncachedPids {
                if let app = findHostAppFromTree(pid: pid, tree: processTree) {
                    newCache[pid] = app
                    log("[doRefresh] pid=\(pid) hostApp=\(app)")
                }
            }
        }

        var found: [ClaudeCodeSession] = []
        for e in entries {
            var session = ClaudeCodeSession(
                id: e.sessionId, pid: e.pid, cwd: e.cwd, name: e.name,
                entrypoint: e.entrypoint,
                startedAt: Date(timeIntervalSince1970: e.startedAt / 1000),
                isAlive: true,
                kind: e.kind, jobId: e.jobId, parentSessionId: e.parentSessionId
            )
            session.tty = ttyMap[e.pid]
            session.hostApp = newCache[e.pid]
            found.append(session)
        }

        let folded = foldBackgroundSessions(found, entries: entries)
        return (folded.sorted { $0.startedAt > $1.startedAt }, newCache)
    }

    /// 分流归并:kind=="bg" 归入父会话 backgroundTasks(不进顶层);
    /// 找不到父的孤儿 bg 保留顶层并标 isBackgroundOrphan(禁直通)。
    /// 纯函数(除 argv 回落读),便于 §4.2 单测。
    nonisolated static func foldBackgroundSessions(
        _ sessions: [ClaudeCodeSession],
        entries: [(pid: Int, sessionId: String, cwd: String, name: String?, entrypoint: String, startedAt: Double, kind: String, jobId: String?, parentSessionId: String?)]
    ) -> [ClaudeCodeSession] {
        let bg = sessions.filter { $0.kind == "bg" }
        guard !bg.isEmpty else { return sessions }
        var top = sessions.filter { $0.kind != "bg" }
        var indexById: [String: Int] = [:]
        for (i, s) in top.enumerated() { indexById[s.id] = i }

        for child in bg {
            // 优先 JSON parentSessionId,读不到回落 argv parse --resume
            let parentId = child.parentSessionId ?? parseParentFromArgv(pid: child.pid)
            if let pid = parentId, let idx = indexById[pid] {
                top[idx].backgroundTasks.append(
                    BackgroundTaskInfo(jobId: child.jobId ?? child.id, name: child.name, status: nil))
            } else {
                var orphan = child
                orphan.isBackgroundOrphan = true
                top.append(orphan)
            }
        }
        return top
    }

    /// `ps -p <pid> -o args=` → parse `--resume …/<uuid>.jsonl` 尾部 uuid。
    /// 失败(格式变化/进程没了)返回 nil → 上层按孤儿处理(不崩不丢,task §7 风险 1)。
    nonisolated private static func parseParentFromArgv(pid: Int) -> String? {
        let args = batchPS(args: ["-o", "args=", "-p", "\(pid)"])
        guard let argv = args[pid] else { return nil }
        // 匹配 --resume 后紧跟(或 = 连接)的路径,取 .jsonl 前的 36 位 uuid
        let pattern = #"--resume[=\s]+\S*?([0-9a-fA-F-]{36})\.jsonl"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: argv, range: NSRange(argv.startIndex..., in: argv)),
              let r = Range(m.range(at: 1), in: argv) else { return nil }
        return String(argv[r])
    }

    /// Claude Code daemon can leave claimed bg spares with a session file but no task.
    /// They are not user-interactive sessions and should not seed UI rows.
    nonisolated private static func isUnstartedBackgroundSession(_ json: [String: Any]) -> Bool {
        guard (json["kind"] as? String) == "bg",
              (json["agent"] as? String) == "claude",
              (json["status"] as? String) == "idle",
              let startedAt = timestampMilliseconds(json["startedAt"]),
              let statusUpdatedAt = timestampMilliseconds(json["statusUpdatedAt"]) else {
            return false
        }
        return startedAt == statusUpdatedAt
    }

    nonisolated private static func timestampMilliseconds(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String, let n = Double(s) { return n }
        return nil
    }

    /// 通用僵尸清理:/tmp/vibepty-*.json 中 pid 已死的,连同同 pid 的 .sock 一起删。
    /// 不按 cmd 过滤(claude sidecar 残留原本无路径可清)。铁律 5:kill(pid,0) 存活即保留,
    /// 宁漏删不误删(误删存活 socket = 砍掉用户正在用的注入通道)。
    nonisolated private static func reapDeadVibeptySidecars() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for name in names where name.hasPrefix("vibepty-") && name.hasSuffix(".json") {
            let jsonPath = "/tmp/" + name
            guard let data = fm.contents(atPath: jsonPath),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let pid = (obj["pid"] as? Int) ?? (obj["pid"] as? Double).map(Int.init)
            guard let pid, kill(Int32(pid), 0) != 0 else { continue }   // 无 pid 或存活 → 不动
            try? fm.removeItem(atPath: jsonPath)
            try? fm.removeItem(atPath: "/tmp/vibepty-\(pid).sock")
        }
    }

    /// Single ps call, returns pid -> value map
    nonisolated private static func batchPS(args: [String]) -> [Int: String] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        var result: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count >= 2, let pid = Int(parts[0]) {
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if val != "??" { result[pid] = val }
            }
        }
        return result
    }

    /// 任意 pid 的宿主终端 App 解析(REQ-020 追加:codex 会话「打开窗口」用)。
    /// 即时构建进程树走祖先链;点击触发的一次性调用,两次 ps 的开销可接受。
    nonisolated static func resolveHostApp(forPid pid: Int) -> String? {
        findHostAppFromTree(pid: pid, tree: buildProcessTree())
    }

    nonisolated private static func buildProcessTree() -> (ppid: [Int: Int], comm: [Int: String]) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=,ppid=,comm=", "-ax"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        var ppidMap: [Int: Int] = [:]
        var commMap: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 2, whereSeparator: \.isWhitespace)
            if parts.count >= 3, let p = Int(parts[0]), let pp = Int(parts[1]) {
                ppidMap[p] = pp
                commMap[p] = String(parts[2])
            }
        }
        return (ppidMap, commMap)
    }

    /// 自下而上走完整条祖先链,取**最高层**的 /Applications/*.app 匹配,不能在第一个匹配就返回:
    /// 中间层可能命中别的 app 附带的运行时(实例:Obsidian 终端插件用 Xcode 自带
    /// Python3.framework 的 Python.app 起 pty,首个匹配会错判宿主为 Xcode.app;
    /// 真宿主 Obsidian Helper (Renderer) 在链条更上方)。截 comm 首个 ".app" 即最外层 bundle。
    nonisolated private static func findHostAppFromTree(pid: Int, tree: (ppid: [Int: Int], comm: [Int: String])) -> String? {
        var current = pid
        var topmost: String?
        var hops = 0
        while current > 1, hops < 64 {   // hops 上限防 ppid 表异常成环
            guard let pp = tree.ppid[current] else { break }
            if let comm = tree.comm[pp], comm.contains("/Applications/"),
               let range = comm.range(of: ".app") {
                topmost = String(comm[comm.startIndex..<range.upperBound])
            }
            current = pp
            hops += 1
        }
        return topmost
    }

}

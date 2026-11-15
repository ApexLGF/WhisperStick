import Foundation
import os

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "CodexSession")

// MARK: - Rate limits (REQ-018 用量卡数据源;017 先解析落库)

/// rollout `token_count.rate_limits` 快照。primary=300min(5h 等价) / secondary=10080min(7d 等价)。
struct CodexRateLimits: Sendable, Equatable, Codable {
    struct Window: Sendable, Equatable, Codable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Date?
    }
    var primary: Window?
    var secondary: Window?
    var planType: String?
    var capturedAt: Date          // 该条 rate_limits 所在 rollout 行的 timestamp
    /// 数据归属账号(auth.json tokens.account_id);换账号时旧快照按此失效。
    /// 旧版快照无此字段(nil)→ 视为未知,账号变更时同样作废
    var accountId: String?

    /// BUG-007:按**窗口时长语义**分槽,不按 primary/secondary 位置。
    /// codex CLI 0.144.4 起可能只上报一个周窗且放在 primary(secondary=null),
    /// 位置映射会把周用量塞进"5 小时"槽(设备端固定两行:第 1 行短窗、第 2 行周窗)。
    /// 规则:≤24h(含 windowMinutes 缺失的旧版数据,历史上 primary 即 5h)→ 短窗;
    /// >24h → 长窗。free 档单一 30d 窗按此归长窗槽。
    var shortWindow: Window? {
        [primary, secondary].compactMap { $0 }
            .first { $0.windowMinutes.map { $0 <= 24 * 60 } ?? true }
    }
    var longWindow: Window? {
        [primary, secondary].compactMap { $0 }
            .first { ($0.windowMinutes ?? 0) > 24 * 60 }
    }
    var hasUsageWindow: Bool { primary != nil || secondary != nil }
}

// MARK: - Session monitor

/// REQ-017: Codex 会话发现与状态管线。
///
/// 免 hook、免 wrapper:纯读 `$CODEX_HOME/sessions/**/rollout-*.jsonl`(CLI 与 Desktop 共用),
/// 每轮扫描对活动窗口内的文件做「首行 meta(缓存)+ 尾窗重推导」,不维护跨轮流式状态机 ——
/// phase 由尾窗中最后一条活动事件决定,天然免疫参考实现(Agent-Signal-Bar)标注的
/// 「token_count 弹回 thinking」与完成后回弹两类时序坑。
@MainActor
final class CodexSessionMonitor: ObservableObject {
    /// key = "codex-cli:<uuid>" / "codex-desktop:<uuid>" / "codex-vscode:<uuid>"(来源前缀防撞)
    @Published private(set) var sessions: [String: HookSession] = [:]
    /// 跨会话时间戳最新的一条 rate_limits(REQ-018);冷启动由快照回填
    @Published private(set) var latestRateLimits: CodexRateLimits?

    // MARK: 安装检测

    /// CODEX_HOME 覆盖;GUI 启动一般无此 env,回退 ~/.codex
    nonisolated static var dataDir: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    nonisolated static var sessionsRoot: URL { dataDir.appendingPathComponent("sessions") }

    nonisolated static var isCLIInstalled: Bool {
        FileManager.default.fileExists(atPath: dataDir.path)
    }
    nonisolated static var isDesktopInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Codex.app")
    }
    /// 数据目录或 Desktop bundle 任一存在即视为已安装(未安装不渲染卡片、不起扫描)
    nonisolated static var isInstalled: Bool { isCLIInstalled || isDesktopInstalled }

    // MARK: 扫描参数

    /// 活跃口径对齐 CC(REQ-014 单一阈值):30min transcript 无更新即非活跃。
    static let inactivityThreshold: TimeInterval = ClaudeHookSessionStore.inactivityThreshold
    /// 文件纳入扫描的 mtime 窗口 = REQ-028 §4 的非活跃保留窗(24h,App 与设备端统一)。
    /// 是否展示/归哪层由 SessionTierClassifier 决定,扫描窗口只管发现。
    private static let scanWindow: TimeInterval = 24 * 3600
    /// 尾窗字节数;token_count/turn_context 逐 turn 出现,256KB 覆盖近若干 turn
    private static let tailWindowBytes = 256 * 1024
    /// 首行 meta 最大读取量(首行含 base_instructions 可能很大)
    private static let headMaxBytes = 512 * 1024
    /// File-descriptor watchers are reserved for the most relevant rollouts.
    /// Directory events plus the 10s scan still discover/reconcile the rest.
    private static let maxEventWatchedRollouts = 64

    /// REQ-021: 审批挂起源;scan 时把 hook 挂起的会话相成 waitingForApproval(优先于 rollout 推导)
    weak var approvalServer: CodexApprovalServer?
    /// Incremental outer-turn events. Initial rollout tails are deliberately
    /// ignored by CodexJSONLTailReader, so App launch never replays old sounds.
    var onTaskLifecycleEvent: ((TaskLifecycleSignal) -> Void)?

    private var timer: Timer?
    private let tailReader = CodexJSONLTailReader(maxTailBytes: tailWindowBytes)
    private var eventMonitor: CodexRolloutEventMonitor?
    private var eventWatchedPaths: Set<String> = []
    private struct RolloutCandidate {
        let path: String
        let mtime: Date
        let size: Int
    }
    /// Full scans reconcile this index. File events update only their exact
    /// paths, avoiding a recursive directory walk for every streamed token.
    private var candidateCache: [String: RolloutCandidate] = [:]
    /// path → (mtime, size, rollout 原生 phase) 扫描门控:未变化不重读;
    /// rawPhase 用于 hook 审批挂起消失后恢复文件推导相(文件可能尚未新写入)
    private var scanGate: [String: (mtime: Date, size: Int, rawPhase: SessionPhase)] = [:]
    /// path → 首行 meta 缓存(session_meta 只写一次,永不重读)
    private var metaCache: [String: RolloutMeta] = [:]
    /// session_index.jsonl mtime → uuid:title cache(Codex TUI rename source).
    private var titleIndexCache: (mtime: Date, titles: [String: String])?
    /// 仅在扫描结果发生变化时落盘，供“Desktop 有会话但卡片未出现”排障。
    /// 不能每 10 秒写一次：扫描本身是常驻路径，日志必须保持有界且低噪声。
    private var lastScanDiagnostic: String?
    /// hook 的 UserPromptSubmit 是比 rollout mtime 更及时的用户活动信号。
    /// 保留时间戳以避免下一次门控扫描把刚收到的活动又覆盖为旧 mtime。
    private var hookActivityByUUID: [String: Date] = [:]
    private var hookActivityByPath: [String: Date] = [:]

    struct RolloutMeta {
        let sessionKey: String        // 带来源前缀
        let uuid: String
        let isDesktop: Bool
        let cwd: String
        let cliVersion: String?
        let gitBranch: String?
        let startedAt: Date?
    }

    /// REQ-021: 审批挂起增删时由 CodexApprovalServer 回调,立即重扫刷新会话相
    func rescan() { scan(refreshLiveness: false) }

    /// Codex UserPromptSubmit 到达时立即刷新排序时间。不能用 attached/lsof 当活动时间：
    /// 长期挂着但未操作的会话同样会持有 rollout fd。
    func noteUserPrompt(sessionId rawSessionId: String, transcriptPath: String?) {
        let now = Date()
        let uuid = Self.uuid(from: rawSessionId)
        if !uuid.isEmpty { hookActivityByUUID[uuid] = now }
        if let transcriptPath, !transcriptPath.isEmpty {
            hookActivityByPath[Self.normalizePath(transcriptPath)] = now
        }
        ClaudeCodeSessionManager.log("[CodexMonitor] prompt activity uuid=\(uuid) path=\(transcriptPath ?? "-")")
        scan(refreshLiveness: false)
    }

    func start() {
        guard Self.isInstalled else {
            logger.info("codex not installed — monitor idle")
            return
        }
        guard timer == nil, eventMonitor == nil else { return }
        loadUsageSnapshot()
        loadDailyPeaks()
        scan(refreshLiveness: true)

        let watchedRoot = FileManager.default.fileExists(atPath: Self.sessionsRoot.path)
            ? Self.sessionsRoot.path : Self.dataDir.path
        let monitor = CodexRolloutEventMonitor(
            rootPath: watchedRoot,
            titleIndexPath: Self.dataDir.appendingPathComponent("session_index.jsonl").path
        ) { [weak self] batch in
            Task { @MainActor in
                guard let self else { return }
                // A normal append updates only the paths reported by the file
                // watcher. Directory changes still use discovery, and the 10s
                // full scan remains authoritative for missed events/liveness.
                self.scan(
                    refreshLiveness: false,
                    changedRolloutPaths: batch.needsDiscoveryScan ? nil : batch.rolloutPaths
                )
            }
        }
        eventMonitor = monitor
        monitor.start()
        monitor.updateRolloutPaths(eventWatchedPaths)

        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan(refreshLiveness: true) }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        logger.info("codex monitor started, root=\(Self.sessionsRoot.path)")
    }

    // MARK: - Scan

    private func scan(refreshLiveness: Bool,
                      changedRolloutPaths: Set<String>? = nil) {
        let fm = FileManager.default
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        // hook 侧活动只用于 bridge rollout 落盘前的短暂空窗；与会话保留窗一起清理，
        // 防止长期运行 App 的内存表无限增长。
        hookActivityByUUID = hookActivityByUUID.filter { $0.value >= cutoff }
        hookActivityByPath = hookActivityByPath.filter { $0.value >= cutoff }

        // REQ-028 §2:每轮一次 lsof fd 枚举,供层2 判定
        // (按 cwd 计数 + Desktop/VSCode 宿主存在性的三个旧快照字段已整体删除,见 BUG-031)
        if refreshLiveness {
            attachedPaths = Self.attachedRolloutPaths()
        }

        // 审批路径直接来自 hook，不依赖“上一轮已经发现会话”。这是审批→会话的主关联：
        // pending rollout 即使旧、未 attached 或 UUID 续接变化，也必须进入本轮候选集。
        let trackedPaths = (approvalServer?.pendingTranscriptPaths ?? [])
            .union(hookActivityByPath.keys)

        if let changedRolloutPaths {
            for path in changedRolloutPaths {
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                      let rv = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey]
                      ),
                      let mtime = rv.contentModificationDate,
                      let size = rv.fileSize else {
                    candidateCache.removeValue(forKey: path)
                    continue
                }
                let normalizedPath = Self.normalizePath(path)
                if mtime >= cutoff || trackedPaths.contains(normalizedPath)
                    || attachedPaths.contains(path) {
                    candidateCache[path] = RolloutCandidate(path: path, mtime: mtime, size: size)
                } else {
                    candidateCache.removeValue(forKey: path)
                }
            }
        } else {
            var discovered: [String: RolloutCandidate] = [:]
            if let en = fm.enumerator(
                at: Self.sessionsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in en {
                    let name = url.lastPathComponent
                    guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
                    guard let rv = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey]
                    ), let mtime = rv.contentModificationDate, let size = rv.fileSize else { continue }
                    // 长时间运行的 Codex CLI 可能在空闲后不再写 rollout。App 重启时，
                    // 仅按 24h mtime 会漏掉仍被活跃进程持有的会话；lsof 的 attached
                    // 结果应和近期写入、审批挂起一样，成为会话发现条件。
                    let normalizedPath = Self.normalizePath(url.path)
                    if mtime >= cutoff || trackedPaths.contains(normalizedPath)
                        || attachedPaths.contains(url.path) {
                        discovered[url.path] = RolloutCandidate(
                            path: url.path, mtime: mtime, size: size
                        )
                    }
                }
            }
            candidateCache = discovered
        }
        let candidates = Array(candidateCache.values)

        var next: [String: HookSession] = [:]
        var bestRL = latestRateLimits
        let titleIndex = sessionTitleIndex()
        // Codex Desktop 可为同一 session_id 续写新的 rollout 文件。文件枚举顺序并不
        // 稳定，不能让较旧副本随机覆盖较新副本，否则会话排序和审批状态都会漂移。
        func retainNewest(_ session: HookSession) {
            guard let existing = next[session.id], existing.lastActivity > session.lastActivity else {
                next[session.id] = session
                return
            }
        }

        for c in candidates {
            // 门控:mtime+size 未变 → 沿用上轮结果(审批挂起态照常增删)
            if let gate = scanGate[c.path], gate.mtime == c.mtime, gate.size == c.size,
               let meta = metaCache[c.path], let prev = sessions[meta.sessionKey] {
                var s = prev
                s.name = titleIndex[meta.uuid]
                // 门控命中不重读 rollout，但 hook 的 UserPromptSubmit 可能刚刚到达；
                // 必须在缓存分支同样合并，否则活动时间会被旧快照永久卡住。
                s.phase = gate.rawPhase
                if let hookActivity = latestHookActivity(uuid: meta.uuid, transcriptPath: c.path),
                   hookActivity > s.lastActivity {
                    s.lastActivity = hookActivity
                    if Date().timeIntervalSince(hookActivity) <= 90 {
                        s.phase = .processing
                        s.modelInferring = true
                    }
                }
                if let p = approvalServer?.pendingEntry(sessionId: s.id, transcriptPath: c.path) {
                    s.phase = .waitingForApproval(p.context)
                } else {
                    Self.expireStaleTurnIfNeeded(&s, now: now)
                }
                retainNewest(s)
                continue
            }
            guard let meta = rolloutMeta(path: c.path) else { continue }
            let tail = parseTail(path: c.path, size: c.size, sessionID: meta.sessionKey)
            scanGate[c.path] = (c.mtime, c.size, tail.phase)

            var snap = TranscriptSnapshot()
            snap.model = tail.model
            snap.contextPromptTokens = tail.contextTokens
            snap.contextLimitTokens = tail.contextWindow
            snap.gitBranch = meta.gitBranch
            snap.cliVersion = meta.cliVersion
            snap.firstTimestamp = meta.startedAt
            snap.lastTimestamp = tail.lastTimestamp
            snap.transcriptMtime = c.mtime
            snap.turnCount = tail.turnCountInWindow
            snap.totalInputTokens = tail.totalInput
            snap.totalCacheReadTokens = tail.totalCachedInput
            snap.totalOutputTokens = tail.totalOutput

            // rollout 尾部事件时间是会话的真实最后活动时间；文件 mtime 是可靠兜底。
            let rolloutActivity = max(c.mtime, tail.lastTimestamp ?? .distantPast)
            let hookActivity = latestHookActivity(uuid: meta.uuid, transcriptPath: c.path)
            let lastActivity = max(rolloutActivity, hookActivity ?? .distantPast)
            var session = HookSession(
                id: meta.sessionKey,
                cwd: meta.cwd,
                phase: tail.phase,
                pid: nil,                     // CLI 会话由下方 sidecar 匹配回填
                tty: nil,
                lastTool: tail.lastTool,
                lastActivity: lastActivity,
                name: titleIndex[meta.uuid]
            )
            session.transcriptPath = c.path
            session.transcriptSnapshot = snap
            // REQ-022 后续批:rollout 推导的 thinking 标志 → 与 CC 会话同款 v5State 判定
            // (processing + inferring → 8);门控命中路径经 prev 会话自然沿用上轮值
            session.modelInferring = tail.modelInferring
            // 用户刚提交 prompt、而 rollout 尚未来得及落事件时，显示为工作中；一旦
            // rollout 写入更新，原始相位立即重新接管，避免把会话永久卡在 processing。
            if let hookActivity,
               hookActivity > rolloutActivity,
               Date().timeIntervalSince(hookActivity) <= 90 {
                session.phase = .processing
                session.modelInferring = true
            }
            // hook 挂起优先于 rollout 推导；路径精确匹配，UUID 仅兼容旧 hook。
            if let p = approvalServer?.pendingEntry(sessionId: session.id, transcriptPath: c.path) {
                session.phase = .waitingForApproval(p.context)
            } else {
                Self.expireStaleTurnIfNeeded(&session, now: now)
            }
            retainNewest(session)

            if let rl = tail.rateLimits, rl.hasUsageWindow {
                if bestRL == nil || bestRL?.hasUsageWindow != true || rl.capturedAt > bestRL!.capturedAt {
                    bestRL = rl
                }
            }
        }

        let candidatePaths = Set(candidates.map(\.path))
        scanGate = scanGate.filter { candidatePaths.contains($0.key) }
        metaCache = metaCache.filter { candidatePaths.contains($0.key) }
        tailReader.retain(paths: candidatePaths)
        let requiredWatchPaths = Set(candidates.compactMap { candidate -> String? in
            let normalized = Self.normalizePath(candidate.path)
            return trackedPaths.contains(normalized) || attachedPaths.contains(normalized)
                ? candidate.path : nil
        })
        var watchedPaths = requiredWatchPaths
        for candidate in candidates.sorted(by: { $0.mtime > $1.mtime })
            where watchedPaths.count < Self.maxEventWatchedRollouts {
            watchedPaths.insert(candidate.path)
        }
        eventWatchedPaths = watchedPaths
        eventMonitor?.updateRolloutPaths(watchedPaths)

        // REQ-019: vibepty sidecar → CLI 会话 pid 回填(直通注入寻址用)
        assignSidecarPids(&next)

        for (sessionID, previous) in sessions {
            guard previous.phase == .processing || previous.phase == .compacting,
                  let current = next[sessionID], current.phase == .idle,
                  CodexTurnLeasePolicy.shouldExpire(
                    isRunning: true,
                    lastProgressAt: current.lastActivity,
                    now: now
                  ) else { continue }
            onTaskLifecycleEvent?(TaskLifecycleSignal(
                provider: .codex,
                sessionID: sessionID,
                turnID: "codex-lease-expired",
                outcome: .expired
            ))
        }
        if !dictEqual(next, sessions) { sessions = next }
        recordScanDiagnostic(candidateCount: candidates.count, parsedSessions: next)

        // 账号切换检测(2026-07-11 用户实测:换 codex 账号后旧快照/徽章一直回显):
        // 当前 auth.json 账号与既有数据归属不一致 → 作废快照与七日历史,写"墓碑"
        // (无窗口、capturedAt=切换时刻、新账号戳)。此后只接受 capturedAt 晚于墓碑的
        // rate_limits —— rollout 不含账号标识,旧账号 rollout 在 24h 窗口内仍会被扫到,
        // 靠时间线切割;徽章即刻回退新 auth.json 的 JWT plan,用量待新账号首个会话。
        let currentAcct = Self.currentAccountId()
        if let rl = latestRateLimits, currentAcct != nil, rl.accountId != currentAcct {
            logger.info("codex account changed — tombstoning usage snapshot/history")
            dailyPeaks = [:]
            try? FileManager.default.removeItem(atPath: historyPath)
            let tombstone = CodexRateLimits(primary: nil, secondary: nil, planType: nil,
                                            capturedAt: now, accountId: currentAcct)
            latestRateLimits = tombstone
            saveUsageSnapshot(tombstone)
        }

        if var rl = bestRL, rl.hasUsageWindow,
           (latestRateLimits?.hasUsageWindow != true || rl.capturedAt > (latestRateLimits?.capturedAt ?? .distantPast)),
           rl != latestRateLimits {
            rl.accountId = currentAcct
            latestRateLimits = rl
            saveUsageSnapshot(rl)
            // BUG-007:峰值语义是短窗(5h);短窗缺席(周窗-only 上报)则记长窗峰值,
            // 保证 7 天峰值条不断档
            if case .subscription = Self.billingMode(latestPlanType: rl.planType) {
                recordDailyPeak((rl.shortWindow ?? rl.longWindow)?.usedPercent)
            }
        }
    }

    private static func expireStaleTurnIfNeeded(_ session: inout HookSession, now: Date) {
        let isRunning = session.phase == .processing || session.phase == .compacting
        guard CodexTurnLeasePolicy.shouldExpire(
            isRunning: isRunning,
            lastProgressAt: session.lastActivity,
            now: now
        ) else { return }
        session.phase = .idle
        session.modelInferring = false
    }

    /// 当前账号标识:auth.json tokens.account_id;API key 模式取 key 前 12 字符
    nonisolated static func currentAccountId() -> String? {
        let path = dataDir.appendingPathComponent("auth.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tokens = json["tokens"] as? [String: Any],
           let acct = tokens["account_id"] as? String, !acct.isEmpty {
            return acct
        }
        if let key = json["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return "apikey:" + String(key.prefix(12))
        }
        return nil
    }

    // MARK: - REQ-018 用量快照落盘 + 七日峰值(机制对齐 ClaudeUsageManager,按 agent 分文件)

    private var usageSnapshotPath: String {
        NSHomeDirectory() + "/Library/Application Support/QuickVibeHost/codex-usage-snapshot.json"
    }
    private var historyPath: String {
        NSHomeDirectory() + "/Library/Application Support/QuickVibeHost/codex-usage-history.json"
    }
    private var dailyPeaks: [String: Double] = [:]

    private func loadUsageSnapshot() {
        guard let data = FileManager.default.contents(atPath: usageSnapshotPath),
              let rl = try? JSONDecoder().decode(CodexRateLimits.self, from: data) else { return }
        latestRateLimits = rl
    }

    private func saveUsageSnapshot(_ rl: CodexRateLimits) {
        let url = URL(fileURLWithPath: usageSnapshotPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(rl) {
            try? data.write(to: url)
        }
    }

    nonisolated private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func loadDailyPeaks() {
        guard let data = FileManager.default.contents(atPath: historyPath),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        dailyPeaks = dict
    }

    /// 记录当天观测到的 primary(5h 等价窗口)峰值;只在刷新峰值时落盘,保留 30 天
    private func recordDailyPeak(_ percent: Double?) {
        guard let percent else { return }
        let key = Self.dayKey(Date())
        guard percent > (dailyPeaks[key] ?? -1) else { return }
        dailyPeaks[key] = percent
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date())
        dailyPeaks = dailyPeaks.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(dailyPeaks) {
            try? data.write(to: URL(fileURLWithPath: historyPath))
        }
    }

    /// 近 7 天(旧→今)每日峰值;无记录的天为 nil
    func last7DayPeaks() -> [Double?] {
        (0..<7).reversed().map { offset in
            guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return dailyPeaks[Self.dayKey(d)]
        }
    }

    // MARK: - REQ-018 身份徽章(全本地:rate_limits.plan_type → id_token JWT → API key 存在性)

    /// auth.json 只读解析;JWT 仅本地 base64 解码 payload,不发任何网络请求、不改文件
    nonisolated static func identityBadge(latestPlanType: String?) -> (text: String, isPlan: Bool)? {
        billingMode(latestPlanType: latestPlanType).identityBadge
    }

    nonisolated static func billingMode(latestPlanType: String?) -> AgentBillingMode {
        let authPath = dataDir.appendingPathComponent("auth.json").path
        let data = FileManager.default.contents(atPath: authPath)
        var plan = latestPlanType
        if plan?.isEmpty != false,
           let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String {
            plan = jwtPlanType(idToken)
        }
        return AgentBillingModeDetector.codex(
            authData: data,
            latestPlanType: plan,
            endpoint: apiEndpointClassification()
        )
    }

    /// REQ-023:Codex 接入点分类。数据源 `~/.codex/config.toml` 当前 provider 的 base_url。
    /// mtime 缓存:SwiftUI body 每次求值会走到这里(identityBadge + identityBadgeHelp),
    /// 不能每次同步读文件 + 解析 TOML(review MEDIUM);config.toml 未变直接回缓存。
    nonisolated(unsafe) private static var endpointCache: (mtime: Date, cls: APIEndpointClassifier.Classification)?
    nonisolated private static let endpointCacheLock = NSLock()

    nonisolated static func apiEndpointClassification() -> APIEndpointClassifier.Classification {
        let configPath = dataDir.appendingPathComponent("config.toml").path
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date)
            ?? .distantPast
        endpointCacheLock.lock()
        defer { endpointCacheLock.unlock() }
        if let cached = endpointCache, cached.mtime == mtime { return cached.cls }
        let cls = APIEndpointClassifier.classify(
            baseURL: APIEndpointClassifier.codexBaseURL(configPath: configPath))
        endpointCache = (mtime, cls)
        return cls
    }

    /// id_token 中段 base64url 解码 → claims["https://api.openai.com/auth"].chatgpt_plan_type
    nonisolated private static func jwtPlanType(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                      .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_plan_type"] as? String
    }

    /// HookSession 未声明 Equatable;逐 key 比较避免每 10s 无脑触发 @Published
    private func dictEqual(_ a: [String: HookSession], _ b: [String: HookSession]) -> Bool {
        guard a.count == b.count else { return false }
        for (k, va) in a {
            guard let vb = b[k] else { return false }
            if va.phase != vb.phase || va.name != vb.name || va.lastActivity != vb.lastActivity
                || va.pid != vb.pid
                || va.modelInferring != vb.modelInferring
                || va.transcriptSnapshot != vb.transcriptSnapshot { return false }
        }
        return true
    }

    /// 将会话发现的输入与输出写进已有的应用日志。UI/蓝牙均订阅 $sessions，
    /// 因此这条记录可以明确区分“没有扫到 rollout”和“已发布会话、问题在下游”。
    private func recordScanDiagnostic(candidateCount: Int, parsedSessions: [String: HookSession]) {
        let activeCount = partitioned().active.count
        let keys = parsedSessions.keys.sorted()
        let pendingKeys = approvalServer?.pending.keys.sorted() ?? []
        let matchedPending = parsedSessions.values.compactMap { session -> String? in
            approvalServer?.pendingKey(sessionId: session.id, transcriptPath: session.transcriptPath)
        }.sorted()
        let diagnostic = "root=\(Self.sessionsRoot.path) candidates=\(candidateCount) parsed=\(parsedSessions.count) active=\(activeCount) attached=\(attachedPaths.count) pending=\(pendingKeys.joined(separator: ",")) matched=\(matchedPending.joined(separator: ",")) keys=\(keys.joined(separator: ","))"
        guard diagnostic != lastScanDiagnostic else { return }
        lastScanDiagnostic = diagnostic
        ClaudeCodeSessionManager.log("[CodexMonitor] \(diagnostic)")
        logger.notice("codex scan \(diagnostic, privacy: .public)")
    }

    /// Codex TUI rename/title source. Append-only jsonl;last row for uuid wins.
    private func sessionTitleIndex() -> [String: String] {
        let url = Self.dataDir.appendingPathComponent("session_index.jsonl")
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
        if let cached = titleIndexCache, cached.mtime == mtime { return cached.titles }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            titleIndexCache = (mtime, [:])
            return [:]
        }
        var titles: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = Self.str(obj, "id"),
                  let title = Self.str(obj, "thread_name") else { continue }
            titles[id] = title
        }
        titleIndexCache = (mtime, titles)
        return titles
    }

    // MARK: - REQ-019 vibepty sidecar → pid 映射

    private struct VibeptySidecar {
        let pid: Int
        let cwd: String
        let startedAt: Date
    }

    /// 读 /tmp/vibepty-<pid>.json(vibepty 启动时写、退出时清),
    /// 只取 cmd=="codex" 且 pid 存活的条目。
    private func readCodexSidecars() -> [VibeptySidecar] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: "/tmp") else { return [] }
        var out: [VibeptySidecar] = []
        for name in names where name.hasPrefix("vibepty-") && name.hasSuffix(".json") {
            let path = "/tmp/" + name
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = Self.int(obj, "pid"),
                  Self.str(obj, "cmd") == "codex",
                  let cwd = Self.str(obj, "cwd"),
                  let started = Self.dbl(obj, "started_at") else { continue }
            guard kill(Int32(pid), 0) == 0 else { continue }   // 死 pid 交给通用 reaper 清
            out.append(VibeptySidecar(pid: pid, cwd: Self.normalizePath(cwd),
                                      startedAt: Date(timeIntervalSince1970: started)))
        }
        return out
    }

    /// 匹配规则(REQ-019 定案):同 cwd;取「启动时间不晚于会话开始 + 2min 宽容」里最近启动的
    /// wrapper(覆盖 TUI 内 /new 换会话:新 rollout 仍归属早已启动的同 cwd codex 进程)。
    private func assignSidecarPids(_ sessions: inout [String: HookSession]) {
        let sidecars = readCodexSidecars()
        guard !sidecars.isEmpty else { return }
        for (key, var session) in sessions where key.hasPrefix("codex-cli:") {
            let cwd = Self.normalizePath(session.cwd)
            let sessionStart = session.transcriptSnapshot?.firstTimestamp ?? session.lastActivity
            let candidates = sidecars.filter {
                $0.cwd == cwd && $0.startedAt <= sessionStart.addingTimeInterval(120)
            }
            guard let best = candidates.max(by: { $0.startedAt < $1.startedAt }) else { continue }
            if session.pid != best.pid {
                session.pid = best.pid
                sessions[key] = session
            }
        }
    }

    nonisolated private static func normalizePath(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    private func latestHookActivity(uuid: String, transcriptPath: String) -> Date? {
        let byUUID = hookActivityByUUID[uuid]
        let byPath = hookActivityByPath[Self.normalizePath(transcriptPath)]
        return [byUUID, byPath].compactMap { $0 }.max()
    }

    private nonisolated static func uuid(from sessionId: String) -> String {
        sessionId.split(separator: ":", maxSplits: 1).last.map(String.init) ?? sessionId
    }

    /// REQ-028 §2:枚举活体 codex 进程持有的 rollout fd —— 层2「attached」的唯一信号。
    /// 取代 2026-07-10 的「按 cwd 计数」(BUG-031 元凶:ChatGPT 内嵌 codex 进程 cwd 恒为 "/",
    /// 且 Desktop 可接管 TUI 创建的会话,宿主与会话 cwd 已彻底脱钩)。
    /// 返回空集 = 无持有(REQ-028 拍板的降级行为:查不到一律归层3,宁折叠不误报);
    /// lsof 执行失败同样返回空集 —— 与「无持有」不做区分,避免"失败即全部误判活跃"。
    /// 开销:单进程几十 ms,10s 扫描周期可承受(REQ-028 §2)。
    nonisolated private static func attachedRolloutPaths() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-c", "codex", "-F", "pn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return CodexFdProbe.parseLsofRolloutPaths(out)
    }

    // MARK: - 活跃/非活跃(REQ-017:纯 mtime 口径,无进程探测)

    /// REQ-028 §2:本轮 lsof 枚举出的、被活体 codex 进程持有的 rollout 路径集合。
    /// 空集 = 无任何会话 attached(含 lsof 失败的降级路径)。
    private var attachedPaths: Set<String> = []

    /// REQ-028 三层判定。**已删除**:cwd 匹配、进程计数封顶、同宿主 displayKey 去重
    /// (三者都建立在"宿主进程 cwd == 会话 cwd"这个已被 ChatGPT 新版打破的前提上,见 BUG-031)。
    /// 层1 只看 mtime;层2 只看 rollout fd 持有;其余层3。
    private func partitioned() -> (active: [HookSession], inactive: [HookSession]) {
        let now = Date()
        let strategy = CodexLivenessStrategy(attachedRolloutPaths: attachedPaths)
        var items: [(item: HookSession, facts: LivenessFacts, tier: SessionTier)] = []
        for s in sessions.values {
            let facts = LivenessFacts(
                lastActivity: s.lastActivity,
                startedAt: s.transcriptSnapshot?.firstTimestamp,
                phasePriority: SessionPhaseRank.priority(s.phase),
                attached: strategy.isAttached(sessionKey: s.id, pid: s.pid,
                                              transcriptPath: s.transcriptPath),
                approvalPending: approvalServer?.pendingEntry(sessionId: s.id, transcriptPath: s.transcriptPath) != nil
            )
            guard let tier = SessionTierClassifier.tier(facts, now: now) else { continue }
            items.append((s, facts, tier))
        }
        return SessionGrouping.group(items, inactiveCap: SessionLivenessParams.appInactiveCap)
    }

    var activeSessions: [HookSession] { partitioned().active }
    /// 进程存在但空闲超 30min:折叠组可见(对齐 CC「idle+进程存活+超时」语义)
    var inactiveSessions: [HookSession] { partitioned().inactive }

    // MARK: - Rollout 解析

    /// 首行 session_meta;缓存(只写一次)。
    private func rolloutMeta(path: String) -> RolloutMeta? {
        if let cached = metaCache[path] { return cached }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: Self.headMaxBytes), !data.isEmpty else { return nil }
        guard let nl = data.firstIndex(of: 0x0A) else { return nil }   // 首行未写完/超长
        guard let obj = try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl]) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }

        let uuid = Self.str(payload, "session_id") ?? Self.str(payload, "sessionId")
            ?? Self.str(payload, "id") ?? Self.uuidFromFilename(path) ?? UUID().uuidString
        // Desktop/VSCode 判定看 originator。ChatGPT/Codex Desktop 实测也会写
        // "codex-tui"；若只匹配 "desktop"，会错误走 CLI 分支，进而把不可直通的
        // Desktop 会话当作 CLI 会话处理。VSCode 优先，避免未来来源串同时带 desktop。
        let originator = (Self.str(payload, "originator") ?? "").lowercased()
        let isVSCode = originator.contains("vscode")
        let isDesktop = !isVSCode && (originator.contains("desktop") || originator.contains("codex-tui"))
        let keyPrefix = isVSCode ? "codex-vscode:" : (isDesktop ? "codex-desktop:" : "codex-cli:")
        let git = payload["git"] as? [String: Any]
        let meta = RolloutMeta(
            sessionKey: keyPrefix + uuid,
            uuid: uuid,
            isDesktop: isDesktop,
            cwd: Self.str(payload, "cwd") ?? "?",
            cliVersion: Self.str(payload, "cli_version") ?? Self.str(payload, "cliVersion"),
            gitBranch: git.flatMap { Self.str($0, "branch") },
            startedAt: Self.date(payload, "timestamp") ?? Self.date(obj, "timestamp")
        )
        metaCache[path] = meta
        return meta
    }

    struct TailInfo {
        var phase: SessionPhase = .processing
        // REQ-022 后续批:thinking 状态。尾窗最后一条**有效事件**(会改 phase 的活动事件)
        // ∈ {response_item.reasoning, event_msg.agent_reasoning} → true;
        // 其它有效事件 → false;token_count/turn_context 等元数据事件不改变该标志
        // (与 phase 推导同口径:token_count 明确不作活动信号)。
        var modelInferring: Bool = false
        var model: String?
        var contextTokens: Int?
        var contextWindow: Int?
        var rateLimits: CodexRateLimits?
        var lastTimestamp: Date?
        var lastTool: String?
        var turnCountInWindow: Int = 0
        // total_token_usage 累计(会话卡 in/out 行)
        var totalInput: Int?
        var totalCachedInput: Int?
        var totalOutput: Int?
    }

    /// 尾窗(≤256KB)重推导:phase 取最后一条活动事件;token_count 仅作元数据。
    private func parseTail(path: String, size _: Int, sessionID: String) -> TailInfo {
        var info = TailInfo()
        guard let snapshot = tailReader.refresh(path: path) else { return info }
        emitTaskLifecycleEvents(snapshot.newCompleteLines, sessionID: sessionID)
        guard
              !snapshot.completeTail.isEmpty else { return info }
        let lines = snapshot.completeTail.split(separator: 0x0A, omittingEmptySubsequences: true)

        for lineData in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let ts = Self.date(obj, "timestamp")
            if let ts { info.lastTimestamp = ts }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let ptype = payload["type"] as? String

            switch type {
            case "turn_context":
                if let m = Self.str(payload, "model") ?? Self.str(payload, "model_name") { info.model = m }
            case "event_msg":
                switch ptype {
                case "task_started":
                    info.phase = .processing
                    info.modelInferring = true   // turn 开始 → 模型进入推理
                    info.turnCountInWindow += 1
                    if let w = payload["model_context_window"] as? Int { info.contextWindow = w }
                case "user_message":
                    info.phase = .processing
                    info.modelInferring = true   // 用户输入落盘 → 模型开始想
                case "agent_message":
                    info.phase = .processing
                    info.modelInferring = false  // 正文输出落盘,通常接 task_complete
                case "mcp_tool_call_end":
                    info.phase = .processing
                    info.modelInferring = true   // 工具结束 → 模型恢复推理
                case "agent_reasoning":
                    // REQ-022 后续批:模型推理增量 → thinking(与 response_item.reasoning 同义)
                    info.phase = .processing
                    info.modelInferring = true
                case "task_complete", "turn_aborted":
                    info.phase = .idle
                    info.modelInferring = false
                case "token_count":
                    // 明确不作活动信号(turn 中/后都会写,当活动会把完成态弹回 processing)
                    if let tokenInfo = payload["info"] as? [String: Any] {
                        if let w = tokenInfo["model_context_window"] as? Int { info.contextWindow = w }
                        if let last = tokenInfo["last_token_usage"] as? [String: Any] {
                            let input = Self.int(last, "input_tokens") ?? 0
                            let total = Self.int(last, "total_tokens") ?? 0
                            // Codex input_tokens already represents prompt/context size; cached_input_tokens is a subset.
                            let derived = max(total, input)
                            if derived > 0 { info.contextTokens = derived }
                        }
                        if let total = tokenInfo["total_token_usage"] as? [String: Any] {
                            let input = Self.int(total, "input_tokens")
                            let cached = Self.int(total, "cached_input_tokens") ?? Self.int(total, "cache_read_input_tokens")
                            // codex input_tokens 含 cached 子集;卡片 "new" 语义 = 非缓存输入
                            if let input {
                                info.totalInput = max(0, input - (cached ?? 0))
                            }
                            info.totalCachedInput = cached
                            info.totalOutput = Self.int(total, "output_tokens")
                        }
                        if info.model == nil {
                            info.model = Self.str(tokenInfo, "model") ?? Self.str(tokenInfo, "model_name")
                        }
                    }
                    if let rl = payload["rate_limits"] as? [String: Any] {
                        info.rateLimits = Self.parseRateLimits(rl, at: ts ?? Date())
                    }
                default:
                    break
                }
            case "response_item":
                switch ptype {
                case "reasoning":
                    // 完成式记录语义(2026-07-23 修正):reasoning 落盘后模型仍在生成
                    // (下一段推理或发起工具调用),直到 function_call 出现前都算 thinking
                    info.phase = .processing
                    info.modelInferring = true
                case "function_call", "custom_tool_call":
                    let name = Self.str(payload, "name") ?? "?"
                    info.lastTool = name
                    info.modelInferring = false
                    if name == "request_user_input" {
                        info.phase = .waitingForInput
                    } else if Self.requiresEscalatedApproval(payload) {
                        let ctx = PermissionContext(
                            toolUseId: Self.str(payload, "call_id") ?? Self.str(payload, "id") ?? UUID().uuidString,
                            toolName: name,
                            toolInput: Self.approvalInput(payload),
                            receivedAt: ts ?? Date()
                        )
                        info.phase = .waitingForApproval(ctx)
                    } else {
                        info.phase = .processing
                    }
                case "function_call_output", "custom_tool_call_output":
                    info.phase = .processing
                    info.modelInferring = true   // 工具结果吸收 → 模型恢复推理(≈CC PostToolUse)
                case "message":
                    info.phase = .processing
                    info.modelInferring = false
                default:
                    break
                }
            case "compacted":
                info.phase = .processing
                info.modelInferring = false
            default:
                break
            }
        }
        return info
    }

    private func emitTaskLifecycleEvents(_ data: Data, sessionID: String) {
        guard !data.isEmpty else { return }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            let turnID = (payload["turn_id"] as? String)
                ?? (obj["turn_id"] as? String)
                ?? "rollout-\(Self.str(obj, "timestamp") ?? UUID().uuidString)"
            let outcome: TaskLifecycleOutcome
            switch type {
            case "task_started": outcome = .started
            case "task_complete": outcome = .completed
            case "turn_aborted": outcome = .cancelled
            default: continue
            }
            onTaskLifecycleEvent?(TaskLifecycleSignal(
                provider: .codex,
                sessionID: sessionID,
                turnID: turnID,
                outcome: outcome
            ))
        }
    }

    /// `arguments` 里 sandbox_permissions == "require_escalated" → 需授权(对象/JSON 字符串双容错)
    private static func requiresEscalatedApproval(_ payload: [String: Any]) -> Bool {
        func check(_ dict: [String: Any]) -> Bool {
            if let v = str(dict, "sandbox_permissions") { return v == "require_escalated" }
            return false
        }
        if let args = payload["arguments"] as? [String: Any] { return check(args) }
        if let s = payload["arguments"] as? String,
           let data = s.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return check(dict)
        }
        return false
    }

    /// 审批卡展示用:arguments 摘要(command 等关键字段)
    private static func approvalInput(_ payload: [String: Any]) -> [String: AnyCodable]? {
        var dict: [String: Any]?
        if let args = payload["arguments"] as? [String: Any] { dict = args }
        else if let s = payload["arguments"] as? String,
                let data = s.data(using: .utf8),
                let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { dict = d }
        guard let dict else { return nil }
        var out: [String: AnyCodable] = [:]
        for key in ["command", "justification", "cwd", "path"] {
            guard let v = dict[key] else { continue }
            // PermissionContext.formattedInput 只认标量;数组(如 command: ["rm","-rf","x"])预拼成串
            if let arr = v as? [Any] {
                out[key] = AnyCodable(arr.map { "\($0)" }.joined(separator: " "))
            } else {
                out[key] = AnyCodable(v)
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func parseRateLimits(_ rl: [String: Any], at ts: Date) -> CodexRateLimits {
        func window(_ any: Any?) -> CodexRateLimits.Window? {
            guard let d = any as? [String: Any],
                  let used = dbl(d, "used_percent") ?? dbl(d, "usedPercent") else { return nil }
            let mins = int(d, "window_minutes") ?? int(d, "windowMinutes")
            let resets = (dbl(d, "resets_at") ?? dbl(d, "resetsAt")).map { Date(timeIntervalSince1970: $0) }
            return .init(usedPercent: used, windowMinutes: mins, resetsAt: resets)
        }
        return CodexRateLimits(
            primary: window(rl["primary"]),
            secondary: window(rl["secondary"]),
            planType: str(rl, "plan_type") ?? str(rl, "planType"),
            capturedAt: ts
        )
    }

    // MARK: - JSON 取值容错(snake/camel 双命名 + 数值宽容)

    private static func str(_ d: [String: Any], _ key: String) -> String? {
        if let s = d[key] as? String, !s.isEmpty { return s }
        return nil
    }
    private static func int(_ d: [String: Any], _ key: String) -> Int? {
        if let i = d[key] as? Int { return i }
        if let dd = d[key] as? Double { return Int(dd) }
        return nil
    }
    private static func dbl(_ d: [String: Any], _ key: String) -> Double? {
        if let dd = d[key] as? Double { return dd }
        if let i = d[key] as? Int { return Double(i) }
        return nil
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// ISO8601 带/不带小数秒双支持
    private static func date(_ d: [String: Any], _ key: String) -> Date? {
        guard let s = d[key] as? String else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    /// `rollout-2026-07-08T20-19-20-<uuid 36 字符>.jsonl` → 尾部 uuid
    private static func uuidFromFilename(_ path: String) -> String? {
        let base = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")
        let parts = base.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let tail = parts.suffix(5).joined(separator: "-")
        return tail.count == 36 ? tail : nil
    }
}

// MARK: - AgentProvider 实现

/// 真实 Codex provider(替换 MockCodexProvider):会话来自 CodexSessionMonitor。
/// REQ-018: 用量 = rollout rate_limits 长窗(周/月),全本地零网络。
struct CodexProvider: AgentProvider {
    let monitor: CodexSessionMonitor
    var selectionStore: SessionSelectionStore? = nil   // REQ-019: 直通会话名展示

    var shortName: String { "Codex" }
    var displayName: String { "Codex" }
    var iconAssetName: String { "CodexIcon" }
    var isInstalled: Bool { CodexSessionMonitor.isInstalled }
    var billingMode: AgentBillingMode {
        CodexSessionMonitor.billingMode(latestPlanType: monitor.latestRateLimits?.planType)
    }

    var usage: AgentUsageSnapshot {
        var snap = AgentUsageSnapshot()
        if let sid = selectionStore?.selectedSessionId,
           let session = monitor.sessions[sid], session.phase != .ended {
            snap.exclusiveName = session.projectName
        }
        guard case .subscription = billingMode else { return snap }
        // 无数据(冷装/快照缺失)或账号切换墓碑(无窗口):等待新账号首个会话产出数据
        guard let rl = monitor.latestRateLimits,
              rl.primary != nil || rl.secondary != nil else {
            snap.awaitingFirstData = true
            return snap
        }
        let now = Date()
        // Codex 当前只展示长窗用量;短窗不再作为"5小时用量"暴露在 UI。
        if let s = rl.longWindow {
            snap.weekLabel = Self.windowLabel(minutes: s.windowMinutes, fallback: AppL10n.tr("本周用量"))
            if let r = s.resetsAt, r <= now {
                snap.weekPercent = 0
            } else {
                snap.weekPercent = s.usedPercent
                snap.weekResetsAt = s.resetsAt
            }
        }
        snap.sevenDayPeaks = monitor.last7DayPeaks()
        snap.lastUpdated = rl.capturedAt
        return snap
    }

    var activeSessions: [HookSession] { monitor.activeSessions }
    var inactiveSessions: [HookSession] { monitor.inactiveSessions }

    var identityBadge: (text: String, isPlan: Bool)? {
        billingMode.identityBadge
    }

    var identityBadgeHelp: String? {
        // 仅 API 徽章(非订阅)时给 base URL tooltip;订阅/ChatGPT 徽章语义自明
        billingMode.identityBadgeHelp
    }

    /// 窗口时长 → 中文标签:≤24h→按实际小时数(如"5小时用量"),≤7d→本周,≤31d→本月;未知沿用缺省
    static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let m = minutes, m > 0 else { return fallback }
        if m <= 24 * 60 { return AppL10n.format("%@小时用量", String(max(1, m / 60))) }
        if m <= 7 * 24 * 60 { return AppL10n.tr("本周用量") }
        if m <= 31 * 24 * 60 { return AppL10n.tr("本月用量") }
        return fallback
    }
}

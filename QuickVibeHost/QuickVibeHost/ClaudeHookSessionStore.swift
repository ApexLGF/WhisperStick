import Foundation
import Combine
import os.log
import ApprovalKit   // REQ-022:ApprovalResolveReason

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "HookSession")

// MARK: - Session Phase

enum SessionPhase: Equatable, Sendable, CustomStringConvertible {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval(PermissionContext)
    case compacting
    case ended

    var description: String {
        switch self {
        case .idle: "idle"
        case .processing: "processing"
        case .waitingForInput: "waitingForInput"
        case .waitingForApproval(let ctx): "waitingForApproval(\(ctx.toolName))"
        case .compacting: "compacting"
        case .ended: "ended"
        }
    }

    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .idle: AppL10n.tr("空闲")
        case .processing: AppL10n.tr("处理中")
        case .waitingForInput: AppL10n.tr("等待输入")
        case .waitingForApproval: AppL10n.tr("等待审批")
        case .compacting: AppL10n.tr("压缩上下文")
        case .ended: AppL10n.tr("已结束")
        }
    }

    var iconName: String {
        switch self {
        case .idle: "circle"
        case .processing: "gearshape.2"
        case .waitingForInput: "text.cursor"
        case .waitingForApproval: "exclamationmark.shield"
        case .compacting: "arrow.triangle.2.circlepath"
        case .ended: "xmark.circle"
        }
    }

    static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.processing, .processing),
             (.waitingForInput, .waitingForInput),
             (.compacting, .compacting), (.ended, .ended):
            return true
        case (.waitingForApproval(let a), .waitingForApproval(let b)):
            return a.toolUseId == b.toolUseId
        default:
            return false
        }
    }
}

// MARK: - Permission Context

struct PermissionContext: Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date

    var formattedInput: String? {
        guard let input = toolInput else { return nil }
        var parts: [String] = []
        for (key, value) in input {
            let str: String
            switch value.value {
            case let s as String: str = s.count > 80 ? String(s.prefix(80)) + "..." : s
            case let n as Int: str = String(n)
            case let d as Double: str = String(d)
            case let b as Bool: str = b ? "true" : "false"
            default: str = "..."
            }
            parts.append("\(key): \(str)")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Hook Session

struct HookSession: Identifiable, Sendable {
    let id: String  // sessionId
    var cwd: String
    var phase: SessionPhase
    var pid: Int?
    var tty: String?
    var lastTool: String?
    var lastActivity: Date
    var name: String?  // user-set name via /name command

    var transcriptPath: String? = nil
    var permissionMode: String? = nil
    var agentId: String? = nil
    var agentType: String? = nil

    /// Snapshot extracted from the session's transcript JSONL (model, context tokens,
    /// git branch, active subagent, ...). `nil` until `SessionTranscriptReader` runs
    /// at least once for this session.
    var transcriptSnapshot: TranscriptSnapshot? = nil

    var backgroundTasks: [BackgroundTaskInfo] = []   // 折叠进本卡片的后台任务(角标用)
    var isBackgroundOrphan: Bool = false             // 孤儿 bg:顶层可见但禁直通

    // REQ-022 后续批:CC 错误 → 设备 TASK_ERROR
    /// StopFailure(turn 因 API 错误结束)置位;该会话下一次活动
    /// (UserPromptSubmit/PreToolUse)自动清除。置位期间 v5 帧 state=6(SDS_BLOCKED),
    /// 设备在进入 BLOCKED 边沿响一次 TASK_ERROR;清除后再次错误可再响。
    /// CC turn 完成时刻(Stop 事件打点):60s 内 v5State 显示 2(COMPLETED 绿短闪),
    /// 之后由 prune 定时器清除衰减为 0(READY)。Codex 的完成语义走 rollout task_complete 同 idle 路径。
    var completedAt: Date? = nil
    var hasError: Bool = false
    /// StopFailure 携带的错误短码(如 invalid_request),UI 提示用
    var lastError: String? = nil
    /// PostToolUseFailure 累计计数(仅内存 + 日志,不进状态不响铃)
    var toolFailureCount: Int = 0
    // REQ-022 后续批:会话 thinking 状态 → 设备 SDS_THINKING(8,蓝呼吸)
    /// "模型推理中"标志。事件状态机(handleEvent):
    /// UserPromptSubmit/PostToolUse → true(其后、下一个 PreToolUse 前 = 模型在生成);
    /// PreToolUse → false(进入工具执行窗口);Stop/SessionEnd/StopFailure → false(turn 结束)。
    /// processing/compacting 相位下 v5State 据此输出 8(thinking)/1(active)。
    /// Codex 会话由 CodexSessionMonitor.parseTail 按 rollout 尾窗最后一条有效事件
    /// (reasoning/agent_reasoning)推导同名标志。
    var modelInferring: Bool = false
    /// 错误会话宽限期:带 hasError 的会话收到 SessionEnd 的时间戳。
    /// -p 一次性会话 StopFailure 后紧跟 SessionEnd(间隔 < 500ms 推送去抖窗口),
    /// 若立即移除,state=6 帧会被去抖后的最终态吞掉,设备永远收不到 BLOCKED。
    /// 置位后会话保留 errorGracePeriod(60s)仍算活跃(v5 帧持续下发 6),到期移除。
    var errorEndedAt: Date? = nil

    var projectName: String {
        transcriptSnapshot?.customTitle ?? name ?? URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Resolved transcript path — prefers the hook-supplied one, falls back to
    /// `TranscriptPath.locate(cwd:sessionId:)`(派生 + sessionId 全局搜索保底,BUG-006)
    /// for seed-scanned sessions that never received a hook event.
    var resolvedTranscriptPath: String {
        transcriptPath
            ?? TranscriptPath.locate(cwd: cwd, sessionId: id)?.path
            ?? TranscriptPath.derive(cwd: cwd, sessionId: id).path
    }
}

/// REQ-028 §3 活跃组内排序键:等审批 > 工作中 > 等输入 > 挂着。
/// (学 ClaudeIsland 的 phasePriority;数值小 = 排前面)
enum SessionPhaseRank {
    static func priority(_ p: SessionPhase) -> Int {
        switch p {
        case .waitingForApproval:      return 0
        case .processing, .compacting: return 1
        case .waitingForInput:         return 2
        case .idle, .ended:            return 3
        }
    }
}

// MARK: - Session Store

@MainActor
final class ClaudeHookSessionStore: ObservableObject {
    @Published private(set) var sessions: [String: HookSession] = [:]
    @Published private(set) var isServerRunning = false
    /// "粘性置顶"的会话：直通选中后，该会话下一次活跃事件发生时被记入；
    /// 之后即使有其它会话活跃也保持置顶。只有当 pin 的会话不再是直通、
    /// 且另一个会话发生活跃事件时才清除（见 updatePinState）。
    @Published private(set) var pinnedSessionId: String?

    /// 直通选择源。弱引用避免循环持有；由 app 入口注入。
    weak var selectionStore: SessionSelectionStore?
    var onTaskLifecycleEvent: ((TaskLifecycleSignal) -> Void)?

    /// REQ-014 非活跃阈值：idle 会话 transcript 30min 无更新即过滤。
    static let inactivityThreshold: TimeInterval = 30 * 60   // 30min
    /// processing/waitingForInput/compacting 相位的判活上限:活跃回合必有 hook 事件
    /// 持续刷新 lastActivity,超过此值视为 session id 轮转/宿主进程长存留下的相位
    /// 残留(如 claude 后台任务续段后旧段永久卡 processing),降级走 mtime 判定
    static let phaseLivenessCap: TimeInterval = 2 * 3600     // 2h
    /// REQ-022 后续批:错误会话宽限期 — "会话带着错误死亡"(agent 崩溃/API 挂)
    /// 恰是最需要提醒的场景,ended + hasError 保留 60s 保证设备收到 state=6 边沿
    static let errorGracePeriod: TimeInterval = 60

    /// REQ-028:分组口径已迁至 `partitionedTiers()`;本函数仅供 `activeSession`
    /// (单数,直通/标题栏用)选取"最近一条可操作会话",不再参与活跃/非活跃分组。
    ///
    /// REQ-014 单一口径：哪些 session 计入"活跃"(显示 / 计数 / 占槽位)。
    /// 过滤：ended ∪ 进程退出 ∪ (idle 且 无 transcript = 零消息 spare) ∪ (idle 且 transcript 30min 无更新)。
    /// 交互态(processing/waitingForApproval/waitingForInput/compacting)恒保留 —— 阻塞会话必须可见。
    static func isActive(_ s: HookSession, now: Date) -> Bool {
        // REQ-022 后续批:错误宽限期内的已结束会话保持可见/占槽
        // (放最前:此时 claude 进程已退出,不能被下方 pid 判死过滤)
        if s.hasError, let endedAt = s.errorEndedAt {
            return now.timeIntervalSince(endedAt) <= errorGracePeriod
        }
        if s.phase == .ended { return false }
        if let pid = s.pid, kill(Int32(pid), 0) != 0 { return false }   // 进程退出
        switch s.phase {
        case .waitingForApproval:
            return true   // 待审批必须可见;过期由 pruneExpiredPermissions 单独回收
        case .processing, .waitingForInput, .compacting:
            if now.timeIntervalSince(s.lastActivity) <= phaseLivenessCap { return true }
            // 超上限 = 相位残留(僵尸),降级走下方 transcript mtime 判定
        case .idle, .ended:
            break
        }
        guard let snap = s.transcriptSnapshot else { return false }      // 零消息 spare(无 transcript)
        guard let mtime = snap.transcriptMtime else { return false }
        return now.timeIntervalSince(mtime) <= inactivityThreshold      // 30min 无更新 → 过滤
    }

    /// Most recently active session (not ended, REQ-014 filtered)
    var activeSession: HookSession? {
        let now = Date()
        return sessions.values
            .filter { Self.isActive($0, now: now) }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    /// REQ-028:三层判定的统一入口。层2 = hook pid 存活(kill(pid,0));
    /// 30s zombie 兜底由既有 pruneTimer(30s 周期)承担,**不新增定时器**。
    private func partitionedTiers() -> (active: [HookSession], inactive: [HookSession]) {
        let now = Date()
        let strategy = ClaudeLivenessStrategy(isProcessAlive: { kill(Int32($0), 0) == 0 })
        var items: [(item: HookSession, facts: LivenessFacts, tier: SessionTier)] = []
        for s in sessions.values {
            // 零消息 spare(无 transcript)仍完全隐藏(REQ-014 既有语义,本次不改)
            guard s.transcriptSnapshot?.transcriptMtime != nil || s.phase != .idle else { continue }
            // 错误宽限期内的已结束会话保持可见(REQ-022 语义,不得回归)
            let errorGrace = s.hasError && s.errorEndedAt
                .map { now.timeIntervalSince($0) <= Self.errorGracePeriod } == true
            if s.phase == .ended && !errorGrace { continue }
            let facts = LivenessFacts(
                lastActivity: s.lastActivity,
                startedAt: s.transcriptSnapshot?.firstTimestamp,
                phasePriority: SessionPhaseRank.priority(s.phase),
                attached: strategy.isAttached(sessionKey: s.id, pid: s.pid,
                                              transcriptPath: s.transcriptPath),
                approvalPending: s.phase.isWaitingForApproval || errorGrace
            )
            guard let tier = SessionTierClassifier.tier(facts, now: now) else { continue }
            items.append((s, facts, tier))
        }
        return SessionGrouping.group(items, inactiveCap: SessionLivenessParams.appInactiveCap)
    }

    var inactiveSessions: [HookSession] { partitionedTiers().inactive }

    /// 活跃组 + 粘性置顶(既有 pinnedSessionId 行为保持)
    var activeSessions: [HookSession] {
        let sorted = partitionedTiers().active
        guard let pid = pinnedSessionId,
              let pinned = sorted.first(where: { $0.id == pid }) else { return sorted }
        return [pinned] + sorted.filter { $0.id != pid }
    }

    /// 在会话发生"活跃事件"（handleEvent / 权限响应）后调用，按规则维护 pinnedSessionId：
    /// - 当前活跃的是直通会话 → 把它标记为置顶
    /// - 当前活跃的是别的会话，而置顶那个已经不是直通了 → 清除置顶（让位给真实活跃顺序）
    /// 注意：系统类 lastActivity 更新（stale waiting 重置、权限过期清理）不走这个方法，
    /// 避免后台 timer 触发置顶切换。
    private func updatePinState(forActiveSessionId sessionId: String) {
        let selected = selectionStore?.selectedSessionId
        if sessionId == selected {
            pinnedSessionId = sessionId
        } else if let pinned = pinnedSessionId, pinned != selected {
            pinnedSessionId = nil
        }
    }

    /// Any session waiting for approval (deterministic: earliest first)
    var pendingApproval: HookSession? {
        sessions.values
            .filter { $0.phase.isWaitingForApproval }
            .min { $0.lastActivity < $1.lastActivity }
    }

    private var pruneTimer: Timer?
    private var healthCheckTimer: Timer?
    private var transcriptRefreshTimer: Timer?
    private let transcriptReader = SessionTranscriptReader()
    private weak var pricingManager: AnthropicPricingManager?
    private var pricingCancellable: AnyCancellable?
    private var lifecycleSequence: [String: UInt64] = [:]
    private var activeLifecycleTurns: [String: String] = [:]

    /// The catalog to use for cost computations. Reads through the injected
    /// `AnthropicPricingManager` if present, otherwise falls back to bundled
    /// defaults so tests / early-boot calls still get sane numbers.
    private var currentPricing: PricingCatalog {
        pricingManager?.catalog ?? PricingCatalog.bundledDefaults()
    }

    /// Inject the pricing manager. Called by the app after both stores are
    /// instantiated. Safe to call before or after `start()`.
    func attachPricingManager(_ manager: AnthropicPricingManager) {
        self.pricingManager = manager
        // Re-run cost with the new catalog whenever it changes: clear the actor's
        // 5s throttle cache, then force-refresh every active (or not-yet-pruned)
        // session so the UI immediately reflects new rates.
        pricingCancellable = manager.$catalog
            .dropFirst()  // skip the initial value we already read via currentPricing
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.transcriptReader.invalidateCostCache()
                    self.refreshAllTranscriptSnapshots()
                }
            }
    }

    func start() {
        HookSocketServer.shared.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEvent(event)
            }
        }
        isServerRunning = true

        // Periodically prune dead sessions (every 30s)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pruneDeadSessions()
            }
        }

        // Periodically verify socket server health (every 30s)
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            HookSocketServer.shared.ensureRunning()
        }

        // Periodically refresh transcript snapshots (every 10s) — covers seed-scanned
        // sessions that never receive hook events, and picks up mid-session model/branch
        // changes for sessions that are idle between hook bursts.
        transcriptRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllTranscriptSnapshots()
            }
        }

        logger.info("Hook session store started")
    }

    /// Seed from existing sessions discovered by process scanning.
    /// These sessions won't have phase info until a hook event arrives,
    /// but they'll show up in the UI as "idle" rather than missing.
    ///
    /// Note: session file IDs (process-level) differ from hook event IDs
    /// (conversation-level), so we deduplicate by PID to avoid ghosts.
    func seedFromDiscoveredSessions(_ discovered: [ClaudeCodeSession]) {
        let now = Date()
        let existingPids = Set(sessions.values.compactMap(\.pid))
        for session in discovered where session.isAlive {
            // Skip if a hook event already created a session for this process
            guard !existingPids.contains(session.pid) else { continue }
            guard sessions[session.id] == nil else { continue }
            sessions[session.id] = HookSession(
                id: session.id, cwd: session.cwd, phase: .idle,
                pid: session.pid, tty: session.tty, lastTool: nil,
                lastActivity: now, name: session.name
            )
        }
        // Also prune any stale sessions whose process died
        pruneDeadSessions()
        if !discovered.isEmpty {
            logger.info("Seeded \(self.sessions.count) sessions from process scan")
        }
        // Kick off a transcript refresh for every seeded session — these never
        // receive hook events, so the periodic timer is their only update path.
        refreshAllTranscriptSnapshots()
    }

    /// Sync session names from process-scanned sessions (which have the /name field)
    func syncNames(from discovered: [ClaudeCodeSession]) {
        for disc in discovered {
            guard let name = disc.name, !name.isEmpty else { continue }
            // Match by PID since session IDs differ (process-level vs conversation-level)
            for (id, var session) in sessions {
                if session.pid == disc.pid, session.name != name {
                    session.name = name
                    sessions[id] = session
                }
            }
        }
    }

    /// 把发现层折叠出的 backgroundTasks / 孤儿标记传导到 HookSession(按 pid 匹配)。
    /// 每次 sessionManager.$sessions 变都调 —— seedFromDiscoveredSessions 只在 boot 跑一次且
    /// guard 已存在会话会跳过,不能靠它更新既有父卡片的角标。铁律 1 的传导环节。
    func syncBackgroundTasks(from discovered: [ClaudeCodeSession]) {
        var byPid: [Int: ClaudeCodeSession] = [:]
        for d in discovered { byPid[d.pid] = d }
        for (id, var session) in sessions {
            guard let pid = session.pid, let d = byPid[pid] else { continue }
            if session.backgroundTasks != d.backgroundTasks || session.isBackgroundOrphan != d.isBackgroundOrphan {
                session.backgroundTasks = d.backgroundTasks
                session.isBackgroundOrphan = d.isBackgroundOrphan
                sessions[id] = session
            }
        }
    }

    /// Remove sessions whose process is no longer running, and reset stale waitingForInput
    private func pruneDeadSessions() {
        // COMPLETED 短闪窗口衰减:过期即清点并写回(触发 $sessions → 设备收到 2→0)
        let nowD = Date()
        for (sid, var sess) in sessions {
            if let c = sess.completedAt, nowD.timeIntervalSince(c) > 60 {
                sess.completedAt = nil
                sessions[sid] = sess
            }
        }
        var removed = 0
        let now = Date()
        for (id, var session) in sessions {
            guard session.phase != .ended else { continue }

            // Prune dead processes
            if let pid = session.pid, kill(Int32(pid), 0) != 0 {
                let path = session.resolvedTranscriptPath
                sessions.removeValue(forKey: id)
                Task { [reader = transcriptReader] in
                    await reader.invalidate(transcriptPath: path)
                }
                removed += 1
                continue
            }

            // Reset stale waitingForInput (>5 min without activity)
            if session.phase == .waitingForInput,
               now.timeIntervalSince(session.lastActivity) > 300 {
                session.phase = .idle
                session.lastActivity = now
                sessions[id] = session
                logger.info("Reset stale waitingForInput for \(id.prefix(8), privacy: .public)")
            }
        }
        if removed > 0 {
            logger.info("Pruned \(removed) dead sessions")
        }

        // Prune expired permission sockets and update session phases
        let expiredIds = HookSocketServer.shared.pruneExpiredPermissions()
        for id in expiredIds {
            if var s = sessions[id], s.phase.isWaitingForApproval {
                s.phase = .processing
                s.lastActivity = now
                sessions[id] = s
                logger.info("Cleared expired approval for \(id.prefix(8), privacy: .public)")
            }
        }
    }

    func stop() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        transcriptRefreshTimer?.invalidate()
        transcriptRefreshTimer = nil
        Task { [reader = transcriptReader] in
            await reader.invalidateAll()
        }
        HookSocketServer.shared.stop()
        isServerRunning = false
    }

    // MARK: - Permission Actions

    func approvePermission(sessionId: String) {
        ClaudeCodeSessionManager.log("[Perm] Approve session \(sessionId.prefix(8)), phase=\(sessions[sessionId]?.phase.description ?? "nil"), pendingCount=\(HookSocketServer.shared.pendingPermissionCount(sessionId: sessionId))")
        let toolUseId = HookSocketServer.shared.respondToPermissionBySession(
            sessionId: sessionId, decision: "allow"
        )
        // REQ-022:Mac UI 判决 → Coordinator.resolveElsewhere → 0x56(2) 撤销设备条目
        if let toolUseId {
            ApprovalCoordinator.shared.resolveClaude(sessionId: sessionId,
                                                     toolUseId: toolUseId, reason: .macUI)
        }
        updatePhaseAfterPermissionResponse(sessionId: sessionId)
        ClaudeCodeSessionManager.log("[Perm] Approve done, phase=\(sessions[sessionId]?.phase.description ?? "nil")")
    }

    func denyPermission(sessionId: String, reason: String? = nil) {
        ClaudeCodeSessionManager.log("[Perm] Deny session \(sessionId.prefix(8)), sending response...")
        let toolUseId = HookSocketServer.shared.respondToPermissionBySession(
            sessionId: sessionId, decision: "deny", reason: reason
        )
        // REQ-022:Mac UI 判决 → Coordinator.resolveElsewhere → 0x56(2) 撤销设备条目
        if let toolUseId {
            ApprovalCoordinator.shared.resolveClaude(sessionId: sessionId,
                                                     toolUseId: toolUseId, reason: .macUI)
        }
        ClaudeCodeSessionManager.log("[Perm] Deny response sent, updating phase...")
        updatePhaseAfterPermissionResponse(sessionId: sessionId)
        ClaudeCodeSessionManager.log("[Perm] Phase updated to \(sessions[sessionId]?.phase.description ?? "nil")")
    }

    /// REQ-022:设备端判决经 Coordinator 直接应答 hook socket 后,回来更新会话相位
    /// (与 Mac UI 判决同一套相位推进逻辑)
    func notePermissionResponded(sessionId: String) {
        updatePhaseAfterPermissionResponse(sessionId: sessionId)
    }

    /// After responding to a permission, check if more are queued
    private func updatePhaseAfterPermissionResponse(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        let remaining = HookSocketServer.shared.pendingPermissionCount(sessionId: sessionId)
        if remaining > 0, let nextEvent = HookSocketServer.shared.oldestPendingPermission(sessionId: sessionId) {
            // Show the next queued permission
            session.phase = .waitingForApproval(PermissionContext(
                toolUseId: nextEvent.toolUseId ?? "",
                toolName: nextEvent.tool ?? "unknown",
                toolInput: nextEvent.toolInput,
                receivedAt: Date()
            ))
            logger.info("Next queued permission for \(sessionId.prefix(8), privacy: .public), \(remaining) remaining")
        } else {
            session.phase = .processing
        }
        session.lastActivity = Date()
        sessions[sessionId] = session
        updatePinState(forActiveSessionId: sessionId)
    }

    /// Count of pending permissions for a session
    func pendingPermissionCount(sessionId: String) -> Int {
        HookSocketServer.shared.pendingPermissionCount(sessionId: sessionId)
    }

    // MARK: - Transcript Snapshots

    /// Kick off (fire-and-forget) a transcript refresh for one session.
    /// Idempotent — `SessionTranscriptReader` gates on (mtime, size) so burst
    /// calls from the same hook tick collapse to one actual file read.
    private func scheduleTranscriptRefresh(sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        let path = session.resolvedTranscriptPath
        let reader = transcriptReader
        let pricing = currentPricing
        Task { @MainActor [weak self] in
            let snapshot = await reader.refresh(transcriptPath: path, pricing: pricing)
            guard let snapshot, let self, var s = self.sessions[sessionId] else { return }
            s.transcriptSnapshot = snapshot
            self.sessions[sessionId] = s
        }
    }

    /// Called from the 10s timer — refreshes every non-ended session so
    /// seed-scanned sessions (no hook events ever) also pick up snapshots.
    /// Also called after a pricing-catalog change so every visible session
    /// switches to the new rates in one sweep (no new/old mixing).
    private func refreshAllTranscriptSnapshots() {
        // Include .ended sessions too — they linger up to ~10s before prune,
        // and we don't want the old cost lingering visibly after a catalog flip.
        for sid in sessions.keys {
            scheduleTranscriptRefresh(sessionId: sid)
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: HookEvent) {
        SessionNavigationService.record(event: event)
        let sessionId = event.sessionId
        let now = Date()

        switch event.event {
        case "UserPromptSubmit":
            let next = (lifecycleSequence[sessionId] ?? 0) + 1
            lifecycleSequence[sessionId] = next
            let turnID = "claude-\(next)"
            activeLifecycleTurns[sessionId] = turnID
            onTaskLifecycleEvent?(TaskLifecycleSignal(
                provider: .claude, sessionID: sessionId, turnID: turnID, outcome: .started
            ))
        case "Stop":
            if let turnID = activeLifecycleTurns.removeValue(forKey: sessionId) {
                onTaskLifecycleEvent?(TaskLifecycleSignal(
                    provider: .claude, sessionID: sessionId, turnID: turnID, outcome: .completed
                ))
            }
        case "StopFailure":
            if let turnID = activeLifecycleTurns.removeValue(forKey: sessionId) {
                onTaskLifecycleEvent?(TaskLifecycleSignal(
                    provider: .claude, sessionID: sessionId, turnID: turnID, outcome: .failed
                ))
            }
        case "SessionEnd":
            if let turnID = activeLifecycleTurns.removeValue(forKey: sessionId) {
                onTaskLifecycleEvent?(TaskLifecycleSignal(
                    provider: .claude, sessionID: sessionId, turnID: turnID, outcome: .cancelled
                ))
            }
        default:
            break
        }

        let phase = mapPhase(event)

        if var session = sessions[sessionId] {
            session.cwd = event.cwd
            session.phase = phase
            session.pid = event.pid ?? session.pid
            session.tty = event.tty ?? session.tty
            if let tool = event.tool { session.lastTool = tool }
            session.lastActivity = now
            if let p = event.transcriptPath { session.transcriptPath = p }
            if let m = event.permissionMode { session.permissionMode = m }
            session.agentId = event.agentId
            session.agentType = event.agentType

            // REQ-022 后续批:错误会话宽限期 — 带 hasError 结束时记录时间戳,
            // isActive 据此保活 60s(v5 帧持续下发 state=6,穿过 500ms 推送去抖)
            if phase == .ended, session.hasError, session.errorEndedAt == nil {
                session.errorEndedAt = now
                logger.info("Session \(sessionId.prefix(8), privacy: .public) ended with error — grace period \(Int(Self.errorGracePeriod))s")
            }

            sessions[sessionId] = session
            updatePinState(forActiveSessionId: sessionId)

            // Clean up ended sessions after delay
            // (REQ-022 后续批:错误会话延至宽限期后移除,移除本身触发 $sessions
            //  推送,设备端条目随列表更新消失,无额外响铃)
            let removalDelay: Double = session.errorEndedAt != nil ? Self.errorGracePeriod + 1 : 10
            if phase == .ended {
                // 结束的会话立即失去置顶资格（activeSessions 已过滤 ended，但避免
                // pinnedSessionId 挂着一个不可见 id 误导后续逻辑）
                if pinnedSessionId == sessionId {
                    pinnedSessionId = nil
                }
                Task {
                    try? await Task.sleep(for: .seconds(removalDelay))
                    await MainActor.run { [weak self] in
                        if self?.sessions[sessionId]?.phase == .ended {
                            self?.sessions.removeValue(forKey: sessionId)
                            if self?.pinnedSessionId == sessionId {
                                self?.pinnedSessionId = nil
                            }
                        }
                    }
                }
            }
        } else if phase != .ended {
            // Remove any session with same PID or same TTY but different ID:
            // - seed 会话(process-level ID)被 hook 会话(conversation-level ID)替换
            // - session id 轮转(claude 续段/resume 换 id,进程/终端不变):同一进程或
            //   同一终端不可能并行跑两个会话,旧 id 条目是残留,直接吸收,
            //   否则旧段卡在 processing 相位永久占一个列表槽位(设备端出现同名双条目)
            for (id, s) in sessions where id != sessionId {
                let samePid = event.pid != nil && s.pid == event.pid
                let sameTty = event.tty != nil && s.tty == event.tty
                if samePid || sameTty {
                    sessions.removeValue(forKey: id)
                    logger.debug("Absorbed stale session \(id.prefix(8), privacy: .public) into \(sessionId.prefix(8), privacy: .public) (\(samePid ? "pid" : "tty", privacy: .public) match)")
                }
            }
            let newSession = HookSession(
                id: sessionId, cwd: event.cwd, phase: phase,
                pid: event.pid, tty: event.tty, lastTool: event.tool,
                lastActivity: now, name: nil,
                transcriptPath: event.transcriptPath,
                permissionMode: event.permissionMode,
                agentId: event.agentId,
                agentType: event.agentType
            )

            sessions[sessionId] = newSession
        }

        // REQ-022 后续批:错误标记/清除/工具失败计数(在会话 upsert 之后统一处理)
        if var s = sessions[sessionId] {
            switch event.event {
            case "StopFailure":
                s.hasError = true
                s.lastError = event.error
                sessions[sessionId] = s
                logger.info("Session \(sessionId.prefix(8), privacy: .public) turn error: \(event.error ?? "unknown", privacy: .public)")
            case "Stop":
                // turn 完成打点:60s 完成短闪窗口(v5State idle 分支读取)
                s.completedAt = Date()
                sessions[sessionId] = s
            case "UserPromptSubmit", "PreToolUse":
                // 会话恢复活动 → 清除 error(自然去重:设备只在 BLOCKED 边沿响一次)
                if s.hasError {
                    s.hasError = false
                    s.lastError = nil
                    sessions[sessionId] = s
                    logger.info("Session \(sessionId.prefix(8), privacy: .public) error cleared on \(event.event, privacy: .public)")
                }
            case "PostToolUseFailure":
                // 仅计数,不进状态不响铃(模型常自愈)
                s.toolFailureCount += 1
                sessions[sessionId] = s
                logger.info("Session \(sessionId.prefix(8), privacy: .public) tool failure #\(s.toolFailureCount) tool=\(event.tool ?? "?", privacy: .public) error=\(event.error ?? "?", privacy: .public)")
            default:
                break
            }
        }

        // REQ-022 后续批:thinking 状态机 — UserPromptSubmit/PostToolUse 之后、下一个
        // PreToolUse 之前 = 模型在生成(推理/组织输出)。取舍说明:
        // - 并发工具调用:同批第一条 PostToolUse 即置 true(其余工具可能仍在执行),
        //   提前进入 thinking 视为可接受近似 — 模型即将恢复生成,且下一批 PreToolUse 会再清位;
        // - PermissionRequest 不改标志:其前必有 PreToolUse 已清位,且审批态(5)优先级压过 8;
        // - PostToolUseFailure 不置位(spec 外事件,模型是否续跑不确定,维持保守 false);
        // - SubagentStop 未注册 hook(HookInstaller 事件表),不会到达此处。
        if var s = sessions[sessionId] {
            switch event.event {
            case "UserPromptSubmit", "PostToolUse":
                if !s.modelInferring { s.modelInferring = true; sessions[sessionId] = s }
            case "PreToolUse", "Stop", "SessionEnd", "StopFailure":
                if s.modelInferring { s.modelInferring = false; sessions[sessionId] = s }
            default:
                break
            }
        }

        // REQ-022:审批挂起 → 注册进 ApprovalRegistry(编 0x55 推设备,reqId 精确匹配)
        if case .waitingForApproval(let ctx) = phase, event.expectsResponse {
            let sessionName = sessions[sessionId]?.projectName
                ?? URL(fileURLWithPath: event.cwd).lastPathComponent
            ApprovalCoordinator.shared.registerClaude(
                sessionId: sessionId,
                toolUseId: ctx.toolUseId,
                toolName: ctx.toolName,
                sessionName: sessionName,
                toolInput: event.toolInput
            )
        }

        // Cancel pending permissions when session moves past approval
        if event.event == "PostToolUse" || event.event == "Stop" {
            if let toolUseId = event.toolUseId {
                HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                // REQ-022:原生端先答/越过审批 → 0x56(2) 撤销设备条目
                ApprovalCoordinator.shared.resolveClaude(sessionId: sessionId,
                                                         toolUseId: toolUseId,
                                                         reason: .rolloutEvent)
            }
        }

        // REQ-022:会话结束 → 该会话全部 pending → cancelled + 0x56(5)
        if event.event == "SessionEnd" {
            ApprovalCoordinator.shared.endSession(sessionKey: sessionId)
        }

        if event.event == "UserPromptSubmit" {
            InputRouter.handleAgentHookPromptSubmit(sessionId: sessionId, prompt: event.prompt)
        }

        logger.debug("Session \(sessionId.prefix(8), privacy: .public) → \(phase.description, privacy: .public)")

        // Pull a fresh transcript snapshot — cache-gated by (mtime, size) so a
        // steady-state session only triggers one tail read per transcript write.
        if phase != .ended {
            scheduleTranscriptRefresh(sessionId: sessionId)
        }
    }

    private func mapPhase(_ event: HookEvent) -> SessionPhase {
        if event.event == "PreCompact" { return .compacting }

        // Stop = turn 正常完成 → idle(READY/COMPLETED 绿系,完成音靠设备边沿)。
        // 旧行为 Stop→waitingForInput 使 CC 永远黄灯无完成态(用户 2026-07-23 反馈修正);
        // 真正"等输入"由 Notification idle_prompt(status waiting_for_input)独立驱动,闲置后自然转黄。
        if event.event == "Stop" { return .idle }

        // PostToolUse without specific status means processing continues
        if event.event == "PostToolUse" && event.status.isEmpty { return .processing }

        switch event.status {
        case "waiting_for_approval":
            return .waitingForApproval(PermissionContext(
                toolUseId: event.toolUseId ?? "",
                toolName: event.tool ?? "unknown",
                toolInput: event.toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        // REQ-022 后续批:turn_error = turn 因 API 错误结束 → 等用户处理(error 标记另走 hasError);
        // tool_error = 单工具失败,模型通常继续 → 维持 processing
        case "turn_error":
            return .waitingForInput
        case "processing", "running_tool", "tool_error":
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        default:
            logger.debug("Unknown event/status: event=\(event.event, privacy: .public) status=\(event.status, privacy: .public)")
            return .idle
        }
    }
}

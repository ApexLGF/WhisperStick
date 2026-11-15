import Foundation

/// 单个 agent 的用量快照;字段 nil = 该 agent 不提供该数据(mock/未接入 → "不可用"态)。
struct AgentUsageSnapshot {
    var todayPercent: Double?      // five_hour 窗口(文案不得写"今日24h")
    var todayResetsAt: Date?
    var weekPercent: Double?       // seven_day
    var weekResetsAt: Date?
    /// 窗口标签;Codex 的窗口随 plan 变(plus: 5h+7d / free: 单一 30d),由 provider 按 window_minutes 定。
    /// CC five_hour 窗口按实际时长标注(2026-07-10 用户定案:「今日用量」改「5小时用量」)
    var todayLabel: String = AppL10n.tr("5小时用量")
    var weekLabel: String = AppL10n.tr("本周用量")
    var exclusiveName: String?     // 直通会话名(从标题栏迁入)
    var sevenDayPeaks: [Double?]?  // 近7天(旧→今)每日 five_hour 峰值%;nil=该 agent 不支持,隐藏该行
    var lastUpdated: Date?         // 数据获取时间;仅成功拉取时更新,卡片常显"数据获取于"标注
    var awaitingFirstData: Bool = false   // 冷启动等待首份会话数据;卡片显示等待动画而非"用量不可用"
    var isAvailable: Bool { todayPercent != nil || weekPercent != nil }
}

/// 一个编程 agent 的抽象:名称/安装/用量/会话/阻塞。CC 首实现,Codex mock 验证扩展性。
@MainActor
protocol AgentProvider {
    var shortName: String { get }        // "CC" / "Codex" — 会话区标题用
    var displayName: String { get }      // "Claude Code" / "Codex"
    var iconAssetName: String { get }    // "ClaudeCodeIcon" / mock 用 SF Symbol 兜底
    var isInstalled: Bool { get }
    var billingMode: AgentBillingMode { get }
    var usage: AgentUsageSnapshot { get }
    var activeSessions: [HookSession] { get }   // REQ-028 层1+层2,phasePriority 排序
    var inactiveSessions: [HookSession] { get } // REQ-028 层3,lastActivity 倒序,≤50 条
    /// 标题行身份徽章:订阅 plan(isPlan=true,橙 pill)/ "API" 或第三方域名(灰 pill)/ nil 不显示
    var identityBadge: (text: String, isPlan: Bool)? { get }
    /// 徽章 tooltip(REQ-023):API 中转/本地中转时为 base URL 原文;其余 nil 不显示
    var identityBadgeHelp: String? { get }
}

extension AgentProvider {
    var identityBadgeHelp: String? { nil }
    var billingMode: AgentBillingMode { .unknown }
}

/// Claude Code 首实现:包装现有 UsageManager / HookStore / SelectionStore。
/// 值全部在 `get` 里现算、不缓存 —— 避免把 @Published 反应性丢在非 @Published 快照里。
struct ClaudeCodeProvider: AgentProvider {
    let usageManager: ClaudeUsageManager
    let hookStore: ClaudeHookSessionStore
    let selectionStore: SessionSelectionStore

    init(usage: ClaudeUsageManager, store: ClaudeHookSessionStore, selection: SessionSelectionStore) {
        self.usageManager = usage
        self.hookStore = store
        self.selectionStore = selection
    }

    var shortName: String { "CC" }
    var displayName: String { "Claude Code" }
    var iconAssetName: String { "ClaudeCodeIcon" }
    var isInstalled: Bool { ClaudeUsageManager.isClaudeCodeInstalled }
    var billingMode: AgentBillingMode { usageManager.billingMode }

    var usage: AgentUsageSnapshot {
        var snap = AgentUsageSnapshot()
        if let sid = selectionStore.selectedSessionId,
           let session = hookStore.sessions[sid], session.phase != .ended {
            snap.exclusiveName = session.projectName
        }
        guard case .subscription = billingMode else { return snap }
        snap.awaitingFirstData = usageManager.awaitingFirstData
        guard let stats = usageManager.stats else { return snap }
        snap.todayPercent = stats.sessionUsedPercent
        snap.todayResetsAt = stats.sessionResetsAt
        snap.weekPercent = stats.weekUsedPercent
        snap.weekResetsAt = stats.weekResetsAt
        snap.sevenDayPeaks = usageManager.last7DayPeaks()
        snap.lastUpdated = stats.lastUpdated
        return snap
    }

    var activeSessions: [HookSession] { hookStore.activeSessions }
    var inactiveSessions: [HookSession] { hookStore.inactiveSessions }

    var identityBadge: (text: String, isPlan: Bool)? {
        billingMode.identityBadge
    }

    var identityBadgeHelp: String? {
        billingMode.identityBadgeHelp
    }
}

/// mock Codex：用量全 nil(不可用态)、会话空。仅验证不改布局即可上第二张卡。
struct MockCodexProvider: AgentProvider {
    var shortName: String { "Codex" }
    var displayName: String { "Codex" }
    var iconAssetName: String { "terminal" }   // SF Symbol 兜底(无自带 asset)
    var isInstalled: Bool { true }
    var billingMode: AgentBillingMode { .api(endpoint: .init(badgeText: "API", fullURL: nil)) }
    var usage: AgentUsageSnapshot { AgentUsageSnapshot() }
    var activeSessions: [HookSession] { [] }
    var inactiveSessions: [HookSession] { [] }
    var identityBadge: (text: String, isPlan: Bool)? { ("API", false) }
}

/// T-027 ui-smoke 夹具:一张带后台任务角标的父卡 + 一张无 socket 置灰直通的卡。
struct MockBgSessionProvider: AgentProvider {
    var shortName: String { "CC" }
    var displayName: String { "Claude Code" }
    var iconAssetName: String { "ClaudeCodeIcon" }
    var isInstalled: Bool { true }
    var usage: AgentUsageSnapshot { AgentUsageSnapshot() }
    var identityBadge: (text: String, isPlan: Bool)? { nil }
    var activeSessions: [HookSession] {
        var parent = HookSession(id: "mock-parent", cwd: "/tmp/demo", phase: .processing,
                                 pid: 999_999, tty: "ttys999", lastTool: nil, lastActivity: Date(), name: "demo-parent")
        parent.backgroundTasks = [BackgroundTaskInfo(jobId: "job-1", name: AppL10n.tr("后台构建"), status: "busy")]
        // pid 999999 无 /tmp/vibepty-999999.sock → 直通按钮置灰
        return [parent]
    }
    var inactiveSessions: [HookSession] { [] }
}

/// T-034 ui-smoke 夹具:两组齐全(活跃 3 条含审批置顶 / 非活跃 4 条倒序),供分组截图。
struct MockTierProvider: AgentProvider {
    var shortName: String { "CC" }
    var displayName: String { "Claude Code" }
    var iconAssetName: String { "ClaudeCodeIcon" }
    var isInstalled: Bool { true }
    var usage: AgentUsageSnapshot { AgentUsageSnapshot() }
    var identityBadge: (text: String, isPlan: Bool)? { nil }
    private func mk(_ id: String, _ name: String, _ phase: SessionPhase, _ ago: TimeInterval) -> HookSession {
        HookSession(id: id, cwd: "/tmp/\(name)", phase: phase, pid: nil, tty: nil,
                    lastTool: nil, lastActivity: Date().addingTimeInterval(-ago), name: name)
    }
    var activeSessions: [HookSession] { [
        mk("t-appr", AppL10n.tr("等审批-项目"), .waitingForInput, 120),
        mk("t-work", AppL10n.tr("工作中-项目"), .processing, 60),
        mk("t-idle", AppL10n.tr("挂着-项目"), .idle, 900),
    ] }
    var inactiveSessions: [HookSession] { [
        mk("t-i1", AppL10n.tr("非活跃-一"), .idle, 3600),
        mk("t-i2", AppL10n.tr("非活跃-二"), .idle, 7200),
        mk("t-i3", AppL10n.tr("非活跃-三"), .idle, 10800),
        mk("t-i4", AppL10n.tr("非活跃-四"), .idle, 14400),
    ] }
}

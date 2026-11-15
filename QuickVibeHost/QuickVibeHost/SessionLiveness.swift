import Foundation

/// REQ-028 §1 统一三层判定模型。数值即优先级(小=更活跃),便于排序与协议编码。
enum SessionTier: Int, Comparable, Sendable {
    case working  = 1   // 层1 活动的:最后写入 < 30min。**不做任何进程匹配**(REQ-028 §1)
    case attached = 2   // 层2 活跃的:宿主判定AppL10n.tr("可立即操作")但超 30min 无产出
    case detached = 3   // 层3 非活跃:只读、可 resume
    static func < (a: SessionTier, b: SessionTier) -> Bool { a.rawValue < b.rawValue }
}

/// REQ-028 §4 用户逐项拍板的参数。**一个都不许改**(task §4.2);单测直接断言这些值。
enum SessionLivenessParams {
    static let activityThreshold: TimeInterval = 30 * 60      // 层1 阈值 30min
    static let retentionWindow:   TimeInterval = 24 * 3600    // 非活跃保留窗,App 与设备端统一
    static let minSessionLifetime: TimeInterval = 30          // 存活 <30s 即死 → 不显示
    static let deviceInactiveCap = 5                          // 设备端非活跃组上限
    static let appInactiveCap    = 50                         // App 端非活跃组上限
}

/// 判定所需的**全部**事实。调用方负责从各自的会话模型里摘出来 —— 分类器不认识 HookSession。
struct LivenessFacts: Sendable {
    let lastActivity: Date
    let startedAt: Date?
    /// REQ-028 §3 活跃组内排序:等审批(0) > 工作中(1) > 等输入(2) > 挂着(3)
    let phasePriority: Int
    /// 宿主"可立即操作"信号,由 AgentLivenessStrategy 算好后填入。层1 判定**完全不看它**。
    let attached: Bool
    /// 审批挂起 → 恒活跃(现有语义保留:阻塞会话必须可见)
    let approvalPending: Bool
}

enum SessionTierClassifier {
    /// nil = 不显示。判定顺序即 REQ-028 §1 的层级顺序,不得调换。
    static func tier(_ f: LivenessFacts, now: Date) -> SessionTier? {
        if f.approvalPending { return .working }
        // 层1:写入时间戳是唯一依据(REQ-028 §1 第 1 条硬性约束)
        if now.timeIntervalSince(f.lastActivity) < SessionLivenessParams.activityThreshold {
            return .working
        }
        // 层2:宿主存活信号(插件给出)。§ 0-C:层2 不受 24h 窗切割
        if f.attached { return .attached }
        // 层3:24h 保留窗 + <30s 即死噪声过滤(§ 0-E)
        if now.timeIntervalSince(f.lastActivity) > SessionLivenessParams.retentionWindow { return nil }
        if let s = f.startedAt,
           f.lastActivity.timeIntervalSince(s) < SessionLivenessParams.minSessionLifetime { return nil }
        return .detached
    }
}

/// REQ-028 §2:按 agent 类型的宿主判活策略。未来 pi/opencode 实现本接口注册接入;
/// UI 不按类型分组(避免类型爆炸)。**纯值语义,信号由构造时注入,便于 fixture 单测。**
protocol AgentLivenessStrategy: Sendable {
    var agentKey: String { get }
    /// 该策略是否负责这个 session key(key 前缀路由)
    func handles(sessionKey: String) -> Bool
    /// 层2 信号:宿主是否"当前加载/挂着"该会话
    func isAttached(sessionKey: String, pid: Int?, transcriptPath: String?) -> Bool
}

/// Claude Code(CLI/Desktop):hook pid → kill(pid,0)。现有机制保持(REQ-028 §2 表)。
struct ClaudeLivenessStrategy: AgentLivenessStrategy {
    var agentKey: String { "claude" }
    /// 注入点:单测传假实现,生产传 { kill(Int32($0), 0) == 0 }
    let isProcessAlive: @Sendable (Int) -> Bool
    func handles(sessionKey: String) -> Bool { !sessionKey.hasPrefix("codex-") }
    func isAttached(sessionKey: String, pid: Int?, transcriptPath: String?) -> Bool {
        guard let pid else { return false }
        return isProcessAlive(pid)
    }
}

/// Codex CLI(TUI)/ Codex Desktop(ChatGPT 内嵌):rollout 文件被活体进程持有(lsof fd 枚举)。
/// **Desktop 开着 ≠ 会话活跃**:内嵌 codex 进程只持有当前加载会话的 fd(2026-07-27 实测,REQ-028 §6)。
/// **降级拍板(REQ-028 §2)**:查不到持有一律归层3 —— 宁折叠不误报。lsof 失败 → 空集 → 全层3。
struct CodexLivenessStrategy: AgentLivenessStrategy {
    var agentKey: String { "codex" }
    /// 本轮 lsof 枚举出的、被活体 codex 进程持有的 rollout 绝对路径(已 resolveSymlinks)
    let attachedRolloutPaths: Set<String>
    func handles(sessionKey: String) -> Bool { sessionKey.hasPrefix("codex-") }
    func isAttached(sessionKey: String, pid: Int?, transcriptPath: String?) -> Bool {
        guard let p = transcriptPath else { return false }
        return attachedRolloutPaths.contains(CodexFdProbe.normalize(p))
    }
}

/// lsof 输出解析 —— 纯函数,单测喂 fixture 文本即可,不需要真实 codex 环境(task §3.2)。
enum CodexFdProbe {
    static func normalize(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
    /// 解析 `lsof -a -c codex -F pn` 的输出;取所有形如 `.../rollout-*.jsonl` 的 n 行。
    /// -F 输出格式:每进程一行 `p<pid>`,其后每个打开文件一行 `n<path>`(可能夹杂 f/t 行,忽略)。
    static func parseLsofRolloutPaths(_ output: String) -> Set<String> {
        var out = Set<String>()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            let base = (path as NSString).lastPathComponent
            guard base.hasPrefix("rollout-"), base.hasSuffix(".jsonl") else { continue }
            out.insert(normalize(path))
        }
        return out
    }
}

/// REQ-028 §3 分组与排序。泛型于会话类型 —— 分类器不认识 HookSession,单测用 String 即可。
enum SessionGrouping {
    /// - 活跃组 = 层1 + 层2,组内 phasePriority 升序,同级 lastActivity 倒序
    /// - 非活跃组 = 层3,lastActivity 倒序,截断到 inactiveCap
    static func group<T>(_ items: [(item: T, facts: LivenessFacts, tier: SessionTier)],
                         inactiveCap: Int) -> (active: [T], inactive: [T]) {
        let act = items.filter { $0.tier != .detached }.sorted { a, b in
            if a.facts.phasePriority != b.facts.phasePriority {
                return a.facts.phasePriority < b.facts.phasePriority
            }
            return a.facts.lastActivity > b.facts.lastActivity
        }
        let inact = items.filter { $0.tier == .detached }
            .sorted { $0.facts.lastActivity > $1.facts.lastActivity }
            .prefix(inactiveCap)
        return (act.map(\.item), inact.map(\.item))
    }
}

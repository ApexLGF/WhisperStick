import Foundation
import UserNotifications

struct ClaudeUsageStats: Codable {
    var sessionUsedPercent: Double = 0
    var sessionResetsAt: Date?
    var weekUsedPercent: Double = 0
    var weekResetsAt: Date?
    var lastUpdated: Date?

    // Context window (current session)
    var contextUsedPercent: Double = 0
    var contextRemainingPercent: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    // Cost (current session)
    var totalCostUSD: Double = 0
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var costUpdatedAt: Date?   // 费用/代码行来源(statusLine capture)的 mtime;>7 天视为过期不展示
}

enum UsageAlert {
    case sessionHigh(Double)
    case weekHigh(Double)

    var message: String {
        switch self {
        case .sessionHigh(let pct): AppL10n.format("当前会话用量已达 %@%", String(Int(pct)))
        case .weekHigh(let pct): AppL10n.format("本周用量已达 %@%", String(Int(pct)))
        }
    }
}

@MainActor
final class ClaudeUsageManager: ObservableObject {
    @Published var stats: ClaudeUsageStats?
    @Published var alert: UsageAlert?
    @Published var awaitingFirstData: Bool = false   // 冷启动无快照且尚无 capture:等待首个 CC 会话渲染状态行产出数据
    @Published private(set) var billingMode: AgentBillingMode = .unknown
    var subscriptionPlan: String? {
        if case .subscription(let plan) = billingMode { return plan }
        return nil
    }
    @Published private(set) var dailyPeaks: [String: Double] = [:]  // "yyyy-MM-dd" → 当日 five_hour 峰值%

    private var timer: Timer?
    private var lastNotificationDate: Date?
    private var lastBillingModeRefresh: Date?

    private let sessionThreshold: Double = 95
    private let weekThreshold: Double = 98
    private let notificationCooldown: TimeInterval = 4 * 3600 // 4 hours

    nonisolated static var isClaudeCodeInstalled: Bool {
        let home = NSHomeDirectory()
        if FileManager.default.isExecutableFile(atPath: "\(home)/.local/bin/claude") {
            return true
        }
        if FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: "\(home)/Applications/Claude.app") {
            return true
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.vscode/extensions") else {
            return false
        }
        return names.contains { $0.hasPrefix("anthropic.claude-code-") }
    }

    init() {
        loadDailyPeaks()
        loadSnapshot()
        awaitingFirstData = (stats == nil)   // 有落盘快照就直接显旧值,不进等待态
    }

    func startPolling() {
        refresh()
        refreshBillingMode(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshBillingMode()
            }
        }
    }

    private func refreshBillingMode(force: Bool = false) {
        if !force, let lastBillingModeRefresh,
           Date().timeIntervalSince(lastBillingModeRefresh) < 60 { return }
        lastBillingModeRefresh = Date()
        Task.detached {
            let auth = Self.runClaudeAuthStatus()
            let configuration = Self.apiConfiguration()
            let endpoint = APIEndpointClassifier.classify(baseURL: configuration.baseURL)
            let mode = AgentBillingModeDetector.claude(
                authStatusData: auth,
                hasExplicitAPICredential: configuration.hasAPICredential,
                endpoint: endpoint
            )
            await MainActor.run { [weak self] in
                self?.billingMode = mode
            }
        }
    }

    nonisolated private static func runClaudeAuthStatus() -> Data? {
        let home = NSHomeDirectory()
        let claudePath = "\(home)/.local/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: claudePath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["auth", "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return process.terminationStatus == 0 ? data : nil
        } catch {}
        return nil
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 七日用量历史(当日 five_hour 峰值,REQ-015 用量卡)

    private var historyPath: String {
        NSHomeDirectory() + "/Library/Application Support/QuickVibeHost/usage-history.json"
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

    /// 每轮 refresh 记录当天观测到的 five_hour 峰值;只在峰值刷新时落盘,保留 30 天
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

    /// 近 7 天(旧→今)每日峰值;无记录的天为 nil(用量卡画灰空条)
    func last7DayPeaks() -> [Double?] {
        (0..<7).reversed().map { offset in
            guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return dailyPeaks[Self.dayKey(d)]
        }
    }

    // MARK: - 额度快照落盘(冷启动先显旧值,拉到新值覆盖;stale 标注由 lastUpdated 驱动)

    private var snapshotPath: String {
        NSHomeDirectory() + "/Library/Application Support/QuickVibeHost/usage-snapshot.json"
    }

    private func loadSnapshot() {
        guard let data = FileManager.default.contents(atPath: snapshotPath),
              let s = try? JSONDecoder().decode(ClaudeUsageStats.self, from: data) else { return }
        stats = s
    }

    private func saveSnapshot(_ s: ClaudeUsageStats) {
        let url = URL(fileURLWithPath: snapshotPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: url)
        }
    }

    /// 无订阅时的身份识别(REQ-023):base URL 分类 → 官方"API" / "API·中转 host" /
    /// "API·本地中转 host:port"。优先消费进程 env/settings.json；GUI 启动拿不到
    /// ~/.zshrc 时，用有超时的登录 Shell 安全探测 URL 和凭据存在性，不输出凭据内容。
    nonisolated private static func apiConfiguration() -> (baseURL: String?, hasAPICredential: Bool) {
        let processEnv = ProcessInfo.processInfo.environment
        var base = nonEmpty(processEnv["ANTHROPIC_BASE_URL"])
        var hasCredential = nonEmpty(processEnv["ANTHROPIC_API_KEY"]) != nil
            || nonEmpty(processEnv["ANTHROPIC_AUTH_TOKEN"]) != nil
        if let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = json["env"] as? [String: Any] {
            if base == nil { base = nonEmpty(env["ANTHROPIC_BASE_URL"] as? String) }
            if !hasCredential {
                hasCredential = nonEmpty(env["ANTHROPIC_API_KEY"] as? String) != nil
                    || nonEmpty(env["ANTHROPIC_AUTH_TOKEN"] as? String) != nil
            }
        }
        if base == nil || !hasCredential, let shell = loginShellAPIConfiguration() {
            if base == nil { base = shell.baseURL }
            if !hasCredential { hasCredential = shell.hasAPICredential }
        }
        return (base, hasCredential)
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Runs the user's normal zsh startup path but emits only the endpoint plus a boolean.
    /// The credential itself is never written to stdout, logs, or persistent storage.
    nonisolated private static func loginShellAPIConfiguration() -> ClaudeShellEnvironmentEvidence? {
        let shell = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let script = """
        printf '%s\\n' '\(ClaudeShellEnvironmentProbe.marker)'
        printf 'QVH_BASE_URL=%s\\n' "${ANTHROPIC_BASE_URL-}"
        if [ -n "${ANTHROPIC_API_KEY-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN-}" ]; then
          printf '%s\\n' 'QVH_HAS_CREDENTIAL=1'
        else
          printf '%s\\n' 'QVH_HAS_CREDENTIAL=0'
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            guard finished.wait(timeout: .now() + 3) == .success else {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return ClaudeShellEnvironmentProbe.parse(pipe.fileHandleForReading.readDataToEndOfFile())
        } catch {
            return nil
        }
    }

    /// 额度/上下文/费用全部来自 statusLine capture(本地文件,零网络、零凭据)。
    /// OAuth 端点路径已移除:无代理网络下 api.anthropic.com 不可达,且依赖 TLS 指纹放行 + token 轮换。
    /// 数据新鲜度依赖 CC session 自身刷新 statusLine;无新 capture 时保留上次值,由 lastUpdated 标注数据时刻。
    private func refresh() {
        Task.detached {
            let sample = Self.readLatestCapture()
            await MainActor.run { [weak self] in
                guard let self, var s = sample else { return }
                let now = Date()
                // 窗口已重置而 capture 未更新:百分比描述的是上一个窗口,清零并摘掉倒计时,不展示过期值
                if let r = s.sessionResetsAt, r <= now {
                    s.sessionUsedPercent = 0
                    s.sessionResetsAt = nil
                }
                if let r = s.weekResetsAt, r <= now {
                    s.weekUsedPercent = 0
                    s.weekResetsAt = nil
                }
                self.stats = s
                self.awaitingFirstData = false
                self.saveSnapshot(s)
                if case .subscription = self.billingMode {
                    self.recordDailyPeak(s.sessionUsedPercent)
                    self.checkThresholds(s)
                } else {
                    self.alert = nil
                }
            }
        }
    }

    // MARK: - statusLine capture 读取(StatusLineInstaller 安装的 wrapper 逐 session 落盘)

    /// 最新一份带 rate_limits 的 capture(mtime 序)。无 rate_limits 的 capture(首个 API 响应前、
    /// API-key 会话)整份跳过——较新但无额度的 capture 不会覆盖较旧有额度的(防并行会话翻转)。
    /// mtime 超 7 天的文件描述不了任何当前窗口,读到即删。lastUpdated/costUpdatedAt = capture mtime。
    /// v5(REQ-007/REQ-017):指定会话的 context **已用**%。capture 文件按 session_id
    /// 命名,逐会话读取;mtime 缓存避免每次推送重复解析。nil = 该会话无 capture 数据。
    /// REQ-017 决策:显示语义双端统一为"已用"(此前为余量)。
    private var perSessionCtxCache: [String: (mtime: Date, pct: Int)] = [:]
    func contextUsedPercent(sessionId: String) -> Int? {
        let path = StatusLineInstaller.captureDir + "/\(sessionId).json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let cached = perSessionCtxCache[sessionId], cached.mtime == mtime {
            return cached.pct
        }
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctx = json["context_window"] as? [String: Any] else { return nil }
        let pct: Int? = (ctx["used_percentage"] as? Double).map { Int($0) }
                     ?? (ctx["used_percentage"] as? Int)
        guard let pct else { return nil }
        perSessionCtxCache[sessionId] = (mtime, pct)
        return pct
    }

    nonisolated private static func readLatestCapture() -> ClaudeUsageStats? {
        let dir = StatusLineInstaller.captureDir
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var best: (stats: ClaudeUsageStats, mtime: Date)?
        for name in names {
            let path = dir + "/" + name
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if mtime < cutoff {
                // 超期的一并删,包括 sid 提取失败遗留的 .json.tmp(它们不走 mv 改名,只能在这里回收)
                try? fm.removeItem(atPath: path)
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            if let prev = best, mtime <= prev.mtime { continue }
            guard var s = parseFile(path) else { continue }
            s.lastUpdated = mtime
            s.costUpdatedAt = mtime
            best = (s, mtime)
        }
        return best?.stats
    }

    nonisolated private static func parseFile(_ path: String) -> ClaudeUsageStats? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = json["rate_limits"] as? [String: Any] else {
            return nil
        }

        var s = ClaudeUsageStats()

        if let fiveHour = rateLimits["five_hour"] as? [String: Any] {
            s.sessionUsedPercent = (fiveHour["used_percentage"] as? Double) ?? Double(fiveHour["used_percentage"] as? Int ?? 0)
            if let ts = fiveHour["resets_at"] as? TimeInterval {
                s.sessionResetsAt = Date(timeIntervalSince1970: ts)
            }
        }

        if let sevenDay = rateLimits["seven_day"] as? [String: Any] {
            s.weekUsedPercent = (sevenDay["used_percentage"] as? Double) ?? Double(sevenDay["used_percentage"] as? Int ?? 0)
            if let ts = sevenDay["resets_at"] as? TimeInterval {
                s.weekResetsAt = Date(timeIntervalSince1970: ts)
            }
        }

        // Context window
        if let ctx = json["context_window"] as? [String: Any] {
            s.contextUsedPercent = (ctx["used_percentage"] as? Double) ?? Double(ctx["used_percentage"] as? Int ?? 0)
            s.contextRemainingPercent = (ctx["remaining_percentage"] as? Double) ?? Double(ctx["remaining_percentage"] as? Int ?? 0)
            if let usage = ctx["current_usage"] as? [String: Any] {
                s.inputTokens = (usage["input_tokens"] as? Int) ?? 0
                s.outputTokens = (usage["output_tokens"] as? Int) ?? 0
                // Include cache tokens in input count for total picture
                let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                s.inputTokens += cacheCreation + cacheRead
            }
        }

        // Cost
        if let cost = json["cost"] as? [String: Any] {
            s.totalCostUSD = (cost["total_cost_usd"] as? Double) ?? 0
            s.linesAdded = (cost["total_lines_added"] as? Int) ?? 0
            s.linesRemoved = (cost["total_lines_removed"] as? Int) ?? 0
        }

        return s
    }

    private func checkThresholds(_ s: ClaudeUsageStats) {
        if s.sessionUsedPercent >= sessionThreshold {
            alert = .sessionHigh(s.sessionUsedPercent)
            sendNotificationIfNeeded(alert!)
        } else if s.weekUsedPercent >= weekThreshold {
            alert = .weekHigh(s.weekUsedPercent)
            sendNotificationIfNeeded(alert!)
        } else {
            alert = nil
        }
    }

    private func sendNotificationIfNeeded(_ usageAlert: UsageAlert) {
        if let last = lastNotificationDate, Date().timeIntervalSince(last) < notificationCooldown {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = AppL10n.tr("Claude Code 用量告警")
        content.body = usageAlert.message
        content.sound = .default

        let request = UNNotificationRequest(identifier: "claude-usage-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        lastNotificationDate = Date()
    }

    static func requestNotificationPermission() {
        guard !UITestFlags.isHeadless else {
            NSLog("[ui-test] skipped UNUserNotificationCenter.requestAuthorization — headless")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

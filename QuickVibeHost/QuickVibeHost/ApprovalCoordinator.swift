// ApprovalCoordinator.swift
// REQ-022 M1:审批协议 v1 的 Mac 侧集成层。
//
// 职责(三向对接):
//   1. 入口 —— CC(HookSocketServer/ClaudeHookSessionStore)与 Codex(CodexApprovalServer)
//      的审批挂起事件 → ApprovalRegistry.register → 0x55 推设备(BLEManager.sendApprovalFrame)
//   2. 设备回传 —— BLE control 0x36 → registry.onDeviceResponse → 消费动作
//      (respond 分发给 ApprovalResponder、0x56 回设备、recordSessionRule)
//   3. 撤销源 —— PostToolUse/Stop 越过、hook EOF、prune/过期、Mac UI 判决、会话结束
//      → registry.resolveElsewhere / expire / endSession → 0x56 下发
//
// 并发契约(ApprovalRegistry 类头硬性要求):Registry 的所有调用都收敛到本类持有的
// 专用串行队列 `queue`;各入口方法内部一律 queue.async 后再触碰 registry。
// 副作用(socket 写回 / BLE 写 / 会话相位更新)按目标线程分发:
//   - HookSocketServer 自带串行队列,线程安全,可从 queue 直接调
//   - CodexApprovalServer / BLEManager / ClaudeHookSessionStore 是 @MainActor → Task { @MainActor }

import Foundation
import ApprovalKit
import os.log

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "ApprovalCoordinator")

// MARK: - 风险分级(REQ-022 D1,简单规则版)

/// riskLevel 分类器:0=normal(只读类) 1=elevated(写文件/网络/git push) 2=dangerous
/// (rm -rf / sudo / 磁盘操作 / 凭据路径)。规则刻意保守简单,后续按误报迭代。
enum ApprovalRiskClassifier {

    /// 已知只读工具(CC 内置)
    private static let readOnlyTools: Set<String> = [
        "Read", "Grep", "Glob", "WebSearch", "TodoWrite",
        "AskUserQuestion", "ExitPlanMode", "Task",
    ]
    /// 已知写/网络类工具 → elevated
    private static let elevatedTools: Set<String> = [
        "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch",
    ]
    /// Bash 命令的只读前缀白名单(命中 → normal;否则 Bash 默认 elevated)
    private static let readOnlyBashPrefixes: [String] = [
        "ls", "cat", "head", "tail", "grep", "rg", "find", "pwd", "which", "echo",
        "wc", "file", "stat", "du", "df", "ps", "env", "git status", "git log",
        "git diff", "git show", "git branch",
    ]
    /// dangerous 关键词(任一命中 → 2)
    private static let dangerousPatterns: [String] = [
        "rm -rf", "rm -fr", "rm -r -f", "sudo ", "diskutil", "mkfs", "fdisk",
        "/dev/disk", "/dev/rdisk", " dd if=", " dd of=",
        "~/.ssh", "/.ssh/", "id_rsa", "id_ed25519", "~/.aws", "/.aws/",
        "credentials", "security find-generic-password", "security dump-keychain",
        ".keychain",
    ]
    /// "下载即执行"/管道到解释器(review fix):任何 "… | sh" / "|bash" / "| zsh"
    /// 形态(空格可有可无,含 curl/wget 与之组合的场景)→ dangerous。
    /// \b 词界防误伤 "| shuf" / "|| show" 等;(sudo\s+)? 覆盖 "| sudo bash"。
    private static let pipeToInterpreterRegex = #"\|\s*(sudo\s+)?(ba|z)?sh\b"#

    /// - Parameters:
    ///   - toolName: hook 上报的工具名
    ///   - body: 已格式化的请求详情(命令/参数拼接文本)
    static func classify(toolName: String, body: String) -> UInt8 {
        let lowered = body.lowercased()
        // 管道到解释器(curl … | sh / wget … |bash 等下载即执行)→ dangerous
        if lowered.range(of: pipeToInterpreterRegex, options: .regularExpression) != nil {
            return 2
        }
        // dangerous 判定不分工具:参数里出现高危模式即 2(padding 空格防误伤词中缀)
        for p in dangerousPatterns where lowered.contains(p) { return 2 }

        if toolName == "Bash" {
            // 取 command 首个非空行做前缀匹配(body 格式为 "command: <cmd>" 行)
            let cmd = Self.bashCommand(from: body).lowercased()
            for p in readOnlyBashPrefixes {
                if cmd == p || cmd.hasPrefix(p + " ") { return 0 }
            }
            return 1   // Bash 默认 elevated(命令语义无法静态穷举,保守)
        }
        if readOnlyTools.contains(toolName) { return 0 }
        if elevatedTools.contains(toolName) { return 1 }
        return 0   // 未知工具(MCP 等)默认 normal,不 over-warn
    }

    /// WorkBuddy 可扩展自定义工具；未知工具默认 elevated，避免第三方写操作
    /// 被误标为只读。已知内置只读工具仍保持 normal。
    static func classifyWorkBuddy(toolName: String, body: String) -> UInt8 {
        let classified = classify(toolName: toolName, body: body)
        if classified > 0 || readOnlyTools.contains(toolName) || toolName == "Bash" {
            return classified
        }
        return 1
    }

    /// 从 body 文本抽出 bash command 字段值(找 "command: " 行;找不到用整个 body)
    private static func bashCommand(from body: String) -> String {
        for line in body.split(separator: "\n") {
            if line.hasPrefix("command: ") {
                return String(line.dropFirst("command: ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return body.trimmingCharacters(in: .whitespaces)
    }

    #if DEBUG
    /// 轻量断言自检(review fix):锁住分类器契约,Debug 启动时跑一次
    /// (configure() 调用;分类器在 app target,ApprovalKit 测试无法覆盖)。
    static func selfTest() {
        assert(classify(toolName: "Bash", body: "command: curl https://x.io/install.sh | sh") == 2,
               "curl … | sh 必须 dangerous")
        assert(classify(toolName: "Bash", body: "command: wget -qO- https://get.x.io |bash") == 2,
               "wget … |bash 必须 dangerous")
        assert(classify(toolName: "Bash", body: "command: git push origin main") == 1,
               "git push 必须 elevated")
        assert(classify(toolName: "Bash", body: "command: ls -la") == 0,
               "ls 必须 normal")
        assert(classify(toolName: "Bash", body: "command: rm -rf /tmp/build") == 2,
               "rm -rf 必须 dangerous")
        assert(classify(toolName: "Bash", body: "command: sort a.txt | shuf") == 1,
               "| shuf 不得误判为管道到解释器")
        assert(classifyWorkBuddy(toolName: "CustomMCPTool", body: "") == 1,
               "WorkBuddy 未知工具必须保守标记为 elevated")
    }
    #endif
}

// MARK: - CC hook 应答的 updatedPermissions 规则(REQ-022 C2/D2)

/// PermissionRequest hook 应答里透传给 Claude Code 的会话级规则
/// (schema 见 REQ-022 复审结论 1:PermissionUpdate, destination=session)
struct PermissionRuleUpdate: Codable {
    struct Rule: Codable { let toolName: String }
    let type: String
    let rules: [Rule]
    let behavior: String
    let destination: String

    /// always_allow → 会话级 allow 规则(toolName 粒度;Bash 已被 bit2 挡在设备端)
    static func sessionAllow(toolName: String) -> PermissionRuleUpdate {
        PermissionRuleUpdate(type: "addRules", rules: [Rule(toolName: toolName)],
                             behavior: "allow", destination: "session")
    }
}

// MARK: - ApprovalResponder(REQ-022 C2)

/// 审批应答通道抽象:新增 agent 只需实现本协议 + 分配 agentId,协议帧与固件零改动。
/// respond 的调用线程 = Coordinator 串行队列;实现内部自行分发到目标线程。
protocol ApprovalResponder {
    var agentId: UInt8 { get }
    /// CC=true(hook 原生支持 updatedPermissions destination:session)
    /// Codex=false(Registry 内存 allowlist 模拟,见 D2)
    var supportsNativeSessionAllow: Bool { get }
    /// - Parameter alwaysToolName: 非 nil = 本次判决为 always_allow,值为规则 toolName
    func respond(key: ApprovalKey, allow: Bool, alwaysToolName: String?)
}

/// CC → hook socket 应答;always_allow 时回包附 updatedPermissions(session 规则)
final class ClaudeCodeApprovalResponder: ApprovalResponder {
    let agentId: UInt8 = 0
    let supportsNativeSessionAllow = true
    /// 应答后更新会话相位(@MainActor hop)
    weak var hookStore: ClaudeHookSessionStore?

    init(hookStore: ClaudeHookSessionStore?) { self.hookStore = hookStore }

    func respond(key: ApprovalKey, allow: Bool, alwaysToolName: String?) {
        let updates = alwaysToolName.map { [PermissionRuleUpdate.sessionAllow(toolName: $0)] }
        HookSocketServer.shared.respondToPermission(
            toolUseId: key.toolUseId,
            decision: allow ? "allow" : "deny",
            reason: allow ? nil : "Denied by user via QuickVibeMicPad",
            updatedPermissions: updates
        )
        let sessionId = key.sessionKey
        Task { @MainActor [weak hookStore] in
            hookStore?.notePermissionResponded(sessionId: sessionId)
        }
    }
}

/// Codex → codexApprovalServer.respond;always 由 Registry 内存 allowlist 承接
/// (本 responder 只需按 allow 应答,后续同会话同工具在 register 阶段被 autoAllowed)
final class CodexApprovalResponder: ApprovalResponder {
    let agentId: UInt8 = 1
    let supportsNativeSessionAllow = false
    weak var server: CodexApprovalServer?

    init(server: CodexApprovalServer?) { self.server = server }

    func respond(key: ApprovalKey, allow: Bool, alwaysToolName: String?) {
        let sessionKey = key.sessionKey
        Task { @MainActor [weak server] in
            server?.respond(sessionKey: sessionKey, decision: allow ? "allow" : "deny")
        }
    }
}

/// WorkBuddy PermissionRequest hook responder. Session-wide allow is disabled
/// in v1 because WorkBuddy's hook result does not expose a durable permission rule.
final class WorkBuddyApprovalResponder: ApprovalResponder {
    let agentId: UInt8 = 2
    let supportsNativeSessionAllow = false
    weak var server: WorkBuddyApprovalServer?

    init(server: WorkBuddyApprovalServer?) { self.server = server }

    func respond(key: ApprovalKey, allow: Bool, alwaysToolName: String?) {
        let requestKey = key.sessionKey
        Task { @MainActor [weak server] in
            server?.respond(
                requestKey: requestKey,
                decision: allow ? "allow" : "deny",
                reason: allow ? nil : "Denied by user via QuickVibeMicStick"
            )
        }
    }
}

// MARK: - Coordinator

final class ApprovalCoordinator {
    static let shared = ApprovalCoordinator()

    /// notifyOnly 工具集(REQ-022 D3):不再黑名单静默,改推 bit1=notifyOnly 帧
    static let notifyOnlyTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// CC:hook 脚本 300s,prune 290s → 设备侧倒计时对齐 prune
    private static let claudeExpiresSec: UInt16 = 290

    // Registry 并发契约:唯一触碰入口是本串行队列
    private let queue = DispatchQueue(label: "com.vibeeverything.approval-registry")
    private let registry = ApprovalRegistry()

    // 副作用目标(@MainActor 类;仅在 Task { @MainActor } 内解引用调用)
    private weak var bleManager: BLEManager?
    private var responders: [UInt8: ApprovalResponder] = [:]

    // 簿记(仅 queue 上读写):Registry 未公开 key→reqId 查询,自维护双向映射
    private var reqIdByKey: [ApprovalKey: UInt16] = [:]
    private var keyByReqId: [UInt16: ApprovalKey] = [:]
    /// 仍 pending 的 0x55 帧缓存(设备断连重连后重推;dismiss/终态即清)
    private var pendingFrames: [UInt16: Data] = [:]
    /// 绝对到期时间；重连重推时使用剩余秒数，不能重置设备倒计时。
    private var expiresAtMsByReqId: [UInt16: UInt64] = [:]

    /// 已下发的 CC session 规则(供后续 UI 查看;本里程碑仅记录)
    private(set) var issuedSessionRules: [(sessionKey: String, agentId: UInt8, toolName: String)] = []

    private var expireTimer: DispatchSourceTimer?

    private init() {}

    /// 单调毫秒(Registry 时间由调用方传入,不用挂钟防 NTP 跳变)
    private func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    // MARK: 装配(app 启动时 MainActor 调用一次)

    @MainActor
    func configure(bleManager: BLEManager,
                   hookStore: ClaudeHookSessionStore,
                   codexApprovalServer: CodexApprovalServer,
                   workBuddyApprovalServer: WorkBuddyApprovalServer) {
        self.bleManager = bleManager
        let cc = ClaudeCodeApprovalResponder(hookStore: hookStore)
        let codex = CodexApprovalResponder(server: codexApprovalServer)
        let workBuddy = WorkBuddyApprovalResponder(server: workBuddyApprovalServer)
        queue.async { [weak self] in
            guard let self else { return }
            self.responders[cc.agentId] = cc
            self.responders[codex.agentId] = codex
            self.responders[workBuddy.agentId] = workBuddy
        }
        startExpireTimer()
        #if DEBUG
        ApprovalRiskClassifier.selfTest()   // review fix:分类器契约断言
        #endif
    }

    private func startExpireTimer() {
        guard expireTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.consume(self.registry.expire(nowMs: self.nowMs()))
        }
        t.resume()
        expireTimer = t
    }

    // MARK: 入口 ①:审批挂起注册

    /// CC PermissionRequest 挂起(ClaudeHookSessionStore.handleEvent 调,MainActor 起跳)
    func registerClaude(sessionId: String, toolUseId: String, toolName: String,
                        sessionName: String, toolInput: [String: AnyCodable]?) {
        guard !toolUseId.isEmpty else { return }   // 空 toolUseId 上游已丢弃,双保险
        let body = Self.formatToolInput(toolInput)
        let key = ApprovalKey(sessionKey: sessionId, agentId: 0, toolUseId: toolUseId)
        register(key: key, toolName: toolName, sessName: sessionName, body: body,
                 expiresInSec: Self.claudeExpiresSec)
    }

    /// Codex hook 挂起(CodexApprovalServer 接入新连接后调,MainActor 起跳)。
    /// sessionKey = server pending key("codex-cli:<uuid>",見 CodexApprovalServer.pendingKey 适配)
    func registerCodex(pendingKey: String, toolUseId: String, toolName: String,
                       sessionName: String, toolInput: [String: AnyCodable]?,
                       expiresInSec: UInt16) {
        let body = Self.formatToolInput(toolInput)
        let key = ApprovalKey(sessionKey: pendingKey, agentId: 1,
                              toolUseId: toolUseId.isEmpty ? pendingKey : toolUseId)
        register(key: key, toolName: toolName, sessName: sessionName, body: body,
                 expiresInSec: expiresInSec)
    }

    /// WorkBuddy hook pending. Always-allow is intentionally disabled until
    /// WorkBuddy exposes a durable per-session permission update contract.
    func registerWorkBuddy(requestKey: String, toolUseId: String, toolName: String,
                           sessionName: String, toolInput: [String: AnyCodable]?,
                           expiresInSec: UInt16) {
        let body = Self.formatToolInput(toolInput)
        let key = ApprovalKey(sessionKey: requestKey, agentId: 2,
                              toolUseId: toolUseId.isEmpty ? requestKey : toolUseId)
        let risk = ApprovalRiskClassifier.classifyWorkBuddy(toolName: toolName, body: body)
        register(key: key, toolName: toolName, sessName: sessionName, body: body,
                 expiresInSec: expiresInSec, forceAlwaysDisabled: true,
                 riskLevelOverride: risk)
    }

    private func register(key: ApprovalKey, toolName: String, sessName: String,
                          body: String, expiresInSec: UInt16,
                          forceAlwaysDisabled: Bool = false,
                          riskLevelOverride: UInt8? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let notifyOnly = Self.notifyOnlyTools.contains(toolName)
            let risk = riskLevelOverride
                ?? ApprovalRiskClassifier.classify(toolName: toolName, body: body)
            // bit0 预判:任一字段超协议上限(Registry 推送前截断并置位;此处仅为 bit2 判定用)
            let willTruncate = body.utf8.count > ApprovalProtocolConst.maxBodyBytes
                || sessName.utf8.count > ApprovalProtocolConst.maxSessNameBytes
                || toolName.utf8.count > ApprovalProtocolConst.maxToolBytes
            // bit2(alwaysDisabled,D1):Bash 一刀切 || dangerous || 截断且 risk≥1
            let alwaysDisabled = forceAlwaysDisabled || toolName == "Bash"
                || risk == 2 || (willTruncate && risk >= 1)

            let input = ApprovalRegisterInput(
                key: key, toolName: toolName, sessName: sessName, body: body,
                riskLevel: risk, expiresInSec: expiresInSec,
                notifyOnly: notifyOnly, alwaysDisabled: alwaysDisabled
            )
            let nowMs = self.nowMs()
            let result = self.registry.register(input, nowMs: nowMs)
            if !result.autoAllowed, result.actions.isEmpty {
                return   // 同 key 仍 pending(重复注册),簿记已存在,零动作
            }
            if !result.autoAllowed {
                self.reqIdByKey[key] = result.reqId
                self.keyByReqId[result.reqId] = key
                self.expiresAtMsByReqId[result.reqId] = nowMs + UInt64(expiresInSec) * 1_000
                for a in result.actions {
                    if case .sendFrame(let d) = a,
                       d.first == ApprovalProtocolConst.requestMagic {
                        self.pendingFrames[result.reqId] = d
                    }
                }
            }
            logger.info("register reqId=\(result.reqId) agent=\(key.agentId) tool=\(toolName, privacy: .public) risk=\(risk) notifyOnly=\(notifyOnly) autoAllowed=\(result.autoAllowed)")
            self.consume(result.actions)
        }
    }

    // MARK: 入口 ②:设备 0x36 回传(BLEManager 0x36 路由至此)

    func handleDeviceFrame(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let frame: ApprovalResponseFrame
            do {
                frame = try ApprovalFrameCodec.decodeApprovalResponse(data)
            } catch {
                logger.warning("0x36 decode error(丢弃): \(String(describing: error), privacy: .public)")
                return
            }
            logger.info("0x36 reqId=\(frame.reqId) decision=\(frame.decision.rawValue)")
            if frame.decision == .dismiss {
                // 设备本地已删条目 → 不再重推。Codex BtnC 的 dismiss 还须立即
                // 关闭 hook socket，令 Codex 进入自身的原生审批。
                self.pendingFrames.removeValue(forKey: frame.reqId)
                if let key = self.keyByReqId[frame.reqId], key.agentId == 1 {
                    self.consume(self.registry.resolveElsewhere(reqId: frame.reqId, reason: .macUI))
                    if let responder = self.responders[1] as? CodexApprovalResponder {
                        Task { @MainActor in responder.server?.abandon(sessionKey: key.sessionKey) }
                    }
                    return
                } else if let key = self.keyByReqId[frame.reqId], key.agentId == 2 {
                    self.consume(self.registry.resolveElsewhere(reqId: frame.reqId, reason: .macUI))
                    if let responder = self.responders[2] as? WorkBuddyApprovalResponder {
                        Task { @MainActor in
                            responder.server?.abandon(requestKey: key.sessionKey)
                        }
                    }
                    return
                }
            }
            self.consume(self.registry.onDeviceResponse(reqId: frame.reqId, decision: frame.decision))
        }
    }

    // MARK: 入口 ③:撤销 / 过期 / 会话结束

    /// CC 侧越过审批(PostToolUse/Stop)、Mac UI 判决 → resolveElsewhere → 0x56(2)
    func resolveClaude(sessionId: String, toolUseId: String, reason: ApprovalResolveReason) {
        let key = ApprovalKey(sessionKey: sessionId, agentId: 0, toolUseId: toolUseId)
        queue.async { [weak self] in
            guard let self, let reqId = self.reqIdByKey[key] else { return }
            self.consume(self.registry.resolveElsewhere(reqId: reqId, reason: reason))
        }
    }

    /// Codex 侧:Mac UI 判决(respond 内通知)、hook EOF、prune → 按 pendingKey 定位
    func resolveCodex(pendingKey: String, reason: ApprovalResolveReason) {
        queue.async { [weak self] in
            guard let self else { return }
            // Codex 一会话一挂起 → sessionKey 唯一定位
            guard let (_, reqId) = self.reqIdByKey.first(where: {
                $0.key.agentId == 1 && $0.key.sessionKey == pendingKey
            }).map({ ($0.key, $0.value) }) else { return }
            self.consume(self.registry.resolveElsewhere(reqId: reqId, reason: reason))
        }
    }

    func resolveWorkBuddy(requestKey: String, reason: ApprovalResolveReason) {
        queue.async { [weak self] in
            guard let self,
                  let reqId = self.reqIdByKey.first(where: {
                      $0.key.agentId == 2 && $0.key.sessionKey == requestKey
                  })?.value else { return }
            self.consume(self.registry.resolveElsewhere(reqId: reqId, reason: reason))
        }
    }

    /// 会话结束(CC SessionEnd / Codex 会话消亡):该会话全部 pending → cancelled + 0x56(5),
    /// 并清除该会话的 Codex allowlist(Registry 内部)
    func endSession(sessionKey: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.consume(self.registry.endSession(sessionKey: sessionKey))
        }
    }

    // MARK: 设备重连:重推仍 pending 的 0x55

    /// v5 握手通过后调用。设备重启/重连后队列是空的,把所有仍 pending(未 dismiss)
    /// 的 0x55 按 reqId 序重推；以剩余秒数更新有效期，不能重置倒计时。
    func deviceReconnected() {
        queue.async { [weak self] in
            guard let self else { return }
            let nowMs = self.nowMs()
            let frames = self.pendingFrames.sorted { $0.key < $1.key }.compactMap { reqId, data -> Data? in
                guard let expiresAtMs = self.expiresAtMsByReqId[reqId], expiresAtMs > nowMs,
                      var request = try? ApprovalFrameCodec.decodeApprovalRequest(data) else { return nil }
                request.expiresInSec = UInt16(clamping: (expiresAtMs - nowMs + 999) / 1_000)
                return try? ApprovalFrameCodec.encodeApprovalRequest(request)
            }
            guard !frames.isEmpty else { return }
            logger.info("device reconnected → 重推 \(frames.count) 条 pending 0x55")
            Task { @MainActor [weak self] in
                guard let ble = self?.bleManager else { return }
                for f in frames { ble.sendApprovalFrame(f) }
            }
        }
    }

    // MARK: 动作消费(queue 上执行)

    private func consume(_ actions: [ApprovalAction]) {
        guard !actions.isEmpty else { return }
        // 同批 recordSessionRule ⇒ 该 respond 是 always_allow(Registry §4 动作组合)
        var alwaysRules: [(sessionKey: String, agentId: UInt8, toolName: String)] = []
        for a in actions {
            if case .recordSessionRule(let s, let ag, let t) = a {
                alwaysRules.append((s, ag, t))
            }
        }

        for action in actions {
            switch action {
            case .respond(let key, let allow):
                let alwaysToolName = alwaysRules.first {
                    $0.sessionKey == key.sessionKey && $0.agentId == key.agentId
                }?.toolName
                if let responder = responders[key.agentId] {
                    responder.respond(key: key, allow: allow, alwaysToolName: alwaysToolName)
                } else {
                    logger.error("no responder for agentId=\(key.agentId) — respond 丢失")
                }

            case .sendFrame(let data):
                if data.first == ApprovalProtocolConst.resolvedMagic, data.count == 4 {
                    // 0x56 = 终态确认:清簿记与重推缓存(单点仲裁出口)
                    let reqId = UInt16(data[1]) | (UInt16(data[2]) << 8)
                    cleanupTerminal(reqId: reqId)
                }
                Task { @MainActor [weak self] in
                    self?.bleManager?.sendApprovalFrame(data)
                }

            case .recordSessionRule(let sessionKey, let agentId, let toolName):
                // CC:updatedPermissions 已在 respond 里透传;Codex:Registry 内存 allowlist
                // 已同步写入。这里只留存供 UI 查看(设置页展示属后续里程碑)。
                issuedSessionRules.append((sessionKey, agentId, toolName))
                logger.info("recordSessionRule agent=\(agentId) tool=\(toolName, privacy: .public)")
            }
        }
    }

    /// 终态(0x56 已发出)清理;注意 dismiss 不产生 0x56,pending 簿记保留
    private func cleanupTerminal(reqId: UInt16) {
        pendingFrames.removeValue(forKey: reqId)
        expiresAtMsByReqId.removeValue(forKey: reqId)
        if let key = keyByReqId.removeValue(forKey: reqId) {
            if reqIdByKey[key] == reqId { reqIdByKey.removeValue(forKey: key) }
        }
    }

    // MARK: 工具

    /// toolInput → body 文本:按 key 排序拼 "key: value" 行(值不预截断,
    /// 256B UTF-8 安全截断由 Registry 推送前统一做并置 bit0)
    static func formatToolInput(_ input: [String: AnyCodable]?) -> String {
        guard let input, !input.isEmpty else { return "" }
        // command 优先展示(设备屏幕小,最关键信息前置)
        let ordered = input.sorted { a, b in
            if a.key == "command" { return true }
            if b.key == "command" { return false }
            return a.key < b.key
        }
        return ordered.map { key, value in
            let str: String
            switch value.value {
            case let s as String: str = s
            case let n as Int: str = String(n)
            case let d as Double: str = String(d)
            case let b as Bool: str = b ? "true" : "false"
            default: str = "…"
            }
            return "\(key): \(str)"
        }.joined(separator: "\n")
    }
}

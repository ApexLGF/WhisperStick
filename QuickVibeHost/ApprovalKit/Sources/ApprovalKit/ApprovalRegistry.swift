// ApprovalRegistry.swift
// Mac 侧审批状态机(规格:docs/approval-protocol-v1.md §4)
// 纯逻辑、无 I/O:动作以枚举返回值表达,时间由调用方传入(不内部取 Date())。
// 所有 0x56 的产生集中于本类,单点仲裁(规格 §4 末条)。

import Foundation

// MARK: - 键与动作

/// 审批请求业务键:(sessionKey, agentId, toolUseId) 三元组(规格 §4)
public struct ApprovalKey: Hashable {
    public let sessionKey: String
    /// 0=ClaudeCode 1=Codex;未知值合法
    public let agentId: UInt8
    public let toolUseId: String

    public init(sessionKey: String, agentId: UInt8, toolUseId: String) {
        self.sessionKey = sessionKey
        self.agentId = agentId
        self.toolUseId = toolUseId
    }
}

/// Registry 输出动作;副作用全部由调用方执行
public enum ApprovalAction: Equatable {
    /// 回应等待中的 hook / 审批请求(allow=true 放行,false 拒绝)
    case respond(key: ApprovalKey, allow: Bool)
    /// 向设备发送一帧(0x55 或 0x56,已编码)
    case sendFrame(Data)
    /// 记录会话级 always_allow 规则(CC:updatedPermissions 透传;Codex:调用方无需额外动作,
    /// Registry 已同步写入内存 allowlist,此动作仅供上层持久化/透传)
    case recordSessionRule(sessionKey: String, agentId: UInt8, toolName: String)
}

/// 终态(规格 §4 状态定义)
public enum ApprovalTerminalState: Equatable {
    case allowed
    case denied
    case resolvedElsewhere
    case expired
    case cancelled
    case autoAllowed
}

/// resolveElsewhere 的原因;决定 0x56 outcome(sessionEnded → 5,其余 → 2)
public enum ApprovalResolveReason: Equatable {
    /// Mac UI 判决
    case macUI
    /// hook EOF
    case hookEOF
    /// rollout 后续事件
    case rolloutEvent
    /// 会话结束
    case sessionEnded
}

// MARK: - register 输入/输出

public struct ApprovalRegisterInput {
    public var key: ApprovalKey
    /// 工具名(allowlist 匹配键,同时作为 0x55 tool 字段)
    public var toolName: String
    /// 会话显示名(0x55 sessName 字段)
    public var sessName: String
    /// 请求详情(0x55 body 字段)
    public var body: String
    /// 0/1/2;>2 推送前钳制为 2
    public var riskLevel: UInt8
    public var expiresInSec: UInt16
    public var notifyOnly: Bool
    public var alwaysDisabled: Bool

    public init(key: ApprovalKey, toolName: String, sessName: String, body: String,
                riskLevel: UInt8, expiresInSec: UInt16,
                notifyOnly: Bool = false, alwaysDisabled: Bool = false) {
        self.key = key
        self.toolName = toolName
        self.sessName = sessName
        self.body = body
        self.riskLevel = riskLevel
        self.expiresInSec = expiresInSec
        self.notifyOnly = notifyOnly
        self.alwaysDisabled = alwaysDisabled
    }
}

public struct ApprovalRegisterResult: Equatable {
    /// 分配的设备通信短句柄
    public let reqId: UInt16
    /// 命中 Codex 会话 allowlist,已直接放行(未推设备)
    public let autoAllowed: Bool
    public let actions: [ApprovalAction]
}

// MARK: - Registry

/// 并发契约(硬性):本类**非线程安全**——内部状态为普通字典/数组,无锁、非 actor。
/// 所有调用(register / onDeviceResponse / resolveElsewhere / expire / endSession …)
/// 必须来自同一个串行队列或同一线程;集成方负责将 BLE 收包线程、hook 判决回调、
/// 会话结束回调全部派发到该串行队列后再调用。违反此契约 = Dictionary 并发写崩溃。
/// (集成阶段如改造为 actor,需同步给 ApprovalAction 等值类型标 Sendable。)
public final class ApprovalRegistry {

    /// Codex 的 agentId(规格 §1.1:1=Codex)
    public static let codexAgentId: UInt8 = 1
    /// 终态环形记录容量(规格要求 ≥256;溢出淘汰最老记录,
    /// 被淘汰的 reqId 走"未知 reqId"路径,对外行为与终态路径一致:静默吞 + 0x56(2))
    public static let terminalRingCapacity = 256

    struct PendingEntry {
        let key: ApprovalKey
        let toolName: String
        let expiresAtMs: UInt64
        var deviceDismissed: Bool = false
    }

    struct CodexAllowKey: Hashable {
        let sessionKey: String
        let toolName: String
    }

    // 内部状态(internal 供 @testable 测试访问)
    var pending: [UInt16: PendingEntry] = [:]
    var keyToReqId: [ApprovalKey: UInt16] = [:]
    /// 终态记录:reqId → 终态(幂等吞的依据)
    var terminal: [UInt16: ApprovalTerminalState] = [:]
    /// 终态插入顺序环(用于容量淘汰)
    var terminalOrder: [UInt16] = []
    /// 下一个候选 reqId;单调递增 u16 回绕,分配时跳过在用(pending)值
    var nextReqId: UInt16 = 0
    /// Codex 会话 allowlist:(sessionKey, toolName)
    var codexAllowlist: Set<CodexAllowKey> = []

    public init() {}

    // MARK: 查询(纯读)

    public func isPending(_ reqId: UInt16) -> Bool { pending[reqId] != nil }

    public func terminalState(of reqId: UInt16) -> ApprovalTerminalState? { terminal[reqId] }

    /// pending 条目是否已被设备 dismiss(非 pending 返回 nil)
    public func isDeviceDismissed(_ reqId: UInt16) -> Bool? { pending[reqId]?.deviceDismissed }

    public var pendingCount: Int { pending.count }

    // MARK: 入口 register(规格 §4)

    /// 注册审批请求。分配 reqId;命中 Codex 会话 allowlist(sessionKey, toolName)→ 直接
    /// autoAllowed(输出 respond(allow),不推设备);否则 pending 并输出 0x55 帧。
    /// 推送前按规格职责做字段截断(UTF-8 字符边界安全)并置 truncated flag。
    public func register(_ input: ApprovalRegisterInput, nowMs: UInt64) -> ApprovalRegisterResult {
        // 同键仍 pending:本设计不重复推送同一请求(规格 §2.3 依赖此性质),返回原 reqId、零动作
        if let existing = keyToReqId[input.key], pending[existing] != nil {
            return ApprovalRegisterResult(reqId: existing, autoAllowed: false, actions: [])
        }

        let reqId = allocateReqId()

        // Codex 会话 allowlist 命中 → 直接 autoAllowed,不推设备
        if input.key.agentId == Self.codexAgentId,
           codexAllowlist.contains(CodexAllowKey(sessionKey: input.key.sessionKey, toolName: input.toolName)) {
            insertTerminal(reqId, .autoAllowed)
            return ApprovalRegisterResult(
                reqId: reqId, autoAllowed: true,
                actions: [.respond(key: input.key, allow: true)]
            )
        }

        // 截断(codec 拒绝超限,截断是 Registry 推送前的职责,规格 §1.1)
        let (sessData, cut1) = Self.truncateUTF8(input.sessName, limit: ApprovalProtocolConst.maxSessNameBytes)
        let (toolData, cut2) = Self.truncateUTF8(input.toolName, limit: ApprovalProtocolConst.maxToolBytes)
        let (bodyData, cut3) = Self.truncateUTF8(input.body, limit: ApprovalProtocolConst.maxBodyBytes)

        var flags: UInt8 = 0
        if cut1 || cut2 || cut3 { flags |= ApprovalProtocolConst.flagTruncated }
        if input.notifyOnly { flags |= ApprovalProtocolConst.flagNotifyOnly }
        if input.alwaysDisabled { flags |= ApprovalProtocolConst.flagAlwaysDisabled }

        let frame = ApprovalRequestFrame(
            reqId: reqId,
            agentId: input.key.agentId,
            riskLevel: min(input.riskLevel, ApprovalProtocolConst.maxRiskLevel),
            expiresInSec: input.expiresInSec,
            flags: flags,
            sessNameData: sessData,
            toolData: toolData,
            bodyData: bodyData
        )
        // 截断与钳制之后编码必然合法
        let data = try! ApprovalFrameCodec.encodeApprovalRequest(frame)

        pending[reqId] = PendingEntry(
            key: input.key,
            toolName: input.toolName,
            expiresAtMs: nowMs + UInt64(input.expiresInSec) * 1000
        )
        keyToReqId[input.key] = reqId
        return ApprovalRegisterResult(reqId: reqId, autoAllowed: false, actions: [.sendFrame(data)])
    }

    // MARK: 设备响应 onDeviceResponse(规格 §4)

    /// 处理已解码的 0x36。幂等契约(规格 §2.4):
    /// - pending + allow/deny → respond + 终态 + 0x56(0/1)
    /// - pending + always_allow → respond(allow) + 记会话规则 + 终态 + 0x56(0)
    /// - pending + dismiss → 标记 deviceDismissed(仍 pending),无 0x56
    /// - 终态/未知 reqId(dismiss 除外)→ 零副作用 + 0x56(outcome=2)
    /// - 重复 0x36 只判决一次,但(dismiss 除外)每次都回 0x56
    public func onDeviceResponse(reqId: UInt16, decision: ApprovalDecision) -> [ApprovalAction] {
        guard var entry = pending[reqId] else {
            // 终态或未知 reqId
            if decision == .dismiss { return [] }
            return [resolvedAction(reqId, outcome: .resolvedElsewhere)]
        }

        switch decision {
        case .dismiss:
            // 设备本地已删条目;Mac 仅标记,不判决、不回 0x56(规格 §2.3)
            entry.deviceDismissed = true
            pending[reqId] = entry
            return []

        case .allow, .deny:
            let allow = decision == .allow
            finalize(reqId, entry: entry, state: allow ? .allowed : .denied)
            return [
                .respond(key: entry.key, allow: allow),
                resolvedAction(reqId, outcome: allow ? .judgedAllow : .judgedDeny),
            ]

        case .alwaysAllow:
            finalize(reqId, entry: entry, state: .allowed)
            // Codex:同步写入内存 allowlist(后续 register 直接 autoAllowed)
            if entry.key.agentId == Self.codexAgentId {
                codexAllowlist.insert(CodexAllowKey(sessionKey: entry.key.sessionKey, toolName: entry.toolName))
            }
            return [
                .respond(key: entry.key, allow: true),
                .recordSessionRule(sessionKey: entry.key.sessionKey,
                                   agentId: entry.key.agentId,
                                   toolName: entry.toolName),
                resolvedAction(reqId, outcome: .judgedAllow),
            ]
        }
    }

    // MARK: 其他终态入口(规格 §4)

    /// Mac UI 判决 / hook EOF / rollout 后续事件 / 会话结束 → 终态 + 0x56(2 或 5)。
    /// 已终态或未知 reqId:零动作(0x56 只在 pending → terminal 迁移时发出)。
    public func resolveElsewhere(reqId: UInt16, reason: ApprovalResolveReason) -> [ApprovalAction] {
        guard let entry = pending[reqId] else { return [] }
        let state: ApprovalTerminalState = reason == .sessionEnded ? .cancelled : .resolvedElsewhere
        let outcome: ApprovalOutcome = reason == .sessionEnded ? .cancelled : .resolvedElsewhere
        finalize(reqId, entry: entry, state: state)
        return [resolvedAction(reqId, outcome: outcome)]
    }

    /// 过期扫描:所有 nowMs ≥ expiresAtMs 的 pending(含 deviceDismissed)→ 终态 expired + 0x56(3)。
    /// 输出按 reqId 升序,保证确定性。
    public func expire(nowMs: UInt64) -> [ApprovalAction] {
        let due = pending.filter { nowMs >= $0.value.expiresAtMs }.keys.sorted()
        var actions: [ApprovalAction] = []
        for reqId in due {
            guard let entry = pending[reqId] else { continue }
            finalize(reqId, entry: entry, state: .expired)
            actions.append(resolvedAction(reqId, outcome: .expired))
        }
        return actions
    }

    /// 会话结束:该会话全部 pending → cancelled + 0x56(5);同时清除该会话的 Codex allowlist
    /// (allowlist 为会话级规则,随会话生命周期终止)。
    public func endSession(sessionKey: String) -> [ApprovalAction] {
        let due = pending.filter { $0.value.key.sessionKey == sessionKey }.keys.sorted()
        var actions: [ApprovalAction] = []
        for reqId in due {
            actions.append(contentsOf: resolveElsewhere(reqId: reqId, reason: .sessionEnded))
        }
        codexAllowlist = codexAllowlist.filter { $0.sessionKey != sessionKey }
        return actions
    }

    // MARK: 内部

    /// 分配 reqId:单调递增 u16 回绕,跳过在用(pending)值。
    /// 若被复用的 reqId 尚留在终态环中,先移除旧终态记录(该句柄语义已转移到新请求)。
    func allocateReqId() -> UInt16 {
        var attempts = 0
        while pending[nextReqId] != nil {
            nextReqId &+= 1
            attempts += 1
            precondition(attempts <= 0x10000, "reqId 空间耗尽(65536 条 pending)")
        }
        let reqId = nextReqId
        nextReqId &+= 1
        if terminal.removeValue(forKey: reqId) != nil {
            terminalOrder.removeAll { $0 == reqId }
        }
        return reqId
    }

    private func finalize(_ reqId: UInt16, entry: PendingEntry, state: ApprovalTerminalState) {
        pending.removeValue(forKey: reqId)
        if keyToReqId[entry.key] == reqId {
            keyToReqId.removeValue(forKey: entry.key)
        }
        insertTerminal(reqId, state)
    }

    private func insertTerminal(_ reqId: UInt16, _ state: ApprovalTerminalState) {
        if terminal.updateValue(state, forKey: reqId) != nil {
            // 覆盖:把该 reqId 移到环尾(理论路径,正常流程不会发生)
            terminalOrder.removeAll { $0 == reqId }
        }
        terminalOrder.append(reqId)
        while terminalOrder.count > Self.terminalRingCapacity {
            let evicted = terminalOrder.removeFirst()
            terminal.removeValue(forKey: evicted)
        }
    }

    private func resolvedAction(_ reqId: UInt16, outcome: ApprovalOutcome) -> ApprovalAction {
        .sendFrame(ApprovalFrameCodec.encodeApprovalResolved(reqId: reqId, outcome: outcome))
    }

    /// UTF-8 字节数截断,不切断多字节字符;返回 (截断后字节, 是否发生截断)
    static func truncateUTF8(_ s: String, limit: Int) -> (Data, Bool) {
        let bytes = Array(s.utf8)
        if bytes.count <= limit { return (Data(bytes), false) }
        var end = limit
        // 回退到字符边界:丢弃位置若是续字节(0b10xxxxxx),该字符被切断,继续回退
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return (Data(bytes[0..<end]), true)
    }
}

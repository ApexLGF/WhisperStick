// RegistryTests.swift
// ApprovalRegistry 状态机全场景(规格 §4 + §2 幂等契约)。
// 时间全部由测试传入;动作用返回值断言,无回调无 I/O。

import XCTest
@testable import ApprovalKit

final class RegistryTests: XCTestCase {

    private func makeKey(session: String = "sess-A", agent: UInt8 = 0,
                         toolUse: String = "tu-1") -> ApprovalKey {
        ApprovalKey(sessionKey: session, agentId: agent, toolUseId: toolUse)
    }

    private func makeInput(key: ApprovalKey, tool: String = "Bash", sess: String = "会话",
                           body: String = "rm -rf /tmp/x", risk: UInt8 = 1,
                           expires: UInt16 = 300, notifyOnly: Bool = false,
                           alwaysDisabled: Bool = false) -> ApprovalRegisterInput {
        ApprovalRegisterInput(key: key, toolName: tool, sessName: sess, body: body,
                              riskLevel: risk, expiresInSec: expires,
                              notifyOnly: notifyOnly, alwaysDisabled: alwaysDisabled)
    }

    /// 从动作列表中取出所有 sendFrame 并解码为 0x56
    private func resolvedFrames(_ actions: [ApprovalAction]) -> [ApprovalResolvedFrame] {
        actions.compactMap {
            guard case let .sendFrame(data) = $0 else { return nil }
            return try? ApprovalFrameCodec.decodeApprovalResolved(data)
        }
    }

    // MARK: register 基本路径

    /// register → pending + 一条可解码 0x55,字段正确
    func testRegisterProducesRequestFrame() throws {
        let reg = ApprovalRegistry()
        let key = makeKey()
        let result = reg.register(makeInput(key: key), nowMs: 1000)

        XCTAssertFalse(result.autoAllowed)
        XCTAssertTrue(reg.isPending(result.reqId))
        XCTAssertEqual(result.actions.count, 1)
        guard case let .sendFrame(data) = result.actions[0] else {
            return XCTFail("register 应输出 sendFrame(0x55)")
        }
        let frame = try ApprovalFrameCodec.decodeApprovalRequest(data)
        XCTAssertEqual(frame.reqId, result.reqId)
        XCTAssertEqual(frame.agentId, 0)
        XCTAssertEqual(frame.riskLevel, 1)
        XCTAssertEqual(frame.expiresInSec, 300)
        XCTAssertEqual(frame.flags, 0)
        XCTAssertEqual(frame.sessName, "会话")
        XCTAssertEqual(frame.tool, "Bash")
        XCTAssertEqual(frame.body, "rm -rf /tmp/x")
    }

    /// notifyOnly / alwaysDisabled → flags bit1/bit2
    func testRegisterSetsFlags() throws {
        let reg = ApprovalRegistry()
        let result = reg.register(makeInput(key: makeKey(), notifyOnly: true, alwaysDisabled: true),
                                  nowMs: 0)
        guard case let .sendFrame(data) = result.actions[0] else { return XCTFail() }
        let frame = try ApprovalFrameCodec.decodeApprovalRequest(data)
        XCTAssertEqual(frame.flags, ApprovalProtocolConst.flagNotifyOnly | ApprovalProtocolConst.flagAlwaysDisabled)
    }

    /// 超长字段:Registry 负责 UTF-8 边界安全截断并置 truncated flag
    func testRegisterTruncatesLongFieldsAtUTF8Boundary() throws {
        let reg = ApprovalRegistry()
        // 100 个三字节 CJK 字符 = 300 字节 > 256;256 不在字符边界,应回退到 255(85 字符)
        let longBody = String(repeating: "试", count: 100)
        let result = reg.register(makeInput(key: makeKey(), body: longBody), nowMs: 0)
        guard case let .sendFrame(data) = result.actions[0] else { return XCTFail() }
        let frame = try ApprovalFrameCodec.decodeApprovalRequest(data)
        XCTAssertEqual(frame.flags & ApprovalProtocolConst.flagTruncated, ApprovalProtocolConst.flagTruncated)
        XCTAssertEqual(frame.bodyData.count, 255)
        XCTAssertEqual(frame.body, String(repeating: "试", count: 85), "截断后仍是合法 UTF-8")
    }

    /// riskLevel>2:Registry 推送前钳制为 2
    func testRegisterClampsRisk() throws {
        let reg = ApprovalRegistry()
        let result = reg.register(makeInput(key: makeKey(), risk: 7), nowMs: 0)
        guard case let .sendFrame(data) = result.actions[0] else { return XCTFail() }
        XCTAssertEqual(try ApprovalFrameCodec.decodeApprovalRequest(data).riskLevel, 2)
    }

    /// 同键重复 register(仍 pending):返回原 reqId,不重复推送
    func testRegisterSameKeyWhilePendingReturnsSameReqId() {
        let reg = ApprovalRegistry()
        let key = makeKey()
        let r1 = reg.register(makeInput(key: key), nowMs: 0)
        let r2 = reg.register(makeInput(key: key), nowMs: 10)
        XCTAssertEqual(r2.reqId, r1.reqId)
        XCTAssertTrue(r2.actions.isEmpty, "同一请求不重复推送")
        XCTAssertEqual(reg.pendingCount, 1)
    }

    // MARK: onDeviceResponse:allow / deny

    /// pending + allow → respond(allow) + 终态 allowed + 0x56(outcome=0)
    func testAllow() {
        let reg = ApprovalRegistry()
        let key = makeKey()
        let reqId = reg.register(makeInput(key: key), nowMs: 0).reqId

        let actions = reg.onDeviceResponse(reqId: reqId, decision: .allow)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0], .respond(key: key, allow: true))
        let frames = resolvedFrames(actions)
        XCTAssertEqual(frames, [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 0)])
        XCTAssertFalse(reg.isPending(reqId))
        XCTAssertEqual(reg.terminalState(of: reqId), .allowed)
    }

    /// pending + deny → respond(deny) + 终态 denied + 0x56(outcome=1)
    func testDeny() {
        let reg = ApprovalRegistry()
        let key = makeKey()
        let reqId = reg.register(makeInput(key: key), nowMs: 0).reqId

        let actions = reg.onDeviceResponse(reqId: reqId, decision: .deny)
        XCTAssertEqual(actions[0], .respond(key: key, allow: false))
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 1)])
        XCTAssertEqual(reg.terminalState(of: reqId), .denied)
    }

    // MARK: onDeviceResponse:always_allow

    /// pending + always_allow(CC)→ respond(allow) + recordSessionRule + 0x56(0);不进 Codex allowlist
    func testAlwaysAllowClaudeCode() {
        let reg = ApprovalRegistry()
        let key = makeKey(agent: 0)
        let reqId = reg.register(makeInput(key: key, tool: "Bash"), nowMs: 0).reqId

        let actions = reg.onDeviceResponse(reqId: reqId, decision: .alwaysAllow)
        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions[0], .respond(key: key, allow: true))
        XCTAssertEqual(actions[1], .recordSessionRule(sessionKey: "sess-A", agentId: 0, toolName: "Bash"))
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 0)])
        XCTAssertEqual(reg.terminalState(of: reqId), .allowed)

        // CC 规则走 updatedPermissions 透传,不写内存 allowlist:同工具再注册仍需推设备
        let r2 = reg.register(makeInput(key: makeKey(agent: 0, toolUse: "tu-2"), tool: "Bash"), nowMs: 10)
        XCTAssertFalse(r2.autoAllowed)
        XCTAssertEqual(r2.actions.count, 1)
    }

    /// pending + always_allow(Codex)→ 写内存 allowlist;后续同 (sessionKey, toolName) 直接 autoAllowed
    func testAlwaysAllowCodexThenAutoAllowed() {
        let reg = ApprovalRegistry()
        let key1 = makeKey(session: "cx-S", agent: 1, toolUse: "tu-1")
        let reqId1 = reg.register(makeInput(key: key1, tool: "shell"), nowMs: 0).reqId
        let actions = reg.onDeviceResponse(reqId: reqId1, decision: .alwaysAllow)
        XCTAssertEqual(actions[1], .recordSessionRule(sessionKey: "cx-S", agentId: 1, toolName: "shell"))

        // 命中 allowlist:autoAllowed,respond(allow),不推设备
        let key2 = makeKey(session: "cx-S", agent: 1, toolUse: "tu-2")
        let r2 = reg.register(makeInput(key: key2, tool: "shell"), nowMs: 10)
        XCTAssertTrue(r2.autoAllowed)
        XCTAssertEqual(r2.actions, [.respond(key: key2, allow: true)])
        XCTAssertFalse(reg.isPending(r2.reqId))
        XCTAssertEqual(reg.terminalState(of: r2.reqId), .autoAllowed)

        // 不同工具不命中
        let r3 = reg.register(makeInput(key: makeKey(session: "cx-S", agent: 1, toolUse: "tu-3"),
                                        tool: "apply_patch"), nowMs: 20)
        XCTAssertFalse(r3.autoAllowed)

        // 不同会话不命中
        let r4 = reg.register(makeInput(key: makeKey(session: "cx-T", agent: 1, toolUse: "tu-4"),
                                        tool: "shell"), nowMs: 30)
        XCTAssertFalse(r4.autoAllowed)
    }

    // MARK: onDeviceResponse:dismiss

    /// pending + dismiss → 标记 deviceDismissed、仍 pending、零动作、无 0x56
    func testDismissKeepsPending() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId

        let actions = reg.onDeviceResponse(reqId: reqId, decision: .dismiss)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(reg.isPending(reqId))
        XCTAssertEqual(reg.isDeviceDismissed(reqId), true)
    }

    /// dismiss 后仍可被其他终态路径处理(此处 Mac UI 判决)
    func testDismissThenResolveElsewhere() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: reqId, decision: .dismiss)

        let actions = reg.resolveElsewhere(reqId: reqId, reason: .macUI)
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 2)])
        XCTAssertEqual(reg.terminalState(of: reqId), .resolvedElsewhere)
    }

    /// 终态/未知 reqId + dismiss → 完全零动作(dismiss 不回 0x56,规格 §4)
    func testDismissOnTerminalOrUnknownIsNoop() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: reqId, decision: .allow)

        XCTAssertTrue(reg.onDeviceResponse(reqId: reqId, decision: .dismiss).isEmpty, "终态 + dismiss")
        XCTAssertTrue(reg.onDeviceResponse(reqId: 0xBEEF, decision: .dismiss).isEmpty, "未知 + dismiss")
    }

    // MARK: 幂等契约(规格 §2.4)

    /// 重复 0x36(重发):只判决一次,每次都回 0x56;重发得 outcome=2、零判决副作用
    func testDuplicateResponseJudgedOnce() {
        let reg = ApprovalRegistry()
        let key = makeKey()
        let reqId = reg.register(makeInput(key: key), nowMs: 0).reqId

        let first = reg.onDeviceResponse(reqId: reqId, decision: .allow)
        XCTAssertEqual(first.count, 2, "首次:respond + 0x56")

        for _ in 0..<3 {
            let retry = reg.onDeviceResponse(reqId: reqId, decision: .allow)
            XCTAssertEqual(retry.count, 1, "重发:仅 0x56,无 respond")
            XCTAssertEqual(resolvedFrames(retry), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 2)])
        }
        XCTAssertEqual(reg.terminalState(of: reqId), .allowed, "终态不被重发改写")
    }

    /// 重复 0x36 携带不同 decision(allow 后又来 deny):同样静默吞,终态不变
    func testConflictingDuplicateResponseSwallowed() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: reqId, decision: .allow)

        let actions = reg.onDeviceResponse(reqId: reqId, decision: .deny)
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 2)])
        XCTAssertEqual(reg.terminalState(of: reqId), .allowed)
    }

    /// 未知 reqId 的 0x36(dismiss 除外)→ 零副作用 + 0x56(outcome=2)
    func testUnknownReqIdSwallowedWithOutcome2() {
        let reg = ApprovalRegistry()
        for decision: ApprovalDecision in [.deny, .allow, .alwaysAllow] {
            let actions = reg.onDeviceResponse(reqId: 0x1234, decision: decision)
            XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: 0x1234, rawOutcome: 2)])
        }
        XCTAssertEqual(reg.pendingCount, 0)
        XCTAssertNil(reg.terminalState(of: 0x1234), "吞掉不产生终态记录")
    }

    // MARK: resolveElsewhere / expire / endSession

    /// resolveElsewhere(非会话结束原因)→ 终态 resolvedElsewhere + 0x56(2)
    func testResolveElsewhereReasons() {
        for reason: ApprovalResolveReason in [.macUI, .hookEOF, .rolloutEvent] {
            let reg = ApprovalRegistry()
            let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId
            let actions = reg.resolveElsewhere(reqId: reqId, reason: reason)
            XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 2)])
            XCTAssertEqual(reg.terminalState(of: reqId), .resolvedElsewhere)
        }
    }

    /// resolveElsewhere(sessionEnded)→ 终态 cancelled + 0x56(5)
    func testResolveElsewhereSessionEnded() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId
        let actions = reg.resolveElsewhere(reqId: reqId, reason: .sessionEnded)
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 5)])
        XCTAssertEqual(reg.terminalState(of: reqId), .cancelled)
    }

    /// resolveElsewhere 对终态/未知 reqId 零动作
    func testResolveElsewhereOnTerminalOrUnknownIsNoop() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey()), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: reqId, decision: .deny)
        XCTAssertTrue(reg.resolveElsewhere(reqId: reqId, reason: .macUI).isEmpty)
        XCTAssertTrue(reg.resolveElsewhere(reqId: 0x7777, reason: .macUI).isEmpty)
    }

    /// expire:到期的 pending → 终态 expired + 0x56(3);未到期保留;deviceDismissed 一样过期
    func testExpire() {
        let reg = ApprovalRegistry()
        let a = reg.register(makeInput(key: makeKey(toolUse: "tu-a"), expires: 10), nowMs: 0).reqId    // 10s
        let b = reg.register(makeInput(key: makeKey(toolUse: "tu-b"), expires: 300), nowMs: 0).reqId   // 300s
        let c = reg.register(makeInput(key: makeKey(toolUse: "tu-c"), expires: 5), nowMs: 0).reqId     // 5s
        _ = reg.onDeviceResponse(reqId: c, decision: .dismiss)

        let actions = reg.expire(nowMs: 10_000) // t=10s:a(=10s)与 c(=5s)到期,b 未到期
        let frames = resolvedFrames(actions)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(Set(frames.map(\.reqId)), [a, c])
        XCTAssertTrue(frames.allSatisfy { $0.rawOutcome == 3 })
        XCTAssertEqual(reg.terminalState(of: a), .expired)
        XCTAssertEqual(reg.terminalState(of: c), .expired, "deviceDismissed 条目同样过期收尾")
        XCTAssertTrue(reg.isPending(b))
    }

    /// expiresInSec=0 → 立即过期(nowMs ≥ expiresAtMs 即到期)
    func testExpireZeroSeconds() {
        let reg = ApprovalRegistry()
        let reqId = reg.register(makeInput(key: makeKey(), expires: 0), nowMs: 500).reqId
        let actions = reg.expire(nowMs: 500)
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: reqId, rawOutcome: 3)])
    }

    /// endSession:该会话全部 pending → cancelled + 0x56(5);其他会话不受影响;Codex allowlist 随会话清除
    func testEndSession() {
        let reg = ApprovalRegistry()
        let s1a = reg.register(makeInput(key: makeKey(session: "S1", agent: 1, toolUse: "t1"), tool: "shell"), nowMs: 0).reqId
        let s1b = reg.register(makeInput(key: makeKey(session: "S1", agent: 1, toolUse: "t2"), tool: "web"), nowMs: 0).reqId
        let s2 = reg.register(makeInput(key: makeKey(session: "S2", toolUse: "t3")), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: s1a, decision: .alwaysAllow) // S1 写入 allowlist(shell)

        let actions = reg.endSession(sessionKey: "S1")
        let frames = resolvedFrames(actions)
        XCTAssertEqual(frames, [ApprovalResolvedFrame(reqId: s1b, rawOutcome: 5)])
        XCTAssertEqual(reg.terminalState(of: s1b), .cancelled)
        XCTAssertTrue(reg.isPending(s2), "其他会话不受影响")

        // allowlist 已清:同 (S1, shell) 再注册不 autoAllowed
        let r = reg.register(makeInput(key: makeKey(session: "S1", agent: 1, toolUse: "t9"), tool: "shell"), nowMs: 99)
        XCTAssertFalse(r.autoAllowed)
    }

    // MARK: reqId 分配

    /// 单调递增 u16 回绕:0xFFFF 之后回到 0
    func testReqIdWrapAround() {
        let reg = ApprovalRegistry()
        reg.nextReqId = 0xFFFF
        let r1 = reg.register(makeInput(key: makeKey(toolUse: "w1")), nowMs: 0)
        let r2 = reg.register(makeInput(key: makeKey(toolUse: "w2")), nowMs: 0)
        XCTAssertEqual(r1.reqId, 0xFFFF)
        XCTAssertEqual(r2.reqId, 0x0000)
    }

    /// 分配时跳过在用(pending)值
    func testReqIdSkipsInUseValues() {
        let reg = ApprovalRegistry()
        reg.nextReqId = 100
        let a = reg.register(makeInput(key: makeKey(toolUse: "u1")), nowMs: 0).reqId // 100,保持 pending
        XCTAssertEqual(a, 100)

        reg.nextReqId = 100 // 人为回拨,模拟回绕撞上在用值
        let b = reg.register(makeInput(key: makeKey(toolUse: "u2")), nowMs: 0).reqId
        XCTAssertEqual(b, 101, "跳过在用的 100")
        XCTAssertTrue(reg.isPending(a))
    }

    /// 回绕跳过连续在用区段
    func testReqIdSkipsContiguousInUseRange() {
        let reg = ApprovalRegistry()
        reg.nextReqId = 0xFFFE
        let ids = (0..<4).map { i in
            reg.register(makeInput(key: makeKey(toolUse: "r\(i)")), nowMs: 0).reqId
        }
        XCTAssertEqual(ids, [0xFFFE, 0xFFFF, 0x0000, 0x0001])

        reg.nextReqId = 0xFFFE // 全部仍 pending,再分配应跳过 4 个在用值
        let next = reg.register(makeInput(key: makeKey(toolUse: "r9")), nowMs: 0).reqId
        XCTAssertEqual(next, 0x0002)
    }

    // MARK: 终态环形记录

    /// 环容量内(≤256):最早的终态仍能幂等吞(带终态记录)
    func testTerminalRingWithinCapacity() {
        let reg = ApprovalRegistry()
        var first: UInt16 = 0
        for i in 0..<ApprovalRegistry.terminalRingCapacity {
            let reqId = reg.register(makeInput(key: makeKey(toolUse: "cap\(i)")), nowMs: 0).reqId
            if i == 0 { first = reqId }
            _ = reg.onDeviceResponse(reqId: reqId, decision: .allow)
        }
        XCTAssertEqual(reg.terminalState(of: first), .allowed, "第 256 条插入后最老记录仍在")
        let actions = reg.onDeviceResponse(reqId: first, decision: .allow)
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: first, rawOutcome: 2)])
    }

    /// 环溢出(256+):最老终态记录被淘汰,但迟到 0x36 走"未知 reqId"路径,
    /// 对外行为不变:仍静默吞 + 0x56(outcome=2)、零判决副作用。
    /// 取舍:实现为固定容量 256 的有限环,淘汰后无法区分"曾终态"与"从未见过",
    /// 由于两者对外语义一致(规格 §2.4 同一条款),此取舍不影响协议行为。
    func testTerminalRingOverflowOldestStillSwallowed() {
        let reg = ApprovalRegistry()
        let total = ApprovalRegistry.terminalRingCapacity + 44 // 300 条终态
        var ids: [UInt16] = []
        for i in 0..<total {
            let reqId = reg.register(makeInput(key: makeKey(toolUse: "of\(i)")), nowMs: 0).reqId
            ids.append(reqId)
            _ = reg.onDeviceResponse(reqId: reqId, decision: .allow)
        }
        // 终态 dict 保持容量上限
        XCTAssertEqual(reg.terminal.count, ApprovalRegistry.terminalRingCapacity)
        // 最老的已被淘汰出记录
        XCTAssertNil(reg.terminalState(of: ids[0]))
        // 但迟到 0x36 仍被吞 + 0x56(2),零副作用
        let late = reg.onDeviceResponse(reqId: ids[0], decision: .allow)
        XCTAssertEqual(resolvedFrames(late), [ApprovalResolvedFrame(reqId: ids[0], rawOutcome: 2)])
        XCTAssertEqual(reg.pendingCount, 0)
        // 环内最新记录仍可查询且同样被吞
        XCTAssertEqual(reg.terminalState(of: ids[total - 1]), .allowed)
        let recent = reg.onDeviceResponse(reqId: ids[total - 1], decision: .deny)
        XCTAssertEqual(resolvedFrames(recent), [ApprovalResolvedFrame(reqId: ids[total - 1], rawOutcome: 2)])
    }

    /// reqId 复用(极端回绕):在用值分配时清除同号旧终态记录,新请求判决不受污染
    func testReqIdReuseClearsStaleTerminalRecord() {
        let reg = ApprovalRegistry()
        reg.nextReqId = 42
        let reqId = reg.register(makeInput(key: makeKey(toolUse: "s1")), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: reqId, decision: .deny)
        XCTAssertEqual(reg.terminalState(of: 42), .denied)

        reg.nextReqId = 42 // 模拟 u16 走满一圈后复用 42
        let reused = reg.register(makeInput(key: makeKey(toolUse: "s2")), nowMs: 0).reqId
        XCTAssertEqual(reused, 42)
        XCTAssertNil(reg.terminalState(of: 42), "旧终态记录已清除")
        XCTAssertTrue(reg.isPending(42))
        let actions = reg.onDeviceResponse(reqId: 42, decision: .allow)
        XCTAssertEqual(actions.count, 2, "新请求正常判决,不被旧终态吞掉")
        XCTAssertEqual(reg.terminalState(of: 42), .allowed)
    }

    // MARK: autoAllowed 与幂等的交互

    /// autoAllowed 的 reqId 也有终态记录:设备侧不可能有此 reqId,若异常收到 0x36 → 吞 + 0x56(2)
    func testAutoAllowedReqIdSwallowsResponse() {
        let reg = ApprovalRegistry()
        let key1 = makeKey(session: "cx", agent: 1, toolUse: "t1")
        let reqId1 = reg.register(makeInput(key: key1, tool: "shell"), nowMs: 0).reqId
        _ = reg.onDeviceResponse(reqId: reqId1, decision: .alwaysAllow)

        let r2 = reg.register(makeInput(key: makeKey(session: "cx", agent: 1, toolUse: "t2"), tool: "shell"), nowMs: 0)
        XCTAssertTrue(r2.autoAllowed)
        let actions = reg.onDeviceResponse(reqId: r2.reqId, decision: .allow)
        XCTAssertEqual(resolvedFrames(actions), [ApprovalResolvedFrame(reqId: r2.reqId, rawOutcome: 2)])
    }
}

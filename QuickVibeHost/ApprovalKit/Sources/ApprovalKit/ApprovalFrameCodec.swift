// ApprovalFrameCodec.swift
// 审批协议 v1 帧编解码(规格:docs/approval-protocol-v1.md §1)
// 双向实现:Mac 正常路径 encode 0x55/0x56、decode 0x36;
// 反向(decode 0x55/0x56、encode 0x36)供 test-dev 打桩设备侧使用。
// 字节序:多字节字段一律 little-endian。

import Foundation

// MARK: - 协议常量

public enum ApprovalProtocolConst {
    /// 0x55 APPROVAL_REQUEST(Mac → 设备)
    public static let requestMagic: UInt8 = 0x55
    /// 0x36 CMD_APPROVAL_RESPONSE(设备 → Mac)
    public static let responseMagic: UInt8 = 0x36
    /// 0x56 APPROVAL_RESOLVED(Mac → 设备)
    public static let resolvedMagic: UInt8 = 0x56
    /// 0x55 帧版本;≠1 整帧丢弃
    public static let frameVersion: UInt8 = 1

    /// sessName 最大字节数(UTF-8 编码后)
    public static let maxSessNameBytes = 24
    /// tool 最大字节数
    public static let maxToolBytes = 64
    /// body 最大字节数
    public static let maxBodyBytes = 256

    /// flags bit0:内容被截断
    public static let flagTruncated: UInt8 = 0x01
    /// flags bit1:仅通知,设备不可判决
    public static let flagNotifyOnly: UInt8 = 0x02
    /// flags bit2:禁用 always_allow
    public static let flagAlwaysDisabled: UInt8 = 0x04
    /// 有效 flags 掩码;bit3..7 解码时忽略
    public static let flagsMask: UInt8 = 0x07

    /// riskLevel 上限;>2 解码时按 2 处理
    public static let maxRiskLevel: UInt8 = 2
}

// MARK: - 错误

public enum ApprovalFrameError: Error, Equatable {
    /// 首字节不是期望的 magic
    case badMagic
    /// 0x55 frameVer ≠ 1
    case badVersion
    /// 总长与声明长度不符(过短 / 截尾 / 尾部多余字节)
    case lengthMismatch
    /// 字段超出规格上限(解码:声明长度超限;编码:入参超限,视为编程错误直接拒绝)
    case fieldTooLong(field: String)
    /// 0x36 decision > 3(编码/解码侧均拒绝,规格 §3.1.5)
    case invalidDecision
}

// MARK: - 帧模型

/// 0x55 APPROVAL_REQUEST。
/// 文本字段以 Data 存储:codec 不校验 UTF-8 合法性(规格 §1.1,渲染层负责)。
public struct ApprovalRequestFrame: Equatable {
    public var reqId: UInt16
    /// 0=ClaudeCode 1=Codex;未知值合法(显示回落通用图标)
    public var agentId: UInt8
    /// 0/1/2;解码时 >2 已钳制为 2
    public var riskLevel: UInt8
    /// 0 = 立即过期(合法)
    public var expiresInSec: UInt16
    /// 解码时 bit3..7 已被屏蔽
    public var flags: UInt8
    public var sessNameData: Data
    public var toolData: Data
    public var bodyData: Data

    /// String 便捷访问(非法 UTF-8 按替换字符解码,仅供显示/测试)
    public var sessName: String { String(decoding: sessNameData, as: UTF8.self) }
    public var tool: String { String(decoding: toolData, as: UTF8.self) }
    public var body: String { String(decoding: bodyData, as: UTF8.self) }

    public init(reqId: UInt16, agentId: UInt8, riskLevel: UInt8, expiresInSec: UInt16,
                flags: UInt8, sessNameData: Data, toolData: Data, bodyData: Data) {
        self.reqId = reqId
        self.agentId = agentId
        self.riskLevel = riskLevel
        self.expiresInSec = expiresInSec
        self.flags = flags
        self.sessNameData = sessNameData
        self.toolData = toolData
        self.bodyData = bodyData
    }

    public init(reqId: UInt16, agentId: UInt8, riskLevel: UInt8, expiresInSec: UInt16,
                flags: UInt8, sessName: String, tool: String, body: String) {
        self.init(reqId: reqId, agentId: agentId, riskLevel: riskLevel, expiresInSec: expiresInSec,
                  flags: flags, sessNameData: Data(sessName.utf8),
                  toolData: Data(tool.utf8), bodyData: Data(body.utf8))
    }
}

/// 0x36 decision 枚举;>3 为 decode error,不进入枚举
public enum ApprovalDecision: UInt8, Equatable {
    case deny = 0
    case allow = 1
    case dismiss = 2
    case alwaysAllow = 3
}

/// 0x36 CMD_APPROVAL_RESPONSE
public struct ApprovalResponseFrame: Equatable {
    public var reqId: UInt16
    public var decision: ApprovalDecision

    public init(reqId: UInt16, decision: ApprovalDecision) {
        self.reqId = reqId
        self.decision = decision
    }
}

/// 0x56 outcome 枚举(已知值)
public enum ApprovalOutcome: UInt8, Equatable {
    case judgedAllow = 0
    case judgedDeny = 1
    case resolvedElsewhere = 2
    case expired = 3
    case autoAllowed = 4
    case cancelled = 5
}

/// 0x56 APPROVAL_RESOLVED。未知 outcome 解码合法,语义按 2(resolvedElsewhere)处理(规格 §1.3)。
public struct ApprovalResolvedFrame: Equatable {
    public var reqId: UInt16
    /// 线上原始值(前向兼容:保留未知值)
    public var rawOutcome: UInt8
    /// 归一化语义:未知值按 resolvedElsewhere(=2) 处理
    public var outcome: ApprovalOutcome {
        ApprovalOutcome(rawValue: rawOutcome) ?? .resolvedElsewhere
    }

    public init(reqId: UInt16, rawOutcome: UInt8) {
        self.reqId = reqId
        self.rawOutcome = rawOutcome
    }
}

// MARK: - 编解码

public enum ApprovalFrameCodec {

    // MARK: 0x55 APPROVAL_REQUEST

    /// 编码 0x55。仅拒绝三个长度超限(编程错误,不做静默截断——截断是 Registry 推送前的职责);
    /// riskLevel/flags 按原值写入,不做钳制/掩码(规格 §3.1.5:钳制/掩码是解码侧规则;
    /// test-server 打桩需要能发 risk>2、flags 高位置位的原始帧来测设备解码侧)。
    public static func encodeApprovalRequest(_ frame: ApprovalRequestFrame) throws -> Data {
        guard frame.sessNameData.count <= ApprovalProtocolConst.maxSessNameBytes else {
            throw ApprovalFrameError.fieldTooLong(field: "sessName")
        }
        guard frame.toolData.count <= ApprovalProtocolConst.maxToolBytes else {
            throw ApprovalFrameError.fieldTooLong(field: "tool")
        }
        guard frame.bodyData.count <= ApprovalProtocolConst.maxBodyBytes else {
            throw ApprovalFrameError.fieldTooLong(field: "body")
        }

        var out = Data()
        out.reserveCapacity(13 + frame.sessNameData.count + frame.toolData.count + frame.bodyData.count)
        out.append(ApprovalProtocolConst.requestMagic)
        out.append(ApprovalProtocolConst.frameVersion)
        appendU16LE(&out, frame.reqId)
        out.append(frame.agentId)
        out.append(frame.riskLevel)
        appendU16LE(&out, frame.expiresInSec)
        out.append(frame.flags)
        out.append(UInt8(frame.sessNameData.count))
        out.append(frame.sessNameData)
        out.append(UInt8(frame.toolData.count))
        out.append(frame.toolData)
        appendU16LE(&out, UInt16(frame.bodyData.count))
        out.append(frame.bodyData)
        return out
    }

    /// 解码 0x55。严格校验:magic / ver=1 / 各字段声明长度上限 / 总长精确匹配;
    /// riskLevel>2 钳制为 2;flags bit3..7 忽略;agentId 未知值合法保留。
    public static func decodeApprovalRequest(_ data: Data) throws -> ApprovalRequestFrame {
        let b = [UInt8](data)
        guard b.count >= 1, b[0] == ApprovalProtocolConst.requestMagic else {
            throw ApprovalFrameError.badMagic
        }
        guard b.count >= 2 else { throw ApprovalFrameError.lengthMismatch }
        guard b[1] == ApprovalProtocolConst.frameVersion else {
            throw ApprovalFrameError.badVersion
        }
        // 最短帧:13 字节(三个变长字段全空)
        guard b.count >= 13 else { throw ApprovalFrameError.lengthMismatch }

        let sessLen = Int(b[9])
        guard sessLen <= ApprovalProtocolConst.maxSessNameBytes else {
            throw ApprovalFrameError.fieldTooLong(field: "sessName")
        }
        let toolLenOffset = 10 + sessLen
        guard b.count > toolLenOffset else { throw ApprovalFrameError.lengthMismatch }
        let toolLen = Int(b[toolLenOffset])
        guard toolLen <= ApprovalProtocolConst.maxToolBytes else {
            throw ApprovalFrameError.fieldTooLong(field: "tool")
        }
        let bodyLenOffset = toolLenOffset + 1 + toolLen
        guard b.count >= bodyLenOffset + 2 else { throw ApprovalFrameError.lengthMismatch }
        let bodyLen = Int(b[bodyLenOffset]) | (Int(b[bodyLenOffset + 1]) << 8)
        guard bodyLen <= ApprovalProtocolConst.maxBodyBytes else {
            throw ApprovalFrameError.fieldTooLong(field: "body")
        }
        // 总长必须精确等于 13 + sessNameLen + toolLen + bodyLen(截尾/尾部多余字节均为错误)
        guard b.count == 13 + sessLen + toolLen + bodyLen else {
            throw ApprovalFrameError.lengthMismatch
        }

        return ApprovalRequestFrame(
            reqId: u16LE(b[2], b[3]),
            agentId: b[4],
            riskLevel: min(b[5], ApprovalProtocolConst.maxRiskLevel),
            expiresInSec: u16LE(b[6], b[7]),
            flags: b[8] & ApprovalProtocolConst.flagsMask,
            sessNameData: Data(b[10 ..< 10 + sessLen]),
            toolData: Data(b[toolLenOffset + 1 ..< toolLenOffset + 1 + toolLen]),
            bodyData: Data(b[bodyLenOffset + 2 ..< bodyLenOffset + 2 + bodyLen])
        )
    }

    // MARK: 0x36 CMD_APPROVAL_RESPONSE

    /// 编码 0x36(设备侧动作,供 test-dev 打桩)。decision 用枚举,非法值在类型层排除。
    public static func encodeApprovalResponse(_ frame: ApprovalResponseFrame) -> Data {
        var out = Data(capacity: 4)
        out.append(ApprovalProtocolConst.responseMagic)
        appendU16LE(&out, frame.reqId)
        out.append(frame.decision.rawValue)
        return out
    }

    /// 解码 0x36。总长必须 =4;decision > 3 → decode error(Mac 丢弃)。
    public static func decodeApprovalResponse(_ data: Data) throws -> ApprovalResponseFrame {
        let b = [UInt8](data)
        guard b.count >= 1, b[0] == ApprovalProtocolConst.responseMagic else {
            throw ApprovalFrameError.badMagic
        }
        guard b.count == 4 else { throw ApprovalFrameError.lengthMismatch }
        guard let decision = ApprovalDecision(rawValue: b[3]) else {
            throw ApprovalFrameError.invalidDecision
        }
        return ApprovalResponseFrame(reqId: u16LE(b[1], b[2]), decision: decision)
    }

    // MARK: 0x56 APPROVAL_RESOLVED

    /// 编码 0x56(已知 outcome)
    public static func encodeApprovalResolved(reqId: UInt16, outcome: ApprovalOutcome) -> Data {
        encodeApprovalResolved(reqId: reqId, rawOutcome: outcome.rawValue)
    }

    /// 编码 0x56(原始 outcome 值;未知值在线上合法,设备按 2 处理——供打桩前向兼容场景)
    public static func encodeApprovalResolved(reqId: UInt16, rawOutcome: UInt8) -> Data {
        var out = Data(capacity: 4)
        out.append(ApprovalProtocolConst.resolvedMagic)
        appendU16LE(&out, reqId)
        out.append(rawOutcome)
        return out
    }

    /// 解码 0x56(设备侧动作,供 test-dev 打桩)。总长必须 =4;未知 outcome 合法,
    /// 原始值保留在 rawOutcome,归一化语义经 `outcome` 属性按 2 处理。
    public static func decodeApprovalResolved(_ data: Data) throws -> ApprovalResolvedFrame {
        let b = [UInt8](data)
        guard b.count >= 1, b[0] == ApprovalProtocolConst.resolvedMagic else {
            throw ApprovalFrameError.badMagic
        }
        guard b.count == 4 else { throw ApprovalFrameError.lengthMismatch }
        return ApprovalResolvedFrame(reqId: u16LE(b[1], b[2]), rawOutcome: b[3])
    }

    // MARK: 内部工具

    private static func appendU16LE(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }

    private static func u16LE(_ lo: UInt8, _ hi: UInt8) -> UInt16 {
        UInt16(lo) | (UInt16(hi) << 8)
    }
}

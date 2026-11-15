// CodecVectorTests.swift
// 帧编解码 × 生成的测试向量(ApprovalVectors.generated.swift,来源 tests/approval_vectors.py)
// 覆盖:ENCODE_* 逐字节比对、DECODE_*_ERR 拒绝、钳制与 treatAs 语义、编解码往返。

import XCTest
@testable import ApprovalKit

/// hex 字符串 ↔ Data 工具
func dataFromHex(_ hex: String) -> Data {
    precondition(hex.count % 2 == 0, "hex 长度必须为偶数")
    var out = Data(capacity: hex.count / 2)
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        out.append(UInt8(hex[idx..<next], radix: 16)!)
        idx = next
    }
    return out
}

func hexFromData(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

final class Codec55VectorTests: XCTestCase {

    /// ENCODE_55:编码结果逐字节等于向量 hex
    func testEncode55Vectors() throws {
        for v in ENCODE_55 {
            let frame = ApprovalRequestFrame(
                reqId: v.reqId, agentId: v.agentId, riskLevel: v.risk,
                expiresInSec: v.expires, flags: v.flags,
                sessName: v.sess, tool: v.tool, body: v.body)
            let encoded = try ApprovalFrameCodec.encodeApprovalRequest(frame)
            XCTAssertEqual(hexFromData(encoded), v.hex, "ENCODE_55/\(v.name)")
        }
    }

    /// ENCODE_55 向量反向解码:字段全等(这些向量 risk ≤2、flags ≤7,无钳制)
    func testDecode55FromEncodeVectors() throws {
        for v in ENCODE_55 {
            let frame = try ApprovalFrameCodec.decodeApprovalRequest(dataFromHex(v.hex))
            XCTAssertEqual(frame.reqId, v.reqId, "DECODE(ENCODE_55)/\(v.name)/reqId")
            XCTAssertEqual(frame.agentId, v.agentId, "DECODE(ENCODE_55)/\(v.name)/agentId")
            XCTAssertEqual(frame.riskLevel, v.risk, "DECODE(ENCODE_55)/\(v.name)/risk")
            XCTAssertEqual(frame.expiresInSec, v.expires, "DECODE(ENCODE_55)/\(v.name)/expires")
            XCTAssertEqual(frame.flags, v.flags, "DECODE(ENCODE_55)/\(v.name)/flags")
            XCTAssertEqual(frame.sessName, v.sess, "DECODE(ENCODE_55)/\(v.name)/sess")
            XCTAssertEqual(frame.tool, v.tool, "DECODE(ENCODE_55)/\(v.name)/tool")
            XCTAssertEqual(frame.body, v.body, "DECODE(ENCODE_55)/\(v.name)/body")
        }
    }

    /// DECODE_55_OK:risk>2 钳制为 2、flags bit3..7 忽略
    func testDecode55ClampVectors() throws {
        for v in DECODE_55_OK {
            let frame = try ApprovalFrameCodec.decodeApprovalRequest(dataFromHex(v.hex))
            XCTAssertEqual(frame.reqId, v.reqId, "DECODE_55_OK/\(v.name)/reqId")
            XCTAssertEqual(frame.agentId, v.agentId, "DECODE_55_OK/\(v.name)/agentId")
            XCTAssertEqual(frame.riskLevel, v.risk, "DECODE_55_OK/\(v.name)/risk(钳制)")
            XCTAssertEqual(frame.expiresInSec, v.expires, "DECODE_55_OK/\(v.name)/expires")
            XCTAssertEqual(frame.flags, v.flags, "DECODE_55_OK/\(v.name)/flags(高位忽略)")
            XCTAssertEqual(frame.sessName, v.sess, "DECODE_55_OK/\(v.name)/sess")
            XCTAssertEqual(frame.tool, v.tool, "DECODE_55_OK/\(v.name)/tool")
            XCTAssertEqual(frame.body, v.body, "DECODE_55_OK/\(v.name)/body")
        }
    }

    /// DECODE_55_ERR:每条反例必须被拒绝
    func testDecode55ErrVectors() {
        for v in DECODE_55_ERR {
            XCTAssertThrowsError(
                try ApprovalFrameCodec.decodeApprovalRequest(dataFromHex(v.hex)),
                "DECODE_55_ERR/\(v.name) 应拒绝")
        }
    }

    /// 编解码往返:encode → decode → 字段全等
    func testRoundtrip55() throws {
        for v in ENCODE_55 {
            let original = ApprovalRequestFrame(
                reqId: v.reqId, agentId: v.agentId, riskLevel: v.risk,
                expiresInSec: v.expires, flags: v.flags,
                sessName: v.sess, tool: v.tool, body: v.body)
            let decoded = try ApprovalFrameCodec.decodeApprovalRequest(
                try ApprovalFrameCodec.encodeApprovalRequest(original))
            XCTAssertEqual(decoded, original, "ROUNDTRIP_55/\(v.name)")
        }
    }
}

final class Codec36VectorTests: XCTestCase {

    /// ENCODE_36:编码逐字节比对(设备侧动作,打桩用)
    func testEncode36Vectors() {
        for v in ENCODE_36 {
            let decision = ApprovalDecision(rawValue: v.decision)!
            let encoded = ApprovalFrameCodec.encodeApprovalResponse(
                ApprovalResponseFrame(reqId: v.reqId, decision: decision))
            XCTAssertEqual(hexFromData(encoded), v.hex, "ENCODE_36/\(v.name)")
        }
    }

    /// ENCODE_36 反向解码 + 往返
    func testDecode36AndRoundtrip() throws {
        for v in ENCODE_36 {
            let frame = try ApprovalFrameCodec.decodeApprovalResponse(dataFromHex(v.hex))
            XCTAssertEqual(frame.reqId, v.reqId, "DECODE_36/\(v.name)/reqId")
            XCTAssertEqual(frame.decision.rawValue, v.decision, "DECODE_36/\(v.name)/decision")
            XCTAssertEqual(ApprovalFrameCodec.encodeApprovalResponse(frame),
                           dataFromHex(v.hex), "ROUNDTRIP_36/\(v.name)")
        }
    }

    /// DECODE_36_ERR:decision>3 / 长度错误 / magic 错误全部拒绝
    func testDecode36ErrVectors() {
        for v in DECODE_36_ERR {
            XCTAssertThrowsError(
                try ApprovalFrameCodec.decodeApprovalResponse(dataFromHex(v.hex)),
                "DECODE_36_ERR/\(v.name) 应拒绝")
        }
    }
}

final class Codec56VectorTests: XCTestCase {

    /// ENCODE_56:编码逐字节比对
    func testEncode56Vectors() {
        for v in ENCODE_56 {
            let outcome = ApprovalOutcome(rawValue: v.outcome)!
            let encoded = ApprovalFrameCodec.encodeApprovalResolved(reqId: v.reqId, outcome: outcome)
            XCTAssertEqual(hexFromData(encoded), v.hex, "ENCODE_56/\(v.name)")
        }
    }

    /// ENCODE_56 反向解码 + 往返
    func testDecode56AndRoundtrip() throws {
        for v in ENCODE_56 {
            let frame = try ApprovalFrameCodec.decodeApprovalResolved(dataFromHex(v.hex))
            XCTAssertEqual(frame.reqId, v.reqId, "DECODE_56/\(v.name)/reqId")
            XCTAssertEqual(frame.rawOutcome, v.outcome, "DECODE_56/\(v.name)/rawOutcome")
            XCTAssertEqual(frame.outcome.rawValue, v.outcome, "DECODE_56/\(v.name)/outcome")
            XCTAssertEqual(ApprovalFrameCodec.encodeApprovalResolved(reqId: frame.reqId, rawOutcome: frame.rawOutcome),
                           dataFromHex(v.hex), "ROUNDTRIP_56/\(v.name)")
        }
    }

    /// DECODE_56_UNKNOWN:未知 outcome 解码合法,raw 保留、语义按 treatAs(=2) 处理
    func testDecode56UnknownVectors() throws {
        for v in DECODE_56_UNKNOWN {
            let frame = try ApprovalFrameCodec.decodeApprovalResolved(dataFromHex(v.hex))
            XCTAssertEqual(frame.rawOutcome, v.raw, "DECODE_56_UNKNOWN/\(v.name)/raw")
            XCTAssertEqual(frame.outcome.rawValue, v.treatAs, "DECODE_56_UNKNOWN/\(v.name)/treatAs")
        }
    }

    /// DECODE_56_ERR:长度错误拒绝
    func testDecode56ErrVectors() {
        for v in DECODE_56_ERR {
            XCTAssertThrowsError(
                try ApprovalFrameCodec.decodeApprovalResolved(dataFromHex(v.hex)),
                "DECODE_56_ERR/\(v.name) 应拒绝")
        }
    }
}

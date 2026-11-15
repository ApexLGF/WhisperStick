// CodecEdgeTests.swift
// 编码侧拒绝规则(规格 §1.1:字段超限直接拒绝编码,不做静默截断)及向量未覆盖的边界。

import XCTest
@testable import ApprovalKit

final class CodecEncodeRejectTests: XCTestCase {

    private func makeFrame(sess: String = "", tool: String = "t", body: String = "",
                           risk: UInt8 = 0, flags: UInt8 = 0) -> ApprovalRequestFrame {
        ApprovalRequestFrame(reqId: 1, agentId: 0, riskLevel: risk, expiresInSec: 60,
                             flags: flags, sessName: sess, tool: tool, body: body)
    }

    /// sessName 25 字节 → 拒绝编码
    func testEncode55RejectsSessOver24() {
        let frame = makeFrame(sess: String(repeating: "a", count: 25))
        XCTAssertThrowsError(try ApprovalFrameCodec.encodeApprovalRequest(frame)) {
            XCTAssertEqual($0 as? ApprovalFrameError, .fieldTooLong(field: "sessName"))
        }
    }

    /// tool 65 字节 → 拒绝编码
    func testEncode55RejectsToolOver64() {
        let frame = makeFrame(tool: String(repeating: "t", count: 65))
        XCTAssertThrowsError(try ApprovalFrameCodec.encodeApprovalRequest(frame)) {
            XCTAssertEqual($0 as? ApprovalFrameError, .fieldTooLong(field: "tool"))
        }
    }

    /// body 257 字节 → 拒绝编码
    func testEncode55RejectsBodyOver256() {
        let frame = makeFrame(body: String(repeating: "b", count: 257))
        XCTAssertThrowsError(try ApprovalFrameCodec.encodeApprovalRequest(frame)) {
            XCTAssertEqual($0 as? ApprovalFrameError, .fieldTooLong(field: "body"))
        }
    }

    /// 上限恰好等于限值 → 合法(与 ENCODE_55/max_lens 向量一致的边界)
    func testEncode55AcceptsExactLimits() throws {
        let frame = makeFrame(sess: String(repeating: "s", count: 24),
                              tool: String(repeating: "t", count: 64),
                              body: String(repeating: "b", count: 256))
        let data = try ApprovalFrameCodec.encodeApprovalRequest(frame)
        XCTAssertEqual(data.count, 13 + 24 + 64 + 256)
        let decoded = try ApprovalFrameCodec.decodeApprovalRequest(data)
        XCTAssertEqual(decoded, frame)
    }

    /// riskLevel>2:编码侧按原值写入不钳制(规格 §3.1.5,供打桩测设备解码侧);解码回读得到钳制值 2
    func testEncode55WritesRawRiskDecodeClamps() throws {
        let data = try ApprovalFrameCodec.encodeApprovalRequest(makeFrame(risk: 3))
        XCTAssertEqual(data[5], 3, "线上字节保持原值")
        XCTAssertEqual(try ApprovalFrameCodec.decodeApprovalRequest(data).riskLevel, 2)

        let data255 = try ApprovalFrameCodec.encodeApprovalRequest(makeFrame(risk: 255))
        XCTAssertEqual(data255[5], 255)
        XCTAssertEqual(try ApprovalFrameCodec.decodeApprovalRequest(data255).riskLevel, 2)
    }

    /// flags bit3..7:编码侧按原值写入不掩码(规格 §3.1.5);解码回读高位被忽略
    func testEncode55WritesRawFlagsDecodeMasks() throws {
        let data = try ApprovalFrameCodec.encodeApprovalRequest(makeFrame(flags: 0xF8))
        XCTAssertEqual(data[8], 0xF8, "线上字节保持原值")
        XCTAssertEqual(try ApprovalFrameCodec.decodeApprovalRequest(data).flags, 0)

        let dataFF = try ApprovalFrameCodec.encodeApprovalRequest(makeFrame(flags: 0xFF))
        XCTAssertEqual(dataFF[8], 0xFF)
        XCTAssertEqual(try ApprovalFrameCodec.decodeApprovalRequest(dataFF).flags, 0x07)
    }

    /// agentId 未知值编码合法(规格 §1.1:未知 agentId 合法)
    func testEncode55AcceptsUnknownAgentId() throws {
        let frame = ApprovalRequestFrame(reqId: 2, agentId: 200, riskLevel: 0, expiresInSec: 1,
                                         flags: 0, sessName: "", tool: "x", body: "")
        let decoded = try ApprovalFrameCodec.decodeApprovalRequest(
            try ApprovalFrameCodec.encodeApprovalRequest(frame))
        XCTAssertEqual(decoded.agentId, 200)
    }

    /// 非法 UTF-8 字节序列可编解码往返(codec 不校验 UTF-8 合法性,规格 §1.1)
    func testCodecDoesNotValidateUTF8() throws {
        let invalidUTF8 = Data([0xFF, 0xFE, 0x80])
        let frame = ApprovalRequestFrame(reqId: 3, agentId: 0, riskLevel: 0, expiresInSec: 1,
                                         flags: 0, sessNameData: invalidUTF8,
                                         toolData: Data("t".utf8), bodyData: Data())
        let decoded = try ApprovalFrameCodec.decodeApprovalRequest(
            try ApprovalFrameCodec.encodeApprovalRequest(frame))
        XCTAssertEqual(decoded.sessNameData, invalidUTF8)
    }
}

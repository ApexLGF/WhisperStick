import Foundation
import Compression
import Network
import os

// MARK: - Protocol Constants

private enum Proto {
    static let version: UInt8 = 0x01
    static let headerSize: UInt8 = 0x01 // in 4-byte units

    enum MsgType: UInt8 {
        case clientFullRequest = 0x01
        case clientAudioOnly = 0x02
        case serverFullResponse = 0x09
        case serverError = 0x0F
    }

    enum Flags: UInt8 {
        case posSequence = 0x01
        case negSequence = 0x02
        case negWithSequence = 0x03
    }

    enum Serialization: UInt8 {
        case json = 0x01
    }

    enum Compress: UInt8 {
        case gzip = 0x01
    }
}

// MARK: - Response

struct ASRResponse {
    var code: Int32 = 0
    var isLast = false
    var payloadSequence: Int32 = 0
    var payloadMsg: [String: Any]?

    var text: String? {
        // Try result.text first, then utterances
        if let result = payloadMsg?["result"] as? [String: Any],
           let text = result["text"] as? String, !text.isEmpty {
            return text
        }
        if let utterances = payloadMsg?["utterances"] as? [[String: Any]] {
            let texts = utterances.compactMap { $0["text"] as? String }
            let joined = texts.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}

// MARK: - NWConnection WebSocket Wrapper

/// Thin async wrapper around NWConnection with WebSocket protocol — bypasses URLSession proxy.
private final class NWWebSocket: @unchecked Sendable {
    private let connection: NWConnection

    init(url: URL, headers: [(String, String)]) {
        let tlsOptions = NWProtocolTLS.Options()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.setAdditionalHeaders(headers.map { (name: $0.0, value: $0.1) })

        let params = NWParameters(tls: tlsOptions)
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
        }

        let endpoint = NWEndpoint.url(url)
        connection = NWConnection(to: endpoint, using: params)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                    self.connection.stateUpdateHandler = nil
                case .failed(let error):
                    cont.resume(throwing: error)
                    self.connection.stateUpdateHandler = nil
                case .waiting(let error):
                    cont.resume(throwing: error)
                    self.connection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func send(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        while true {
            let data: Data = try await withCheckedThrowingContinuation { cont in
                connection.receiveMessage { content, context, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                        // Skip ping/pong frames — auto-reply handles them
                        if metadata.opcode == .ping || metadata.opcode == .pong {
                            cont.resume(returning: Data())
                            return
                        }
                        if metadata.opcode == .close {
                            cont.resume(throwing: ASRError.unexpectedMessage)
                            return
                        }
                    }
                    guard let data = content, !data.isEmpty else {
                        cont.resume(returning: Data())
                        return
                    }
                    cont.resume(returning: data)
                }
            }
            if !data.isEmpty { return data }
            // Empty data means ping/pong — loop to receive next real message
        }
    }

    func close() {
        connection.cancel()
    }
}

// MARK: - Client

final class DoubaoASRClient {
    let appKey: String
    let accessKey: String

    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "ASR")
    // 流式输入模式：录完再发，发送最后一包后快速返回结果
    private let baseURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"

    let enablePunc: Bool
    /// 语义顺滑(去口水词/重复)。★ 会**删内容**:命令/代码口述场景可能吞掉真实词句
    ///(实测样本"按住电源键不松手——"被服务端吞掉,疑为 DDC 收敛)。默认关,完整性优先。
    let enableDDC: Bool
    /// 逆文本规范化(数字/日期/单位:十秒→10秒)。默认开。
    let enableITN: Bool
    let hotwords: [[String: String]]     // [{"word": "xxx"}] 格式
    let dialogContext: [String]          // 对话历史文本，新到旧排列

    init(appKey: String, accessKey: String, enablePunc: Bool = false,
         enableDDC: Bool = false, enableITN: Bool = true,
         hotwords: [[String: String]] = [], dialogContext: [String] = []) {
        self.appKey = appKey
        self.accessKey = accessKey
        self.enablePunc = enablePunc
        self.enableDDC = enableDDC
        self.enableITN = enableITN
        self.hotwords = hotwords
        self.dialogContext = dialogContext
    }

    /// Recognize speech from WAV data. Returns recognized text.
    func recognize(wavData: Data) async throws -> String {
        guard !appKey.isEmpty, !accessKey.isEmpty else {
            throw ASRError.missingCredentials
        }
        guard wavData.count > 44 else {
            throw ASRError.invalidAudio
        }

        // 200ms segments: docs require 100-200ms per packet for optimal performance
        let segmentSize = 16000 * 2 * 1 * 200 / 1000  // 6400 bytes = 200ms of 16kHz/16bit/mono
        let segments = stride(from: 0, to: wavData.count, by: segmentSize).map { start -> Data in
            wavData[start..<min(start + segmentSize, wavData.count)]
        }

        logger.info("ASR start: WAV=\(wavData.count) bytes, \(segments.count) segments")
        let asrStartedAt = Date()

        // Connect via NWConnection (bypasses URLSession proxy completely)
        let ws = try await connect()
        let wsReadyElapsedMs = Int(Date().timeIntervalSince(asrStartedAt) * 1000)

        // Send config (full client request)
        var seq: Int32 = 1
        try await ws.send(buildFullClientRequest(seq: seq))
        seq += 1

        // Receive config response
        let configResp = try await receiveOne(ws)
        ClaudeCodeSessionManager.log("[ASR config] code=\(configResp.code) payload=\(configResp.payloadMsg?.description.prefix(300) ?? "<nil>")")
        if configResp.code != 0 {
            ws.close()
            throw ASRError.serverError(configResp.code, configResp.payloadMsg)
        }

        // Send audio in 200ms segments — no inter-packet delay since audio is pre-recorded
        for (i, segment) in segments.enumerated() {
            let isLast = (i == segments.count - 1)
            let packet = buildAudioRequest(seq: seq, data: segment, isLast: isLast)
            try await ws.send(packet)
            if !isLast { seq += 1 }
        }

        // Receive responses until last
        var finalText = ""
        while true {
            let resp = try await receiveOne(ws)
            do {
                let payloadStr: String
                if let msg = resp.payloadMsg, let jsonData = try? JSONSerialization.data(withJSONObject: msg), let s = String(data: jsonData, encoding: .utf8) {
                    payloadStr = String(s.prefix(500))
                } else {
                    payloadStr = "<nil>"
                }
                ClaudeCodeSessionManager.log("[ASR resp] code=\(resp.code) isLast=\(resp.isLast) seq=\(resp.payloadSequence) text='\(resp.text ?? "<nil>")' payload=\(payloadStr)")
            }
            if let text = resp.text {
                finalText = text
            }
            if resp.isLast || resp.code != 0 {
                if resp.code != 0 {
                    ws.close()
                    throw ASRError.serverError(resp.code, resp.payloadMsg)
                }
                break
            }
        }

        let totalElapsedMs = Int(Date().timeIntervalSince(asrStartedAt) * 1000)
        logger.info("ASR done: isEmpty=\(finalText.isEmpty) len=\(finalText.count) totalMs=\(totalElapsedMs) wsReadyMs=\(wsReadyElapsedMs) text='\(finalText.prefix(40))'")
        ClaudeCodeSessionManager.log("[ASR done] isEmpty=\(finalText.isEmpty) len=\(finalText.count) totalMs=\(totalElapsedMs) wsReadyMs=\(wsReadyElapsedMs) text='\(finalText.prefix(80))'")
        ws.close()
        return finalText
    }

    /// Validate credentials with the same config handshake used by recognition, without sending audio.
    func validateConfiguration() async throws {
        guard !appKey.isEmpty, !accessKey.isEmpty else {
            throw ASRError.missingCredentials
        }

        let ws = try await connect()
        defer { ws.close() }
        try await ws.send(buildFullClientRequest(seq: 1))
        let resp = try await receiveOne(ws)
        guard resp.code == 0 else {
            throw ASRError.serverError(resp.code, resp.payloadMsg)
        }
    }

    // MARK: - WebSocket Connection

    fileprivate func connect(urlString: String? = nil) async throws -> NWWebSocket {
        let target = urlString ?? baseURL
        guard let url = URL(string: target) else {
            throw ASRError.invalidURL
        }

        let headers = [
            ("X-Api-Resource-Id", "volc.seedasr.sauc.duration"),
            ("X-Api-Request-Id", UUID().uuidString),   // 文档列为必填;非流式容忍缺它,双向流式 bigmodel 缺它即 NWError 53 abort
            ("X-Api-Connect-Id", UUID().uuidString),
            ("X-Api-Access-Key", accessKey),
            ("X-Api-App-Key", appKey),
        ]

        logger.info("Connecting via NWConnection to \(target)")

        let ws = NWWebSocket(url: url, headers: headers)
        try await ws.connect()

        logger.info("NWConnection WebSocket ready")
        return ws
    }

    fileprivate func receiveOne(_ ws: NWWebSocket) async throws -> ASRResponse {
        let data = try await ws.receive()
        return parseResponse(data)
    }

    // MARK: - Build Requests

    private func buildHeader(msgType: Proto.MsgType, flags: Proto.Flags) -> Data {
        var header = Data(count: 4)
        header[0] = (Proto.version << 4) | Proto.headerSize
        header[1] = (msgType.rawValue << 4) | flags.rawValue
        header[2] = (Proto.Serialization.json.rawValue << 4) | Proto.Compress.gzip.rawValue
        header[3] = 0x00
        return header
    }

    fileprivate func buildFullClientRequest(seq: Int32, format: String = "wav") -> Data {
        let header = buildHeader(msgType: .clientFullRequest, flags: .posSequence)

        // Build context JSON string (hotwords + dialog_ctx combined)
        var requestDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": enableITN,
            "enable_punc": enablePunc,
            "enable_ddc": enableDDC,
            "show_utterances": true,
            "enable_nonstream": false,
            // PTT 场景:句子边界由用户松手(末包)控制,**不要**让服务器因短停顿就 VAD 判停
            // (默认 end_window_size=800ms 太短,停顿一下就判停致后续不再延续识别)。设大值。
            "end_window_size": 30000
        ]

        // Build corpus.context as JSON string (API requires string, not dict)
        if !hotwords.isEmpty || !dialogContext.isEmpty {
            var contextObj: [String: Any] = [:]
            if !hotwords.isEmpty {
                contextObj["hotwords"] = hotwords
            }
            if !dialogContext.isEmpty {
                contextObj["context_type"] = "dialog_ctx"
                contextObj["context_data"] = dialogContext.map { ["text": $0] }
            }
            if let contextData = try? JSONSerialization.data(withJSONObject: contextObj),
               let contextJSON = String(data: contextData, encoding: .utf8) {
                requestDict["corpus"] = ["context": contextJSON] as [String: Any]
            }
        }

        let config: [String: Any] = [
            "user": ["uid": "quickvibepanel"],
            "audio": [
                "format": format,
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ] as [String: Any],
            "request": requestDict
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: config)
        let compressed = Gzip.compress(jsonData)!

        var packet = Data()
        packet.append(header)
        appendBE(&packet, seq)
        appendBE(&packet, UInt32(compressed.count))
        packet.append(compressed)
        return packet
    }

    fileprivate func buildAudioRequest(seq: Int32, data: Data, isLast: Bool) -> Data {
        let flags: Proto.Flags = isLast ? .negWithSequence : .posSequence
        let actualSeq = isLast ? -seq : seq

        var header = buildHeader(msgType: .clientAudioOnly, flags: flags)
        header[1] = (Proto.MsgType.clientAudioOnly.rawValue << 4) | flags.rawValue

        let compressed = Gzip.compress(data)!

        var packet = Data()
        packet.append(header)
        appendBE(&packet, actualSeq)
        appendBE(&packet, UInt32(compressed.count))
        packet.append(compressed)
        return packet
    }

    // MARK: - Parse Response

    private func parseResponse(_ data: Data) -> ASRResponse {
        var resp = ASRResponse()
        guard data.count >= 4 else { return resp }

        let headerSize = Int(data[0] & 0x0F) * 4
        let msgType = data[1] >> 4
        let flags = data[1] & 0x0F
        let compression = data[2] & 0x0F

        guard data.count > headerSize else { return resp }
        var payload = data[headerSize...]

        // Parse flags
        if flags & 0x01 != 0 { // has sequence
            guard payload.count >= 4 else { return resp }
            resp.payloadSequence = readBE(payload)
            payload = payload.dropFirst(4)
        }
        if flags & 0x02 != 0 { // is last
            resp.isLast = true
        }
        if flags & 0x04 != 0 { // has event
            payload = payload.dropFirst(4)
        }

        // Parse message type
        if msgType == Proto.MsgType.serverFullResponse.rawValue {
            guard payload.count >= 4 else { return resp }
            let _ : UInt32 = readBE(payload) // payload size
            payload = payload.dropFirst(4)
        } else if msgType == Proto.MsgType.serverError.rawValue {
            guard payload.count >= 8 else { return resp }
            resp.code = readBE(payload)
            payload = payload.dropFirst(4)
            let _ : UInt32 = readBE(payload) // payload size
            payload = payload.dropFirst(4)
        }

        guard !payload.isEmpty else { return resp }

        // Decompress
        var jsonData = Data(payload)
        if compression == Proto.Compress.gzip.rawValue {
            guard let decompressed = Gzip.decompress(jsonData) else {
                logger.error("Failed to decompress response")
                return resp
            }
            jsonData = decompressed
        }

        // Parse JSON
        if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            resp.payloadMsg = json
        }

        return resp
    }

    // MARK: - Helpers

    private func appendBE(_ data: inout Data, _ value: Int32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private func appendBE(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private func readBE<T: FixedWidthInteger>(_ data: Data.SubSequence) -> T {
        let size = MemoryLayout<T>.size
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { ptr in
            data.prefix(size).copyBytes(to: ptr.bindMemory(to: UInt8.self))
        }
        return T(bigEndian: value)
    }
}

// MARK: - Streaming Session (REQ-009 子模块 A)

/// 豆包流式适配器。复用 DoubaoASRClient 的 WebSocket 原语(同文件 fileprivate)。
/// 并发模型:start 起一个后台 receive Task 持续抛 partial;feed 由**外部单 pump**
/// 串行调用(VoiceInputManager 保证),故 send 顺序天然不乱。@unchecked Sendable
/// 因持有 NWWebSocket(已 @unchecked)。
final class DoubaoStreamingSession: StreamingASRSession, @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    /// 服务端异常截断(45000081 收包超时等):非空但残缺 → 调用方丢弃回落整段。
    private(set) var endedAbnormally = false
    private let client: DoubaoASRClient            // 复用 build*/connect/receiveOne
    private var ws: NWWebSocket?
    private var seq: Int32 = 1
    private var receiveTask: Task<String, Error>?  // 后台收 partial,finish 时 await 出定稿
    /// 双向流式**优化版**端点(bigmodel_async)。实测:2.0(seedasr)资源在 plain `bigmodel`
    /// 返回 400「resourceId not allowed」,只有 `bigmodel_async` 返 101。文档亦推荐优化版。
    /// 离线 recognize() 仍走 client.baseURL(bigmodel_nostream)。
    private let streamURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

    init(client: DoubaoASRClient) { self.client = client }

    func start(context: ASRContext) async throws {
        guard !client.appKey.isEmpty, !client.accessKey.isEmpty else {
            throw ASRError.missingCredentials
        }
        // 1. connect 真流式端点(复用 client headers 构造)
        let ws = try await client.connect(urlString: streamURL)
        self.ws = ws
        // 2. 发 config:流式 raw PCM(无 RIFF 头)→ format "pcm";seq 自增
        try await ws.send(client.buildFullClientRequest(seq: seq, format: "pcm"))
        seq += 1
        // 3. config 响应,code != 0 抛错
        let configResp = try await client.receiveOne(ws)
        ClaudeCodeSessionManager.log("[ASR stream config] code=\(configResp.code) payload=\(configResp.payloadMsg?.description.prefix(300) ?? "<nil>")")
        if configResp.code != 0 {
            ws.close()
            self.ws = nil
            throw ASRError.serverError(configResp.code, configResp.payloadMsg)
        }
        // 4. 后台 receive 循环:每个 interim → onPartial(MainActor hop);
        //    resp.isLast/code != 0 → break;返回累计定稿。
        receiveTask = Task { [weak self] in
            guard let self else { return "" }
            var finalText = ""
            do {
                while true {
                    let resp = try await self.client.receiveOne(ws)
                    if let text = resp.text, !text.isEmpty {
                        finalText = text
                        // onPartial 必须 hop 到 MainActor(编辑器是 @MainActor)。
                        DispatchQueue.main.async { self.onPartial?(text) }
                    }
                    if resp.isLast || resp.code != 0 {
                        // 流式 partial 是**累积式**的,已累积的 finalText 就是完整定稿。
                        // 收尾空 isLast 包常引发 code≠0(如 45000000),但此时 finalText 已是完整结果,
                        // 不能因终响应报错就丢弃 → 仅当尚无任何文本时才视为真失败抛错。
                        if resp.code != 0 {
                            ClaudeCodeSessionManager.log("[stream recv] 终响应 code=\(resp.code),已累积 finalTextLen=\(finalText.count),用它收尾 payload=\(resp.payloadMsg?.description.prefix(300) ?? "<nil>")")
                            if finalText.isEmpty {
                                throw ASRError.serverError(resp.code, resp.payloadMsg)
                            }
                            // 非 45000000(正常收尾)的 code = 服务端异常截断(45000081 收包超时等):
                            // finalText 是残缺前几字,标记让调用方丢弃并回落整段识别。
                            if resp.code != 45000000 { self.endedAbnormally = true }
                        }
                        break
                    }
                }
            } catch {
                ClaudeCodeSessionManager.log("[stream recv] 循环异常: \(error.localizedDescription) finalTextLen=\(finalText.count)")
                throw error
            }
            ClaudeCodeSessionManager.log("[stream recv] 循环结束 finalTextLen=\(finalText.count)")
            return finalText
        }
    }

    func feed(_ pcm: Data) async throws {
        guard let ws, !pcm.isEmpty else { return }
        try await ws.send(client.buildAudioRequest(seq: seq, data: pcm, isLast: false))
        seq += 1
    }

    func finish() async throws -> String {
        guard let ws else { ClaudeCodeSessionManager.log("[stream finish] ws=nil 返空"); return "" }
        // 发空 isLast 包收尾;await 终响应出定稿。
        try await ws.send(client.buildAudioRequest(seq: seq, data: Data(), isLast: true))
        let final: String
        do { final = try await receiveTask?.value ?? "" }
        catch { ClaudeCodeSessionManager.log("[stream finish] receiveTask 抛错: \(error.localizedDescription)"); final = "" }
        ClaudeCodeSessionManager.log("[stream finish] 定稿 len=\(final.count) text='\(final.prefix(40))'")
        close()
        return final
    }

    /// 彻底收尾:取消 receiveTask(否则它持有 ws、连接不释放)+ 关 ws。所有退出路径(finish/
    /// discard/deinit)都走它,避免会话泄漏占满并发限额(实测会越来越慢直至停止识别)。
    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        ws?.close()
        ws = nil
    }

    deinit { receiveTask?.cancel(); ws?.close() }   // 兜底:会话被释放时确保连接关闭
}

// MARK: - Errors

enum ASRError: LocalizedError {
    case missingCredentials
    case invalidAudio
    case invalidURL
    case unexpectedMessage
    case serverError(Int32, [String: Any]?)
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingCredentials: AppL10n.tr("请先配置豆包 ASR 的 App Key 和 Access Key")
        case .invalidAudio: AppL10n.tr("音频数据无效")
        case .invalidURL: AppL10n.tr("WebSocket URL 无效")
        case .unexpectedMessage: AppL10n.tr("收到非预期的消息类型")
        case .serverError(let code, _): AppL10n.format("ASR 服务错误 (code: %@)", String(code))
        case .timeout: AppL10n.tr("语音识别超时 (15s)")
        }
    }
}

// MARK: - Gzip (using Apple Compression framework + manual CRC32)

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        // Raw DEFLATE via Compression framework
        let bufferSize = max(data.count + 512, 1024)
        var destBuffer = [UInt8](repeating: 0, count: bufferSize)
        let compressedSize = data.withUnsafeBytes { srcPtr -> Int in
            compression_encode_buffer(
                &destBuffer, bufferSize,
                srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard compressedSize > 0 else { return nil }

        // Wrap in gzip container
        var result = Data(capacity: 10 + compressedSize + 8)
        // Header: magic(2) + method(1) + flags(1) + mtime(4) + xfl(1) + os(1)
        result.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x13])
        // Compressed data
        result.append(contentsOf: destBuffer[..<compressedSize])
        // Footer: CRC32 + original size (little-endian)
        var crc = crc32Checksum(data).littleEndian
        result.append(Data(bytes: &crc, count: 4))
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        result.append(Data(bytes: &size, count: 4))

        return result
    }

    static func decompress(_ data: Data) -> Data? {
        guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B else { return nil }

        // Parse gzip header to find deflate data start
        var offset = 10
        let flags = data[3]
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= data.count else { return nil }
            let len = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + len
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC

        let deflateData = data[offset..<(data.count - 8)]
        guard !deflateData.isEmpty else { return nil }

        // Decompress raw DEFLATE
        let outputSize = deflateData.count * 20 // generous estimate for text
        var destBuffer = [UInt8](repeating: 0, count: outputSize)
        let decompressedSize = deflateData.withUnsafeBytes { srcPtr -> Int in
            compression_decode_buffer(
                &destBuffer, outputSize,
                srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), deflateData.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard decompressedSize > 0 else { return nil }

        return Data(bytes: destBuffer, count: decompressedSize)
    }

    // MARK: - CRC32

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
            }
            return crc
        }
    }()

    private static func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }
}

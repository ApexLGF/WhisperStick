import Foundation

/// 引擎无关流式 ASR 会话。生命周期:start → feed* → finish。
/// onPartial 抛实时草稿给编辑器;finish 返回定稿(带热词/标点)。
/// Phase 2 本地 2-pass 实现同协议即可接入(T-018)。
protocol StreamingASRSession: AnyObject {
    /// 实时草稿回调。**实现方必须 hop 到 MainActor 再调**(编辑器是 @MainActor)。
    var onPartial: ((String) -> Void)? { get set }
    /// connect + 发 config + 起后台 receive 循环。
    func start(context: ASRContext) async throws
    /// 喂一段 raw 16-bit LE PCM(无 WAV 头)。实现方串行发送、自增 seq。
    func feed(_ pcm: Data) async throws
    /// 发 isLast 收尾,await 终响应,返回定稿。
    func finish() async throws -> String
    /// 彻底收尾(取消后台收包 task + 关连接)。丢弃/中止路径调,避免会话泄漏。
    func close()
    /// 会话是否被服务端**异常截断**(如 45000081 收包超时:服务端没等到下一个音频包就
    /// 结束会话)。此时 finish() 拿到的是残缺前几字,调用方应丢弃并回落整段识别。
    var endedAbnormally: Bool { get }
}

// MARK: - 本地 FunTpass 2-pass 流式(T-018)

/// FunTpass 2-pass 引擎封装(actor:推理在后台执行器跑,不阻塞主线程)。
/// 生命周期:prepare(一次,加载 offline+online+vad+punc)→ reset(每句)→ feed*→ free。
/// 需要 online punc(2pass 强制,否则 FunTpassInferBuffer 恒 null)。
actor FunASRStreamingEngine {
    private var ctx: FunasrTpassCtx?
    private var loadedHotwordHash = 0

    var isLoaded: Bool { ctx != nil }

    /// 加载 2-pass 模型集(idempotent)。任一必需模型缺失 → 返 false(调用方回落整段)。
    func prepare(offlineDir: String, onlineDir: String, vadDir: String, puncDir: String) -> Bool {
        if ctx != nil { return true }
        let fm = FileManager.default
        for f in ["\(onlineDir)/model_quant.onnx", "\(vadDir)/model_quant.onnx",
                  "\(puncDir)/model_quant.onnx", "\(offlineDir)/model_quant.onnx"] {
            guard fm.fileExists(atPath: f) else { return false }
        }
        guard let c = funasr_tpass_init(offlineDir, onlineDir, vadDir, puncDir, 1) else { return false }
        ctx = c
        _ = funasr_tpass_set_hotwords(c, "")
        return true
    }

    func reloadHotwordsIfChanged(_ hotwords: [ASRHotword]) {
        guard let ctx else { return }
        let joined = hotwords.map { "\($0.word) \($0.weight)" }.joined(separator: "\n")
        let h = joined.hashValue
        if h != loadedHotwordHash {
            let started = Date()
            ClaudeCodeSessionManager.log("[ASR local stream] hotwords apply begin count=\(hotwords.count) bytes=\(joined.utf8.count)")
            let status = funasr_tpass_set_hotwords(ctx, joined)
            loadedHotwordHash = h
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            ClaudeCodeSessionManager.log("[ASR local stream] hotwords apply end count=\(hotwords.count) status=\(status) elapsedMs=\(elapsedMs)")
        }
    }

    func reset() { if let ctx { funasr_tpass_reset(ctx) } }

    /// 喂 16k mono int16;isFinal=false 返在线**增量**片段,isFinal=true 返 offline 精确定稿。
    func feed(_ samples: [Int16], isFinal: Bool) -> String {
        guard let ctx else { return "" }
        let p = samples.withUnsafeBufferPointer {
            funasr_tpass_feed(ctx, $0.baseAddress, Int32(samples.count), isFinal ? 1 : 0)
        }
        return p.map { String(cString: $0) } ?? ""
    }

    /// 累积的 offline 段级定稿(2pass 精确结果,近离线质量)——整段喂完后取,作为最终注入文本。
    func definitive() -> String {
        guard let ctx, let p = funasr_tpass_definitive(ctx) else { return "" }
        return String(cString: p)
    }
}

/// 本地 2-pass 流式会话:实现引擎无关 `StreamingASRSession` → 胶囊/编辑器直接消费。
/// 在线增量片段累积成草稿(onPartial);finish 出 offline 带标点定稿。
final class LocalTpassStreamingSession: StreamingASRSession, @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    var endedAbnormally: Bool { false }   // 本地无服务端截断

    private let engine: FunASRStreamingEngine
    private let dirs: (offline: String, online: String, vad: String, punc: String)
    private var accumulated = ""
    private var started = false

    init(engine: FunASRStreamingEngine, dirs: (offline: String, online: String, vad: String, punc: String)) {
        self.engine = engine
        self.dirs = dirs
    }

    func start(context: ASRContext) async throws {
        accumulated = ""
        let ok = await engine.prepare(offlineDir: dirs.offline, onlineDir: dirs.online,
                                      vadDir: dirs.vad, puncDir: dirs.punc)
        guard ok else { throw FunASRSeacoError.modelNotReady }   // 回落整段 runASR
        await engine.reloadHotwordsIfChanged(context.hotwords)
        await engine.reset()
        started = true
    }

    func feed(_ pcm: Data) async throws {
        guard started, !pcm.isEmpty else { return }
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let piece = await engine.feed(samples, isFinal: false)   // 在线增量片段
        if !piece.isEmpty {
            ClaudeCodeSessionManager.log("[ASR local stream] feed samples=\(samples.count) pieceLen=\(piece.count) piece='\(piece.prefix(40))'")
        }
        if !piece.isEmpty {
            accumulated += piece
            onPartial?(accumulated)   // 调用方闭包 hop 到 MainActor
        }
    }

    func finish() async throws -> String {
        guard started else { return "" }
        started = false
        // 喂一小段静音收尾(触发最后一段 offline 定稿);随后取**累积的段级定稿**(2pass 精确,近离线质量)。
        _ = await engine.feed([Int16](repeating: 0, count: 160), isFinal: true)
        let def = await engine.definitive()
        ClaudeCodeSessionManager.log("[ASR local stream] finish defLen=\(def.count) accLen=\(accumulated.count) def='\(def.prefix(80))' acc='\(accumulated.prefix(80))'")
        await engine.reset()
        return def.isEmpty ? accumulated : def   // 定稿为空(极短音频)才退回在线累积
    }

    func close() { Task { await engine.reset() } }
}

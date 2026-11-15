import Foundation
import Combine
import os

/// C++ 初始化结果跨回 MainActor 后才被正式接管；初始化期间没有其它线程访问句柄。
private final class FunASRContextBox: @unchecked Sendable {
    let value: FunasrCtx?
    init(_ value: FunasrCtx?) { self.value = value }
}

enum FunASRSeacoError: Error, LocalizedError {
    case modelNotReady
    case engineInitFailed(String)
    case recognitionFailed(String)
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return AppL10n.tr("本地 ASR 模型未就绪")
        case .engineInitFailed(let m): return AppL10n.format("引擎初始化失败: %@", m)
        case .recognitionFailed(let m): return AppL10n.format("本地识别失败: %@", m)
        case .invalidAudio: return AppL10n.tr("音频格式不支持(需 16k mono PCM WAV)")
        }
    }
}

/// 进程内常驻 FunASR SeACo-Paraformer offline recognizer 的 Swift 封装。
/// TASK-VibeEverything-014(Phase B):通过 Phase A 就位的 funasr_c_shim 4 函数
/// (init/set_hotwords/infer_pcm/free)封装 SeACo C++ runtime,拿原生模型级热词。
/// 热词变化只调 set_hotwords(重算 model_eb,毫秒级,不重建声学主干)。
@MainActor
final class FunASRSeacoEngine: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle

    /// C shim 句柄(`FunasrCtx` = `void*`)。deinit 兜底释放,主动销毁走 `free()`。
    private var ctx: FunasrCtx?
    /// 模型状态通知与引擎切换可能同时调用 prepare；共享同一次昂贵的 C++ 初始化。
    private var initializationTask: Task<FunASRContextBox, Never>?
    private var loadedHotwordHash: Int = 0
    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "FunASR")
    private let modelManager: ASRModelManager

    init(modelManager: ASRModelManager) {
        self.modelManager = modelManager
    }

    /// 已 ready 直接返回;否则加载 SeACo 双图 + 应用热词。
    func prepare(hotwords: [ASRHotword]) async throws {
        if loadState == .ready, ctx != nil { return }
        guard let modelDir = modelManager.currentVersionDir() else {
            loadState = .failed(AppL10n.tr("模型清单未拉取"))
            throw FunASRSeacoError.modelNotReady
        }
        // 防御:FunOfflineInit 缺 config.yaml 等会在 C++ 层直接 exit 进程(非优雅返回)→ 先校验
        let required = ["config.yaml", "am.mvn", "model_quant.onnx", "model_eb.onnx", "tokens.json"]
        for f in required where !FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(f).path) {
            loadState = .failed(AppL10n.format("模型文件缺失: %@", f))
            throw FunASRSeacoError.modelNotReady
        }
        let modelPath = modelDir.path
        let initialization: Task<FunASRContextBox, Never>
        if let active = initializationTask {
            initialization = active
        } else {
            loadState = .loading
            logger.info("Loading SeACo engine at \(modelPath, privacy: .public)")
            // 可选 ct-punc 标点模型目录(modelDir/punc);齐全才启用,缺则降级为无标点(不阻断识别)。
            let puncDir = modelDir.appendingPathComponent("punc", isDirectory: true)
            let hasPunc = ["model_quant.onnx", "config.yaml", "tokens.json"].allSatisfy {
                FileManager.default.fileExists(atPath: puncDir.appendingPathComponent($0).path)
            }
            let puncPath = hasPunc ? puncDir.path : ""
            logger.info("Punc model \(hasPunc ? "enabled" : "absent", privacy: .public)")
            // use_quant=1 → 加载 model_quant.onnx + model_eb.onnx。C++ 初始化耗时较长，移出 MainActor。
            let created = Task.detached(priority: .userInitiated) {
                FunASRContextBox(funasr_seaco_init(modelPath, puncPath, 1))
            }
            initializationTask = created
            initialization = created
        }
        let prepared = await initialization.value
        initializationTask = nil
        guard let handle = prepared.value else {
            loadState = .failed(AppL10n.tr("引擎初始化失败"))
            throw FunASRSeacoError.engineInitFailed(modelPath)
        }
        // 多个等待者会拿到同一句柄；第一个接管，后续只更新热词，不重复创建/释放。
        if ctx == nil { ctx = handle }
        applyHotwords(hotwords)
        loadState = .ready
        logger.info("SeACo engine ready (hotwords=\(hotwords.count, privacy: .public))")
    }

    /// 热路径:16k mono PCM WAV → 文本(若 punc 模型就位则带标点,FunASR runtime 内部完成)。
    func recognize(wavData: Data) async throws -> String {
        guard loadState == .ready, let ctx else {
            throw FunASRSeacoError.modelNotReady
        }
        guard let pcm = Self.pcm16WavToInt16(wavData) else {
            throw FunASRSeacoError.invalidAudio
        }
        // C shim 返回内部缓冲,有效到下次调用 → 立即 String(cString:) 拷贝。
        let text: String = pcm.withUnsafeBufferPointer { buf in
            guard let cstr = funasr_seaco_infer_pcm(ctx, buf.baseAddress, Int32(pcm.count)) else {
                return ""
            }
            return String(cString: cstr)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 热词变化时只重算 model_eb(set_hotwords,毫秒级),不重建声学主干。
    func reloadHotwordsIfChanged(_ hotwords: [ASRHotword]) async {
        let h = hotwordHash(hotwords)
        guard h != loadedHotwordHash, loadState == .ready, ctx != nil else { return }
        applyHotwords(hotwords)
    }

    /// 主动销毁(app 退出/引擎替换时调)。deinit 兜底。
    func free() {
        if let ctx {
            funasr_seaco_free(ctx)
            self.ctx = nil
        }
    }

    // MARK: - Helpers

    /// 把 `[ASRHotword]` 转 funasr hotword 格式 `"词 权重\n..."`,空 → ""。
    private func applyHotwords(_ hotwords: [ASRHotword]) {
        guard let ctx else { return }
        let clean = hotwords.filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let payload = clean.map { "\($0.word) \($0.weight)" }.joined(separator: "\n")
        _ = funasr_seaco_set_hotwords(ctx, payload)
        loadedHotwordHash = hotwordHash(hotwords)
        logger.info("SeACo hotwords applied (count=\(clean.count, privacy: .public))")
    }

    private func hotwordHash(_ hotwords: [ASRHotword]) -> Int {
        hotwords
            .map { "\($0.word.lowercased()):\($0.weight)" }
            .sorted()
            .joined(separator: "\n")
            .hashValue
    }

    /// 解析 16-bit PCM mono WAV(扫 data chunk)→ Int16 PCM。按字节读避免对齐问题。
    /// 与 SherpaParaformerEngine.pcm16WavToFloats 同 chunk 扫描,但 append Int16(bitPattern:) 而非 /32768.0。
    nonisolated static func pcm16WavToInt16(_ input: Data) -> [Int16]? {
        let data = Data(input)
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<offset + 4)
            let size = data.subdata(in: offset + 4..<offset + 8).withUnsafeBytes {
                Int($0.load(as: UInt32.self).littleEndian) }
            let body = offset + 8
            if id == Data("data".utf8) {
                let end = min(body + size, data.count)
                guard end > body else { return [] }
                var out = [Int16](); out.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    out.append(Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i+1]) << 8)))
                    i += 2
                }
                return out
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    deinit {
        // @MainActor isolated 句柄不能直接在 deinit 调;nonisolated 捕获后释放兜底。
        if let ctx { funasr_seaco_free(ctx) }
    }
}

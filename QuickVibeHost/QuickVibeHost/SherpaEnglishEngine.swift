import Foundation

enum SherpaEnglishError: LocalizedError {
    case modelNotReady
    case initializationFailed
    case sessionFailed
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .modelNotReady: AppL10n.tr("英文模型未下载")
        case .initializationFailed: AppL10n.tr("英文识别引擎初始化失败")
        case .sessionFailed: AppL10n.tr("英文流式识别会话创建失败")
        case .invalidAudio: AppL10n.tr("音频格式不支持")
        }
    }
}

/// Serializes all native Sherpa access. The C API is fast, but a recognizer
/// and its streams must not be mutated from multiple executors concurrently.
actor SherpaEnglishEngine {
    private var context: QVHSherpaEnglishContext?
    private var loadedDirectory: String?
    private var loadedHotwordSignature = ""
    private var sessions: [UUID: QVHSherpaEnglishSession] = [:]

    var isLoaded: Bool { context != nil }

    func prepare(modelDirectory: URL, hotwords: [ASRHotword]) throws {
        let cleanHotwords = Self.normalizedHotwords(hotwords)
        let signature = cleanHotwords.joined(separator: "\n")
        if context != nil,
           loadedDirectory == modelDirectory.path,
           loadedHotwordSignature == signature {
            return
        }
        guard sessions.isEmpty else {
            throw SherpaEnglishError.initializationFailed
        }
        unload()

        let paths = ModelPaths(root: modelDirectory)
        guard paths.allExist else { throw SherpaEnglishError.modelNotReady }
        let created = qvh_sherpa_english_create(
            paths.encoder.path,
            paths.decoder.path,
            paths.joiner.path,
            paths.tokens.path,
            paths.asrBPEVocabulary.path,
            paths.punctuationModel.path,
            paths.punctuationVocabulary.path,
            signature
        )
        guard let created else { throw SherpaEnglishError.initializationFailed }
        context = created
        loadedDirectory = modelDirectory.path
        loadedHotwordSignature = signature
        ClaudeCodeSessionManager.log(
            "[ASR English] engine ready hotwords=\(cleanHotwords.count) dir=\(modelDirectory.lastPathComponent)"
        )
    }

    func createSession() throws -> UUID {
        guard let context else { throw SherpaEnglishError.modelNotReady }
        guard let native = qvh_sherpa_english_session_create(context) else {
            throw SherpaEnglishError.sessionFailed
        }
        let id = UUID()
        sessions[id] = native
        return id
    }

    func feed(sessionID: UUID, samples: [Int16]) throws -> String {
        guard let native = sessions[sessionID] else { throw SherpaEnglishError.sessionFailed }
        guard !samples.isEmpty else { return "" }
        let result = samples.withUnsafeBufferPointer { buffer in
            qvh_sherpa_english_session_feed(native, buffer.baseAddress, Int32(buffer.count))
        }
        return result.map(String.init(cString:)) ?? ""
    }

    func finish(sessionID: UUID) throws -> String {
        guard let native = sessions.removeValue(forKey: sessionID) else {
            throw SherpaEnglishError.sessionFailed
        }
        defer { qvh_sherpa_english_session_destroy(native) }
        let result = qvh_sherpa_english_session_finish(native)
        return result.map(String.init(cString:))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func close(sessionID: UUID) {
        guard let native = sessions.removeValue(forKey: sessionID) else { return }
        qvh_sherpa_english_session_destroy(native)
    }

    func recognize(wavData: Data) throws -> String {
        guard let samples = Self.pcm16WavSamples(wavData) else {
            throw SherpaEnglishError.invalidAudio
        }
        let sessionID = try createSession()
        do {
            var offset = 0
            while offset < samples.count {
                let end = min(offset + 3200, samples.count)
                _ = try feed(sessionID: sessionID, samples: Array(samples[offset..<end]))
                offset = end
            }
            return try finish(sessionID: sessionID)
        } catch {
            close(sessionID: sessionID)
            throw error
        }
    }

    func unload() {
        for native in sessions.values {
            qvh_sherpa_english_session_destroy(native)
        }
        sessions.removeAll()
        if let context { qvh_sherpa_english_destroy(context) }
        context = nil
        loadedDirectory = nil
        loadedHotwordSignature = ""
    }

    private struct ModelPaths {
        let encoder: URL
        let decoder: URL
        let joiner: URL
        let tokens: URL
        let asrBPEVocabulary: URL
        let punctuationModel: URL
        let punctuationVocabulary: URL

        init(root: URL) {
            encoder = root.appendingPathComponent("asr/encoder.int8.onnx")
            decoder = root.appendingPathComponent("asr/decoder.onnx")
            joiner = root.appendingPathComponent("asr/joiner.int8.onnx")
            tokens = root.appendingPathComponent("asr/tokens.txt")
            asrBPEVocabulary = root.appendingPathComponent("asr/bpe.vocab")
            punctuationModel = root.appendingPathComponent("punctuation/model.int8.onnx")
            punctuationVocabulary = root.appendingPathComponent("punctuation/bpe.vocab")
        }

        var allExist: Bool {
            [encoder, decoder, joiner, tokens, asrBPEVocabulary,
             punctuationModel, punctuationVocabulary]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    nonisolated private static func normalizedHotwords(_ hotwords: [ASRHotword]) -> [String] {
        var seen = Set<String>()
        return hotwords.compactMap { item in
            let normalized = item.word
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !normalized.isEmpty, normalized.count <= 80,
                  normalized.unicodeScalars.allSatisfy({ 0x20...0x7E ~= $0.value }),
                  seen.insert(normalized).inserted else { return nil }
            return normalized
        }.prefix(40).map { $0 }
    }

    nonisolated private static func pcm16WavSamples(_ input: Data) -> [Int16]? {
        let data = Data(input)
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = data.subdata(in: offset..<(offset + 4))
            let size = Int(data[offset + 4]) |
                (Int(data[offset + 5]) << 8) |
                (Int(data[offset + 6]) << 16) |
                (Int(data[offset + 7]) << 24)
            let body = offset + 8
            guard size >= 0, body <= data.count else { return nil }
            if identifier == Data("data".utf8) {
                let end = min(body + size, data.count)
                var values: [Int16] = []
                values.reserveCapacity((end - body) / 2)
                var index = body
                while index + 1 < end {
                    let bits = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
                    values.append(Int16(bitPattern: bits))
                    index += 2
                }
                return values
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}

final class SherpaEnglishStreamingSession: StreamingASRSession, @unchecked Sendable {
    var onPartial: ((String) -> Void)?
    var endedAbnormally: Bool { false }

    private let engine: SherpaEnglishEngine
    private let modelDirectory: URL
    private var sessionID: UUID?

    init(engine: SherpaEnglishEngine, modelDirectory: URL) {
        self.engine = engine
        self.modelDirectory = modelDirectory
    }

    func start(context: ASRContext) async throws {
        try await engine.prepare(modelDirectory: modelDirectory, hotwords: context.hotwords)
        sessionID = try await engine.createSession()
    }

    func feed(_ pcm: Data) async throws {
        guard let sessionID, !pcm.isEmpty else { return }
        let samples = pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        let partial = try await engine.feed(sessionID: sessionID, samples: samples)
        if !partial.isEmpty { onPartial?(partial) }
    }

    func finish() async throws -> String {
        guard let sessionID else { return "" }
        self.sessionID = nil
        return try await engine.finish(sessionID: sessionID)
    }

    func close() {
        guard let sessionID else { return }
        self.sessionID = nil
        Task { await engine.close(sessionID: sessionID) }
    }
}

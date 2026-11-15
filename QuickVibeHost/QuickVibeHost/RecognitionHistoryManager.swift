import Foundation
import SwiftUI

enum RecognitionSource: String, Codable {
    case microphone = "mic"
    case bleDevice = "ble"        // Button A (Claude Code input)

    var displayName: String {
        switch self {
        case .microphone: AppL10n.tr("麦克风")
        case .bleDevice: AppL10n.tr("设备")
        }
    }

    var iconName: String {
        switch self {
        case .microphone: "mic.fill"
        case .bleDevice: "antenna.radiowaves.left.and.right"
        }
    }
}

/// Processing phase for a recognition record
enum ProcessingPhase: String, Codable {
    case receiving = "receiving"       // Audio arriving from BLE
    case asrProcessing = "asr"         // ASR in progress
    case llmProcessing = "llm"         // LLM call in progress (Button B only)
    case completed = "done"            // All processing finished
    case failed = "failed"             // Processing failed at some stage

    var displayName: String {
        switch self {
        case .receiving: AppL10n.tr("接收音频中...")
        case .asrProcessing: AppL10n.tr("语音识别中...")
        case .llmProcessing: AppL10n.tr("AI 处理中...")
        case .completed: AppL10n.tr("完成")
        case .failed: AppL10n.tr("失败")
        }
    }
}

struct RecognitionRecord: Codable, Identifiable {
    let id: UUID
    var text: String              // Recognized text (empty until ASR completes)
    let timestamp: Date
    var source: RecognitionSource
    var isSuccess: Bool = true
    var errorMessage: String?
    var hasWavData: Bool = false
    var phase: ProcessingPhase = .completed  // Default .completed for backward compat
    var asrMethod: String = ""               // 识别方法标识(豆包流式/豆包云端/本地),历史展示用
    var sourceName: String?                  // 记录产生时的具体设备名；旧记录为空时回退 source.displayName
    var rawText: String?
    var itnText: String?
    var programmingText: String?
    var finalText: String?
    var asrEngineName: String?
    var postprocessStrategy: String?
    var hotwordCount: Int?
    var usedProjectHotwords: Bool?
    var usedLearnedHotwords: Bool?
    var audioId: String?
    var llmText: String?
    var llmMs: Int?
    var llmModel: String?
    var llmError: String?

    /// Create a pending record when audio starts arriving
    init(source: RecognitionSource, hasWav: Bool, sourceName: String? = nil) {
        self.id = UUID()
        self.text = ""
        self.timestamp = Date()
        self.source = source
        self.sourceName = sourceName
        self.isSuccess = true
        self.errorMessage = nil
        self.hasWavData = hasWav
        self.phase = .receiving
    }

    init(text: String, source: RecognitionSource = .microphone, sourceName: String? = nil) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.source = source
        self.sourceName = sourceName
        self.isSuccess = true
        self.errorMessage = nil
        self.hasWavData = false
        self.phase = .completed
    }

    init(error: String, source: RecognitionSource, hasWav: Bool, sourceName: String? = nil) {
        self.id = UUID()
        self.text = ""
        self.timestamp = Date()
        self.source = source
        self.sourceName = sourceName
        self.isSuccess = false
        self.errorMessage = error
        self.hasWavData = hasWav
        self.phase = .failed
    }

    init(id: UUID, text: String, timestamp: Date, source: RecognitionSource, sourceName: String? = nil, isSuccess: Bool, hasWavData: Bool) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.source = source
        self.sourceName = sourceName
        self.isSuccess = isSuccess
        self.errorMessage = nil
        self.hasWavData = hasWavData
        self.phase = isSuccess ? .completed : .failed
    }
}

@MainActor
final class RecognitionHistoryManager: ObservableObject {
    @Published var records: [RecognitionRecord] = []
    @AppStorage("maxHistoryRecords") var maxRecords: Int = 200

    private let fileURL: URL
    private let audioDir: URL

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("QuickVibeHost")
        self.init(fileURL: dir.appendingPathComponent("history.json"), audioDir: dir.appendingPathComponent("audio"))
    }

    init(fileURL: URL, audioDir: URL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.fileURL = fileURL
        self.audioDir = audioDir
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Add Records

    /// Create a pending record immediately when audio starts arriving
    func addPendingRecord(source: RecognitionSource, sourceName: String? = nil) -> RecognitionRecord {
        let record = RecognitionRecord(source: source, hasWav: false, sourceName: sourceName)
        records.insert(record, at: 0)
        trimAndSave()
        return record
    }

    /// Update a pending record's phase to ASR processing
    func updatePhase(_ recordId: UUID, phase: ProcessingPhase) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].phase = phase
        save()
    }

    /// Update a record with ASR result text and advance phase
    func updateWithASRResult(_ recordId: UUID, text: String, nextPhase: ProcessingPhase, method: String = "") {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].text = text
        records[idx].finalText = text
        records[idx].phase = nextPhase
        records[idx].isSuccess = true
        if !method.isEmpty { records[idx].asrMethod = method }
        save()
    }

    /// Mark a record as failed
    func markFailed(_ recordId: UUID, error: String, wavData: Data? = nil) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].isSuccess = false
        records[idx].errorMessage = error
        records[idx].phase = .failed
        if let wavData {
            saveWavData(wavData, for: recordId)
            records[idx].hasWavData = true
        }
        save()
    }

    /// Set hasWavData flag for a record
    func setHasWav(_ recordId: UUID, hasWav: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].hasWavData = hasWav
        save()
    }

    /// Mark a record as completed
    func markCompleted(_ recordId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].phase = .completed
        records[idx].isSuccess = true
        save()
    }

    func removeRecord(_ recordId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records.remove(at: idx)
        save()
    }

    @discardableResult
    func addRecord(_ text: String, source: RecognitionSource = .microphone, method: String = "", sourceName: String? = nil) -> RecognitionRecord {
        var record = RecognitionRecord(text: text, source: source, sourceName: sourceName)
        record.asrMethod = method
        record.finalText = text
        records.insert(record, at: 0)
        trimAndSave()
        return record
    }

    func updateProcessingTrace(
        _ recordId: UUID,
        rawText: String,
        itnText: String,
        programmingText: String,
        finalText: String,
        engine: String,
        strategy: String,
        hotwordCount: Int,
        usedProjectHotwords: Bool,
        usedLearnedHotwords: Bool,
        audioId: String? = nil,
        llmText: String? = nil,
        llmMs: Int? = nil,
        llmModel: String? = nil,
        llmError: String? = nil
    ) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].rawText = rawText
        records[idx].itnText = itnText
        records[idx].programmingText = programmingText
        records[idx].finalText = finalText
        records[idx].asrEngineName = engine
        records[idx].postprocessStrategy = strategy
        records[idx].hotwordCount = hotwordCount
        records[idx].usedProjectHotwords = usedProjectHotwords
        records[idx].usedLearnedHotwords = usedLearnedHotwords
        records[idx].audioId = audioId
        records[idx].llmText = llmText
        records[idx].llmMs = llmMs
        records[idx].llmModel = llmModel
        records[idx].llmError = llmError
        save()
    }

    func addFailedRecord(error: String, source: RecognitionSource, wavData: Data?, sourceName: String? = nil) -> RecognitionRecord {
        let hasWav = wavData != nil
        let record = RecognitionRecord(error: error, source: source, hasWav: hasWav, sourceName: sourceName)
        if let wavData {
            saveWavData(wavData, for: record.id)
        }
        records.insert(record, at: 0)
        trimAndSave()
        return record
    }

    // MARK: - Retry

    /// Clear error state and set phase to ASR processing (for retry)
    func prepareForRetry(_ recordId: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].phase = .asrProcessing
        records[idx].isSuccess = true
        records[idx].errorMessage = nil
        save()
    }

    func updateRecordWithRetryResult(_ recordId: UUID, text: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].text = text
        records[idx].finalText = text
        records[idx].phase = .completed
        records[idx].isSuccess = true
        records[idx].errorMessage = nil
        save()
    }

    func updateRecordWithRetryError(_ recordId: UUID, error: String) {
        guard let idx = records.firstIndex(where: { $0.id == recordId }) else { return }
        records[idx].errorMessage = error
        records[idx].phase = .failed
        save()
    }

    // MARK: - WAV Data Management

    func wavDataURL(for recordId: UUID) -> URL {
        audioDir.appendingPathComponent("\(recordId.uuidString).wav")
    }

    func saveWavData(_ data: Data, for recordId: UUID) {
        let url = wavDataURL(for: recordId)
        try? data.write(to: url, options: .atomic)
    }

    func loadWavData(for recordId: UUID) -> Data? {
        let url = wavDataURL(for: recordId)
        return try? Data(contentsOf: url)
    }

    private func deleteWavData(for recordId: UUID) {
        let url = wavDataURL(for: recordId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Cleanup

    func clearAll() {
        for record in records where record.hasWavData {
            deleteWavData(for: record.id)
        }
        records.removeAll()
        save()
    }

    private func trimAndSave() {
        if records.count > maxRecords {
            let removed = Array(records.suffix(from: maxRecords))
            for record in removed where record.hasWavData {
                deleteWavData(for: record.id)
            }
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([RecognitionRecord].self, from: data) else { return }
        // 启动清理在途记录:.receiving/.asr/.llm 在应用重启后不可能仍在进行 → 标失败,
        // 避免"程序一启动历史里就有一条'接收音频中…'幽灵记录"(录音中崩溃/被杀残留)。
        var swept = false
        records = decoded.map { rec in
            switch rec.phase {
            case .receiving, .asrProcessing, .llmProcessing:
                var r = rec
                r.phase = .failed
                r.isSuccess = false
                if r.errorMessage == nil { r.errorMessage = AppL10n.tr("未完成(应用重启)") }
                swept = true
                return r
            case .completed, .failed:
                return rec
            }
        }
        if swept { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

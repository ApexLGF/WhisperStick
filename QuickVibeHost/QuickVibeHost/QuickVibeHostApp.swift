import SwiftUI
import Combine
import os
import AVFoundation
import CoreAudio
import CoreBluetooth
import UserNotifications
import ApplicationServices
import CryptoKit
import Sentry
import ServiceManagement
import Darwin

/// Which physical button triggered the current voice input
enum ActiveButton {
    case none
    case buttonA  // Claude Code voice input
}

enum VoiceInputState: Equatable {
    case idle
    case recording
    case processing
    case error(String)

    static func == (lhs: VoiceInputState, rhs: VoiceInputState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.processing, .processing): true
        case (.error(let a), .error(let b)): a == b
        default: false
        }
    }
}

enum ASREngine: String, CaseIterable {
    case local = "local"            // Paraformer 本地(默认)
    case localEnglish = "localEnglish" // Sherpa-ONNX Streaming Zipformer English
    case doubao = "doubao"          // 豆包云端(可选)

    var displayName: String {
        switch self {
        case .local: AppL10n.tr("本地 Paraformer")
        case .localEnglish: AppL10n.tr("本地英文 · Zipformer")
        case .doubao: AppL10n.tr("豆包云端")
        }
    }
}

enum AppBrand {
    static let displayName = AppL10n.tr("VE 语音指挥棒")
}

enum DoubaoConfigCheckStatus: String {
    case unchecked
    case success
    case failed
}

/// ASR context: hotwords + dialog history for Seed ASR
struct ASRHotword: Hashable {
    var word: String
    var weight: Int

    var cloudPayload: [String: String] { ["word": word] }
}

struct ASRContext {
    var hotwords: [ASRHotword] = []
    var dialogContext: [String] = []        // conversation history, newest first
}

typealias ProcessedRecognitionText = (
    learning: String,
    display: String,
    raw: String,
    itn: String,
    programming: String,
    hotwordCount: Int,
    usedProjectHotwords: Bool,
    usedLearnedHotwords: Bool,
    llmText: String?,
    llmMs: Int?,
    llmModel: String?,
    llmError: String?
)

// MARK: - UI Test Launch Flags (TASK-VibeEverything-006)
//
// 解析 ProcessInfo.arguments 一次性算出两个静态值，供:
//   - 4 处 TCC 入口 (audio / BLE / 通知 / Accessibility) 的 guard 短路
//   - ContentView 初始 tab override
//
// 设计选择: 不用 #if DEBUG 包裹 — Release 也保留, 但 LaunchServices 双击
// 启动不会注入 args, 实际触发概率为 0。
// 用法: `open Foo.app --args --ui-test-headless --ui-test-tab=settings`
//      或 `Foo.app/Contents/MacOS/QuickVibeHost --ui-test-headless`
enum UITestFlags {
    static let isHeadless: Bool = ProcessInfo.processInfo.arguments.contains("--ui-test-headless")

    /// argv 含 `--ui-test-tab=<name>` 则映射到 tag; name ∈ {status, device, history, settings}
    static let forcedInitialTabTag: Int? = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-tab=") }) else {
            return nil
        }
        let name = String(arg.dropFirst("--ui-test-tab=".count))
        switch name {
        case "status":   return 0
        case "device":   return 1
        case "history":  return 2
        case "settings": return 4   // tag 3 是 T-004 砍 HotDog Buddy 留下的洞
        default:         return nil
        }
    }()

    /// argv 含 `--ui-test-settings-category=<name>` 则强制 sidebar 初始选中
    /// name ∈ {general, shortcuts, voice, history, permissions, billing, about}
    static let forcedSettingsCategory: SettingsCategory? = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-settings-category=") }) else {
            return nil
        }
        let name = String(arg.dropFirst("--ui-test-settings-category=".count))
        return SettingsCategory(rawValue: name)
    }()

    /// argv 含 `--ui-test-editor=<text>` 则拉起可编辑浮窗(name 非数字),
    /// 叠加 `--ui-test-editor-error` 则改拉起错误态。供 QVHSnapshot 截图。
    static let editorPreview: (text: String, isError: Bool)? = {
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-editor=") }) else {
            return nil
        }
        let v = String(arg.dropFirst("--ui-test-editor=".count))
        let isError = ProcessInfo.processInfo.arguments.contains("--ui-test-editor-error")
        return (v, isError)
    }()

    /// argv 含 `--ui-test-overlay-phase=recording|processing` 则拉起对应录音/转录态浮窗,
    /// 供 QVHSnapshot 验证①「4 phase 外壳一致不跳」(补齐 editing/error 之外两态)。
    static let overlayPhase: String? = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-overlay-phase=") })
            .map { String($0.dropFirst("--ui-test-overlay-phase=".count)) }
    }()

    /// argv 含 `--ui-test-editor-draft=<text>` → 拉起录音态 + 注入草稿,供 QVHSnapshot 截草稿样式。
    static let editorDraft: String? = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-editor-draft=") })
            .map { String($0.dropFirst("--ui-test-editor-draft=".count)) }
    }()

    /// argv 含 `--ui-test-mock-codex` → 强开 mock Codex provider(状态页出第二张用量卡 + 会话混排),供 QVHSnapshot 截双 agent 形态。
    static let mockCodex: Bool = ProcessInfo.processInfo.arguments.contains("--ui-test-mock-codex")

    /// argv 含 `--ui-test-mock-bg-session` → 状态页注入一张带「后台任务 ×1」角标 +
    /// 一张直通按钮置灰(无 socket)的会话卡,供 QVHSnapshot 截 T-027 新 UI(零 TCC)。
    static let mockBgSession: Bool = ProcessInfo.processInfo.arguments.contains("--ui-test-mock-bg-session")

    /// argv 含 `--ui-test-mock-tiers` → 状态页注入活跃 3 + 非活跃 4 的夹具 provider,
    /// 供 T-034 分组结构截图(现有 mock provider 的 inactiveSessions 恒为空,截不出两组)。
    static let mockTiers: Bool = ProcessInfo.processInfo.arguments.contains("--ui-test-mock-tiers")

    /// argv 含 `--ui-test-route-text=<text>` → 启动后延时(snapshotDelay 同款)把文本经
    /// InputRouter.route 走完整直通/自由路由,供 ui-smoke 端到端验证 PTY 注入链(REQ-019)。
    static let routeText: String? = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-route-text=") })
            .map { String($0.dropFirst("--ui-test-route-text=".count)) }
    }()

    /// argv 含 `--ui-test-exclusive-sid=<sid>` → route 前 3s 由 selectionStore.select 强制直通选择
    /// (headless 下 BLE lifecycle 清选择/外部 defaults 时序不可控,ui-smoke 用内部通道)
    static let exclusiveSid: String? = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-exclusive-sid=") })
            .map { String($0.dropFirst("--ui-test-exclusive-sid=".count)) }
    }()

    /// argv 含 `--ui-test-codex-approval=<allow|deny>` → 首个 codex 审批挂起出现 5s 后自动应答
    /// (REQ-021 ui-smoke:验证 hook→server→UI→respond 闭环;5s 窗口留给 snapshot 截审批卡)
    static let codexApproval: String? = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-codex-approval=") })
            .map { String($0.dropFirst("--ui-test-codex-approval=".count)) }
    }()

    /// argv 含 `--ui-test-snapshot=<path.png>` → 启动后延时对主窗口自截图(bitmapImageRep,零 TCC)
    /// 写 PNG 后退出。叠加 `--ui-test-snapshot-delay=<秒>` 调整等待数据填充的时长(默认 4s)。
    static let snapshotPath: String? = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-snapshot=") })
            .map { String($0.dropFirst("--ui-test-snapshot=".count)) }
    }()
    static let snapshotDelay: Double = {
        ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-snapshot-delay=") })
            .flatMap { Double($0.dropFirst("--ui-test-snapshot-delay=".count)) } ?? 4
    }()
}

/// 流式 chunk 缓冲:tee 回调(音频线程/BLE)写 + pump(MainActor)读,NSLock 保护。
/// 独立非 actor 类,故 tee 闭包从任意线程同步写入无需 actor hop。@unchecked Sendable。
private final class PCMChunkBuffer: @unchecked Sendable {
    private var samples: [Int16] = []
    private var readIndex = 0
    private let lock = NSLock()

    func append(_ s: [Int16]) {
        lock.lock(); samples.append(contentsOf: s); lock.unlock()
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count - readIndex
    }

    /// 取出**恰好 threshold 个**样本(够一包就发一包,余量留下次)。
    /// ★ 关键:不能返回"全部累积"——一旦 feedPump 落后,缓冲累积会被一次性当超大包发出,
    ///   而豆包双向流式单包过大会拖慢处理 → 缓冲更涨 → 包更大 → 正反馈雪崩(越来越慢直至跳音)。
    ///   固定 200ms(=3200样本)包符合文档"单包 100~200ms 最优"。
    func drain(min threshold: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        guard samples.count - readIndex >= threshold else { return [] }
        return drainLocked(count: threshold)
    }

    /// 收尾阶段最多取一包；即使用户松键时有积压，也不得把全部 PCM 一次交给原生引擎。
    func drain(maximum: Int) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let available = samples.count - readIndex
        guard available > 0 else { return [] }
        return drainLocked(count: min(maximum, available))
    }

    /// 回退整段识别或取消时直接丢弃流式积压，同时释放曾被长录音撑大的容量。
    func discardAll() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: false)
        readIndex = 0
    }

    private func drainLocked(count: Int) -> [Int16] {
        let end = readIndex + count
        let out = Array(samples[readIndex..<end])
        readIndex = end
        if readIndex == samples.count {
            samples.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 65_536, readIndex * 2 >= samples.count {
            // Array.removeFirst 每包都搬移剩余数据，长录音会退化为 O(n²)。
            // 只在读取游标较大时批量紧缩一次。
            samples = Array(samples[readIndex...])
            readIndex = 0
        }
        return out
    }
}

@MainActor
final class VoiceInputManager: ObservableObject {
    @Published var state: VoiceInputState = .idle
    /// v5(REQ-012):设备处于文字编辑模式 → 设备 PTT 识别结果强制走胶囊 UI
    /// (即便用户设置为编辑器模式;插入光标处场景不该弹编辑器)
    @Published var deviceEditMode = false
    @Published var lastRecognizedText: String?
    @Published var localASRAvailable = false
    /// 当前已接入本地引擎的 Claude Code 上下文热词数(UI 显示用,必须 @Published)。
    @Published private(set) var localHotwordCount: Int = 0
    @Published var activeButton: ActiveButton = .none
    /// 当前正在录音/处理的通道。任一通道活跃时，其它通道的触发先到先得忽略。
    /// `.asrInject` 覆盖 Option+1 + Stick A 键。
    @Published private(set) var activeIntent: VoiceIntent?
    /// 当前活跃录音的触发源。决定 stopAndRecognize 后的注入路径与 overlay 直通徽章显示。
    /// 只在 startRecording 时写入；stopAndRecognize 读取后保留到 recognizeWAV 完成。
    private var activeTriggerSource: VoiceTriggerSource = .hotkey

    let audioCapture = AudioCaptureManager()
    let overlayController = RecordingOverlayController()
    var historyManager: RecognitionHistoryManager?
    var bleManager: BLEManager?
    var modelManager: ASRModelManager?
    var englishModelManager: EnglishASRModelManager?
    var funasrEngine: FunASRSeacoEngine?
    let sherpaEnglishEngine = SherpaEnglishEngine()
    private var audioCaptureSubscription: AnyCancellable?
    /// T-033 §1.11:CoreAudio 设备列表变化监听(USB 麦热插拔)
    private var micHotplugListener: AudioObjectPropertyListenerBlock?
    private let micHotplugAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var modelStateSubscription: AnyCancellable?
    private var funasrStateSubscription: AnyCancellable?
    private var deviceActionConnectionSubscription: AnyCancellable?
    private var deviceActionController: DeviceActionModeController?
    weak var inputAssistantController: InputAssistantCoordinator?
    /// 启动检查、设置切换可能同时触发；合并为一个任务，避免重复 SHA/模型初始化。
    private var localRecognitionRefreshTask: Task<Void, Never>?

    private struct PendingButtonARecording {
        let recordId: UUID?
        let capsuleSession: RecordingOverlayController.CapsuleSessionID?
    }

    /// Track pending BLE Button A recordings until audio-ready/abort arrives.
    private var pendingButtonARecordings: [PendingButtonARecording] = []
    private var activeCapsuleSession: RecordingOverlayController.CapsuleSessionID?
    /// Track if Button A pipeline is actively processing
    private var isProcessingA = false
    private var pendingRecognitionRevision: RecognitionBoostPendingRevision?

    private func discardPendingButtonARecording() -> PendingButtonARecording? {
        let pending = pendingButtonARecordings.isEmpty ? nil : pendingButtonARecordings.removeFirst()
        if let recordId = pending?.recordId {
            historyManager?.removeRecord(recordId)
        }
        return pending
    }

    // MARK: 流式 ASR(REQ-009 子模块 A)
    /// 当前活跃流式会话(豆包流式);nil = 非流式,停录走现有整段 runASR。
    private var streamingSession: StreamingASRSession?
    /// 流式 start() 是否成功。失败(NWError/端点/config)时 finishStreaming 返 nil,
    /// 触发回落整段 runASR —— 修"流式连接 abort 即返空丢录音"(reviewer 预警)。
    private var streamStarted = false
    private var streamSawPartialText = false
    /// 两路 tee 的单缓冲(锁保护,跨线程安全)。
    private let pcmPending = PCMChunkBuffer()
    /// 单 pump Task:串行排空缓冲 → await feed(保证 seq 顺序;禁 per-chunk Task 乱序)。
    private var feedPump: Task<Void, Never>?
    /// chunk 节流:200ms @16kHz = 3200 样本(= 6400 bytes,对齐豆包 100-200ms/包)。
    private let streamChunkSamples = StreamingASRFlushPolicy.chunkSamples
    private static let hardSilenceRMS: Double = 80
    private static let softSilenceRMS: Double = 320
    private static let minSpeechSampleRatio: Double = 0.08
    /// 本地 2-pass 流式引擎(T-018,共享单例;首次 start 懒加载模型)。
    let localStreamingEngine = FunASRStreamingEngine()
    private let projectStreamingEngine = FunASRStreamingEngine()
    private weak var projectStreamingSession: StreamingASRSession?
    private var projectStreamingHotwordSignature = ""
    private var projectStreamingPrewarmSignature = ""
    private var projectStreamingPrewarmTask: Task<Void, Never>?

    /// 本地流式模型目录:offline=SeACo(currentVersionDir),online/vad/punc=流式集(streamingDir,Step B 版本管理)。
    /// 磁盘文件未就绪 → 返 nil → 本地不走流式,回落整段离线。
    /// 不只依赖 streamingState：运行中从云端切到本地时，状态检查 Task 可能尚未完成。
    private func localStreamingDirs() -> (offline: String, online: String, vad: String, punc: String)? {
        guard let modelManager else {
            ClaudeCodeSessionManager.log("[ASR local stream] unavailable: model manager not attached")
            return nil
        }
        guard let offline = modelManager.currentVersionDir()?.path else {
            ClaudeCodeSessionManager.log("[ASR local stream] unavailable: offline model state not ready")
            return nil
        }
        guard let stream = modelManager.installedStreamingDir()?.path else {
            ClaudeCodeSessionManager.log("[ASR local stream] unavailable: streaming model files missing or incomplete")
            return nil
        }
        if modelManager.streamingState != .ready {
            ClaudeCodeSessionManager.log("[ASR local stream] using installed model files while readiness state refreshes")
        }
        let online = (stream as NSString).appendingPathComponent("online")
        let vad    = (stream as NSString).appendingPathComponent("vad")
        let punc   = (stream as NSString).appendingPathComponent("punc")
        let fm = FileManager.default
        for f in ["\(online)/model_quant.onnx", "\(vad)/model_quant.onnx", "\(punc)/model_quant.onnx"] {
            guard fm.fileExists(atPath: f) else { return nil }
        }
        return (offline, online, vad, punc)
    }
    /// 在途识别任务(整段/流式定稿处理)。用户在「识别中」按 ESC×2 / ✕ 时取消它,
    /// 中断卡住的识别;各识别流末尾以 `Task.isCancelled` 守卫,取消后不再呈现 UI。
    private var recognitionTask: Task<Void, Never>?
    /// 上一次流式是否被服务端**异常截断**(45000081 等)。为真说明云端正不健康
    /// (服务端过载/限流)→ 回落时直接走本地,跳过同样会慢的云端整段。finishStreaming 写,
    /// 回落路径读后清。
    private var lastStreamEndedAbnormally = false

    /// T-033:`QuickVibeHostApp.pushV5Config` 是 static(三处调用点签名已固化),
    /// 需要在下发时刻拿到设备麦克风快照做音源解析,故留一个弱引用入口。
    static weak var shared: VoiceInputManager?

    init() {
        Self.shared = self
        audioCaptureSubscription = audioCapture.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        overlayController.onEditorDismiss = { [weak self] in
            self?.discardRecognitionRevision()
        }
        overlayController.onEditorSubmit = { [weak self] edited in
            self?.finishRecognitionRevision(edited: edited)
        }
    }

    @AppStorage("doubaoAppKey") var appKey = ""
    @AppStorage("doubaoAccessKey") var accessKey = ""
    @AppStorage("doubaoConfigCheckStatus") private var doubaoConfigCheckStatusRaw = DoubaoConfigCheckStatus.unchecked.rawValue
    @AppStorage("doubaoConfigCheckMessage") private var doubaoConfigCheckMessage = ""
    @AppStorage("doubaoConfigCheckedAppKeyFingerprint") private var doubaoConfigCheckedAppKeyFingerprint = ""
    @AppStorage("doubaoConfigCheckedAccessKeyFingerprint") private var doubaoConfigCheckedAccessKeyFingerprint = ""
    @AppStorage("enablePunctuation") var enablePunctuation = true
    /// 悬浮窗模式:capsule(胶囊·识别即输入,默认)/ editor(可编辑编辑器)。REQ-012。
    @AppStorage("overlayMode") var overlayModeRaw = "capsule"
    /// 豆包语义顺滑(去口水词)。默认关:实测会吞真实词句(命令/代码口述完整性优先)。
    @AppStorage("doubaoEnableDDC") var doubaoEnableDDC = false
    /// 豆包逆文本规范化(数字/日期:十秒→10秒)。默认开。
    @AppStorage("doubaoEnableITN") var doubaoEnableITN = true
    /// 定稿 ITN 后处理(Swift 侧,本地/豆包统一:二零二六→2026)。默认开。REQ-008 #3。
    @AppStorage("itnPostProcessEnabled") var itnPostProcessEnabled = true
    @AppStorage("deepseekPostprocessEnabled") var deepseekPostprocessEnabled = false
    @AppStorage("asrEngine") var asrEngineRaw: String = ASREngine.local.rawValue
    @AppStorage("customHotwords") var customHotwords = ""

    var asrEngine: ASREngine {
        get {
            // 老用户 AppStorage 残留 "sensevoice"(指旧 Python 服务)→ 透明映射到 .local
            // 不写回 AppStorage,保留 rollback 路径
            if asrEngineRaw == "sensevoice" { return .local }
            return ASREngine(rawValue: asrEngineRaw) ?? .local
        }
        set {
            asrEngineRaw = newValue.rawValue
            // 切到本地:重新读取离线/流式模型状态并预热。App 可能以豆包启动，不能依赖启动时检查。
            if newValue == .local {
                Task { @MainActor [weak self] in
                    await self?.refreshLocalRecognitionState()
                }
            } else if newValue == .localEnglish {
                Task { @MainActor [weak self] in
                    await self?.englishModelManager?.checkLocalState()
                }
            }
            // 不再 start/stop Python 进程(已删)
        }
    }

    var isConfigured: Bool {
        switch asrEngine {
        case .doubao: !appKey.isEmpty && !accessKey.isEmpty
        case .local:  localASRAvailable
        case .localEnglish: englishModelManager?.state == .ready
        }
    }

    var doubaoConfigCheckStatus: DoubaoConfigCheckStatus {
        DoubaoConfigCheckStatus(rawValue: doubaoConfigCheckStatusRaw) ?? .unchecked
    }

    var isDoubaoConfigComplete: Bool {
        !appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isDoubaoConfigChangedSinceCheck: Bool {
        guard doubaoConfigCheckStatus != .unchecked, isDoubaoConfigComplete else { return false }
        return doubaoConfigCheckedAppKeyFingerprint != doubaoKeyFingerprint(appKey) ||
            doubaoConfigCheckedAccessKeyFingerprint != doubaoKeyFingerprint(accessKey)
    }

    var doubaoConfigCheckDisplayText: String {
        guard isDoubaoConfigComplete else { return AppL10n.tr("未配置完整") }
        if isDoubaoConfigChangedSinceCheck { return AppL10n.tr("配置已变更，建议重新检测") }
        switch doubaoConfigCheckStatus {
        case .unchecked:
            return AppL10n.tr("未检测")
        case .success:
            return AppL10n.tr("配置可用")
        case .failed:
            if doubaoConfigCheckMessage == AppL10n.tr("网络连接失败，请检查网络") {
                return AppL10n.tr("连接或鉴权失败，请检查密钥和 ASR 资源授权")
            }
            return doubaoConfigCheckMessage.isEmpty ? AppL10n.tr("配置检测失败") : doubaoConfigCheckMessage
        }
    }

    @MainActor
    func validateDoubaoConfiguration() async {
        let currentAppKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAccessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentAppKey.isEmpty, !currentAccessKey.isEmpty else { return }

        let client = DoubaoASRClient(appKey: currentAppKey, accessKey: currentAccessKey, enablePunc: enablePunctuation,
                                     enableDDC: doubaoEnableDDC, enableITN: doubaoEnableITN)
        do {
            try await client.validateConfiguration()
            doubaoConfigCheckStatusRaw = DoubaoConfigCheckStatus.success.rawValue
            doubaoConfigCheckMessage = AppL10n.tr("配置可用")
        } catch {
            doubaoConfigCheckStatusRaw = DoubaoConfigCheckStatus.failed.rawValue
            doubaoConfigCheckMessage = friendlyDoubaoConfigError(error)
        }
        doubaoConfigCheckedAppKeyFingerprint = doubaoKeyFingerprint(currentAppKey)
        doubaoConfigCheckedAccessKeyFingerprint = doubaoKeyFingerprint(currentAccessKey)
        objectWillChange.send()
    }

    private func doubaoKeyFingerprint(_ value: String) -> String {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func friendlyDoubaoConfigError(_ error: Error) -> String {
        if let asrError = error as? ASRError {
            switch asrError {
            case .missingCredentials:
                return AppL10n.tr("请填写 App Key 和 Access Key")
            case .serverError(let code, _):
                return AppL10n.format("服务返回错误 code: %@", String(code))
            default:
                return asrError.errorDescription ?? AppL10n.tr("配置检测失败")
            }
        }
        return AppL10n.tr("连接或鉴权失败，请检查密钥和 ASR 资源授权")
    }

    func checkLocalASR() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.modelManager?.checkLocalState()
            let modelReady = self.modelManager?.state == .ready
            let engineReady = self.funasrEngine?.loadState == .ready
            self.localASRAvailable = modelReady && engineReady
        }
    }

    /// 刷新本地模型库存，并在当前选中本地引擎时准备离线与 2-pass 流式识别。
    /// 未就绪时才检查磁盘；await 期间若用户切回云端，则只更新库存而不继续预热本地引擎。
    func refreshLocalRecognitionState() async {
        if let active = localRecognitionRefreshTask {
            await active.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLocalRecognitionRefresh()
        }
        localRecognitionRefreshTask = task
        await task.value
        localRecognitionRefreshTask = nil
    }

    private func performLocalRecognitionRefresh() async {
        guard let modelManager else {
            ClaudeCodeSessionManager.log("[ASR local] refresh skipped: model manager not attached")
            return
        }
        // 下载/首次启动完成后，运行中切换引擎只读缓存状态，不重复扫描 1GB+ 模型文件。
        if modelManager.state != .ready {
            await modelManager.checkLocalState()
        }
        if modelManager.streamingState != .ready {
            await modelManager.checkStreamingLocalState()
        }
        ClaudeCodeSessionManager.log(
            "[ASR local] model refresh offline=\(modelManager.state == .ready ? "ready" : "unavailable") " +
            "streaming=\(modelManager.streamingState == .ready ? "ready" : "unavailable")"
        )
        guard asrEngine == .local else { return }
        guard modelManager.state == .ready else {
            refreshLocalASRAvailable()
            return
        }
        let hotwords = buildASRContextForButtonA().hotwords
        try? await funasrEngine?.prepare(hotwords: hotwords)
        guard asrEngine == .local else { return }
        updateLocalHotwordCount(hotwords.count)
        refreshLocalASRAvailable()
        prewarmProjectStreamingHotwords()
    }

    /// 同步本地引擎已接入的热词数到 UI(@Published private(set) 的内部写口)。
    func updateLocalHotwordCount(_ n: Int) { localHotwordCount = n }

    func setupLocalEngineObserver() {
        modelStateSubscription = modelManager?.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLocalASRAvailable() }
        }
        funasrStateSubscription = funasrEngine?.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLocalASRAvailable() }
        }
    }

    private func refreshLocalASRAvailable() {
        let modelReady = modelManager?.state == .ready
        let engineReady = funasrEngine?.loadState == .ready
        localASRAvailable = modelReady && engineReady
        // 模型就绪但引擎尚未加载 + 当前为本地引擎 → 自动 prepare(下载完成后自动生效,
        // 无需手动切引擎)。loading 中不重入;prepare 完成会再触发本方法把 available 置真。
        if modelReady, !engineReady, asrEngine == .local,
           let engine = funasrEngine, engine.loadState != .loading {
            let hotwords = currentHotwordList()
            Task { [weak self] in
                try? await self?.funasrEngine?.prepare(hotwords: hotwords)
            }
        }
    }

    func toggleRecording() {
        toggleRecording(intent: .asrInject, triggerSource: .hotkey)
    }

    /// 双通道 toggle：先到先得。已有 intent 在录/处理时，其它 intent 触发被忽略。
    /// `triggerSource` 决定 ASR 结果的注入路径：
    /// - `.hotkey` → `.microphone` 源走 KeyboardSimulator 光标注入
    func toggleRecording(intent: VoiceIntent, triggerSource: VoiceTriggerSource = .hotkey) {
        // 设备 A/B 键录音中时，快捷键录音被屏蔽
        if bleManager?.isReceivingAudio == true { return }

        switch state {
        case .idle:
            activeIntent = intent
            activeTriggerSource = triggerSource
            startRecording(intent: intent)
        case .recording:
            // 只允许同一 intent 停止，异 intent 触发忽略
            guard activeIntent == intent else {
                ClaudeCodeSessionManager.log("[toggleRecording] ignored intent=\(String(describing: intent)) while active=\(String(describing: activeIntent))")
                return
            }
            stopAndRecognize(intent: intent)
        default:
            break
        }
    }

    // MARK: - T-033 音源解析

    /// 用户当前选的音源模式(不代表实际可用 —— 可用性由 resolveMicSourceNow 判定)。
    var currentMicSourceIsSystem: Bool {
        MicSourceMode(rawValue: UserDefaults.standard.integer(forKey: MicSourceMode.defaultsKey)) == .system
    }

    /// 读用户偏好 + 当前设备快照 → 实际音源。纯转发给 MicSourceResolver(可测)。
    func resolveMicSourceNow() -> MicSourceResolution {
        let mode = MicSourceMode(rawValue: UserDefaults.standard.integer(forKey: MicSourceMode.defaultsKey)) ?? .device
        // BUG-032(用户拍板):App 内不再支持指定系统麦,恒随系统默认输入设备。
        // 切换麦克风 = 用户在 系统设置 → 声音 → 输入 里改默认(与快捷键链路同语义)。
        let devices = audioCapture.inputDevices.map { (uid: $0.uid, id: $0.id, name: $0.name) }
        return MicSourceResolver.resolve(mode: mode, preferredUID: "", devices: devices,
                                         systemDefaultID: audioCapture.systemDefaultInputDeviceID())
    }

    /// PTT 期间发现系统麦没了:重推 0x53 —— 内部会 resolve 出 .fellBack,
    /// 弹通知并下发 micSource=0,把设备切回设备麦语义。
    func notifyMicFallbackAndRepush() {
        QuickVibeHostApp.pushV5Config(ble: bleManager)
    }

    /// §1.11 USB 麦热插拔:设备列表变化 → 刷新下拉 + 重跑音源解析并重推 0x53。
    /// 插入刷新列表、拔出触发回退,两个需求一次覆盖。
    private func setupMicHotplugListener() {
        guard !UITestFlags.isHeadless else {
            NSLog("[ui-test] skipped CoreAudio device listener — headless")
            return
        }
        guard micHotplugListener == nil else { return }
        var address = micHotplugAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioCapture.refreshInputDevices()
                ClaudeCodeSessionManager.log("[T-033] audio devices changed, count=\(self.audioCapture.inputDevices.count)")
                QuickVibeHostApp.pushV5Config(ble: self.bleManager)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status == noErr {
            micHotplugListener = block
        } else {
            ClaudeCodeSessionManager.log("[T-033] failed to add audio device listener: \(status)")
        }
    }

    deinit {
        // CoreAudio 持有 listener block,不摘除会继续回调(block 内已 [weak self],
        // 不构成循环引用,但残留 listener 编译器与 xcodebuild 都不报)
        if let block = micHotplugListener {
            var address = micHotplugAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
    }

    // MARK: - BLE Audio Handler

    func setupBLEAudioHandler() {
        setupMicHotplugListener()   // T-033:与 BLE 回调同一处接线,应用启动时调一次
        // 实时 RMS 电平 → 浮窗波形(两路输入都接;录音中高频回调)。
        bleManager?.onLevel = { [weak self] l in self?.overlayController.updateLevel(l) }
        audioCapture.onLevel = { [weak self] l in self?.overlayController.updateLevel(l) }
        bleManager?.onAudioStreamStarted = { [weak self] buttonId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 快捷键录音中时，设备 A 键录音被屏蔽，通知设备停止
                guard self.state != .recording else {
                    self.bleManager?.sendASRNotification(success: false, buttonId: buttonId, errorMessage: "Mic busy")
                    return
                }
                guard self.state != .processing, self.pendingButtonARecordings.isEmpty, self.streamingSession == nil else {
                    self.bleManager?.sendASRNotification(success: false, buttonId: buttonId, errorMessage: "ASR busy")
                    return
                }
                let record = self.historyManager?.addPendingRecord(
                    source: .bleDevice,
                    sourceName: self.historySourceName(for: .bleDevice)
                )
                self.activeButton = .buttonA
                let capsuleSession = self.overlayController.showButtonA()
                self.pendingButtonARecordings.append(.init(recordId: record?.id, capsuleSession: capsuleSession))
                self.startStreamingIfSupported(context: self.buildASRContextForButtonA(), capsuleSession: capsuleSession)
                ClaudeCodeSessionManager.log("[BLE] Audio stream started, buttonId=\(buttonId), recordId=\(record?.id.uuidString.prefix(8) ?? "nil")")
            }
        }

        // T-033: 系统麦模式 —— 0x19 起采,0x14 收尾。设备麦模式此回调不会触发(固件不发 0x19)。
        bleManager?.onPTTStart = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentMicSourceIsSystem else { return }
                guard self.state == .idle, self.pendingButtonARecordings.isEmpty,
                      self.streamingSession == nil else {
                    self.bleManager?.sendASRNotification(success: false, buttonId: 0x01, errorMessage: "ASR busy")
                    return
                }
                guard case .system(let devID, let micName) = self.resolveMicSourceNow() else {
                    // 配置下发后被热拔:通知 + 让设备退回 idle(否则卡在录音页),并重推 0x53 回退。
                    self.notifyMicFallbackAndRepush()
                    self.bleManager?.sendASRNotification(success: false, buttonId: 0x01, errorMessage: "Mic unavailable")
                    return
                }
                do {
                    try self.audioCapture.startSystemMicPTT(deviceID: devID)   // 内部 flush 预滚环形
                } catch {
                    self.notifyMicFallbackAndRepush()
                    self.bleManager?.sendASRNotification(success: false, buttonId: 0x01, errorMessage: "Mic error")
                    return
                }
                self.state = .recording
                self.activeButton = .buttonA
                // 触发源仍是设备按键 → source 保持 .bleDevice(§1.6 要"标注所用麦克风",落在 sourceName)
                let record = self.historyManager?.addPendingRecord(
                    source: .bleDevice,
                    sourceName: AppL10n.format("系统麦克风 · %@", micName))
                let capsuleSession = self.overlayController.showButtonA()
                self.pendingButtonARecordings.append(.init(recordId: record?.id, capsuleSession: capsuleSession))
                self.startStreamingIfSupported(context: self.buildASRContextForButtonA(), capsuleSession: capsuleSession)
                ClaudeCodeSessionManager.log("[T-033] system-mic PTT start, mic=\(micName), recordId=\(record?.id.uuidString.prefix(8) ?? "nil")")
            }
        }
        bleManager?.onPTTStop = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentMicSourceIsSystem, self.state == .recording,
                      let pending = self.pendingButtonARecordings.first else { return }
                let wav = self.audioCapture.stopSystemMicPTT()
                ClaudeCodeSessionManager.log("[T-033] system-mic PTT stop, wav=\(wav.count) bytes")
                _ = self.pendingButtonARecordings.removeFirst()
                self.processButtonAAudio(wav, recordId: pending.recordId, capsuleSession: pending.capsuleSession)
            }
        }

        bleManager?.onAudioStreamAborted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let buttonId = self.bleManager?.audioStreamButtonId ?? 0x01
                let pending = self.discardPendingButtonARecording()
                self.discardStreamingIfActive()   // 录音太短/丢弃:收尾流式会话避免泄漏
                self.overlayController.dismissOrRestoreEditing(session: pending?.capsuleSession)   // 编辑器有未提交结果则恢复,不关
                self.activeButton = .none
                self.state = .idle
                // Notify device so it returns to idle (don't leave it stuck on recording screen)
                if (self.bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                    self.bleManager?.sendASRNotification(success: true, buttonId: buttonId)
                } else {
                    self.bleManager?.sendVoiceState(0x04)
                }
                ClaudeCodeSessionManager.log("[BLE] Audio stream discarded (too short/empty)")
            }
        }

        bleManager?.onAudioReady = { [weak self] wavData in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // 快捷键录音中时，丢弃 BLE 设备的音频
                guard self.state != .recording else {
                    ClaudeCodeSessionManager.log("[BLE] Ignoring BLE audio: keyboard recording in progress")
                    _ = self.discardPendingButtonARecording()
                    self.discardStreamingIfActive()   // 收尾已起流式会话避免泄漏
                    return
                }

                // Button A: uses main state machine (Button B 不再发起音频)
                guard let pending = self.pendingButtonARecordings.isEmpty ? nil : self.pendingButtonARecordings.removeFirst() else {
                    ClaudeCodeSessionManager.log("[BLE] Ignoring Button A audio: no pending session")
                    self.discardStreamingIfActive()   // 已取消/已拒绝的迟到音频:不进 ASR
                    return
                }
                guard self.state != .processing else {
                    ClaudeCodeSessionManager.log("[BLE] Ignoring Button A audio: already processing")
                    self.discardStreamingIfActive()   // 收尾已起流式会话避免泄漏
                    if let recordId = pending.recordId {
                        self.historyManager?.markFailed(recordId, error: AppL10n.tr("已有任务处理中"))
                    }
                    return
                }
                self.processButtonAAudio(wavData, recordId: pending.recordId, capsuleSession: pending.capsuleSession)
            }
        }
    }

    func setupBLEControlHandler() {
        bleManager?.onControlCommand = { [weak self] command in
            Task { @MainActor in
                // 编辑器驻留时:enter→提交、esc→关闭,改驱动编辑器而非注入目标 app。
                let editorOpen = self?.overlayController.isEditorActive == true
                switch command {
                // REQ-022:0x10/0x11 的审批语义已摘除 —— 审批应答一律走专用 0x36 帧
                // (ApprovalCoordinator,reqId 精确匹配);这里只保留普通 Enter/ESC 注入。
                case 0x10:
                    if editorOpen { self?.overlayController.submitEditorExternally() }
                    else { InputRouter.routeControl(.enter, source: .bleButtonA) }
                case 0x11:
                    if editorOpen { self?.overlayController.closeEditorExternally() }
                    else { InputRouter.routeControl(.escapeOnce, source: .bleButtonB) }
                case 0x12: InputRouter.routeControl(.shiftTab, source: .bleButtonB)   // BtnB long-press
                case 0x13: InputRouter.routeControl(.backspace, source: .bleButtonB)  // BtnB 单击/长按节拍（删除）
                case 0x15: InputRouter.routeControl(.upArrow, source: .bleButtonA)
                case 0x16: InputRouter.routeControl(.downArrow, source: .bleButtonA)
                case 0x17: InputRouter.routeControl(.leftArrow, source: .bleButtonA)   // v5 编辑模式光标←
                case 0x18: InputRouter.routeControl(.rightArrow, source: .bleButtonA)  // v5 编辑模式光标→
                default: break
                }
            }
        }
    }

    func setupDeviceActionHandler(sceneModes: SceneModeStore) {
        guard let bleManager else { return }
        let controller = DeviceActionModeController(ble: bleManager, sceneModes: sceneModes)
        deviceActionController = controller
        bleManager.onDeviceAction = { [weak controller] event in
            Task { @MainActor in controller?.handle(event) }
        }
        deviceActionConnectionSubscription = bleManager.$connectionState
            .removeDuplicates()
            .sink { [weak controller] state in
                guard state != .connected else { return }
                Task { @MainActor in controller?.stopTransientActions() }
            }
    }

    // MARK: - Button A Pipeline

    /// Calculate RMS of WAV audio data (skipping 44-byte header)
    private func calculateRMS(_ wavData: Data) -> Double {
        guard wavData.count > 44 else { return 0 }
        let audioData = wavData.subdata(in: 44..<wavData.count)
        let sampleCount = audioData.count / 2
        guard sampleCount > 0 else { return 0 }
        var sumSquares: Double = 0
        audioData.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let s = Double(samples[i])
                sumSquares += s * s
            }
        }
        return (sumSquares / Double(sampleCount)).squareRoot()
    }

    private func speechSampleRatio(_ wavData: Data) -> Double {
        guard wavData.count > 44 else { return 0 }
        let audioData = wavData.subdata(in: 44..<wavData.count)
        let sampleCount = audioData.count / 2
        guard sampleCount > 0 else { return 0 }
        var voiced = 0
        audioData.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let magnitude = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                if magnitude >= Int(Self.softSilenceRMS) { voiced += 1 }
            }
        }
        return Double(voiced) / Double(sampleCount)
    }

    private func processButtonAAudio(_ wavData: Data, recordId: UUID?, capsuleSession: RecordingOverlayController.CapsuleSessionID?) {
        state = .processing
        activeButton = .buttonA
        let analyticsStartedAt = Date()
        overlayController.showProcessing(engine: currentEngineLabel(), session: capsuleSession)
        let buttonId: UInt8 = 0x01

        // Save WAV file for all BLE recordings
        if let recordId {
            historyManager?.saveWavData(wavData, for: recordId)
            historyManager?.setHasWav(recordId, hasWav: true)
        }

        // RMS gate: skip ASR for noise-only audio (RMS < 320 ≈ ~1% of full scale)
        // 阈值历史: 800 是 MicPad 0.4.1- 时代 INMP441 16-bit 截断读法下调出来的;
        // 0.4.2 改 32-bit 读 + >>14 后整体信号涨 ~10×, 阈值下调到 320 仍远高于
        // 静音底噪 (encoded RMS ~32) 又能让正常坐姿讲话稳过线
        let rms = calculateRMS(wavData)
        let speechRatio = speechSampleRatio(wavData)
        ClaudeCodeSessionManager.log("[ButtonA] Audio RMS=\(String(format: "%.0f", rms)) speechRatio=\(String(format: "%.3f", speechRatio))")
        let isHardSilence = rms < Self.hardSilenceRMS
        let isSparseNoise = speechRatio < Self.minSpeechSampleRatio
        let hasStreamingSpeech = streamingSession != nil && streamSawPartialText
        // BUG-032 问题1:RMS 门只拦"整段路径的误触噪声"。流式活跃且已采到实质音频时豁免 ——
        // HFP 蓝牙麦(DJI 直连)电平天然偏低(实测 RMS=271<320)但流式一路出字,
        // 整段 RMS 拦截会把有效定稿丢掉(气泡有字、历史空结果)。定稿是否有效交 finishStreaming 判。
        if !isHardSilence, !isSparseNoise || hasStreamingSpeech, rms < Self.softSilenceRMS, streamingSession != nil, wavData.count >= 1000 {
            ClaudeCodeSessionManager.log("[BUG-032] RMS \(String(format: "%.0f", rms)) below gate but streaming active — deferring to streaming final")
        } else if rms < Self.softSilenceRMS || (isSparseNoise && !hasStreamingSpeech) {
            ClaudeCodeSessionManager.log("[ButtonA] Audio too quiet (RMS=\(String(format: "%.0f", rms))), skipping ASR")
            discardStreamingIfActive()   // 收尾流式会话(若已起),避免泄漏
            AnalyticsClient.shared.captureRecordingResult(
                source: RecognitionSource.bleDevice.rawValue,
                result: wavData.count < 1000 ? "failure" : "cancelled",
                errorKind: wavData.count < 1000 ? "mic_unavailable" : "cancelled",
                triggerSource: "ble_button"
            )
            if let recordId {
                historyManager?.markCompleted(recordId)
            }
            inputAssistantController?.reportVoiceFailure()
            overlayController.dismissOrRestoreEditing(session: capsuleSession)   // 太短/太静:编辑器有结果则恢复,不关
            activeButton = .none
            state = .idle
            // BUG-032: wav 仅头无样本 = 采集根本没起来(蓝牙麦 HFP 激活 1-3s 内松键的典型特征),
            // 与"有样本但太静"(误触)语义不同:前者要 error + 系统通知,否则用户以为设备坏了。
            if wavData.count < 1000 {
                ClaudeCodeSessionManager.log("[BUG-032] Empty capture (\(wavData.count)B) — mic produced no samples, notifying user")
                QuickVibeHostApp.notifyMicCaptureEmpty()
                if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                    bleManager?.sendASRNotification(success: false, buttonId: buttonId, errorMessage: AppL10n.tr("无音频输入"))
                } else {
                    bleManager?.sendVoiceState(0x05, errorMessage: AppL10n.tr("无音频输入"))
                }
                return
            }
            // Notify device
            if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                bleManager?.sendASRNotification(success: true, buttonId: buttonId)
            } else {
                bleManager?.sendVoiceState(0x04)
            }
            return
        }

        AnalyticsClient.shared.captureRecordingResult(source: RecognitionSource.bleDevice.rawValue, result: "success", errorKind: "none", triggerSource: "ble_button")

        if let recordId {
            historyManager?.updatePhase(recordId, phase: .asrProcessing)
        }

        recognitionTask = Task {
            do {
                let asrContext = buildASRContextForButtonA()
                // 流式活跃：finish 出定稿;非流式走现有整段 runASR(本地 offline 零回归)。
                let rawText: String
                let method: String
                var analyticsFallback = "none"
                if let final = await finishStreaming() {
                    if final.isEmpty, let fb = await fallbackLocalASR(wavData, context: asrContext) {
                        rawText = fb
                        method = AppL10n.tr("豆包失败·本地兜底")
                        analyticsFallback = "local_asr"
                    } else {
                        rawText = final
                        method = streamingMethodLabel
                    }
                } else {
                    // 流式失败回落整段。流式被服务端异常截断(45000081)说明服务端在降速但仍可用
                    // (闪电说同期整段 10s 能成)→ 给整段 25s 宽限,别误判超时;否则常规 15s。
                    let segTimeout: Double = lastStreamEndedAbnormally ? 25 : 15
                    lastStreamEndedAbnormally = false
                    do {
                        rawText = try await runASR(wavData, context: asrContext, timeout: segTimeout)
                        method = asrEngine == .doubao ? AppL10n.tr("豆包云端") : AppL10n.tr("本地")
                    } catch {
                        // 豆包整段也失败 → 本地兜底;兜底也无果则抛回原错误走错误态。
                        if asrEngine == .doubao, let fb = await fallbackLocalASR(wavData, context: asrContext) {
                            rawText = fb
                            method = AppL10n.tr("豆包失败·本地兜底")
                            analyticsFallback = "local_asr"
                        } else {
                            throw error
                        }
                    }
                }
                // BLE 入口不走 presentEditor,ITN/识别增强后处理在此汇合点单独挂
                // (两条入口都要接,见 [[语音识别有 mic + 蓝牙两条入口]])。
                let processed = postprocessRecognizedText(rawText)
                if let assistant = inputAssistantController, assistant.isActive {
                    if Task.isCancelled { return }
                    overlayController.setSource(method, session: capsuleSession)
                    let instruction = processed.display
                    if !instruction.isEmpty {
                        _ = assistant.executeVoiceInstruction(instruction)
                        overlayController.showCapsuleFinal(instruction, session: capsuleSession)
                    } else {
                        assistant.reportVoiceFailure()
                        overlayController.dismissOrRestoreEditing(session: capsuleSession)
                    }
                    if let recordId { historyManager?.removeRecord(recordId) }
                    if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                        bleManager?.sendASRNotification(success: true, buttonId: buttonId)
                    }
                    activeButton = .none; state = .idle
                    return
                }
                let polished = await maybePolishRecognizedText(processed)
                if Task.isCancelled { return }   // 用户已中断:不再呈现 UI
                overlayController.setSource(method, session: capsuleSession)
                lastRecognizedText = polished.display
                ClaudeCodeSessionManager.log("[ButtonA] Text='\(String(polished.display.prefix(80)))' isEmpty=\(polished.display.isEmpty) method=\(method)")
                if !polished.display.isEmpty {
                    if let recordId {
                        historyManager?.updateWithASRResult(recordId, text: polished.display, nextPhase: .completed, method: method)
                        updateHistoryTrace(recordId: recordId, processed: polished, method: method, audioId: recordId.uuidString)
                    } else {
                        let record = historyManager?.addRecord(
                            polished.display,
                            source: .bleDevice,
                            method: method,
                            sourceName: historySourceName(for: .bleDevice)
                        )
                        if let record {
                            updateHistoryTrace(recordId: record.id, processed: polished, method: method)
                        }
                    }
                    // 胶囊模式:识别即输入——展示定稿 + 自动注入(重试成功改复制,不注入)。
                    // v5(REQ-012):设备编辑模式下强制胶囊(识别文字插入光标处,不弹编辑器)
                    // BUG-001 现象 A:编辑器驻留时(editorSessionActive)必须优先追加进编辑器,
                    // 设备编辑态 PTT 同样——原先 deviceEditMode 分支在前,识别文字绕过打开的
                    // 编辑器直接注入系统原光标。
                    if overlayController.editorSessionActive, !overlayController.isCapsuleMode {
                        // 编辑器模式 ②:编辑会话开着则追加不清空(沿用首次 showEditor 注入闭包)。
                        appendRecognitionRevision(asrText: polished.learning)
                        overlayController.appendText(polished.display)
                    } else if deviceEditMode || overlayController.isCapsuleMode {
                        deliverCapsule(polished.display, session: capsuleSession) { InputRouter.routeASRText(polished.display, learningText: polished.learning, source: .bleButtonA) }
                    } else {
                        beginRecognitionRevision(asrText: polished.learning)
                        overlayController.showEditor(text: polished.display) { edited in
                            guard !edited.isEmpty else { return }
                            InputRouter.route(text: edited, source: .bleButtonA)
                        }
                    }
                } else {
                    AnalyticsClient.shared.captureASRResult(
                        engine: asrEngine,
                        result: "failure",
                        errorKind: "asr_empty_result",
                        durationSeconds: Date().timeIntervalSince(analyticsStartedAt),
                        textLength: 0,
                        localModelState: analyticsLocalModelState(),
                        fallbackUsed: analyticsFallback,
                        source: RecognitionSource.bleDevice.rawValue,
                        triggerSource: "ble_button",
                        deviceType: analyticsDeviceType(),
                        deviceProtocolVersion: Int(bleManager?.deviceProtocolVersion ?? 0),
                        localModelVersion: analyticsLocalModelVersion()
                    )
                    if let recordId {
                        // Empty ASR result: flag as soft failure so the record surfaces in history
                        // (WAV was already saved at line 270 / hasWavData=true → user can replay to diagnose).
                        historyManager?.markFailed(recordId, error: AppL10n.tr("ASR 返空结果"))
                        ClaudeCodeSessionManager.log("[ButtonA] Empty ASR result — marked as soft failure for diagnosis")
                    }
                    overlayController.dismissOrRestoreEditing(session: capsuleSession)   // 空结果:编辑器有上次结果则恢复,不关
                }
                if !polished.display.isEmpty {
                    AnalyticsClient.shared.captureASRResult(
                        engine: asrEngine,
                        result: "success",
                        errorKind: "none",
                        durationSeconds: Date().timeIntervalSince(analyticsStartedAt),
                        textLength: AnalyticsSupport.speechTextUnits(polished.display),
                        localModelState: analyticsLocalModelState(),
                        fallbackUsed: analyticsFallback,
                        source: RecognitionSource.bleDevice.rawValue,
                        triggerSource: "ble_button",
                        deviceType: analyticsDeviceType(),
                        deviceProtocolVersion: Int(bleManager?.deviceProtocolVersion ?? 0),
                        localModelVersion: analyticsLocalModelVersion()
                    )
                }
                // Notify device
                if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                    bleManager?.sendASRNotification(success: true, buttonId: buttonId)
                } else {
                    bleManager?.sendVoiceState(0x04)
                }
                // 非空文本时编辑器要驻留等用户提交,原 dismissButtonA() 已删(对齐 recognizeWAV)。
                activeButton = .none
                state = .idle
            } catch {
                if error is CancellationError || Task.isCancelled { return }   // 用户中断:静默退出
                inputAssistantController?.reportVoiceFailure()
                AnalyticsClient.shared.captureASRResult(
                    engine: asrEngine,
                    result: "failure",
                    errorKind: analyticsErrorKind(error),
                    durationSeconds: Date().timeIntervalSince(analyticsStartedAt),
                    textLength: 0,
                    localModelState: analyticsLocalModelState(),
                    fallbackUsed: asrEngine == .doubao ? "local_asr_failed" : "none",
                    source: RecognitionSource.bleDevice.rawValue,
                    triggerSource: "ble_button",
                    deviceType: analyticsDeviceType(),
                    deviceProtocolVersion: Int(bleManager?.deviceProtocolVersion ?? 0),
                    localModelVersion: analyticsLocalModelVersion()
                )
                handleASRError(
                    error,
                    source: .bleDevice,
                    buttonId: buttonId,
                    wavData: wavData,
                    recordId: recordId,
                    fallbackUsed: asrEngine == .doubao ? "local_asr_failed" : "none"
                )
                // 错误态:浮窗转错误样式 + 重试按钮(重试 = 重跑整条 BLE 识别管线),不立即 dismiss。
                let wav = wavData
                overlayController.showError(shortErrorMessage(error), session: capsuleSession) { [weak self] in
                    self?.processButtonAAudio(wav, recordId: nil, capsuleSession: capsuleSession)
                }
                activeButton = .none
                state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(3))
                if case .error = state { state = .idle }
            }
        }
    }

    // MARK: - 流式 ASR(REQ-009 子模块 A)

    /// 录音开始:若引擎支持流式 + 有 keys → 建 session、start、起单 pump、挂两路 tee。
    /// 非流式引擎/缺 keys 直接 return,onPCMChunk 保持 nil,整段 runASR 路径零触碰。
    private func startStreamingIfSupported(context: ASRContext, capsuleSession: RecordingOverlayController.CapsuleSessionID?) {
        lastStreamEndedAbnormally = false   // 新会话:清上次异常标志
        // 按引擎选流式会话:豆包(需 keys)/ 本地 FunTpass 2-pass(需流式模型齐)。都不满足 → 走整段。
        let session: StreamingASRSession
        var streamContext = context
        if asrEngine == .doubao, !appKey.isEmpty, !accessKey.isEmpty {
            let client = DoubaoASRClient(appKey: appKey, accessKey: accessKey, enablePunc: enablePunctuation,
                                         enableDDC: doubaoEnableDDC, enableITN: doubaoEnableITN,
                                         hotwords: context.hotwords.map(\.cloudPayload), dialogContext: context.dialogContext)
            session = DoubaoStreamingSession(client: client)
        } else if asrEngine == .local, let dirs = localStreamingDirs() {
            let signature = hotwordSignature(context.hotwords)
            prewarmProjectStreamingHotwords(context: context, dirs: dirs, signature: signature)
            if !signature.isEmpty, projectStreamingHotwordSignature == signature {
                session = LocalTpassStreamingSession(engine: projectStreamingEngine, dirs: dirs)
                projectStreamingSession = session
            } else {
                streamContext = buildASRContextForButtonA(includeProjectHotwords: false)
                if streamContext.hotwords.count != context.hotwords.count {
                    ClaudeCodeSessionManager.log("[ASR stream] project hotwords not ready, streaming without project hotwords count=\(streamContext.hotwords.count)")
                }
                session = LocalTpassStreamingSession(engine: localStreamingEngine, dirs: dirs)
            }
        } else if asrEngine == .localEnglish,
                  let directory = englishModelManager?.installedDirectory() {
            session = SherpaEnglishStreamingSession(
                engine: sherpaEnglishEngine,
                modelDirectory: directory
            )
        } else {
            return   // 非流式:onPCMChunk 保持 nil,整段 runASR 路径零触碰
        }
        session.onPartial = { [weak self] partial in
            Task { @MainActor in
                if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.streamSawPartialText = true
                }
                self?.overlayController.updateDraft(partial, session: capsuleSession)
            }
        }
        streamingSession = session
        // 两路 tee(仅此刻起活跃;finishStreaming 置回 nil)
        audioCapture.onPCMChunk = { [weak self] data in
            let s = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            self?.pcmPending.append(s)
        }
        bleManager?.onPCMChunk = { [weak self] samples in self?.pcmPending.append(samples) }
        streamStarted = false
        streamSawPartialText = false
        feedPump = Task { [weak self] in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.streamingSession === session, !self.streamStarted else { return }
                ClaudeCodeSessionManager.log("[ASR stream] start slow >2s")
            }
            do { try await session.start(context: streamContext); self?.streamStarted = true }
            catch {
                ClaudeCodeSessionManager.log("[ASR stream] start failed: \(error.localizedDescription) → 回落离线整段")
                return
            }
            await self?.runFeedPump(session)
        }
    }

    fileprivate func prewarmProjectStreamingHotwords() {
        guard asrEngine == .local, let dirs = localStreamingDirs() else { return }
        let context = buildASRContextForButtonA()
        prewarmProjectStreamingHotwords(context: context, dirs: dirs, signature: hotwordSignature(context.hotwords))
    }

    private func prewarmProjectStreamingHotwords(
        context: ASRContext,
        dirs: (offline: String, online: String, vad: String, punc: String),
        signature: String
    ) {
        guard !signature.isEmpty, projectStreamingHotwordSignature != signature else { return }
        guard projectStreamingSession == nil else {
            ClaudeCodeSessionManager.log("[ASR stream] project hotwords prewarm skipped: stream active")
            return
        }
        guard projectStreamingPrewarmTask == nil else { return }
        projectStreamingPrewarmSignature = signature
        ClaudeCodeSessionManager.log("[ASR stream] project hotwords prewarm begin count=\(context.hotwords.count)")
        projectStreamingPrewarmTask = Task { [weak self] in
            guard let self else { return }
            let ok = await self.projectStreamingEngine.prepare(
                offlineDir: dirs.offline,
                onlineDir: dirs.online,
                vadDir: dirs.vad,
                puncDir: dirs.punc
            )
            guard ok else {
                await MainActor.run {
                    self.projectStreamingPrewarmTask = nil
                    ClaudeCodeSessionManager.log("[ASR stream] project hotwords prewarm skipped: model not ready")
                }
                return
            }
            await self.projectStreamingEngine.reloadHotwordsIfChanged(context.hotwords)
            await self.projectStreamingEngine.reset()
            await MainActor.run {
                if self.projectStreamingPrewarmSignature == signature {
                    self.projectStreamingHotwordSignature = signature
                    ClaudeCodeSessionManager.log("[ASR stream] project hotwords prewarm ready count=\(context.hotwords.count)")
                }
                self.projectStreamingPrewarmTask = nil
            }
        }
    }

    /// 单 pump:串行排空缓冲 → await feed(保证 seq 顺序;避免 per-chunk Task 乱序)。
    private func runFeedPump(_ session: StreamingASRSession) async {
        var fed = 0
        while !Task.isCancelled {
            let take = pcmPending.drain(min: streamChunkSamples)
            if take.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000); continue }
            let data = take.withUnsafeBufferPointer { Data(buffer: $0) }
            do {
                try await session.feed(data)
                fed += 1
            } catch {
                ClaudeCodeSessionManager.log("[stream feed] 第 \(fed+1) 包失败: \(error.localizedDescription)")
            }
        }
    }

    /// 停录:停 tee + 等 pump 退出(避免与 flush 并发 send → seq race)+ flush 余量 + finish。
    /// 返回 nil 表示当前非流式(走旧整段 runASR);返回字符串(含空串)表示流式定稿。
    private func finishStreaming() async -> String? {
        guard let session = streamingSession else { return nil }
        defer {
            if projectStreamingSession === session { projectStreamingSession = nil }
        }
        audioCapture.onPCMChunk = nil
        bleManager?.onPCMChunk = nil
        feedPump?.cancel()
        await feedPump?.value   // 等 pump 真正退出,再 flush(单一 send 入口,无 seq race)
        feedPump = nil
        streamingSession = nil
        let started = streamStarted
        streamStarted = false
        streamSawPartialText = false
        guard started else {
            // 流式 start 没成功(连接 abort/端点/config 失败)→ 关会话 + 清缓冲 + 返 nil 触发整段 runASR 回落。
            session.close()
            pcmPending.discardAll()
            ClaudeCodeSessionManager.log("[ASR stream] start 未成功 → finishStreaming 返 nil,回落离线整段 runASR")
            return nil
        }

        let flushPlan = StreamingASRFlushPolicy.plan(backlogSamples: pcmPending.pendingCount)
        ClaudeCodeSessionManager.log(
            "[ASR stream] finish backlog samples=\(flushPlan.backlogSamples) "
            + "ms=\(flushPlan.backlogMilliseconds) chunkSamples=\(flushPlan.chunkSamples) "
            + "memoryMB=\(residentMemoryMBDescription())"
        )
        if flushPlan.action == .fallbackToSegment {
            pcmPending.discardAll()
            lastStreamEndedAbnormally = true
            session.close()
            ClaudeCodeSessionManager.log(
                "[ASR stream] finish fallback reason=backlog samples=\(flushPlan.backlogSamples) "
                + "limit=\(StreamingASRFlushPolicy.maxBacklogSamples) → 整段 runASR"
            )
            return nil
        }

        var flushChunkIndex = 0
        while true {
            let chunk = pcmPending.drain(maximum: flushPlan.chunkSamples)
            guard !chunk.isEmpty else { break }
            flushChunkIndex += 1
            ClaudeCodeSessionManager.log(
                "[ASR stream] finish chunk begin index=\(flushChunkIndex)/\(flushPlan.chunkCount) "
                + "samples=\(chunk.count) memoryMB=\(residentMemoryMBDescription())"
            )
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            do {
                try await session.feed(data)
            } catch {
                lastStreamEndedAbnormally = true
                pcmPending.discardAll()
                session.close()
                ClaudeCodeSessionManager.log(
                    "[ASR stream] finish chunk failed index=\(flushChunkIndex)/\(flushPlan.chunkCount) "
                    + "error=\(error.localizedDescription) → 整段 runASR"
                )
                return nil
            }
            ClaudeCodeSessionManager.log(
                "[ASR stream] finish chunk end index=\(flushChunkIndex)/\(flushPlan.chunkCount) "
                + "memoryMB=\(residentMemoryMBDescription())"
            )
        }
        // ★ 流式 finish 加超时:receiveMessage 底层无超时,服务端半死(不回包也不发 close,
        //   典型 Clash 半开连接)会让 session.finish() 永久挂起 → 永远卡「识别中」。
        //   超时即关会话 + 返 nil,上层回落整段 runASR(自带 15s 超时 + 本地兜底)。
        let final: String?
        do {
            final = try await withTimeout(seconds: 12) { try await session.finish() }
            ClaudeCodeSessionManager.log("[ASR stream] finish finalLen=\(final?.count ?? -1) text='\((final ?? "").prefix(80))'")
        } catch {
            lastStreamEndedAbnormally = true   // 收尾超时也算云端降速 → 整段给宽限时间
            ClaudeCodeSessionManager.log("[ASR stream] finish 超时/失败(\(error.localizedDescription))→ 关会话,回落整段 runASR(宽限)")
            session.close()
            return nil
        }
        // 服务端 8s 收包超时(45000081)截断 → final 是残缺前几字,丢弃,回落整段
        // (整段单请求单响应,无逐包超时约束,网络抖动下往往仍能成;再不行本地兜底)。
        if session.endedAbnormally {
            lastStreamEndedAbnormally = true   // 云端不健康 → 回落路径优先本地
            ClaudeCodeSessionManager.log("[ASR stream] 服务端异常截断 → 丢弃残缺定稿 '\(final ?? "")'(len=\(final?.count ?? 0)),回落(优先本地)")
            return nil
        }
        return final
    }

    /// 通用超时:op 与 sleep 竞速,谁先完成用谁;超时抛 ASRError.timeout。
    private func withTimeout<T: Sendable>(seconds: Double, _ op: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ASRError.timeout
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }

    /// 早退/丢弃路径(BLE RMS gate、abort、并发忽略):后台收尾流式会话(关 ws + 取消 task),
    /// 定稿结果丢弃。复用 finishStreaming 的标准收尾,避免会话/WebSocket 泄漏(静态盲区 #7)。
    private func discardStreamingIfActive() {
        guard let session = streamingSession else { return }
        audioCapture.onPCMChunk = nil
        bleManager?.onPCMChunk = nil
        feedPump?.cancel()
        feedPump = nil
        streamingSession = nil
        if projectStreamingSession === session { projectStreamingSession = nil }
        streamStarted = false
        streamSawPartialText = false
        pcmPending.discardAll()
        session.close()   // 直接关连接(不发收尾包),彻底释放,避免泄漏占满并发
    }

    private func residentMemoryMBDescription() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return "--" }
        return String(format: "%.1f", Double(info.resident_size) / 1_048_576.0)
    }

    // MARK: - Microphone Recording

    private func startRecording(intent: VoiceIntent = .asrInject) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard !UITestFlags.isHeadless else {
                activeIntent = nil
                activeCapsuleSession = nil
                state = .error(AppL10n.tr("麦克风权限未授权"))
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.startRecording(intent: intent)
                    } else {
                        self.activeIntent = nil
                        self.activeCapsuleSession = nil
                        self.state = .error(AppL10n.tr("麦克风权限未授权"))
                    }
                }
            }
            return
        default:
            activeIntent = nil
            activeCapsuleSession = nil
            state = .error(AppL10n.tr("麦克风权限未授权"))
            return
        }

        do {
            try audioCapture.startRecording()
            state = .recording
            // 全局快捷键触发沿用旧行为——徽章保持隐藏，避免历史快捷键用户的视觉变化。
            let suppress = (activeTriggerSource == .hotkey)
            switch intent {
            case .asrInject: activeCapsuleSession = overlayController.showButtonA(suppressBadge: suppress)
            }
            startStreamingIfSupported(context: buildASRContextForButtonA(), capsuleSession: activeCapsuleSession)
        } catch {
            activeIntent = nil
            activeCapsuleSession = nil
            state = .error(error.localizedDescription)
        }
    }

    private func stopAndRecognize(intent: VoiceIntent = .asrInject) {
        let wavData = audioCapture.stopRecording()
        state = .processing
        let capsuleSession = activeCapsuleSession
        overlayController.showProcessing(engine: currentEngineLabel(), session: capsuleSession)
        // source 仅用于历史归因，统一为 .microphone。
        let trigger = activeTriggerSource
        recognitionTask = Task {
            // 流式活跃：finish 出定稿→编辑器(走与离线一致的 presentEditor);
            // 非流式 finishStreaming 返 nil,走现有整段 runASR(本地 offline 零回归)。
            if let final = await finishStreaming() {
                if Task.isCancelled { return }   // 用户已中断
                if !final.isEmpty {
                    overlayController.setSource(streamingMethodLabel, session: capsuleSession)
                    await presentEditor(text: final, source: .microphone, trigger: trigger, method: streamingMethodLabel, capsuleSession: capsuleSession)
                } else if let fb = await fallbackLocalASR(wavData, context: buildASRContextForButtonA()) {
                    // 豆包流式返空 → 本地 FunASR 兜底一次。
                    overlayController.setSource(AppL10n.tr("豆包失败·本地兜底"), session: capsuleSession)
                    await presentEditor(text: fb, source: .microphone, trigger: trigger, method: AppL10n.tr("豆包失败·本地兜底"), capsuleSession: capsuleSession)
                } else {
                    overlayController.dismissOrRestoreEditing(session: capsuleSession)
                }
                activeButton = .none
                activeIntent = nil
                activeCapsuleSession = nil
                state = .idle
                return
            }
            recognizeWAV(wavData, source: .microphone, capsuleSession: capsuleSession)
        }
    }

    // MARK: - Shared ASR

    func runASR(_ wavData: Data, context: ASRContext = ASRContext(), timeout: Double = 15) async throws -> String {
        let normalized = normalizeWAV(wavData)
        ClaudeCodeSessionManager.log("[ASR] engine=\(asrEngine.rawValue) wavData=\(wavData.count)→\(normalized.count) bytes hotwords=\(context.hotwords.count) dialogCtx=\(context.dialogContext.count)")
        let engine = asrEngine
        let ak = appKey
        let ack = accessKey
        let punc = enablePunctuation
        let ddc = doubaoEnableDDC
        let itn = doubaoEnableITN
        let ctx = context
        let funasr = self.funasrEngine
        let englishModelDirectory = self.englishModelManager?.installedDirectory()
        let englishEngine = self.sherpaEnglishEngine
        // 本地引擎:把当前 Claude Code 上下文热词数同步给 UI(@Published)
        if engine == .local {
            localHotwordCount = ctx.hotwords.count
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                switch engine {
                case .doubao:
                    let client = DoubaoASRClient(appKey: ak, accessKey: ack, enablePunc: punc,
                                                 enableDDC: ddc, enableITN: itn,
                                                 hotwords: ctx.hotwords.map(\.cloudPayload), dialogContext: ctx.dialogContext)
                    return try await client.recognize(wavData: normalized)
                case .local:
                    guard let funasr else { throw FunASRSeacoError.modelNotReady }
                    // 热词动态刷新(hash 比对,变了只重算 model_eb,毫秒级,不重建声学主干)
                    await funasr.reloadHotwordsIfChanged(ctx.hotwords)
                    return try await funasr.recognize(wavData: normalized)   // 本期无标点后处理(SeACo 无内置标点)
                case .localEnglish:
                    guard let englishModelDirectory else { throw SherpaEnglishError.modelNotReady }
                    try await englishEngine.prepare(
                        modelDirectory: englishModelDirectory,
                        hotwords: ctx.hotwords
                    )
                    return try await englishEngine.recognize(wavData: normalized)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ASRError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// 「识别中」用户中断(ESC×2 / ✕):取消在途识别任务 + 关流式会话 + 复位状态。
    /// 浮窗收起由 controller.confirmedDismiss 负责;这里只管后端中止。
    func cancelActiveRecognition() {
        ClaudeCodeSessionManager.log("[ASR] 用户中断识别(ESC×2/✕)→ 取消任务 + 关流式")
        recognitionTask?.cancel()
        recognitionTask = nil
        discardStreamingIfActive()   // 关 ws + 取消 feed pump(若流式还活着)
        activeButton = .none
        activeIntent = nil
        activeCapsuleSession = nil
        while discardPendingButtonARecording() != nil {}
        state = .idle
    }

    /// 当前识别将用哪个引擎(供标题栏「xx 识别中」展示)。
    /// 流式会话还在 → 豆包流式;否则按选定引擎给整段标签。
    /// 流式定稿来源标签(引擎相关)。
    private var streamingMethodLabel: String {
        switch asrEngine {
        case .local: AppL10n.tr("本地中文流式")
        case .localEnglish: AppL10n.tr("本地英文流式")
        case .doubao: AppL10n.tr("豆包流式")
        }
    }

    private func currentEngineLabel() -> String {
        if streamingSession != nil { return streamingMethodLabel }
        switch asrEngine {
        case .doubao: return AppL10n.tr("豆包云端")
        case .local: return AppL10n.tr("本地中文 ASR")
        case .localEnglish: return AppL10n.tr("本地英文 ASR")
        }
    }

    /// 跨引擎兜底:豆包(流式/整段)失败或返空时,用本地 FunASR 整段识别一次。
    /// - 仅当本地模型**已下载**(modelManager.state == .ready)才可兜底;未下载返 nil(无兜底)。
    /// - 引擎句柄未加载则**懒加载**一次(prepare 双图,数秒级,仅首次)。
    /// - 返回非空文本表示兜底成功;nil 表示无兜底/兜底也失败,调用方按原"空结果"处理。
    func fallbackLocalASR(_ wavData: Data, context: ASRContext) async -> String? {
        guard let funasr = funasrEngine else {
            ClaudeCodeSessionManager.log("[ASR fallback] funasrEngine=nil → 无兜底")
            return nil
        }
        // 模型必须已下载,否则无法兜底(避免触发下载阻塞识别)。
        if modelManager?.state != .ready {
            await modelManager?.checkLocalState()
            guard modelManager?.state == .ready else {
                ClaudeCodeSessionManager.log("[ASR fallback] 本地模型未下载就绪 → 无兜底")
                return nil
            }
        }
        do {
            if funasr.loadState != .ready {
                try await funasr.prepare(hotwords: context.hotwords)   // 懒加载双图(仅首次)
            }
            await funasr.reloadHotwordsIfChanged(context.hotwords)
            let normalized = normalizeWAV(wavData)
            let t = try await funasr.recognize(wavData: normalized)
            ClaudeCodeSessionManager.log("[ASR fallback] 本地兜底 len=\(t.count) text='\(t.prefix(40))'")
            return t.isEmpty ? nil : t
        } catch {
            ClaudeCodeSessionManager.log("[ASR fallback] 本地兜底失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 给 asrEngine setter 复用的快速热词快照(不含 history 自动提炼,避免 setter 跑大循环)
    private func currentHotwordList() -> [ASRHotword] {
        buildHotwords()
    }

    // MARK: - ASR Context Builders

    private static let customHotwordLimit = 20
    private static let learnedHotwordLimit = 30
    private static let projectHotwordCandidateLimit = 50
    private static let projectHotwordLimit = 25
    private static let defaultHotwordLimit = 10
    private static let customHotwordWeight = 30
    private static let learnedHotwordWeight = 25
    private static let projectHotwordWeight = 20
    private static let defaultHotwordWeight = 10

    /// 内置编程场景热词
    private static let defaultHotwords = ["Claude", "Claude Code", "Codex", "Git", "GitHub", "JSON", "API", "CLI", "TypeScript", "Python"]

    func buildASRContextForButtonA(includeProjectHotwords: Bool = true) -> ASRContext {
        // Dialog context: recent successful recognition texts
        let recentTexts = historyManager?.records
            .filter { $0.isSuccess && !$0.text.isEmpty }
            .prefix(5)
            .map { $0.text } ?? []

        let hotwords = buildHotwords(includeProjectHotwords: includeProjectHotwords)

        return ASRContext(hotwords: hotwords, dialogContext: Array(recentTexts))
    }

    private func buildHotwords(includeProjectHotwords: Bool = true) -> [ASRHotword] {
        var hotwordMap: [String: ASRHotword] = [:]
        var order: [String] = []

        addHotwords(
            ASRHotwordInputParser.parse(customHotwords, limit: Self.customHotwordLimit),
            limit: Self.customHotwordLimit,
            weight: Self.customHotwordWeight,
            into: &hotwordMap,
            order: &order
        )

        let learnedHotwords = RecognitionBoostStore.shared.activeHotwords(limit: Self.learnedHotwordLimit)
        let projectHotwords = includeProjectHotwords
            ? filteredProjectHotwords(currentProjectHotwords(limit: Self.projectHotwordCandidateLimit))
            : []
        addHotwords(
            learnedHotwords,
            limit: Self.learnedHotwordLimit,
            weight: Self.learnedHotwordWeight,
            into: &hotwordMap,
            order: &order
        )

        addHotwords(
            projectHotwords,
            limit: Self.projectHotwordLimit,
            weight: Self.projectHotwordWeight,
            into: &hotwordMap,
            order: &order
        )

        addHotwords(
            Self.defaultHotwords,
            limit: Self.defaultHotwordLimit,
            weight: Self.defaultHotwordWeight,
            into: &hotwordMap,
            order: &order
        )

        if RecognitionBoostSettings.enabled {
            logRecognitionBoostInjection(learnedHotwords: learnedHotwords, totalHotwords: hotwordMap.count)
        }
        if RecognitionBoostSettings.enabled || !projectHotwords.isEmpty {
            ClaudeCodeSessionManager.log("[ASR] projectHotwords=\(projectHotwords.count) totalContextHotwords=\(hotwordMap.count) words=\(projectHotwords.joined(separator: "|"))")
        }

        return order.compactMap { hotwordMap[$0] }
    }

    private func hotwordSignature(_ hotwords: [ASRHotword]) -> String {
        hotwords.map { "\($0.word.lowercased()):\($0.weight)" }.sorted().joined(separator: "\n")
    }

    private func addHotwords(_ words: [String], limit: Int, weight: Int, into hotwordMap: inout [String: ASRHotword], order: inout [String]) {
        for raw in words.lazy.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }).prefix(limit) {
            let key = raw.lowercased()
            if let existing = hotwordMap[key] {
                hotwordMap[key] = ASRHotword(word: existing.word, weight: max(existing.weight, weight))
            } else {
                hotwordMap[key] = ASRHotword(word: raw, weight: weight)
                order.append(key)
            }
        }
    }

    private func currentProjectHotwords(limit: Int) -> [String] {
        let session: HookSession?
        switch InputRouter.currentMode() {
        case .exclusive(let sid):
            session = InputRouter.sessionResolver?(sid)
        case .free:
            session = InputRouter.activeSessionResolver?()
        }
        guard let session else { return [] }
        return ProjectHotwordProvider.hotwords(for: session, limit: limit)
    }

    private func filteredProjectHotwords(_ words: [String]) -> [String] {
        let lowValue: Set<String> = [
            "foundation", "swiftui", "button", "string", "codable", "int", "bool",
            "input", "output", "display", "iconname", "displayname", "right",
            "left", "top", "bottom", "state", "phase", "record", "processing"
        ]
        var seen = Set<String>()
        var kept: [String] = []
        for word in words {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = clean.lowercased()
            guard !clean.isEmpty, !lowValue.contains(key), seen.insert(key).inserted else { continue }
            kept.append(clean)
            if kept.count >= Self.projectHotwordLimit { break }
        }
        return kept
    }

    private func logRecognitionBoostInjection(learnedHotwords: [String], totalHotwords: Int) {
        var msg = "[RecognitionBoost] active hotwords injected learned=\(learnedHotwords.count) totalContextHotwords=\(totalHotwords)"
        if ProcessInfo.processInfo.environment["QVH_RECOGNITION_BOOST_DEBUG"] == "1", !learnedHotwords.isEmpty {
            msg += " words=\(learnedHotwords.prefix(20).joined(separator: "|"))"
            if learnedHotwords.count > 20 { msg += "|..." }
        }
        ClaudeCodeSessionManager.log(msg)
    }

    private func shortErrorMessage(_ error: Error) -> String {
        if let asrErr = error as? ASRError {
            switch asrErr {
            case .timeout: return "ASR Timeout"
            case .serverError: return "Server Error"
            case .missingCredentials: return "No Credentials"
            case .invalidAudio: return "Bad Audio"
            case .invalidURL: return "Invalid URL"
            case .unexpectedMessage: return "Bad Response"
            }
        }
        return "ASR Failed"
    }

    private func diagnosticModelState(_ state: ModelDownloadState) -> String {
        switch state {
        case .notDownloaded: return "notDownloaded"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    private func diagnosticRoutingMode() -> String {
        InputRouter.currentMode().isExclusive ? "exclusive" : "free"
    }

    private func analyticsLocalModelState() -> String {
        switch modelManager?.state {
        case .notDownloaded: return "not_downloaded"
        case .downloading, .verifying: return "downloading"
        case .ready: return "ready"
        case .failed: return "failed"
        case nil: return "unknown"
        }
    }

    private func analyticsLocalModelVersion() -> String {
        modelManager?.manifest?.version ?? "unknown"
    }

    private func analyticsDeviceType() -> String {
        guard let type = bleManager?.diagnosticDeviceType else { return "none" }
        if type == DeviceType.micPad.rawValue { return "micpad" }
        if type == DeviceType.stickS3.rawValue { return "sticks3" }
        return "unknown"
    }

    private func analyticsErrorKind(_ error: Error?) -> String {
        guard let error else { return "none" }
        if error is CancellationError { return "cancelled" }
        if let asrError = error as? ASRError {
            switch asrError {
            case .missingCredentials: return "asr_missing_credentials"
            case .invalidAudio: return "mic_unavailable"
            case .serverError: return "asr_server_error"
            case .timeout: return "timeout"
            case .invalidURL, .unexpectedMessage: return "unknown"
            }
        }
        if let localError = error as? FunASRSeacoError {
            switch localError {
            case .modelNotReady: return "asr_model_not_ready"
            case .invalidAudio: return "mic_unavailable"
            case .engineInitFailed, .recognitionFailed: return "unknown"
            }
        }
        return "unknown"
    }

    private func historySourceName(for source: RecognitionSource) -> String? {
        guard source == .bleDevice else { return nil }
        // T-033:与系统麦记录("系统麦克风 · X")对称,设备麦记录也带音源前缀
        return AppL10n.tr("设备麦克风 · ") + (bleManager?.connectedDeviceName ?? bleManager?.memorizedDeviceName ?? "MicPad")
    }

    private func handleASRError(
        _ error: Error,
        source: RecognitionSource,
        buttonId: UInt8,
        wavData: Data,
        recordId: UUID?,
        fallbackUsed: String = "none"
    ) {
        if case .serverError(let code, let msg) = error as? ASRError {
            ClaudeCodeSessionManager.log("[ASR] ERROR: code=\(code), msg=\(msg ?? [:])")
        } else {
            ClaudeCodeSessionManager.log("[ASR] ERROR: \(error.localizedDescription)")
        }
        let context = buildASRContextForButtonA()
        DiagnosticsReporter.capture(DiagnosticsReporter.asrFailure(
            error: error,
            source: source,
            engine: asrEngine,
            buttonId: buttonId,
            wavBytes: wavData.count,
            hotwordCount: context.hotwords.count,
            dialogContextCount: context.dialogContext.count,
            fallbackUsed: fallbackUsed,
            modelState: diagnosticModelState(modelManager?.state ?? .notDownloaded),
            streamingModelState: diagnosticModelState(modelManager?.streamingState ?? .notDownloaded),
            bleConnected: bleManager?.connectionState == .connected,
            deviceProtocolVersion: Int(bleManager?.deviceProtocolVersion ?? 0),
            deviceType: bleManager?.diagnosticDeviceType ?? "unknown",
            deviceUUID: bleManager?.diagnosticDeviceUUID,
            routingMode: diagnosticRoutingMode(),
            axTrusted: AXIsProcessTrusted(),
            secureInputEnabled: KeyboardSimulator.isSecureInputEnabled
        ))
        let shortMsg = shortErrorMessage(error)
        if let recordId {
            historyManager?.markFailed(recordId, error: shortMsg, wavData: wavData)
        } else {
            _ = historyManager?.addFailedRecord(
                error: shortMsg,
                source: source,
                wavData: wavData,
                sourceName: historySourceName(for: source)
            )
        }
        if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
            bleManager?.sendASRNotification(success: false, buttonId: buttonId, errorMessage: shortMsg)
        } else {
            bleManager?.sendVoiceState(0x05, errorMessage: shortMsg)
        }
    }

    /// Legacy recognizeWAV for mic input
    func recognizeWAV(_ wavData: Data, source: RecognitionSource = .microphone, capsuleSession: RecordingOverlayController.CapsuleSessionID? = nil) {
        if state != .processing {
            state = .processing
        }
        let analyticsStartedAt = Date()
        let analyticsDeviceTypeForSource = source == .bleDevice ? analyticsDeviceType() : "none"
        let analyticsDeviceProtocolForSource = source == .bleDevice ? Int(bleManager?.deviceProtocolVersion ?? 0) : 0
        AnalyticsClient.shared.captureRecordingResult(source: source.rawValue, result: "success", errorKind: "none", triggerSource: activeTriggerSource.rawValue)
        overlayController.showProcessing(engine: currentEngineLabel(), session: capsuleSession)
        let buttonId: UInt8 = 0x01

        recognitionTask = Task {
            do {
                let asrContext = buildASRContextForButtonA()
                // 流式被服务端异常截断说明云端降速但可用 → 整段给 25s 宽限(闪电说同期整段 10s 能成)。
                let segTimeout: Double = lastStreamEndedAbnormally ? 25 : 15
                lastStreamEndedAbnormally = false
                let text = try await runASR(wavData, context: asrContext, timeout: segTimeout)
                if Task.isCancelled { return }   // 用户已中断
                lastRecognizedText = text
                ClaudeCodeSessionManager.log("[recognizeWAV] Text='\(String(text.prefix(80)))' isEmpty=\(text.isEmpty) source=\(source.rawValue)")
                var analyticsTextLength = AnalyticsSupport.speechTextUnits(text)
                var analyticsResult = text.isEmpty ? "failure" : "success"
                var analyticsErrorKind = text.isEmpty ? "asr_empty_result" : "none"
                var analyticsFallback = "none"
                if !text.isEmpty {
                    let method = asrEngine == .doubao ? AppL10n.tr("豆包云端") : AppL10n.tr("本地")
                    overlayController.setSource(method, session: capsuleSession)
                    // 不再直接注入:灌入可编辑浮窗,Enter 才走原有注入链。
                    // 路由按 activeTriggerSource 分派——source 只管历史归因。
                    // 时序安全：activeTriggerSource 在 toggleRecording 的 .idle 分支
                    // 才会写入，录音中同 intent 二次触发走 stopAndRecognize,因此
                    // Task 闭包读取时不会被覆写（在此快照传入 presentEditor）。
                    await presentEditor(text: text, source: source, trigger: activeTriggerSource, method: method, capsuleSession: capsuleSession)
                } else if asrEngine == .doubao, let fb = await fallbackLocalASR(wavData, context: asrContext) {
                    // 豆包整段返空 → 本地兜底。
                    if Task.isCancelled { return }
                    analyticsTextLength = AnalyticsSupport.speechTextUnits(fb)
                    analyticsResult = "success"
                    analyticsErrorKind = "none"
                    analyticsFallback = "local_asr"
                    overlayController.setSource(AppL10n.tr("豆包失败·本地兜底"), session: capsuleSession)
                    await presentEditor(text: fb, source: source, trigger: activeTriggerSource, method: AppL10n.tr("豆包失败·本地兜底"), capsuleSession: capsuleSession)
                } else {
                    overlayController.dismissOrRestoreEditing(session: capsuleSession)
                }
                if Task.isCancelled { return } // 等待回退或编辑器期间取消，不计入完成量。
                AnalyticsClient.shared.captureASRResult(
                    engine: asrEngine,
                    result: analyticsResult,
                    errorKind: analyticsErrorKind,
                    durationSeconds: Date().timeIntervalSince(analyticsStartedAt),
                    textLength: analyticsTextLength,
                    localModelState: analyticsLocalModelState(),
                    fallbackUsed: analyticsFallback,
                    source: source.rawValue,
                    triggerSource: activeTriggerSource.rawValue,
                    deviceType: analyticsDeviceTypeForSource,
                    deviceProtocolVersion: analyticsDeviceProtocolForSource,
                    localModelVersion: analyticsLocalModelVersion()
                )
                if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                    bleManager?.sendASRNotification(success: true, buttonId: buttonId)
                } else {
                    bleManager?.sendVoiceState(0x04)
                }
                // 编辑器要驻留等用户提交，原 overlayController.dismiss() 已删除。
                activeButton = .none
                activeIntent = nil
                if source == .microphone { activeCapsuleSession = nil }
                state = .idle
            } catch {
                if error is CancellationError || Task.isCancelled { return }   // 用户中断:静默退出
                // 豆包整段抛错 → 先试本地兜底,成功则灌编辑器,不进错误态。
                if asrEngine == .doubao, let fb = await fallbackLocalASR(wavData, context: buildASRContextForButtonA()) {
                    if Task.isCancelled { return }
                    AnalyticsClient.shared.captureASRResult(
                        engine: asrEngine,
                        result: "success",
                        errorKind: "none",
                        durationSeconds: Date().timeIntervalSince(analyticsStartedAt),
                        textLength: AnalyticsSupport.speechTextUnits(fb),
                        localModelState: analyticsLocalModelState(),
                        fallbackUsed: "local_asr",
                        source: source.rawValue,
                        triggerSource: activeTriggerSource.rawValue,
                        deviceType: analyticsDeviceTypeForSource,
                        deviceProtocolVersion: analyticsDeviceProtocolForSource,
                        localModelVersion: analyticsLocalModelVersion()
                    )
                    overlayController.setSource(AppL10n.tr("豆包失败·本地兜底"), session: capsuleSession)
                    await presentEditor(text: fb, source: source, trigger: activeTriggerSource, method: AppL10n.tr("豆包失败·本地兜底"), capsuleSession: capsuleSession)
                    if (bleManager?.deviceProtocolVersion ?? 0) >= 2 {
                        bleManager?.sendASRNotification(success: true, buttonId: buttonId)
                    } else {
                        bleManager?.sendVoiceState(0x04)
                    }
                    activeButton = .none
                    activeIntent = nil
                    if source == .microphone { activeCapsuleSession = nil }
                    state = .idle
                    return
                }
                if Task.isCancelled { return } // 回退失败也可能源于取消。
                AnalyticsClient.shared.captureASRResult(
                    engine: asrEngine,
                    result: "failure",
                    errorKind: analyticsErrorKind(error),
                    durationSeconds: Date().timeIntervalSince(analyticsStartedAt),
                    textLength: 0,
                    localModelState: analyticsLocalModelState(),
                    fallbackUsed: asrEngine == .doubao ? "local_asr_failed" : "none",
                    source: source.rawValue,
                    triggerSource: activeTriggerSource.rawValue,
                    deviceType: analyticsDeviceTypeForSource,
                    deviceProtocolVersion: analyticsDeviceProtocolForSource,
                    localModelVersion: analyticsLocalModelVersion()
                )
                handleASRError(
                    error,
                    source: source,
                    buttonId: buttonId,
                    wavData: wavData,
                    recordId: nil,
                    fallbackUsed: asrEngine == .doubao ? "local_asr_failed" : "none"
                )
                // 错误态:浮窗转错误样式 + 重试按钮（走现有 runASR 重跑），不立即 dismiss。
                let wav = wavData
                overlayController.showError(shortErrorMessage(error), session: capsuleSession) { [weak self] in
                    self?.retryRecognition(wav: wav, source: source, buttonId: buttonId)
                }
                activeButton = .none
                activeIntent = nil
                state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(3))
                if case .error = state { state = .idle }
            }
        }
    }

    /// 胶囊模式定稿分发(REQ-012):出错重试成功 → 显示文本+复制(不注入);否则 → 展示定稿 + 自动注入。
    private func deliverCapsule(_ text: String, session: RecordingOverlayController.CapsuleSessionID?, inject: () -> Void) {
        if overlayController.capsuleRetryPending {
            overlayController.showCapsuleCopy(text, session: session)
        } else {
            if overlayController.showCapsuleFinal(text, session: session) {
                inject()
            }
        }
    }

    private func postprocessRecognizedText(
        _ rawText: String,
        trackHotwordUse: Bool = true,
        engine: ASREngine? = nil
    ) -> ProcessedRecognitionText {
        let recognitionEngine = engine ?? asrEngine
        // ChineseITN is intentionally bypassed for the English engine. It contains
        // Chinese numeral/date rules and can corrupt English technical dictation.
        let itn = recognitionEngine == .localEnglish
            ? rawText
            : RecognitionPunctuationPostProcessor.apply(ITNPostProcessor.apply(rawText))
        let hotwords = buildHotwords()
        let projectHotwords = filteredProjectHotwords(currentProjectHotwords(limit: Self.projectHotwordCandidateLimit))
        let projectKeys = Set(projectHotwords.map { $0.lowercased() })
        let programming = ProgrammingTextPostProcessor.analyze(itn, terms: hotwords.map(\.word))
        let learning = programming.text
        var usedLearnedHotwords = false
        let display = RecognitionBoostPostProcessor.apply(
            learning,
            hotwords: RecognitionBoostStore.shared.activeHotwordRecords(limit: 100)
        ) { used in
            usedLearnedHotwords = !used.isEmpty
            if trackHotwordUse {
                RecognitionBoostStore.shared.markHotwordsUsed(used)
            }
        }
        return (
            learning,
            display,
            rawText,
            itn,
            learning,
            hotwords.count,
            programming.replacedTerms.contains { projectKeys.contains($0.lowercased()) },
            usedLearnedHotwords,
            nil,
            nil,
            nil,
            nil
        )
    }

    private func maybePolishRecognizedText(_ processed: ProcessedRecognitionText) async -> ProcessedRecognitionText {
        guard deepseekPostprocessEnabled,
              !processed.display.isEmpty,
              !DeepSeekPostProcessor.shouldSkip(processed.display) else { return processed }
        let configuration = FastLLMConfiguration.load()
        guard configuration.isConfigured else { return processed }
        do {
            let result = try await DeepSeekPostProcessor(
                apiKey: configuration.apiKey,
                baseURL: configuration.baseURL,
                model: configuration.model,
                timeoutSeconds: configuration.timeoutSeconds
            ).polish(processed.display)
            return (
                processed.learning,
                result.text,
                processed.raw,
                processed.itn,
                processed.programming,
                processed.hotwordCount,
                processed.usedProjectHotwords,
                processed.usedLearnedHotwords,
                result.text,
                result.elapsedMs,
                result.model,
                nil
            )
        } catch {
            ClaudeCodeSessionManager.log("[DeepSeekPostprocess] fallback: \(error.localizedDescription)")
            return (
                processed.learning,
                processed.display,
                processed.raw,
                processed.itn,
                processed.programming,
                processed.hotwordCount,
                processed.usedProjectHotwords,
                processed.usedLearnedHotwords,
                nil,
                nil,
                configuration.model,
                error.localizedDescription
            )
        }
    }

    private func updateHistoryTrace(
        recordId: UUID,
        processed: ProcessedRecognitionText,
        method: String,
        audioId: String? = nil
    ) {
        let postprocessStrategy = processed.llmText == nil && processed.llmError == nil ? "normal+programming" : "normal+programming+deepseek-faithful"
        historyManager?.updateProcessingTrace(
            recordId,
            rawText: processed.raw,
            itnText: processed.itn,
            programmingText: processed.programming,
            finalText: processed.display,
            engine: method.isEmpty ? asrEngine.rawValue : method,
            strategy: postprocessStrategy,
            hotwordCount: processed.hotwordCount,
            usedProjectHotwords: processed.usedProjectHotwords,
            usedLearnedHotwords: processed.usedLearnedHotwords,
            audioId: audioId,
            llmText: processed.llmText,
            llmMs: processed.llmMs,
            llmModel: processed.llmModel,
            llmError: processed.llmError
        )
    }

    private func beginRecognitionRevision(asrText text: String) {
        guard RecognitionBoostSettings.enabled, !text.isEmpty else { return }
        pendingRecognitionRevision = .init(
            id: UUID(),
            segments: [.init(id: UUID(), asrText: text, createdAt: Date())],
            createdAt: Date()
        )
    }

    private func appendRecognitionRevision(asrText text: String) {
        guard RecognitionBoostSettings.enabled, !text.isEmpty else { return }
        discardExpiredRecognitionRevision()
        guard pendingRecognitionRevision != nil else {
            beginRecognitionRevision(asrText: text)
            return
        }
        pendingRecognitionRevision?.segments.append(.init(id: UUID(), asrText: text, createdAt: Date()))
    }

    private func finishRecognitionRevision(edited: String) {
        guard RecognitionBoostSettings.enabled else {
            discardRecognitionRevision()
            return
        }
        discardExpiredRecognitionRevision()
        guard let revision = pendingRecognitionRevision else { return }
        defer { pendingRecognitionRevision = nil }
        let asrFullText = revision.segments.map(\.asrText).joined()
        guard !edited.isEmpty, edited != asrFullText else { return }
        RecognitionBoostLearner.learn(
            id: revision.id,
            segments: revision.segments,
            createdAt: revision.createdAt,
            revisedText: edited,
            source: "editor"
        )
    }

    private func discardRecognitionRevision() {
        pendingRecognitionRevision = nil
    }

    private func discardExpiredRecognitionRevision() {
        guard let pendingRecognitionRevision,
              Date().timeIntervalSince(pendingRecognitionRevision.createdAt) > 600 else { return }
        self.pendingRecognitionRevision = nil
        ClaudeCodeSessionManager.log("[RecognitionBoost] pending expired")
    }

    /// 识别定稿 → 灌入可编辑浮窗;Enter 才走原有注入链(触发源语义不变)。
    /// 抽出复用于首次成功 + 重试成功,避免重复。
    /// 入口先过 ITN + 识别增强后处理(本地/豆包统一,幂等)。
    private func presentEditor(text rawText: String, source: RecognitionSource, trigger: VoiceTriggerSource, method: String = "", capsuleSession: RecordingOverlayController.CapsuleSessionID? = nil) async {
        let processed = postprocessRecognizedText(rawText)
        let polished = await maybePolishRecognizedText(processed)
        if Task.isCancelled { return }
        lastRecognizedText = polished.display   // 覆盖入口处的原始值,保证两条入口存的都是后处理文本
        let record = historyManager?.addRecord(polished.display, source: source, method: method, sourceName: historySourceName(for: source))
        if let record {
            updateHistoryTrace(recordId: record.id, processed: polished, method: method)
        }
        // 胶囊模式(REQ-012):识别即输入——展示定稿 + 自动注入(重试成功则改为复制,不注入)。
        if overlayController.isCapsuleMode {
            deliverCapsule(polished.display, session: capsuleSession) {
                // hotkey free 模式仍输入当前光标；exclusive 模式直通选中 CLI。
                InputRouter.routeASRText(polished.display, learningText: polished.learning, source: .hotkey)
            }
            return
        }
        // ② 编辑会话开着则追加不清空(沿用首次 showEditor 注入闭包),否则首次 showEditor。
        if overlayController.editorSessionActive {
            appendRecognitionRevision(asrText: polished.learning)
            overlayController.appendText(polished.display)
            return
        }
        beginRecognitionRevision(asrText: polished.learning)
        overlayController.showEditor(text: polished.display) { edited in
            guard !edited.isEmpty else { return }
            // 现状语义:hotkey 总在当前光标处 typeText（free 模式）。
            KeyboardSimulator.typeText(edited)
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "free",
                targetKind: "other",
                result: KeyboardSimulator.hasAccessibilityPermission ? "success" : "failure",
                errorKind: KeyboardSimulator.hasAccessibilityPermission ? "none" : "permission_denied",
                textLength: edited.count,
                source: "asr"
            )
        }
    }

    /// 错误态重试:复用现有 runASR 重跑路径(不新造 ASR 调用),成功则灌编辑器。
    private func retryRecognition(wav: Data, source: RecognitionSource, buttonId: UInt8) {
        let capsuleSession = activeCapsuleSession
        overlayController.showProcessing(session: capsuleSession)
        Task {
            do {
                let t = try await runASR(wav, context: buildASRContextForButtonA())
                if !t.isEmpty {
                    await presentEditor(text: t, source: source, trigger: activeTriggerSource, capsuleSession: capsuleSession)
                } else {
                    overlayController.dismissOrRestoreEditing(session: capsuleSession)
                }
            } catch {
                handleASRError(error, source: source, buttonId: buttonId, wavData: wav, recordId: nil)
                overlayController.showError(shortErrorMessage(error), session: capsuleSession) { [weak self] in
                    self?.retryRecognition(wav: wav, source: source, buttonId: buttonId)
                }
            }
        }
    }

    // MARK: - Normalize WAV

    private func normalizeWAV(_ wavData: Data) -> Data {
        guard wavData.count > 44 else { return wavData }
        let headerData = wavData.prefix(44)
        let pcmData = wavData.suffix(from: 44)

        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return wavData }
        var samples = [Int16](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { buf in
            let src = buf.bindMemory(to: Int16.self)
            for i in 0..<sampleCount { samples[i] = src[i] }
        }

        var peak: Int16 = 0
        for s in samples {
            let magnitude = s == Int16.min ? Int16.max : abs(s)
            peak = max(peak, magnitude)
        }
        guard peak > 0 else { return wavData }

        // Silence gate: skip normalization for very quiet audio (likely noise/silence)
        if peak < 500 {
            ClaudeCodeSessionManager.log("[Normalize] peak=\(peak) — skip (silence/noise)")
            return wavData
        }

        let targetPeak: Float = 29491.0
        let gain = targetPeak / Float(peak)
        guard gain > 1.2 else {
            ClaudeCodeSessionManager.log("[Normalize] peak=\(peak) gain=\(String(format: "%.2f", gain)) — skip (loud enough)")
            return wavData
        }
        let clampedGain = min(gain, 8.0)
        ClaudeCodeSessionManager.log("[Normalize] peak=\(peak) gain=\(String(format: "%.2f", clampedGain))")

        for i in 0..<sampleCount {
            let v = Float(samples[i]) * clampedGain
            samples[i] = Int16(max(-32768, min(32767, v)))
        }

        var result = Data(headerData)
        samples.withUnsafeBufferPointer { buf in
            result.append(UnsafeBufferPointer(start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self), count: buf.count * 2))
        }
        return result
    }

    // MARK: - Retry

    func retryRecord(_ record: RecognitionRecord) {
        guard !record.isSuccess || record.phase == .failed,
              let wavData = historyManager?.loadWavData(for: record.id) else { return }
        let recordId = record.id

        // Clear previous error state and start retry
        historyManager?.prepareForRetry(recordId)

        Task {
            do {
                let text = try await runASR(wavData)
                if !text.isEmpty {
                    let processed = postprocessRecognizedText(text, trackHotwordUse: false)
                    let polished = await maybePolishRecognizedText(processed)
                    historyManager?.updateRecordWithRetryResult(recordId, text: polished.display)
                    updateHistoryTrace(recordId: recordId, processed: polished, method: asrEngine.rawValue, audioId: recordId.uuidString)
                } else {
                    historyManager?.markCompleted(recordId)
                }
            } catch {
                let shortMsg = shortErrorMessage(error)
                historyManager?.updateRecordWithRetryError(recordId, error: shortMsg)
            }
        }
    }

    // MARK: - Bench

    /// ASRBench 专用入口：完整走 normalizeWAV → ASR → ITNPostProcessor，与 mic/BLE 路径等效。
    /// 新增识别入口必须挂 ITN，见 ITNPostProcessor.swift 挂载点说明。
    func recognizeForBench(wavData: Data, engineOverride: ASREngine? = nil) async -> BenchResponse {
        let engine = engineOverride ?? asrEngine
        let normalized = normalizeWAV(wavData)
        let context = buildASRContextForButtonA()
        let ak = appKey
        let ack = accessKey
        let punc = enablePunctuation
        let ddc = doubaoEnableDDC
        let itn = doubaoEnableITN
        let funasr = self.funasrEngine
        let englishModelDirectory = self.englishModelManager?.installedDirectory()
        let englishEngine = self.sherpaEnglishEngine
        let t0 = Date()

        do {
            let rawText = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    switch engine {
                    case .local:
                        guard let funasr else { throw FunASRSeacoError.modelNotReady }
                        let hotwords = context.hotwords
                        if await funasr.loadState != .ready {
                            try await funasr.prepare(hotwords: hotwords)
                        } else {
                            await funasr.reloadHotwordsIfChanged(hotwords)
                        }
                        return try await funasr.recognize(wavData: normalized)
                    case .localEnglish:
                        guard let englishModelDirectory else { throw SherpaEnglishError.modelNotReady }
                        try await englishEngine.prepare(
                            modelDirectory: englishModelDirectory,
                            hotwords: context.hotwords
                        )
                        return try await englishEngine.recognize(wavData: normalized)
                    case .doubao:
                        guard !ak.isEmpty, !ack.isEmpty else { throw ASRError.missingCredentials }
                        let client = DoubaoASRClient(appKey: ak, accessKey: ack,
                                                     enablePunc: punc, enableDDC: ddc, enableITN: itn,
                                                     hotwords: context.hotwords.map(\.cloudPayload), dialogContext: context.dialogContext)
                        return try await client.recognize(wavData: normalized)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw ASRError.timeout
                }
                let r = try await group.next()!
                group.cancelAll()
                return r
            }
            let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            let text = postprocessRecognizedText(
                rawText,
                trackHotwordUse: false,
                engine: engine
            ).display
            return BenchResponse(text: text, latencyMs: latencyMs, engine: engine.rawValue, error: "")
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            return BenchResponse(text: "", latencyMs: latencyMs, engine: engine.rawValue, error: error.localizedDescription)
        }
    }
}

/// T-018 Step A 功能冒烟:验证 FunTpass 2-pass 流式真能出结果。
/// 触发:`QVH_TPASS_SMOKE=1 [QVH_TPASS_WAV=…] <binary>`;跑完 exit,不进 GUI。
/// 默认模型:offline=SeACo(已下)、online/vad=tpass-smoke/(手放)、punc 跳过。
func runTpassSmokeIfRequested() {
    let env = ProcessInfo.processInfo.environment
    guard env["QVH_TPASS_SMOKE"] != nil else { return }
    func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    let home = NSHomeDirectory()
    let root = home + "/Library/Application Support/QuickVibeHost/models"
    let modelDir  = env["QVH_TPASS_MODEL_DIR"]  ?? (root + "/seaco-paraformer-zh-2024-2")
    let onlineDir = env["QVH_TPASS_ONLINE_DIR"] ?? (root + "/tpass-smoke/online")
    let vadDir    = env["QVH_TPASS_VAD_DIR"]    ?? (root + "/tpass-smoke/vad")
    let puncDir   = env["QVH_TPASS_PUNC_DIR"]   ?? (root + "/tpass-smoke/punc")   // 2pass 必需
    let wavPath   = env["QVH_TPASS_WAV"]        ?? "/tmp/tpass_test16k.wav"

    err("[tpass-smoke] init\n  model=\(modelDir)\n  online=\(onlineDir)\n  vad=\(vadDir)\n  punc=\(puncDir)")
    guard let ctx = funasr_tpass_init(modelDir, onlineDir, vadDir, puncDir, 1) else {
        err("[tpass-smoke] init FAILED (nil ctx)"); exit(2)
    }
    err("[tpass-smoke] init OK")
    // 热词:逗号或换行分隔(引擎约定换行);验收「热词 bias」用。
    let hotwords = (env["QVH_TPASS_HOTWORDS"] ?? "").replacingOccurrences(of: ",", with: "\n")
    _ = funasr_tpass_set_hotwords(ctx, hotwords)
    if !hotwords.isEmpty { err("[tpass-smoke] hotwords: \(hotwords.replacingOccurrences(of: "\n", with: " | "))") }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: wavPath)), data.count > 44 else {
        err("[tpass-smoke] wav read FAILED: \(wavPath)"); exit(3)
    }
    // 正确定位 'data' chunk(afconvert 的头可能含 FLLR 等额外 chunk,不止 44 字节)。
    var dataOff = 44
    let bytes = [UInt8](data)
    var p = 12
    while p + 8 <= bytes.count {
        let id = String(bytes: bytes[p..<p+4], encoding: .ascii) ?? ""
        let sz = Int(bytes[p+4]) | Int(bytes[p+5])<<8 | Int(bytes[p+6])<<16 | Int(bytes[p+7])<<24
        if id == "data" { dataOff = p + 8; break }
        p += 8 + sz + (sz & 1)
    }
    let pcm = data.subdata(in: dataOff..<data.count)
    let nSamples = pcm.count / 2
    let samples: [Int16] = pcm.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Int16.self).prefix(nSamples))
    }
    err(String(format: "[tpass-smoke] dataOff=%d samples=%d (%.1fs)", dataOff, nSamples, Double(nSamples) / 16000.0))

    // ① tpass 流式:累积在线 partial;② offline 段级定稿(累积)(chunk=3200=200ms,与真实 pump 一致)
    // QVH_TPASS_ROUNDS>1:同一 ctx 连跑多轮 + 轮间 reset —— 验收「连续 PTT 多句状态不串」。
    let rounds = max(1, Int(env["QVH_TPASS_ROUNDS"] ?? "1") ?? 1)
    var accumulated = ""
    var tpassFinal = ""
    for round in 1...rounds {
        accumulated = ""
        let chunk = 3200
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            let isFinal: Int32 = end >= samples.count ? 1 : 0
            let slice = Array(samples[i..<end])
            let s = slice.withUnsafeBufferPointer {
                funasr_tpass_feed(ctx, $0.baseAddress, Int32(slice.count), isFinal)
            }.map { String(cString: $0) } ?? ""
            if isFinal == 0, !s.isEmpty { accumulated += s }
            i = end
        }
        tpassFinal = funasr_tpass_definitive(ctx).map { String(cString: $0) } ?? ""   // 累积段级定稿
        if rounds > 1 {
            err("[round \(round)/\(rounds)] partial: \(accumulated)")
            err("[round \(round)/\(rounds)] final:   \(tpassFinal)")
        }
        if round < rounds { funasr_tpass_reset(ctx) }   // 与 LocalTpassStreamingSession.close 同路径
    }
    funasr_tpass_free(ctx)

    // ② 离线整段 SeACo(app 非流式路径,一次性喂全段)
    let seacoPuncDir = (modelDir as NSString).appendingPathComponent("punc")
    var offline = AppL10n.tr("<seaco init 失败>")
    if let sctx = funasr_seaco_init(modelDir, FileManager.default.fileExists(atPath: seacoPuncDir) ? seacoPuncDir : nil, 1) {
        _ = funasr_seaco_set_hotwords(sctx, "")
        offline = samples.withUnsafeBufferPointer {
            funasr_seaco_infer_pcm(sctx, $0.baseAddress, Int32(samples.count))
        }.map { String(cString: $0) } ?? ""
        funasr_seaco_free(sctx)
    }

    err(AppL10n.tr("\n========== 本地 ASR 三方对比 =========="))
    err(AppL10n.format("① tpass 在线累积(流式实时显示的):\n   %@", accumulated))
    err(AppL10n.format("② tpass 最终定稿(2pass offline):\n   %@", tpassFinal))
    err(AppL10n.format("③ 离线整段 SeACo(非流式路径):\n   %@", offline))
    err("=======================================")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var showMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow?() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AnalyticsClient.shared.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
    }
}

@main
enum QuickVibeHostEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--analytics-self-test") {
            exit(AnalyticsClient.runSelfTest())
        }
        QuickVibeHostApp.main()
    }
}

struct QuickVibeHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var manager = VoiceInputManager()
    @StateObject private var appUpdateManager = AppUpdateManager()
    @StateObject private var historyManager = RecognitionHistoryManager()
    @StateObject private var usageManager = ClaudeUsageManager()
    @StateObject private var localAIUsageManager = LocalAIUsageManager()
    @StateObject private var sessionManager = ClaudeCodeSessionManager()
    @StateObject private var hotkeyManager = GlobalHotkeyManager()
    @StateObject private var bleManager = BLEManager()
    @StateObject private var hookStore = ClaudeHookSessionStore()
    @StateObject private var pricingManager = AnthropicPricingManager()
    @StateObject private var selectionStore = SessionSelectionStore()
    @StateObject private var colorManager = SessionColorManager.shared
    @StateObject private var modelManager = ASRModelManager()
    @StateObject private var englishModelManager = EnglishASRModelManager()
    @StateObject private var aliasInstaller = VibeptyAliasInstaller()
    @StateObject private var codexMonitor = CodexSessionMonitor()
    @StateObject private var codexApprovalServer = CodexApprovalServer()
    @StateObject private var chatGPTConversationMonitor = ChatGPTConversationMonitor()
    @StateObject private var workBuddyMonitor = WorkBuddySessionMonitor()
    @StateObject private var workBuddyApprovalServer = WorkBuddyApprovalServer()
    @StateObject private var sceneModes = SceneModeStore()
    @StateObject private var promptTemplates = PromptTemplateStore()
    @StateObject private var inputAssistantSkills = InputAssistantSkillStore()
    @StateObject private var taskLifecycleCoordinator = TaskLifecycleCoordinator()

    @StateObject private var windowController = MainWindowController()
    @StateObject private var toastCenter = FallbackToastCenter()
    @StateObject private var languageSettings = AppLanguageSettings()
    @State private var hookBLECancellables = Set<AnyCancellable>()
    @State private var promptRecommendationController: PromptRecommendationController?
    @State private var inputAssistantController: InputAssistantCoordinator?

    init() {
        // Public demo: crash reporting is disabled. Configure your own Sentry DSN to opt in.
        AnalyticsClient.shared.configure()

        runTpassSmokeIfRequested()   // T-018 Step A 功能冒烟:env QVH_TPASS_SMOKE=1 → 跑本地 2-pass 流式并 exit

        if UITestFlags.isHeadless {
            NSLog("[ui-test] HEADLESS mode — skipping all TCC-protected init (audio / BLE / notif / ax). forcedInitialTabTag=\(UITestFlags.forcedInitialTabTag.map(String.init) ?? "nil")")
        }

        ClaudeUsageManager.requestNotificationPermission()

    }

    var body: some Scene {
        MenuBarExtra {
            Button(windowController.isShown ? AppL10n.tr("隐藏面板") : AppL10n.tr("显示面板")) {
                windowController.toggle()
            }
            Divider()
            Button(manager.state == .recording ? AppL10n.tr("停止录音") : AppL10n.tr("开始录音")) {
                manager.toggleRecording()
            }
            .disabled(manager.state == .processing)
            Divider()
            Button(AppL10n.tr("退出")) {
                windowController.resetAutoExpandedWindow()
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label(AppBrand.displayName, systemImage: menuBarIcon)
                .onAppear {
                    appUpdateManager.checkForUpdates()

                    // Cold-start Accessibility check. If ax=N at boot, every
                    // subsequent synthetic-keystroke bug report traces back here.
                    // See MEMORY/feedback_accessibility_stale.md — Xcode debug
                    // rebuild invalidates the grant in a "half-trusted" way.
                    let axOK = AXIsProcessTrusted()
                    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                    ClaudeCodeSessionManager.log(
                        "[boot] version=\(appVersion) path=\(Bundle.main.bundleURL.path) "
                        + "AXIsProcessTrusted=\(axOK ? "Y" : "N")"
                    )

                    hotkeyManager.voiceInputManager = manager
                    hotkeyManager.start()
                    manager.historyManager = historyManager
                    manager.bleManager = bleManager
                    manager.setupBLEAudioHandler()
                    manager.setupBLEControlHandler()
                    manager.setupDeviceActionHandler(sceneModes: sceneModes)

                    let mgr = manager
                    // 新管理器注入(PR-4)
                    mgr.modelManager = modelManager
                    mgr.englishModelManager = englishModelManager
                    let funasr = FunASRSeacoEngine(modelManager: modelManager)
                    mgr.funasrEngine = funasr
                    mgr.setupLocalEngineObserver()
                    BenchServer.shared.voiceManager = mgr
                    BenchServer.shared.start()
                    // 模型库存与当前引擎选择解耦：即使以豆包启动，也要识别已安装的本地流式模型；
                    // 运行中切回本地时即可直接建立 2-pass 会话，而不是静默退回松键后整段识别。
                    Task { @MainActor in
                        await mgr.refreshLocalRecognitionState()
                        await englishModelManager.checkLocalState()
                    }

                    // 用户在设置里关掉集成后,重启不得静默重装(移除是为卸载 app 做清理)
                    if UserDefaults.standard.object(forKey: "claudeIntegrationEnabled") as? Bool ?? true {
                        HookInstaller.installIfNeeded()
                        StatusLineInstaller.installIfNeeded()
                    }
                    // REQ-022:审批协议 v1 链路装配 — Coordinator 持有 ApprovalRegistry
                    // (专用串行队列满足并发契约);0x36 回传路由 + Codex 会话名解析。
                    // 必须先于 hookStore.start(),避免启动瞬间到达的 PermissionRequest
                    // 找不到 responder。
                    ApprovalCoordinator.shared.configure(
                        bleManager: bleManager,
                        hookStore: hookStore,
                        codexApprovalServer: codexApprovalServer,
                        workBuddyApprovalServer: workBuddyApprovalServer
                    )
                    taskLifecycleCoordinator.bleManager = bleManager
                    codexMonitor.onTaskLifecycleEvent = { [weak taskLifecycleCoordinator] signal in
                        taskLifecycleCoordinator?.handle(signal)
                    }
                    hookStore.onTaskLifecycleEvent = { [weak taskLifecycleCoordinator] signal in
                        taskLifecycleCoordinator?.handle(signal)
                    }
                    workBuddyMonitor.onTaskLifecycleEvent = { [weak taskLifecycleCoordinator] signal in
                        taskLifecycleCoordinator?.handle(signal)
                    }
                    codexApprovalServer.isDeviceReadyForApproval = { [weak bleManager] in
                        guard let bleManager else { return false }
                        return bleManager.connectionState == .connected && bleManager.characteristicsReady
                    }
                    workBuddyApprovalServer.isDeviceReadyForApproval = { [weak bleManager] in
                        guard let bleManager else { return false }
                        return bleManager.connectionState == .connected && bleManager.characteristicsReady
                    }
                    bleManager.onApprovalResponse = { data in
                        ApprovalCoordinator.shared.handleDeviceFrame(data)
                    }
                    codexApprovalServer.sessionNameProvider = { [weak codexMonitor] uuid in
                        codexMonitor?.sessions.values.first { $0.id.hasSuffix(":\(uuid)") }?.projectName
                    }
                    codexApprovalServer.onUserPromptSubmitted = { [weak codexMonitor, weak taskLifecycleCoordinator] sessionId, transcriptPath, turnID in
                        codexMonitor?.noteUserPrompt(sessionId: sessionId, transcriptPath: transcriptPath)
                        let resolvedTurnID = turnID.flatMap { $0.isEmpty ? nil : $0 }
                            ?? "hook-\(UUID().uuidString)"
                        taskLifecycleCoordinator?.handle(TaskLifecycleSignal(
                            provider: .codex,
                            sessionID: sessionId,
                            turnID: resolvedTurnID,
                            outcome: .started
                        ))
                    }

                    hookStore.attachPricingManager(pricingManager)
                    hookStore.selectionStore = selectionStore
                    hookStore.start()
                    // BUG-005:启动恢复直通选择不再激活宿主终端——开机瞬间夺焦无人预期;
                    // 直通注入(PTY 直写)与自由回退(JIT 激活在 InputRouter.activator)均不依赖此处
                    selectionStore.bind(to: hookStore, codexMonitor: codexMonitor)
                    selectionStore.bindDeviceLifecycle(from: bleManager)

                    InputRouter.sessionResolver = { [weak hookStore, weak codexMonitor] sid in
                        // REQ-019: codex- 前缀查 CodexSessionMonitor,其余走 CC hook store
                        if sid.hasPrefix("codex-") { return codexMonitor?.sessions[sid] }
                        return hookStore?.sessions[sid]
                    }
                    InputRouter.activeSessionResolver = { [weak hookStore, weak codexMonitor] in
                        let hookSession = hookStore?.sessions.values.max { $0.lastActivity < $1.lastActivity }
                        let codexSession = codexMonitor?.sessions.values.max { $0.lastActivity < $1.lastActivity }
                        switch (hookSession, codexSession) {
                        case let (hook?, codex?):
                            return hook.lastActivity >= codex.lastActivity ? hook : codex
                        case let (hook?, nil):
                            return hook
                        case let (nil, codex?):
                            return codex
                        case (nil, nil):
                            return nil
                        }
                    }
                    InputRouter.activator = { [sessionManager] session in
                        SessionActivator.bringToFront(session: session, sessionManager: sessionManager)
                    }
                    InputRouter.clearSelection = { [weak selectionStore] in
                        selectionStore?.clear()
                    }
                    InputRouter.toast = { [toastCenter] reason in
                        NSLog("[Exclusive toast] \(reason.logDescription): \(reason.toastMessage)")
                        Task { @MainActor in toastCenter.show(reason: reason) }
                    }

                    // 「识别中」中断:浮窗 ESC×2 / ✕ → 取消在途识别任务。
                    manager.overlayController.onCancelRecognition = { [weak manager] in
                        manager?.cancelActiveRecognition()
                    }

                    manager.overlayController.exclusiveBadgeProvider = { [weak selectionStore, weak hookStore, weak codexMonitor] in
                        guard let sid = selectionStore?.selectedSessionId else { return nil }
                        // REQ-019: codex- 前缀查 CodexSessionMonitor
                        let session = sid.hasPrefix("codex-")
                            ? codexMonitor?.sessions[sid] : hookStore?.sessions[sid]
                        guard let session, session.phase != .ended else { return nil }
                        let color = SessionColorManager.shared.colorForSession(sid, pid: session.pid)
                        return ExclusiveBadge(name: session.projectName, colorName: color)
                    }

                    if promptRecommendationController == nil {
                        let controller = PromptRecommendationController(
                            bleManager: bleManager,
                            store: promptTemplates
                        ) { [weak selectionStore, weak hookStore, weak codexMonitor] in
                            let foreground = PromptForegroundApplication.capture()
                            let selectedID = selectionStore?.selectedSessionId
                            let selected = selectedID.flatMap { id in
                                id.hasPrefix("codex-") ? codexMonitor?.sessions[id] : hookStore?.sessions[id]
                            }
                            let latestHook = hookStore?.sessions.values.max { $0.lastActivity < $1.lastActivity }
                            let latestCodex = codexMonitor?.sessions.values.max { $0.lastActivity < $1.lastActivity }
                            let latest: HookSession?
                            switch (latestHook, latestCodex) {
                            case let (a?, b?): latest = a.lastActivity >= b.lastActivity ? a : b
                            case let (a?, nil): latest = a
                            case let (nil, b?): latest = b
                            case (nil, nil): latest = nil
                            }
                            let session: HookSession?
                            if foreground.category.usesRecentAgentSession {
                                switch foreground.inferredAgentProvider {
                                case .codex:
                                    let selectedCodex = selectedID?.hasPrefix("codex-") == true ? selected : nil
                                    session = selectedCodex ?? latestCodex
                                case .claudeCode:
                                    let selectedClaude = selectedID?.hasPrefix("codex-") == false ? selected : nil
                                    session = selectedClaude ?? latestHook
                                default:
                                    session = selected ?? latest
                                }
                            } else {
                                session = nil
                            }
                            return await PromptContextCollector.collect(session: session,
                                                                         foreground: foreground)
                        }
                        bleManager.onPromptRecommendationRequest = { [weak controller] requestID in
                            Task { @MainActor in controller?.request(requestID) }
                        }
                        bleManager.onDynamicPromptSelect = { [weak controller] requestID, index in
                            Task { @MainActor in controller?.select(requestID: requestID, index: index) }
                        }
                        promptRecommendationController = controller
                    }
                    if inputAssistantController == nil {
                        let controller = InputAssistantCoordinator(ble: bleManager, skillStore: inputAssistantSkills)
                        bleManager.onInputAssistantRequest = { [weak controller] requestID in
                            Task { @MainActor in controller?.request(requestID) }
                        }
                        bleManager.onInputAssistantAction = { [weak controller] requestID, operation in
                            Task { @MainActor in controller?.handle(requestID: requestID, operation: operation) }
                        }
                        manager.inputAssistantController = controller
                        inputAssistantController = controller
                    }
                    self.setupHookBLEBridge()

                    sessionManager.startPolling()
                    usageManager.startPolling()
                    localAIUsageManager.startPolling()
                    // REQ-021: codex 审批闭环 — hook 安装 + 挂起 server + 会话相联动
                    if CodexSessionMonitor.isInstalled {
                        CodexHookInstaller.installIfNeeded()
                        codexMonitor.approvalServer = codexApprovalServer
                        codexApprovalServer.onPendingChanged = { [weak codexMonitor] in
                            codexMonitor?.rescan()
                        }
                        codexApprovalServer.start()
                    }
                    if WorkBuddySessionMonitor.isInstalled {
                        let enabled = UserDefaults.standard.bool(
                            forKey: WorkBuddyApprovalFeature.enabledKey
                        )
                        do {
                            try WorkBuddyHookInstaller.reconcile(enabled: enabled)
                        } catch {
                            ClaudeCodeSessionManager.log(
                                "[WorkBuddy] approval hook reconcile failed: \(error.localizedDescription)"
                            )
                        }
                        workBuddyMonitor.approvalServer = workBuddyApprovalServer
                        workBuddyApprovalServer.sessionNameProvider = { [weak workBuddyMonitor] rawID in
                            workBuddyMonitor?.sessions["workbuddy:\(rawID)"]?.projectName
                        }
                        workBuddyApprovalServer.onPendingChanged = { [weak workBuddyMonitor] in
                            workBuddyMonitor?.refresh()
                        }
                        workBuddyApprovalServer.start()
                    }
                    // 审批 server 与 monitor 的依赖先完成，再开始首轮扫描，避免启动时
                    // 首轮 session 状态没有审批源、随后才补接的竞态。
                    codexMonitor.start()   // REQ-017: Codex rollout 扫描(未安装时空转直接返回)
                    chatGPTConversationMonitor.start()
                    workBuddyMonitor.start()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        hookStore.seedFromDiscoveredSessions(sessionManager.sessions)
                    }

                    var showMainWindowRoot: (() -> Void)!
                    showMainWindowRoot = {
                        let initialTab = ContentView.initialTabTag(
                            forcedTab: UITestFlags.forcedInitialTabTag,
                            storedLastTabTag: ContentView.storedLastTabTag()
                        )
                        let rootView = ContentView(initialTab: initialTab) { tab in
                            windowController.applyLayout(for: tab)
                        }
                            .environmentObject(manager)
                            .environmentObject(appUpdateManager)
                            .environmentObject(historyManager)
                            .environmentObject(usageManager)
                            .environmentObject(localAIUsageManager)
                            .environmentObject(sessionManager)
                            .environmentObject(hotkeyManager)
                            .environmentObject(bleManager)
                            .environmentObject(hookStore)
                            .environmentObject(pricingManager)
                            .environmentObject(selectionStore)
                            .environmentObject(modelManager)
                            .environmentObject(englishModelManager)
                            .environmentObject(toastCenter)
                            .environmentObject(languageSettings)
                            .environmentObject(aliasInstaller)
                            .environmentObject(codexMonitor)
                            .environmentObject(codexApprovalServer)
                            .environmentObject(chatGPTConversationMonitor)
                            .environmentObject(workBuddyMonitor)
                            .environmentObject(workBuddyApprovalServer)
                            .environmentObject(sceneModes)
                            .environmentObject(promptTemplates)
                            .environmentObject(inputAssistantSkills)
                        windowController.setupWindow(with: rootView)
                    }

                    if FirstRunSetupState.shouldShowSetup(localASRAvailable: mgr.localASRAvailable) {
                        let setupRoot = FirstRunSetupView(onFinish: showMainWindowRoot)
                            .environmentObject(manager)
                            .environmentObject(modelManager)
                            .environmentObject(englishModelManager)
                            .environmentObject(bleManager)
                            .environmentObject(languageSettings)
                        windowController.setupFirstRunWindow(with: setupRoot)
                    } else if !FirstRunSetupState.accessibilityGranted {
                        let repairRoot = AccessibilityRepairView(onFinish: showMainWindowRoot)
                            .environmentObject(languageSettings)
                        windowController.setupFirstRunWindow(with: repairRoot)
                    } else {
                        showMainWindowRoot()
                    }
                    let mainWindowController = windowController
                    appDelegate.showMainWindow = { [weak mainWindowController] in
                        mainWindowController?.show()
                    }
                    windowController.show()

                    // ui-smoke:拉起编辑器/错误态供 QVHSnapshot 截图(零 TCC)。
                    if let p = UITestFlags.editorPreview {
                        if p.isError {
                            manager.overlayController.showError(AppL10n.tr("识别失败:网络超时")) {}
                        } else {
                            manager.overlayController.showEditor(text: p.text) { _ in }
                        }
                    }
                    // ui-smoke:拉起录音态草稿供 QVHSnapshot 截草稿样式(零 TCC)。
                    if let d = UITestFlags.editorDraft {
                        manager.overlayController.showButtonA()       // 录音态(passive,零 TCC)
                        manager.overlayController.updateDraft(d)       // 注入草稿
                    }
                    // ui-smoke:拉起录音/转录态供 QVHSnapshot 比对①四态外壳一致(零 TCC)。
                    if let ph = UITestFlags.overlayPhase {
                        switch ph {
                        case "recording":  manager.overlayController.showButtonA()
                        case "processing": manager.overlayController.showProcessing()
                        default: break
                        }
                    }
                    // ui-smoke:REQ-021 审批闭环 — 首个 codex 挂起出现 5s 后自动应答
                    if let decision = UITestFlags.codexApproval {
                        var responded = false
                        let t = Timer(timeInterval: 1, repeats: true) { [weak codexApprovalServer] timer in
                            Task { @MainActor in
                                guard let server = codexApprovalServer, !responded,
                                      let key = server.pending.keys.first else { return }
                                responded = true
                                timer.invalidate()
                                print("[ui-test-codex-approval] pending \(key) -> \(decision) in 5s")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                    server.respond(sessionKey: key, decision: decision)
                                    print("[ui-test-codex-approval] responded \(decision)")
                                }
                            }
                        }
                        RunLoop.main.add(t, forMode: .common)
                    }
                    // ui-smoke:REQ-019 注入链端到端 — 延时后把文本按当前直通选择路由。
                    // 主线程执行:free 回退的 KeyboardSimulator(TSM)有主线程断言。
                    if let sid = UITestFlags.exclusiveSid {
                        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, UITestFlags.snapshotDelay - 3)) { [weak selectionStore] in
                            selectionStore?.select(sid)
                            print("[ui-test-exclusive-sid] selected \(sid)")
                        }
                    }
                    if let text = UITestFlags.routeText {
                        DispatchQueue.main.asyncAfter(deadline: .now() + UITestFlags.snapshotDelay) { [weak hookStore, weak codexMonitor] in
                            let mode = InputRouter.currentMode()
                            var info = "mode=\(mode.debugDescription)"
                            if case .exclusive(let sid) = mode {
                                let s = sid.hasPrefix("codex-") ? codexMonitor?.sessions[sid] : hookStore?.sessions[sid]
                                info += " found=\(s != nil) pid=\(s?.pid.map(String.init) ?? "nil") phase=\(s.map { String(describing: $0.phase) } ?? "?")"
                            }
                            print("[ui-test-route-text] pre: \(info)")
                            InputRouter.route(text: text, source: .test)
                            print("[ui-test-route-text] routed \(text.count) chars")
                        }
                    }
                    // ui-smoke:自截图(cacheDisplay)在系统深色模式下文本层渲染成白字白底
                    // (2026-07-10 实测),headless 强制浅色外观保证截图可读。
                    // 必须在 onAppear 设置:App.init() 时 NSApp 尚为 nil。
                    if UITestFlags.isHeadless {
                        NSApp.appearance = NSAppearance(named: .aqua)
                    }
                    // ui-smoke:主窗口自截图(零 TCC,app 自渲染 contentView),写 PNG 后退出
                    // route-text 同时启用时多等 5s,避免 terminate 抢跑注入
                    if let snapPath = UITestFlags.snapshotPath {
                        let snapDelay = UITestFlags.snapshotDelay + (UITestFlags.routeText != nil ? 5 : 0)
                        DispatchQueue.main.asyncAfter(deadline: .now() + snapDelay) {
                            let ok = windowController.snapshotWindow(to: snapPath)
                            print("[ui-test-snapshot] \(ok ? "written" : "FAILED") -> \(snapPath)")
                            NSApp.terminate(nil)
                        }
                    }
                }
        }
        .menuBarExtraStyle(.menu)
    }

    /// Bridge hook session changes to BLE (Mac → device push only;
    /// device → Mac approval reverse-channel was removed in v3 protocol simplification)
    /// v5(REQ-007):MicPad 走 v5 帧(会话帧事件驱动 500ms 去抖 + Agent 帧 60s 周期
    /// + 会话数变化即推 + config 连接下发);Stick S3 保持 v4 路径不变。
    private func setupHookBLEBridge() {
        // Mac → Device: observe hookStore changes and push via BLE(500ms 去抖合并)
        hookStore.$sessions
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] _ in
                Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                     codex: codexMonitor, codexApproval: codexApprovalServer,
                                     chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
                Self.pushV5AgentInfoIfCountChanged(ble: bleManager, store: hookStore, codex: codexMonitor,
                                                   workBuddy: workBuddyMonitor, usage: usageManager)
            }
            .store(in: &hookBLECancellables)

        // REQ-020: codex 会话变化同样驱动设备推送(与 CC 同一去抖参数)
        codexMonitor.$sessions
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] _ in
                Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                     codex: codexMonitor, codexApproval: codexApprovalServer,
                                     chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
                Self.pushV5AgentInfoIfCountChanged(ble: bleManager, store: hookStore, codex: codexMonitor,
                                                   workBuddy: workBuddyMonitor, usage: usageManager)
            }
            .store(in: &hookBLECancellables)

        // 认证识别是异步的：unknown 时设备不展示 Claude 用量卡；一旦解析为
        // 订阅或 API，立即重发 0x52，无需等待 60s 周期。
        usageManager.$billingMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak usageManager, weak codexMonitor, weak workBuddyMonitor] _ in
                Self.pushV5AgentInfo(ble: bleManager, store: hookStore,
                                     codex: codexMonitor, workBuddy: workBuddyMonitor, usage: usageManager)
            }
            .store(in: &hookBLECancellables)

        // 普通 ChatGPT 侧栏变化也要刷新设备会话帧；availability 参与组合，避免
        // ChatGPT 关闭/侧栏不可读时继续向设备发送上一次的旧缓存。
        chatGPTConversationMonitor.$conversations
            .combineLatest(chatGPTConversationMonitor.$availability)
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] _ in
                Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                     codex: codexMonitor, codexApproval: codexApprovalServer,
                                     chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
            }
            .store(in: &hookBLECancellables)

        workBuddyMonitor.$sessions
            .combineLatest(workBuddyMonitor.$credits)
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] _ in
                Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager,
                                     usage: usageManager, codex: codexMonitor,
                                     codexApproval: codexApprovalServer,
                                     chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
                Self.pushV5AgentInfo(ble: bleManager, store: hookStore, codex: codexMonitor,
                                     workBuddy: workBuddyMonitor, usage: usageManager)
            }
            .store(in: &hookBLECancellables)

        // Push when BLE characteristics are discovered (device is fully ready)
        bleManager.$characteristicsReady
            .receive(on: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] ready in
                guard ready else { return }
                Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                     codex: codexMonitor, codexApproval: codexApprovalServer,
                                     chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
            }
            .store(in: &hookBLECancellables)

        // Sync session names from process scanning (which has /name field)
        sessionManager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak hookStore] discovered in
                hookStore?.syncNames(from: discovered)
                hookStore?.syncBackgroundTasks(from: discovered)
            }
            .store(in: &hookBLECancellables)

        // v3: device-initiated status poll (CMD_REQUEST_STATUS=0x21) → push latest dashboard
        bleManager.onStatusRequestFromDevice = { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] in
            Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                 codex: codexMonitor, codexApproval: codexApprovalServer,
                                 chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
            Self.pushV5AgentInfo(ble: bleManager, store: hookStore, codex: codexMonitor,
                                 workBuddy: workBuddyMonitor, usage: usageManager)
        }

        // v5 握手通过(仅 MicPad):下发 config + 全量状态
        bleManager.onDeviceReadyV5 = { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] in
            Self.pushV5Config(ble: bleManager)
            bleManager?.sendV5Time()
            // 设备硬件偏好(蜂鸣器/LED)以固件 NVS 为准;只有用户在设备页改动时才下发,
            // 避免换电脑连接时被本机 UserDefaults 默认值覆盖。
            bleManager?.requestDevicePreferences()
            Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                 codex: codexMonitor, codexApproval: codexApprovalServer,
                                 chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
            Self.pushV5AgentInfo(ble: bleManager, store: hookStore, codex: codexMonitor,
                                 workBuddy: workBuddyMonitor, usage: usageManager)
            // REQ-022:重连后设备审批队列为空 → 重推所有仍 pending 的 0x55
            ApprovalCoordinator.shared.deviceReconnected()
        }
        bleManager.onDeviceCapabilitiesChanged = { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] in
            Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager,
                                 usage: usageManager, codex: codexMonitor,
                                 codexApproval: codexApprovalServer,
                                 chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
            Self.pushV5AgentInfo(ble: bleManager, store: hookStore, codex: codexMonitor,
                                 workBuddy: workBuddyMonitor, usage: usageManager)
        }

        // v5 Agent 信息帧:60s 周期(用量数据更新粒度低,REQ-007 决策)
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak bleManager, weak hookStore, weak usageManager, weak codexMonitor, weak workBuddyMonitor] _ in
                Self.pushV5AgentInfo(ble: bleManager, store: hookStore, codex: codexMonitor,
                                     workBuddy: workBuddyMonitor, usage: usageManager)
            }
            .store(in: &hookBLECancellables)

        // v5(T-025):时间重同步 10min 周期,防固件 millis 漂移
        Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak bleManager] _ in
                bleManager?.sendV5Time()
            }
            .store(in: &hookBLECancellables)

        Self.captureAnalyticsSnapshots(ble: bleManager, manager: manager, modelManager: modelManager, historyManager: historyManager)

        Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak bleManager, weak manager, weak modelManager, weak historyManager] _ in
                guard let manager, let modelManager, let historyManager else { return }
                AnalyticsClient.shared.flushHourlyStatsIfNeeded()
                Self.captureAnalyticsSnapshots(ble: bleManager, manager: manager, modelManager: modelManager, historyManager: historyManager)
            }
            .store(in: &hookBLECancellables)

        // Legacy v5 firmware prompt selection. All entries only insert text and never press Enter.
        bleManager.onPromptSelect = { idx in
            if idx == 0 {
                guard let item = promptTemplates.enabledTemplates.first else { return }
                InputRouter.routePromptText(item.body.value(for: DeviceDisplayLanguage.selected),
                                            source: .bleButtonB)
            } else {
                let prompts = UserDefaults.standard.array(forKey: "micpadPrompts") as? [[String: String]] ?? []
                let i = Int(idx) - 1
                guard i >= 0, i < prompts.count,
                      let body = prompts[i]["body"], !body.isEmpty else { return }
                InputRouter.routePromptText(body, source: .bleButtonB)
            }
        }

        // v5(REQ-013/REQ-020):设备框选直通切换(索引与 pushV5Sessions 的合并顺序一致);
        // ChatGPT App 工作会话/VSCode 不可直通:点按不 toggle 选择(设备无高亮),
        // 改为打开对应会话(desktop=codex://threads/<uuid> deep link 直达;vscode=激活宿主)
        // —— 用户 2026-07-23:"框选点击不高亮,但可以打开对应的 codex desktop 会话";
        // Codex CLI 无 pid(未经 vibepty)仍拦截,Mac 侧弹 toast 说明
        bleManager.onExclusiveToggle = { [weak hookStore, weak selectionStore, weak codexMonitor, weak toastCenter, weak manager, weak chatGPTConversationMonitor, weak workBuddyMonitor, weak sessionManager] idx in
            // T-034:返回值改为 (list, inactiveStart);此处只需会话列表 —— 设备发来的
            // CMD_EXCLUSIVE_TOGGLE 载荷已由固件经 ui_row_to_session 换算回**会话下标**。
            let ordered = Self.deviceOrderedSessions(store: hookStore, codex: codexMonitor,
                                                      chatGPT: chatGPTConversationMonitor,
                                                      workBuddy: workBuddyMonitor).list
            let i = Int(idx)
            guard i < ordered.count else { return }
            let session = ordered[i]
            // 2026-07-25 用户定稿:设备旋钮确认选中"不可直通"会话 = 用户意图已切换
            // 输入目标 → 必须取消原直通回自由输入(否则直通仍挂旧会话,PTT 语音注错
            // 会话),并 toast 告知。$selectedSessionId 订阅会自动补推 v5 帧,设备
            // 高亮即刻消失(BUG-022 链路)。
            let clearedStaleExclusive: () -> Bool = {
                guard let store = selectionStore, store.selectedSessionId != nil else { return false }
                ClaudeCodeSessionManager.log("[Selection] cleared (device picked unsupported sid=\(session.id.prefix(8)))")
                store.clear()
                return true
            }
            if session.id.hasPrefix("chatgpt:") {
                _ = chatGPTConversationMonitor?.openConversation(id: session.id)
                if clearedStaleExclusive() { toastCenter?.show(reason: .exclusiveClearedUnsupported) }
                return
            }
            if session.id.hasPrefix("workbuddy:") {
                _ = workBuddyMonitor?.openConversation(id: session.id)
                if clearedStaleExclusive() { toastCenter?.show(reason: .exclusiveClearedUnsupported) }
                return
            }
            if session.id.hasPrefix("codex-desktop:") {
                if let sessionManager {
                    SessionNavigationService.open(session: session, sessionManager: sessionManager)
                }
                if clearedStaleExclusive() { toastCenter?.show(reason: .exclusiveClearedUnsupported) }
                return
            }
            if Self.isVSCodeHostedCodexSession(session) {
                if let sessionManager {
                    SessionNavigationService.open(session: session, sessionManager: sessionManager)
                }
                if clearedStaleExclusive() { toastCenter?.show(reason: .exclusiveClearedUnsupported) }
                return
            }
            if session.id.hasPrefix("codex-"), session.pid == nil,
               !(selectionStore?.isSelected(session.id) ?? false) {
                // 有直通被取消时提示"已切自由输入"(覆盖切换事实);否则维持原"未接管"提示
                if clearedStaleExclusive() { toastCenter?.show(reason: .exclusiveClearedUnsupported) }
                else                       { toastCenter?.show(reason: .codexNotWrapped) }
                return
            }
            // 不可直通的 CC 会话(Desktop/headless:有 pid 有 tty 但未经 vibepty,
            // 或孤儿/pid 已死)→ claude://resume 直达,不 toggle(2026-07-24 修:
            // 原判据 tty==nil 对 Desktop CC 不成立,Desktop 会话有伪终端故漏判)。
            let ccInjectable: Bool = {
                guard !session.id.hasPrefix("codex-"), !session.isBackgroundOrphan,
                      let pid = session.pid else { return false }
                return VibeptyClient.isChannelAvailable(pid: pid)
            }()
            if !session.id.hasPrefix("codex-"), !ccInjectable,
               !(selectionStore?.isSelected(session.id) ?? false) {
                if let sessionManager {
                    SessionNavigationService.open(session: session, sessionManager: sessionManager)
                }
                if clearedStaleExclusive() { toastCenter?.show(reason: .exclusiveClearedUnsupported) }
                return
            }
            selectionStore?.toggle(session.id)
            manager?.prewarmProjectStreamingHotwords()
        }

        // v5(REQ-012):设备编辑模式 → ASR 呈现强制胶囊 UI
        bleManager.onDeviceModeChange = { [weak manager, weak promptRecommendationController, weak inputAssistantController] mode in
            manager?.deviceEditMode = (mode == 1)
            if mode != 2 { promptRecommendationController?.cancel() }
            if mode != 5 { inputAssistantController?.cancel() }
        }

        // BUG-022:直通选择变化立即推会话帧 — v1.0.0 只订阅了 $sessions,
        // 直通切换不触发推送,设备端要等下一次会话事件或 30s 轮询才看到高亮变化。
        selectionStore.$selectedSessionId
            .removeDuplicates()
            .dropFirst()   // 启动恢复选择不需要推(设备尚未连接/握手时另有全量推送)
            .receive(on: DispatchQueue.main)
            .sink { [weak bleManager, weak hookStore, weak manager, weak usageManager, weak codexMonitor, weak codexApprovalServer, weak chatGPTConversationMonitor, weak workBuddyMonitor] _ in
                Self.pushStatusToBLE(ble: bleManager, store: hookStore, voiceManager: manager, usage: usageManager,
                                     codex: codexMonitor, codexApproval: codexApprovalServer,
                                     chatGPT: chatGPTConversationMonitor, workBuddy: workBuddyMonitor)
            }
            .store(in: &hookBLECancellables)

        // REQ-022:0x10/0x11 审批拦截(REQ-020 的 codexApprovalControlInterceptor)已删除,
        // 设备端审批应答统一走 0x36 专用帧 → ApprovalCoordinator(reqId 精确匹配)。
    }

    // MARK: - v5 push(REQ-007)

    /// REQ-028:设备会话帧 = 活跃组(跨 agent 混排,phasePriority→时间倒序)+ 非活跃组(≤5 条)。
    /// 返回 boundary = 非活跃组在合并列表中的起始下标;nil = 无非活跃组。
    /// onExclusiveToggle 的索引必须与此列表一致。
    static func deviceOrderedSessions(store: ClaudeHookSessionStore?, codex: CodexSessionMonitor?,
                                      chatGPT: ChatGPTConversationMonitor? = nil,
                                      workBuddy: WorkBuddySessionMonitor? = nil)
        -> (list: [HookSession], inactiveStart: Int?) {
        let realActives = StatusTab.sortForCards(
            (store?.activeSessions ?? []) + (codex?.activeSessions ?? [])
                + (workBuddy?.activeSessions ?? [])
        )
        let chats = ChatGPTConversationClassifier.deviceConversations(
            chatGPT?.conversations ?? [], availability: chatGPT?.availability ?? .appNotRunning
        ).map { chat in
            HookSession(id: chat.id, cwd: "", phase: .idle, pid: nil, tty: nil,
                        lastTool: nil, lastActivity: .distantPast, name: "GPT \(chat.title)")
        }
        // 设备最多显示 12 行，预留普通聊天行，避免活跃工作任务恰好达到上限时
        // ChatGPT 永远被截断；高优先级工作任务仍然排在普通聊天之前。
        let realHeadCount = max(0, 12 - chats.count)
        let actives = Array(realActives.prefix(realHeadCount))
            + chats
            + Array(realActives.dropFirst(realHeadCount))
        let inactives = ((store?.inactiveSessions ?? []) + (codex?.inactiveSessions ?? [])
            + (workBuddy?.inactiveSessions ?? []))
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(SessionLivenessParams.deviceInactiveCap)      // REQ-028 §4:设备端 5 条
        guard !inactives.isEmpty else { return (actives, nil) }
        return (actives + inactives, actives.count)
    }

    private static func isVSCodeHostedCodexSession(_ session: HookSession) -> Bool {
        session.id.hasPrefix("codex-vscode:")
    }

    /// codex 会话的 ctx%(transcriptSnapshot token 比值;CC 走 statusLine capture)
    private static func codexCtxPct(_ s: HookSession) -> UInt8? {
        guard let snap = s.transcriptSnapshot,
              let used = snap.contextPromptTokens,
              let limit = snap.contextLimitTokens, limit > 0 else { return nil }
        return UInt8(clamping: min(100, used * 100 / limit))
    }

    /// 按设备协议版本分流:v5 → MicPad 多 Agent 帧;v4 → Stick S3 原路径
    private static func pushStatusToBLE(
        ble: BLEManager?,
        store: ClaudeHookSessionStore?,
        voiceManager: VoiceInputManager?,
        usage: ClaudeUsageManager? = nil,
        codex: CodexSessionMonitor? = nil,
        codexApproval: CodexApprovalServer? = nil,
        chatGPT: ChatGPTConversationMonitor? = nil,
        workBuddy: WorkBuddySessionMonitor? = nil
    ) {
        guard let ble, let store, ble.connectionState == .connected else { return }
        if let mgr = voiceManager,
           mgr.state == .recording || mgr.state == .processing { return }
        if ble.deviceProtocolVersion >= 5 {
            pushV5Sessions(ble: ble, store: store, codex: codex, usage: usage,
                           chatGPT: chatGPT, workBuddy: workBuddy)
            // REQ-022:审批推送已迁至 ApprovalCoordinator(register 时机推 0x55,
            // reqId 精确匹配),不再随状态帧按"优先级推断"重复推送。
        } else {
            // Stick S3(v4)本期不动:维持纯 CC 视图(REQ-020 定案)
            pushClaudeStatusToBLE(ble: ble, store: store, voiceManager: voiceManager, usage: usage)
        }
    }

    /// HookSession → v5 DisplayState(agent-signal-bar 8 态)
    /// 映射决策(REQ-009):approval→permission红;非活跃(30min)→stale灰(ended→paused灰);
    /// processing/compacting→active;waitingForInput(完成一轮等用户看)→needs_review黄;idle→ready绿
    /// REQ-017:StatusTab 会话卡圆点复用同一映射(internal)
    /// REQ-022 后续批:processing/compacting + modelInferring → 8=SDS_THINKING(蓝呼吸);
    /// 设备边沿检测把 {1,8} 视为同一 running 集合,1↔8 切换不触发提示音。
    static func v5State(_ s: HookSession, isActive: Bool) -> UInt8 {
        if case .waitingForApproval = s.phase { return 5 }
        // REQ-022 后续批:StopFailure 标记的 error 会话 → 6=SDS_BLOCKED(红快闪),
        // 固件在进入 BLOCKED 边沿响一次 BZ_TASK_ERROR(固件零改动,状态位早已预留)。
        // 优先级:审批(5)> error(6)> 其余;error 由下一次会话活动自动清除。
        if s.hasError { return 6 }
        if !isActive {
            if case .ended = s.phase { return 7 }
            return 3
        }
        switch s.phase {
        case .idle:
            // 完成短闪窗口(60s):启用固件预留态 2=SDS_COMPLETED(绿短闪),之后回 0 常亮
            if let c = s.completedAt, Date().timeIntervalSince(c) <= 60 { return 2 }
            return 0
        case .processing, .compacting: return s.modelInferring ? 8 : 1
        case .waitingForInput: return 4
        case .waitingForApproval: return 5
        case .ended: return 7
        }
    }

    private static func pushV5Sessions(ble: BLEManager, store: ClaudeHookSessionStore,
                                       codex: CodexSessionMonitor?, usage: ClaudeUsageManager?,
                                       chatGPT: ChatGPTConversationMonitor?,
                                       workBuddy: WorkBuddySessionMonitor?) {
        // REQ-020: CC + Codex 混排 + ChatGPT 普通聊天 + CC/Codex 非活跃排尾;
        // 上限 12 由 sendV5Sessions 截断;mock 数据路径已移除(真实 CodexProvider 替代)
        let ccActiveIds = Set((store.activeSessions).map(\.id))
        let codexActiveIds = Set((codex?.activeSessions ?? []).map(\.id))
        let chatActiveIds = Set(ChatGPTConversationClassifier.deviceConversations(
            chatGPT?.conversations ?? [], availability: chatGPT?.availability ?? .appNotRunning
        ).map(\.id))
        let workBuddyActiveIds = Set((workBuddy?.activeSessions ?? []).map(\.id))
        let activeIds = ccActiveIds.union(codexActiveIds).union(chatActiveIds).union(workBuddyActiveIds)
        let (ordered, inactiveStartOpt) = deviceOrderedSessions(
            store: store, codex: codex, chatGPT: chatGPT, workBuddy: workBuddy
        )

        // 12 条截断必须保住分组边界:活跃块与非活跃块各自独立截断,不跨块挪位。
        let cap = 12
        var activeN = inactiveStartOpt ?? ordered.count
        var kept = Array(ordered.prefix(cap))
        if activeN > cap { activeN = cap }
        let boundary: Int? = (inactiveStartOpt == nil || activeN >= kept.count) ? nil : activeN

        // 直通索引 = 截断后列表中的位置。若目标会话被截断掉,**在其所属块内**与该块末位交换
        // (跨块挪位会破坏 inactiveStart 边界语义,老代码的 "挪到 11 号槽" 在此不再成立)。
        var exclusiveIdx: UInt8 = 0xFF
        if case .exclusive(let sid) = InputRouter.currentMode(),
           let full = ordered.firstIndex(where: { $0.id == sid }) {
            if full < kept.count {
                exclusiveIdx = UInt8(full)
            } else if boundary != nil, full >= (inactiveStartOpt ?? 0) {
                kept[kept.count - 1] = ordered[full]          // 非活跃块末位
                exclusiveIdx = UInt8(kept.count - 1)
            } else if activeN > 0 {
                kept[activeN - 1] = ordered[full]             // 活跃块末位
                exclusiveIdx = UInt8(activeN - 1)
            }
        }

        let sessions: [BLEManager.V5Session] = kept.map { s in
            let isCodex = s.id.hasPrefix("codex-")
            let isChatGPT = s.id.hasPrefix("chatgpt:")
            let isWorkBuddy = s.id.hasPrefix("workbuddy:")
            let ctx: UInt8 = (isCodex || isChatGPT || isWorkBuddy)
                ? (codexCtxPct(s) ?? 0xFF)
                : ((usage?.contextUsedPercent(sessionId: s.id)).flatMap { $0 }
                    .map { UInt8(clamping: $0) } ?? 0xFF)   // REQ-017: 语义=已用%
            return BLEManager.V5Session(
                name: s.projectName,
                agentId: isWorkBuddy ? 2 : ((isCodex || isChatGPT) ? 1 : 0),
                state: v5State(s, isActive: activeIds.contains(s.id)),
                ctxPct: ctx,
                colorIndex: SessionColorManager.shared.colorIndexForSession(s.id, pid: s.pid)
            )
        }

        ble.sendV5Sessions(sessions, exclusiveIndex: exclusiveIdx,
                           inactiveStart: boundary.map { UInt8($0) } ?? 0xFF)
    }

    private static var lastAgentCounts: (active: Int, total: Int, codexTotal: Int, workBuddyTotal: Int) = (-1, -1, -1, -1)

    /// REQ-020: 会话累计 token(input+output+cache_creation+cache_read),与 StatusTab 同口径
    private static func cumulativeTokens(_ s: HookSession) -> Int {
        guard let snap = s.transcriptSnapshot else { return 0 }
        return (snap.totalInputTokens ?? 0) + (snap.totalOutputTokens ?? 0)
             + (snap.totalCacheCreationTokens ?? 0) + (snap.totalCacheReadTokens ?? 0)
    }

    private static func pushV5AgentInfo(ble: BLEManager?, store: ClaudeHookSessionStore?,
                                        codex: CodexSessionMonitor? = nil,
                                        workBuddy: WorkBuddySessionMonitor? = nil,
                                        usage: ClaudeUsageManager?) {
        guard let ble, let store, ble.connectionState == .connected,
              ble.deviceProtocolVersion >= 5 else { return }
        let stats = usage?.stats
        let active = store.activeSessions.count
        let total = active + store.inactiveSessions.count
        let workBuddyTotal = (workBuddy?.activeSessions.count ?? 0) + (workBuddy?.inactiveSessions.count ?? 0)
        let codexTotal = (codex?.activeSessions.count ?? 0) + (codex?.inactiveSessions.count ?? 0)
        lastAgentCounts = (active, total, codexTotal, workBuddyTotal)

        var resetH: UInt8 = 0xFF
        if let resetsAt = stats?.sessionResetsAt {
            let hrs = Int((max(0, resetsAt.timeIntervalSinceNow) / 3600).rounded(.up))
            resetH = UInt8(clamping: hrs)
        }
        // REQ-020: 当日累计 token(delta 累加,spec A1)+ 计费模式(无订阅=API)
        for s in (store.activeSessions + store.inactiveSessions) {
            DailyTokenAccumulator.shared.record(agentKey: "claude", sessionKey: s.id,
                                                cumulativeTokens: cumulativeTokens(s))
        }
        var agents: [BLEManager.V5AgentInfo] = []
        if let billingMode = usage?.billingMode, billingMode.shouldPublishDeviceUsage {
            let claudeBilling: UInt8 = billingMode.isAPI ? 1 : 0
            let claudeDaily = UInt32(clamping: DailyTokenAccumulator.shared.todayTokens(agentKey: "claude"))
            agents.append(BLEManager.V5AgentInfo(
                agentId: 0,
                usage5hPct: UInt8(clamping: Int(stats?.sessionUsedPercent ?? 0)),
                usage7dPct: UInt8(clamping: Int(stats?.weekUsedPercent ?? 0)),
                resetInHours: resetH,
                activeCount: UInt8(clamping: active),
                totalCount: UInt8(clamping: total),
                billingMode: claudeBilling,
                dailyTokens: claudeDaily
            ))
        }
        // REQ-020: 真实 Codex Agent 帧(rate_limits 本地源)。
        // BUG-023(固件 v1.0.1 起支持): 用量 0xFF=窗口不存在哨兵(固件画空条 "--");
        // reset 编码 ≤200=小时,201..254=(值-200)天(codex free 档 30d 窗口超 UInt8 小时上限)
        if let codex, CodexSessionMonitor.isInstalled {
            let rl = codex.latestRateLimits
            // BUG-007:按窗口时长语义分槽(shortWindow/longWindow),不按 primary/secondary
            // 位置——CLI 0.144.4 起可能只报一个周窗且在 primary,位置映射会串行。
            // Codex 不再展示短窗:第 1 行发 0xFF 哨兵画 "--",第 2 行展示长窗。
            let longWin = rl?.longWindow
            var codexResetH: UInt8 = 0xFF
            if let resetsAt = longWin?.resetsAt {
                let hrs = Int((max(0, resetsAt.timeIntervalSinceNow) / 3600).rounded(.up))
                codexResetH = hrs <= 200
                    ? UInt8(hrs)
                    : UInt8(clamping: 200 + Int((Double(hrs) / 24).rounded(.up)))   // 254 封顶=54天
            }
            let codexActive = codex.activeSessions.count
            let codexTotal = codexActive + codex.inactiveSessions.count
            // REQ-020: Codex 当日 token(delta 累加)+ 计费模式(有 plan=订阅,否则=API)
            for s in (codex.activeSessions + codex.inactiveSessions) {
                DailyTokenAccumulator.shared.record(agentKey: "codex", sessionKey: s.id,
                                                    cumulativeTokens: cumulativeTokens(s))
            }
            let codexBilling: UInt8 = CodexSessionMonitor.billingMode(latestPlanType: rl?.planType).isAPI ? 1 : 0
            let codexDaily = UInt32(clamping: DailyTokenAccumulator.shared.todayTokens(agentKey: "codex"))
            agents.append(BLEManager.V5AgentInfo(
                agentId: 1,
                usage5hPct: 0xFF,
                usage7dPct: longWin.map { UInt8(clamping: Int($0.usedPercent)) } ?? 0xFF,
                resetInHours: codexResetH,
                activeCount: UInt8(clamping: codexActive),
                totalCount: UInt8(clamping: codexTotal),
                billingMode: codexBilling,
                dailyTokens: codexDaily
            ))
        }
        // Agent id 2, dynamic labels, and credit metrics are intentionally gated.
        // Legacy firmware can parse at most two fixed Claude/Codex cards and would
        // otherwise render WorkBuddy with the wrong semantics even when count <= 2.
        if let workBuddy, WorkBuddySessionMonitor.isInstalled,
           ble.supportsExtendedAgentCards {
            let workBuddyActive = workBuddy.activeSessions.count
            let workBuddyTotal = workBuddyActive + workBuddy.inactiveSessions.count
            let creditCents = UInt32(clamping: Int((workBuddy.credits.historicalCredits * 100).rounded()))
            agents.append(BLEManager.V5AgentInfo(
                agentId: 2,
                usage5hPct: 0xFF,
                usage7dPct: 0xFF,
                resetInHours: 0xFF,
                activeCount: UInt8(clamping: workBuddyActive),
                totalCount: UInt8(clamping: workBuddyTotal),
                billingMode: 2,
                dailyTokens: creditCents,
                metricKind: 2,
                displayName: "WorkBuddy"
            ))
        }
        ble.sendV5AgentInfo(agents)
    }

    /// 会话数变化立即推 Agent 帧(60s 周期之外的即时性,REQ-007 决策;REQ-020 含 codex 计数)
    private static func pushV5AgentInfoIfCountChanged(ble: BLEManager?, store: ClaudeHookSessionStore?,
                                                      codex: CodexSessionMonitor? = nil,
                                                      workBuddy: WorkBuddySessionMonitor? = nil,
                                                      usage: ClaudeUsageManager?) {
        guard let store else { return }
        let active = store.activeSessions.count
        let total = active + store.inactiveSessions.count
        let codexTotal = (codex?.activeSessions.count ?? 0) + (codex?.inactiveSessions.count ?? 0)
        let workBuddyTotal = (workBuddy?.activeSessions.count ?? 0) + (workBuddy?.inactiveSessions.count ?? 0)
        if (active, total, codexTotal, workBuddyTotal) != lastAgentCounts {
            pushV5AgentInfo(ble: ble, store: store, codex: codex,
                            workBuddy: workBuddy, usage: usage)
        }
    }

    /// v5 config 下发:语音模式(REQ-010)+ 自定义 Prompt 标题(REQ-011)。
    /// 设置变更时也调用(设置 UI 侧触发)。
    static func pushV5Config(ble: BLEManager?) {
        guard let ble, ble.connectionState == .connected else { return }
        let titles = loadMicpadPromptTitles()
        // T-033:音源在"下发时刻"定死。若所选系统麦不可用 → 就地回退设备麦 + 发通知,
        // 下发 micSource=0,保证设备侧不会停采而 Mac 又没接上 → 不存在空录窗口。
        let manager = VoiceInputManager.shared
        var micSource: UInt8 = 0
        switch manager?.resolveMicSourceNow() ?? .device {
        case .device:
            manager?.audioCapture.disarmPreroll()
        case .system(let deviceID, let name):
            micSource = 1
            manager?.audioCapture.armPreroll(deviceID: deviceID)   // 常驻预滚,消除按下首字丢失
            ClaudeCodeSessionManager.log("[T-033] mic source = system mic: \(name)")
        case .fellBack(let reason):
            manager?.audioCapture.disarmPreroll()
            notifyMicFallback(reason)                   // §1.9 弹系统通知
            ClaudeCodeSessionManager.log("[T-033] mic fallback -> device mic: \(reason)")
        }
        // PCB v12 automatically distinguishes A tap/double-tap/hold. Keep the
        // legacy byte at zero for older protocol-v5 firmware compatibility.
        let displayLanguage: DeviceDisplayLanguage = DeviceType.isMicStickName(ble.memorizedDeviceName)
            ? .selected : .simplifiedChinese
        ble.sendV5Config(
            voiceMode: 0,
            promptTitles: titles,
            micSource: micSource,
            language: displayLanguage,
            laboratoryFeatures: LaboratoryFeatureSettings.protocolFlags
        )
    }

    static func captureDevicePreferenceState(ble: BLEManager?) {
        guard VibePanelBLE.isPadName(ble?.memorizedDeviceName) else { return }
        let defaults = UserDefaults.standard
        let promptCount = (defaults.array(forKey: "micpadPrompts") as? [[String: String]])?.count ?? 0
        AnalyticsClient.shared.captureDevicePreferenceState(
            deviceType: "micpad",
            buzzerMuted: defaults.bool(forKey: BLEManager.buzzerMutedKey),
            buzzerVolumePercent: defaults.object(forKey: BLEManager.buzzerVolumePercentKey) as? Int ?? 60,
            ledBrightnessPercent: defaults.object(forKey: BLEManager.ledBrightnessPercentKey) as? Int ?? 32,
            micSource: (MicSourceMode(rawValue: defaults.integer(forKey: MicSourceMode.defaultsKey)) ?? .device) == .system ? "system" : "device",
            voiceMode: "automatic",
            customPromptCount: promptCount
        )
    }

    static func captureAnalyticsSnapshots(
        ble: BLEManager?,
        manager: VoiceInputManager,
        modelManager: ASRModelManager,
        historyManager: RecognitionHistoryManager
    ) {
        capturePermissionStateSnapshot()
        captureDevicePreferenceState(ble: ble)
        captureSettingsState(manager: manager, modelManager: modelManager, historyManager: historyManager)
    }

    static func capturePermissionStateSnapshot() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let notificationGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            AnalyticsClient.shared.capturePermissionState(
                // Microphone permission is intentionally requested and inspected only
                // when the user starts recording with the Mac microphone.
                microphone: "on_demand",
                bluetooth: CBManager.authorization == .allowedAlways ? "granted" : "denied",
                accessibility: KeyboardSimulator.hasAccessibilityPermission ? "granted" : "denied",
                notification: notificationGranted ? "granted" : "denied"
            )
        }
    }

    @MainActor
    static func captureSettingsState(
        manager: VoiceInputManager,
        modelManager: ASRModelManager,
        historyManager: RecognitionHistoryManager
    ) {
        let defaults = UserDefaults.standard
        let overlayInputMode = manager.overlayModeRaw == "editor" ? "editor" : "capsule"
        let overlayFontSize: String = {
            switch defaults.object(forKey: "overlayFontScale") as? Double ?? 1.0 {
            case 2.0: return "large"
            case 3.0: return "xlarge"
            default: return "default"
            }
        }()
        let customHotwordCount = ASRHotwordInputParser.parse(manager.customHotwords, limit: 20).count
        let launchAtLoginEnabled: Bool = {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }()
        AnalyticsClient.shared.captureSettingsState(
            launchAtLoginEnabled: launchAtLoginEnabled,
            aiUsageStatsEnabled: defaults.object(forKey: "claudeIntegrationEnabled") as? Bool ?? true,
            overlayInputMode: overlayInputMode,
            overlayFontSize: overlayFontSize,
            historyLimit: historyManager.maxRecords,
            historyCountBucket: AnalyticsSupport.textLengthBucket(historyManager.records.count),
            asrEngine: manager.asrEngine.rawValue,
            punctuationEnabled: manager.enablePunctuation,
            itnPostprocessEnabled: manager.itnPostProcessEnabled,
            recognitionBoostEnabled: defaults.object(forKey: RecognitionBoostSettings.enabledKey) as? Bool ?? true,
            deepseekPostprocessEnabled: defaults.object(forKey: "deepseekPostprocessEnabled") as? Bool ?? false,
            customHotwordCount: customHotwordCount,
            localOfflineModelDownloaded: modelManager.state == .ready,
            localStreamingModelDownloaded: modelManager.streamingState == .ready,
            firstRunCompleted: defaults.object(forKey: FirstRunSetupState.hasCompletedKey) as? Bool ?? false
        )
    }

    /// T-033 §1.9:回退不静默,弹系统通知告知用户已改用设备麦。
    static func notifyMicFallback(_ reason: String) {
        guard !UITestFlags.isHeadless else {          // TCC 铁律
            NSLog("[ui-test] skipped mic-fallback notification — headless")
            return
        }
        let c = UNMutableNotificationContent()
        c.title = AppL10n.tr("麦克风已回退")
        c.body  = AppL10n.format("%@，已改用设备麦克风。", reason)
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "mic-fallback-\(UUID().uuidString)", content: c, trigger: nil))
    }

    /// BUG-032:系统麦采集 0 样本(蓝牙麦激活延迟内松键/输入设备无声)——不静默,提示用户原因。
    static func notifyMicCaptureEmpty() {
        guard !UITestFlags.isHeadless else {          // TCC 铁律
            NSLog("[ui-test] skipped mic-capture-empty notification — headless")
            return
        }
        let c = UNMutableNotificationContent()
        c.title = AppL10n.tr("系统麦克风无音频输入")
        c.body  = AppL10n.tr("本次录音没有采到声音。请检查所选系统麦克风是否可用（蓝牙麦克风需 1-3 秒激活）。")
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "mic-empty-\(UUID().uuidString)", content: c, trigger: nil))
    }

    /// 自定义 Prompt 存储:UserDefaults "micpadPrompts" = [[title:..., body:...]](REQ-011)
    static func loadMicpadPromptTitles() -> [String] {
        guard let arr = UserDefaults.standard.array(forKey: "micpadPrompts") as? [[String: String]] else { return [] }
        return arr.compactMap { $0["title"] }
    }

    // REQ-022:原 pushApprovalV5(按优先级推断审批目标 → 裸 JSON permRequest 通道)
    // 已删除。审批推送在挂起注册时由 ApprovalCoordinator 发 0x55(带 reqId),
    // 回传走 0x36,撤销/确认走 0x56;多条并发全部下推,不再只推一条。

    /// Shared logic: push current Claude session status to Stick S3 via BLE
    private static func pushClaudeStatusToBLE(
        ble: BLEManager?,
        store: ClaudeHookSessionStore?,
        voiceManager: VoiceInputManager?,
        usage: ClaudeUsageManager? = nil
    ) {
        guard let ble, let store, ble.connectionState == .connected else { return }

        // Skip BLE pushes during voice input to avoid conflicts
        if let mgr = voiceManager,
           mgr.state == .recording || mgr.state == .processing { return }

        // Get usage percentages
        let usagePct = UInt8(min(usage?.stats?.sessionUsedPercent ?? 0, 100))
        let ctxPct = UInt8(min(usage?.stats?.contextUsedPercent ?? 0, 100))

        // v4 dashboard extras: token/code counters + up to 5 active sessions (exclusive pinned to index 0)
        let stats = usage?.stats
        let tokenInK = UInt16(min((stats?.inputTokens ?? 0) / 1000, 65535))
        let tokenOutK = UInt16(min((stats?.outputTokens ?? 0) / 1000, 65535))
        let linesAdded = UInt16(min(stats?.linesAdded ?? 0, 65535))
        let linesRemoved = UInt16(min(stats?.linesRemoved ?? 0, 65535))

        func dashboardPhase(_ p: SessionPhase) -> UInt8 {
            switch p {
            case .idle: return 0
            case .processing: return 1
            case .waitingForInput: return 2
            case .waitingForApproval: return 3
            case .compacting: return 4
            case .ended: return 5
            }
        }

        // 1. Determine exclusive session (if any)
        let exclusiveSessionId: String? = {
            if case .exclusive(let sid) = InputRouter.currentMode() { return sid }
            return nil
        }()

        // 2. Build session list: exclusive session force-pinned to index 0
        var orderedSessions: [HookSession] = []
        var exclusiveIdx: UInt8 = 0xFF

        if let exSid = exclusiveSessionId,
           let exSession = store.sessions[exSid],
           exSession.phase != .ended {
            orderedSessions.append(exSession)
            exclusiveIdx = 0
            let rest = store.activeSessions.filter { $0.id != exSid }.prefix(4)
            orderedSessions.append(contentsOf: rest)
        } else {
            orderedSessions = Array(store.activeSessions.prefix(5))
        }

        let dashboardSessions = orderedSessions.map { s in
            BLEManager.DashboardSession(
                name: s.projectName,
                colorIndex: SessionColorManager.shared.colorIndexForSession(s.id, pid: s.pid),
                phase: dashboardPhase(s.phase)
            )
        }

        // 3. Pick active session for phase/toolName push
        // Exclusive mode: reuse orderedSessions[0] (same object as BLE list, no timing window)
        let active: HookSession
        if exclusiveIdx == 0 {
            active = orderedSessions[0]
        } else {
            guard let a = store.pendingApproval ?? store.activeSession else {
                ble.sendClaudeStatus(
                    phase: 0xFF, sessionCount: 0, projectName: "", toolName: "",
                    usagePercent: usagePct, contextPercent: ctxPct,
                    tokenInK: tokenInK, tokenOutK: tokenOutK,
                    linesAdded: linesAdded, linesRemoved: linesRemoved,
                    sessions: dashboardSessions,
                    exclusiveIndex: exclusiveIdx
                )
                return
            }
            active = a
        }

        let phase = dashboardPhase(active.phase)
        let count = UInt8(min(store.activeSessions.count, 255))
        let colorIdx = SessionColorManager.shared.colorIndexForSession(active.id, pid: active.pid)
        ble.sendClaudeStatus(
            phase: phase,
            sessionCount: count,
            projectName: active.projectName,
            toolName: active.lastTool ?? "",
            colorIndex: colorIdx,
            usagePercent: usagePct,
            contextPercent: ctxPct,
            tokenInK: tokenInK,
            tokenOutK: tokenOutK,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            sessions: dashboardSessions,
            exclusiveIndex: exclusiveIdx
        )

        // REQ-022(E2):v4(Stick S3)的裸 JSON 审批 toast 推送已随
        // sendPermissionRequest 通道一并移除;Stick S3 无 0x55 能力,本期无审批提示。
    }

    private var menuBarIcon: String {
        switch manager.state {
        case .recording: "mic.fill"
        case .processing: "ellipsis.circle"
        case .error: "exclamationmark.triangle"
        case .idle: "waveform.circle"
        }
    }
}

/// REQ-020: 每-agent「当日累计 token」聚合(spec A1 口径)。
///
/// 当日累计 token = 本地时区自然日内,该 agent 各会话「累计 token 计数器
/// (input+output+cache_creation+cache_read)」正增量之和,跨自然日归零。
/// 用 delta 累加实现:会话内计数器单调递增,取 max(0, 当前累计 - 该会话上次累计)
/// 累加进当天桶。机制对齐 ClaudeUsageManager.recordDailyPeak。
///
/// last[session] 与 buckets 均持久化到
/// ~/Library/Application Support/QuickVibeHost/usage-daily-tokens.json,
/// App 重启后不把整段历史重算进当天(delta 从上次持久值起算)。
@MainActor
final class DailyTokenAccumulator {
    static let shared = DailyTokenAccumulator()

    private struct Persisted: Codable {
        var buckets: [String: [String: Int]]   // agentKey → (dayKey → 累计 delta)
        var last: [String: Int]                 // "agentKey|sessionKey" → 上次见到的会话累计
    }

    private var buckets: [String: [String: Int]] = [:]
    private var last: [String: Int] = [:]

    private var path: String {
        NSHomeDirectory() + "/Library/Application Support/QuickVibeHost/usage-daily-tokens.json"
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"     // 本地时区自然日
        return f.string(from: date)
    }

    init() { load() }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        buckets = p.buckets
        last = p.last
    }

    private func persist() {
        let p = Persisted(buckets: buckets, last: last)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// 记录某 agent 某会话的最新累计 token;正增量累加进当天桶(跨日自动落到新 dayKey)。
    /// 首次见到会话时 seed(不把已有历史算进当天,delta=0)。
    func record(agentKey: String, sessionKey: String, cumulativeTokens: Int) {
        let lk = "\(agentKey)|\(sessionKey)"
        let prev = last[lk]
        if prev == cumulativeTokens { return }   // 无变化,跳过持久化
        let delta = (prev == nil) ? 0 : max(0, cumulativeTokens - prev!)
        last[lk] = cumulativeTokens
        if delta > 0 {
            let key = Self.dayKey(Date())
            var m = buckets[agentKey] ?? [:]
            m[key, default: 0] += delta
            let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date())
            buckets[agentKey] = m.filter { $0.key >= cutoff }   // 保留 30 天
        }
        persist()
    }

    /// 当天(本地自然日)该 agent 累计 token;无记录返回 0。
    func todayTokens(agentKey: String) -> Int {
        buckets[agentKey]?[Self.dayKey(Date())] ?? 0
    }
}

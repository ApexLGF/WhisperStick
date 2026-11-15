import Foundation
import CoreBluetooth
import os

/// VibeEverything BLE GATT Service/Characteristic UUIDs
/// These must match the firmware side (QuickVibeStickS3)
enum VibePanelBLE {
    static let audioServiceUUID = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    static let audioDataCharUUID = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    static let controlCharUUID = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    static let claudeStatusCharUUID = CBUUID(string: "19B10003-E8F2-537E-4F6C-D104768A1214")
    static let permRequestCharUUID = CBUUID(string: "19B10004-E8F2-537E-4F6C-D104768A1214")
    static let permResponseCharUUID = CBUUID(string: "19B10005-E8F2-537E-4F6C-D104768A1214")
    static let otaServiceUUID = CBUUID(string: "19B10010-E8F2-537E-4F6C-D104768A1214")
    static let otaControlCharUUID = CBUUID(string: "19B10011-E8F2-537E-4F6C-D104768A1214")
    static let otaDataCharUUID = CBUUID(string: "19B10012-E8F2-537E-4F6C-D104768A1214")
    static let otaStatusCharUUID = CBUUID(string: "19B10013-E8F2-537E-4F6C-D104768A1214")

    /// Protocol version — increment when BLE data format changes (must match firmware)
    /// v3: dashboard payload (token/code/session list) + device polls status via 0x21
    /// v4: 5 sessions + exclusive session index byte(Stick S3 现行版本)
    static let protocolVersion: UInt8 = 4
    /// v5(REQ-007,仅 MicPad v1.0.0):多 Agent 帧 0x51 sessions / 0x52 agent info /
    /// 0x53 config;版本不匹配拒连。Stick S3 不受影响,仍走 v4。
    static let micPadProtocolVersion: UInt8 = 5

    /// v5 自制 PCB 设备(MicPad + MicStick v12 同协议同特性)。名字前缀判定:
    /// MicStick 是 MicPad 衍生的新产品线(v12,PROTOCOL_VERSION 5),UI/帧格式完全一致。
    /// 用此 helper 统一识别,避免漏判导致 onDeviceReadyV5 不触发(会话卡"跳舞"页)/ 误当 StickS3。
    static func isPadName(_ name: String?) -> Bool {
        guard let n = name else { return false }
        return n.hasPrefix("MicPad") || DeviceType.isMicStickName(n)
    }
}

/// Lightweight value type for SwiftUI display — no CBPeripheral references
struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    var rssi: Int
    /// 从广播 Service UUID 推导的设备类型；无匹配则为 nil（扫描侧会直接过滤）。
    var type: DeviceType?
}

enum BLEConnectionState: String {
    case disconnected
    case scanning
    case connecting
    case connected

    var displayName: String {
        switch self {
        case .disconnected: AppL10n.tr("未连接")
        case .scanning: AppL10n.tr("扫描中...")
        case .connecting: AppL10n.tr("连接中...")
        case .connected: AppL10n.tr("已连接")
        }
    }
}

@MainActor
final class BLEManager: NSObject, ObservableObject {
    /// 对 UI 友好的记忆设备生命周期，由 connection/重连状态派生。
    enum DeviceLifecycleState: Equatable {
        case noMemory
        case memorizedConnected
        case memorizedReconnecting(attempt: Int)
        /// 快速重连耗尽后挂起系统级 pending connect(永不超时,设备一广播即连)
        case memorizedWaiting
        case memorizedFailed
    }

    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDeviceName: String?
    @Published var isReceivingAudio = false
    @Published var characteristicsReady = false
    @Published var packetsReceived: UInt32 = 0
    @Published var bytesReceived: Int = 0

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var connectingPeripheral: CBPeripheral?
    private var disconnectingPeripheral: CBPeripheral?
    private var shouldScanAfterDisconnect = false
    private var audioDataCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var claudeStatusCharacteristic: CBCharacteristic?
    private var permRequestCharacteristic: CBCharacteristic?
    private var otaControlCharacteristic: CBCharacteristic?
    private var otaDataCharacteristic: CBCharacteristic?
    private var otaStatusCharacteristic: CBCharacteristic?
    private var otaImageURL: URL?
    private var otaSignature: Data?
    private var otaOffset: Int = 0
    private var otaChunkSize: Int = 0
    private var otaPumpTask: Task<Void, Never>?
    private var otaAckTimeoutTask: Task<Void, Never>?
    private var otaManifestTask: Task<Void, Never>?
    private var otaRelease: MicStickFirmwareRelease?
    private var otaInfo: MicStickOTAInfo?
    private var otaSendOffset: Int = 0
    private var otaBeginSent = false
    private var otaBeginFragments: [Data] = []
    private var otaBeginFragmentIndex = 0
    private var otaFinishSent = false
    private var otaInfoRequested = false
    private var otaInfoResponseTimeoutTask: Task<Void, Never>?
    private var otaBootVerificationTask: Task<Void, Never>?
    private var otaBootVerificationDeadline: Date?
    private enum MicStickOTAControlOperation: Equatable {
        case info
        case begin
        case finish
        case abort

        var logName: String {
            switch self {
            case .info: return "info"
            case .begin: return "begin"
            case .finish: return "finish"
            case .abort: return "abort"
            }
        }
    }
    private struct PendingMicStickOTAControlWrite {
        let data: Data
        let operation: MicStickOTAControlOperation
        var retryPolicy = MicStickOTARetryPolicy()
    }
    private var pendingMicStickOTAControlWrite: PendingMicStickOTAControlWrite?
    private var queuedMicStickOTAControlWrite: PendingMicStickOTAControlWrite?
    private var otaControlWriteTimeoutTask: Task<Void, Never>?
    private var otaTargetVersion: AppVersion?
    private var otaTargetPeripheralID: UUID?
    private var otaTransferWindow = MicStickOTATransferWindow(startOffset: 0)
    private var otaRetryPolicy = MicStickOTARetryPolicy()
    private var otaInfoRetryPolicy = MicStickOTARetryPolicy()
    private var otaAbortState = MicStickOTAAbortState()
    @Published private(set) var micStickFirmwareVersion: String?
    @Published private(set) var firmwareUpdateState: MicStickFirmwareUpdateState = .unavailable
    @Published private(set) var firmwareUpdateProgress: Double?

    private static let compatibilityURL = URL(string: "https://vibeeverything.cc/compatibility.json")!
    private static let firmwareBaseURL = URL(string: "https://vibeeverything.cc")!
    private static let otaAckTimeoutNanoseconds: UInt64 = 3_000_000_000
    private var activeActionModeContext: DeviceActionContext?
    /// CBPeripheral references keyed by UUID — kept separate from SwiftUI-visible state
    private var peripheralMap: [UUID: CBPeripheral] = [:]
    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "BLE")

    /// BLE 事件文件日志(2026-07-08):os_log 不可事后检索,冻结排查需要断连时间戳。
    /// 追加到 ~/Library/Logs/QuickVibeHost/ble-events.log,格式:ISO时间 事件 详情
    private static let eventLogURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/QuickVibeHost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ble-events.log")
    }()
    nonisolated static func logEvent(_ event: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(event)\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: eventLogURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: eventLogURL)
            }
        }
    }

    nonisolated private static func describeAdvertisementData(_ data: [String: Any]) -> String {
        data.keys.sorted().map { key in
            let value = data[key]
            if let uuids = value as? [CBUUID] {
                return "\(key)=\(uuids.map(\.uuidString).joined(separator: ","))"
            }
            if let bytes = value as? Data {
                return "\(key)=data[\(bytes.count)]:\(bytes.map { String(format: "%02X", $0) }.joined())"
            }
            if let dict = value as? [String: Any] {
                return "\(key)=dict[\(dict.keys.sorted().joined(separator: ","))]"
            }
            return "\(key)=\(String(describing: value))"
        }.joined(separator: " ")
    }

    private func logState(_ event: String) {
        BLEManager.logEvent(
            "BLESTATE \(event) app=\(connectionState.rawValue) central=\(centralManager?.state.rawValue ?? -1) connected=\(connectedPeripheral?.identifier.uuidString ?? "nil") connecting=\(connectingPeripheral?.identifier.uuidString ?? "nil") disconnecting=\(disconnectingPeripheral?.identifier.uuidString ?? "nil") pending=\(pendingPeripheral?.identifier.uuidString ?? "nil") manual=\(isManualDisconnect) timeout=\(isTimeoutCancel) scanAfterDisconnect=\(shouldScanAfterDisconnect) discovered=\(discoveredDevices.count) last=\(lastDeviceUUIDString.isEmpty ? "nil" : lastDeviceUUIDString)"
        )
    }

    private func logMicStickOTA(_ event: String) {
        BLEManager.logEvent(
            "OTA \(event) hostState=\(String(describing: firmwareUpdateState)) " +
            "device=\(connectedPeripheral?.identifier.uuidString ?? otaTargetPeripheralID?.uuidString ?? "nil")"
        )
    }

    // Auto-reconnect
    private static let lastDeviceUUIDKey = "lastConnectedBLEDeviceUUID"
    private var lastDeviceUUIDString: String {
        get { UserDefaults.standard.string(forKey: Self.lastDeviceUUIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastDeviceUUIDKey) }
    }
    /// 记忆设备的广播名(仅持久化 UUID 冷启动认不出 MicPad / Stick,故一并存名)。
    private static let lastDeviceNameKey = "lastConnectedBLEDeviceName"
    private var lastDeviceNameString: String {
        get { UserDefaults.standard.string(forKey: Self.lastDeviceNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastDeviceNameKey) }
    }
    @Published private(set) var autoReconnectAttempts = 0
    private let maxAutoReconnectAttempts = 10
    private var serviceDiscoveryRetries = 0
    private var charDiscoveryRetries = 0
    private var autoReconnectTimer: Timer?
    private var connectTimeoutTimer: Timer?
    private var isManualDisconnect = false
    /// 快速重连耗尽后进入"挂起等待":发一个不带超时的 connect() 交给系统,
    /// 设备哪怕几小时后才重新广播也会瞬间回调 didConnect(CoreBluetooth 原生 pending connect,零功耗)
    @Published private(set) var isPendingWait = false
    private var pendingPeripheral: CBPeripheral?

    /// Protocol version reported by device (0 = unknown/old firmware,UI 绑定需 Published)
    @Published var deviceProtocolVersion: UInt8 = 0
    /// Optional fourth byte of 0x3B. Unknown/old hardware reports 0 so the App
    /// never exposes irreversible features without an explicit capability.
    @Published private(set) var deviceHardwareRevision: UInt8 = 0
    /// Optional fifth byte of 0x3B. Capability bits gate backward-compatible extensions.
    @Published private(set) var deviceCapabilities: UInt8 = 0
    @Published private(set) var deviceMaxAgentCards: UInt8 = 2
    var supportsDynamicSceneModes: Bool { deviceCapabilities & 0x01 != 0 }
    var supportsDynamicPromptRecommendations: Bool { deviceCapabilities & 0x02 != 0 }
    var supportsInputAssistant: Bool { deviceCapabilities & 0x04 != 0 }
    /// Bit 3 couples the device-rendered running-App list with the revised
    /// scene gesture contract (D tap cycles, D hold exits).
    var supportsApplicationListSwitcher: Bool { deviceCapabilities & 0x08 != 0 }
    /// Bit 4: task sounds are driven by explicit Prompt lifecycle events rather
    /// than inferred from frequently changing session status frames.
    var supportsExplicitTaskLifecycle: Bool { deviceCapabilities & 0x10 != 0 }
    /// Bit 5: 0x52 supports more than two cards plus metric/name metadata.
    var supportsExtendedAgentCards: Bool { deviceCapabilities & 0x20 != 0 }

    /// v5(REQ-007):MicPad 协议版本不匹配时的提示文案(nil = 正常);触发即断连
    @Published var versionMismatchMessage: String?
    /// v5 握手通过后的回调(App 层推 config + 全量状态帧)
    var onDeviceReadyV5: (() -> Void)?
    var onDeviceCapabilitiesChanged: (() -> Void)?
    /// v5(REQ-011):设备 Prompt 选择(0=内置"AI推荐" 1..8=自定义)
    var onPromptSelect: ((UInt8) -> Void)?
    var onPromptRecommendationRequest: ((UInt8) -> Void)?
    var onDynamicPromptSelect: ((UInt8, UInt8) -> Void)?
    var onInputAssistantRequest: ((UInt8) -> Void)?
    var onInputAssistantAction: ((UInt8, UInt8) -> Void)?
    /// v5(REQ-013):设备请求切换直通会话(索引 = v5 会话帧顺序)
    var onExclusiveToggle: ((UInt8) -> Void)?
    /// v5(REQ-012):设备 UI 模式变化(0=normal 1=edit 2=prompt)
    var onDeviceModeChange: ((UInt8) -> Void)?
    /// PCB v12 reports semantic B/C/D gestures; Host owns the actual macOS actions.
    var onDeviceAction: ((DeviceActionEvent) -> Void)?

    private static var devicePreferenceEchoSuppressedUntil: Date = .distantPast

    static func shouldSuppressDevicePreferenceEcho() -> Bool {
        Date() < devicePreferenceEchoSuppressedUntil
    }

    /// 当前连接设备是否为 MicPad(广播名前缀分型,与 didDiscover 逻辑一致)
    var isConnectedMicPad: Bool { VibePanelBLE.isPadName(connectedDeviceName) }
    /// 当前连接是否为 MicStick；运输模式能力还需结合硬件版本判断。
    var isConnectedMicStick: Bool { DeviceType.isMicStickName(connectedDeviceName ?? "") }
    var supportsTransportMode: Bool {
        isConnectedMicStick && deviceHardwareRevision >= 13
    }
    var availableMicStickFirmwareVersion: String? {
        otaRelease?.latest.description
    }
    /// 按设备类型给出期望协议版本(MicPad=5,Stick S3=4)
    var expectedProtocolVersion: UInt8 {
        isConnectedMicPad ? VibePanelBLE.micPadProtocolVersion : VibePanelBLE.protocolVersion
    }

    /// 是否存在已记忆设备（连接过一次就算）。
    var hasMemorizedDevice: Bool {
        !lastDeviceUUIDString.isEmpty
    }

    /// 由连接态 + 重连计数派生的 UI 生命周期。
    var deviceLifecycle: DeviceLifecycleState {
        guard hasMemorizedDevice else { return .noMemory }
        if connectionState == .connected { return .memorizedConnected }
        if autoReconnectAttempts > 0 && autoReconnectAttempts < maxAutoReconnectAttempts {
            return .memorizedReconnecting(attempt: autoReconnectAttempts)
        }
        if isPendingWait { return .memorizedWaiting }
        // 还未启动重连 / pending 都挂不上(设备不可检索)→ failed(显示"未连接 / 重新连接")
        return .memorizedFailed
    }

    /// 可读的记忆设备名；未连接过或已忘记时为 nil。
    /// 冷启动未连接时回落到持久化的设备名，驱动正确选卡(Stick/MicPad)。
    var memorizedDeviceName: String? {
        connectedDeviceName ?? (lastDeviceNameString.isEmpty ? nil : lastDeviceNameString)
    }

    var diagnosticDeviceUUID: String? {
        connectedPeripheral?.identifier.uuidString
            ?? (lastDeviceUUIDString.isEmpty ? nil : lastDeviceUUIDString)
    }

    var diagnosticDeviceType: String {
        if isConnectedMicPad { return DeviceType.micPad.rawValue }
        let name = memorizedDeviceName ?? ""
        if name.hasPrefix("MicPad") { return DeviceType.micPad.rawValue }
        if name.hasPrefix("QuickVibeStick") || name.hasPrefix("Stick") { return DeviceType.stickS3.rawValue }
        return "unknown"
    }

    private func analyticsDeviceType(_ type: DeviceType? = nil) -> String {
        if let type { return AnalyticsSupport.deviceTypeName(type) }
        switch diagnosticDeviceType {
        case DeviceType.micPad.rawValue: return "micpad"
        case DeviceType.stickS3.rawValue: return "sticks3"
        default: return "unknown"
        }
    }

    /// 清空设备记忆并断开当前连接。二次确认在 UI 层做。
    func forgetDevice() {
        guard MicStickOTAResumePolicy.allowsManualDisconnect(state: firmwareUpdateState) else {
            logger.warning("Ignoring device removal while MicStick OTA is in progress")
            return
        }
        BLEManager.logEvent("FORGET requested state=\(connectionState.rawValue) connected=\(connectedPeripheral?.identifier.uuidString ?? "nil") connecting=\(connectingPeripheral?.identifier.uuidString ?? "nil")")
        logState("forget.begin")
        let hasActivePeripheral = connectedPeripheral != nil || connectingPeripheral != nil || pendingPeripheral != nil || disconnectingPeripheral != nil
        isManualDisconnect = hasActivePeripheral
        cancelAutoReconnect()
        clearPendingWait(cancelConnection: true)
        if let peripheral = connectedPeripheral {
            disconnectingPeripheral = peripheral
            centralManager.cancelPeripheralConnection(peripheral)
        }
        if let peripheral = connectingPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceUUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceNameKey)
        if firmwareUpdateState == .downloading || firmwareUpdateState == .transferring {
            cancelMicStickFirmwareUpdate()
        }
        cleanup()
        resetMicStickOTAState()
        logState("forget.afterCleanup")
        // 手动触发的一次 objectWillChange — lastDeviceUUIDString 直接读 UserDefaults 不会自动通知 UI
        objectWillChange.send()
    }

    /// "重新连接"按钮：拉起一次自动重连循环。
    func retryConnect() {
        guard hasMemorizedDevice else { return }
        cancelAutoReconnect()
        clearPendingWait(cancelConnection: true)
        attemptAutoReconnect()
    }

    // Audio decoding
    private var adpcmDecoder = ADPCMDecoder()
    private var pcmBuffer: [Int16] = []
    private let pcmBufferLock = NSLock()
    /// 流式 tee:解码后的 PCM samples 同步抛出(VoiceInputManager 接)。nil = 不 tee。
    var onPCMChunk: (([Int16]) -> Void)?
    /// 实时音频 RMS 电平回调(0~1),驱动浮窗录音波形。主线程回调。
    var onLevel: ((Float) -> Void)?
    /// Button ID from current audio stream (parsed from packet header in protocol v2+)
    var audioStreamButtonId: UInt8 = 0x01

    // Write retry tracking for critical writes
    private struct PendingWrite {
        let data: Data
        let characteristic: CBCharacteristic
        var retryCount: Int = 0
        static let maxRetries = 2
    }
    private var pendingWrites: [CBUUID: PendingWrite] = [:]
    /// Characteristic UUIDs that should be retried on write failure
    /// (REQ-022:permRequest 裸 JSON 通道已删,不再有写入,移出重试集)
    private let retryableCharUUIDs: Set<CBUUID> = [
        VibePanelBLE.claudeStatusCharUUID,
    ]

    // REQ-022(review fix):approval 帧(0x55/0x56)独立完成追踪 —— 与 legacy
    // writeWithRetry 的按-uuid 单槽机制彻底分离。两者共用 claudeStatus 特征值,
    // 若不区分,didWriteValueFor 会归因错乱:approval 帧失败会触发重发单槽里
    // 别人的旧帧、approval 帧成功会误清别人的重试记录。
    // 归因依据:GATT write-with-response 是 ATT 串行事务(同一时刻至多一个在途
    // 请求),didWriteValueFor 回调顺序 == writeValue 发出顺序 → 用每-uuid 的
    // kind FIFO 即可无歧义区分每次完成属于哪条路径。
    // 约束:对 claudeStatus 的写必须且只能经 writeWithRetry(入队 .legacy)或
    // sendApprovalFrame(入队 .approval)二者之一,否则 FIFO 失配。
    private enum TrackedWriteKind { case legacy, approval, applicationSwitcher, taskLifecycle }
    /// 每-uuid 在途写的类型队列(FIFO,与发出顺序一致)
    private var inFlightWriteKinds: [CBUUID: [TrackedWriteKind]] = [:]
    private struct ApprovalPendingWrite {
        let data: Data
        var retryCount: Int = 0
        static let maxRetries = 3
    }
    /// approval 帧在途/重试队列(FIFO,与 inFlightWriteKinds 中的 .approval 一一对应)
    private var approvalInFlight: [ApprovalPendingWrite] = []
    private struct ApplicationSwitcherPendingWrite {
        let data: Data
        var retryCount = 0
        static let maxRetries = 2
    }
    private var applicationSwitcherWriteQueue: [ApplicationSwitcherPendingWrite] = []
    private var applicationSwitcherWriteInFlight: ApplicationSwitcherPendingWrite?
    private struct TaskLifecyclePendingWrite {
        let data: Data
        var retryCount = 0
        static let maxRetries = 3
    }
    private var taskLifecycleWriteQueue: [TaskLifecyclePendingWrite] = []
    private var taskLifecycleWriteInFlight: TaskLifecyclePendingWrite?

    // Packet loss tracking
    private var lastSeq: UInt16 = 0
    private var packetsLost: Int = 0
    private var packetsOutOfOrder: Int = 0

    // Auto-detect end of audio stream (no new packets for timeout)
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 1.5
    private let pttStopDrainTimeout: TimeInterval = 0.15  // Short drain window after PTT stop
    /// REQ-005 Phase 1: 最小录音时长门槛 (BLE 首帧 → END 帧 wall-clock Δt)
    /// < kMinRecordingDurationMs 静默丢弃,不调 ASR,不弹 toast/menu bar。
    private let kMinRecordingDurationMs: Int = 500
    /// BLE audio session 首帧 wall-clock 时间;finalizeRecording 取它算 Δt。
    private var sessionStartTime: Date?
    /// Timestamp of last audio packet — used to detect stuck isReceivingAudio
    private var lastAudioPacketTime: Date?
    /// Set when PTT stop command received — waiting for in-flight packets to drain
    private var pttStopReceived = false
    /// BUG-032: 系统麦 PTT 看门狗 —— 0x19 后 0x14 丢失(BLE notify 丢帧/固件漏发)时,
    /// Mac 停留采集态且设备卡"正在识别",双侧无自愈。60s 未收 0x14 则视同收到,触发正常收尾。
    private var pttWatchdogTimer: Timer?
    private let pttWatchdogTimeout: TimeInterval = 60

    /// Called when BLE audio stream ends and WAV data is ready
    var onAudioReady: ((Data) -> Void)?
    var onAudioStreamAborted: (() -> Void)?
    /// Called when a control command is received from the device (Enter=0x10, ESC=0x11)
    var onControlCommand: ((UInt8) -> Void)?
    /// Called when BLE audio stream starts (first packet received). Passes buttonId (固定 0x01=A;Button B 不再发起音频)
    var onAudioStreamStarted: ((UInt8) -> Void)?
    /// Called when device polls for status (CMD_REQUEST_STATUS=0x21, v3+)
    var onStatusRequestFromDevice: (() -> Void)?
    /// T-033: 设备在系统麦模式下按下 PTT(CMD_BTN_A_PTT_START=0x19)。设备不会发音频流。
    var onPTTStart: (() -> Void)?
    /// T-033: PTT 松开(0x14)。设备麦模式下 BLE 内部已做 drain;此回调供系统麦模式收尾。
    var onPTTStop: (() -> Void)?
    /// REQ-022:设备 0x36 审批应答帧(完整 4B 帧)→ ApprovalCoordinator 解码处理
    var onApprovalResponse: ((Data) -> Void)?

    override init() {
        super.init()
        guard !UITestFlags.isHeadless else {
            NSLog("[ui-test] skipped CBCentralManager init (BLE TCC) — headless")
            return
        }
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func refreshMicStickFirmwareUpdate() {
        guard isConnectedMicStick,
              otaControlCharacteristic != nil,
              let info = otaInfo,
              info.product == "micstick",
              info.hardware == 14,
              info.protocolVersion == 5 else {
            if !firmwareUpdateState.isActive, firmwareUpdateState != .failed {
                firmwareUpdateState = .unavailable
            }
            return
        }
        checkMicStickFirmwareRelease()
    }

    func startMicStickFirmwareUpdate() {
        guard firmwareUpdateState == .available,
              !isReceivingAudio,
              let release = otaRelease,
              let artifact = release.ota,
              let peripheral = connectedPeripheral,
              let imageURL = trustedFirmwareURL(artifact.url),
              let signatureURL = trustedFirmwareURL(artifact.signatureURL) else { return }

        otaManifestTask?.cancel()
        otaPumpTask?.cancel()
        otaAckTimeoutTask?.cancel()
        otaAckTimeoutTask = nil
        otaInfoResponseTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask = nil
        clearMicStickOTABootVerification()
        cancelPendingMicStickOTAControlWrite()
        firmwareUpdateState = .downloading
        firmwareUpdateProgress = nil
        otaOffset = 0
        otaSendOffset = 0
        otaBeginSent = false
        otaBeginFragments.removeAll()
        otaBeginFragmentIndex = 0
        otaFinishSent = false
        otaTargetPeripheralID = peripheral.identifier
        otaTransferWindow.rewind(to: 0)
        otaRetryPolicy.reset()
        otaInfoRetryPolicy.reset()
        let version = release.latest.description
        let directory = AppUpdateStorage.updatesDirectory
        let imageTempURL = directory.appendingPathComponent("MicStick-v\(version).bin.tmp")
        let imageFinalURL = directory.appendingPathComponent("MicStick-v\(version).bin")
        logMicStickOTA(
            "START current=\(micStickFirmwareVersion ?? "unknown") target=\(version) " +
            "size=\(artifact.size) sha256=\(artifact.sha256)"
        )

        otaManifestTask = Task { @MainActor [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: imageTempURL)
                let (imageData, _) = try await URLSession.shared.data(from: imageURL)
                self?.logMicStickOTA("DOWNLOAD image bytes=\(imageData.count)")
                guard let self,
                      MicStickOTADownloadPolicy.canCommit(
                          state: self.firmwareUpdateState,
                          taskCancelled: Task.isCancelled) else { return }
                try imageData.write(to: imageTempURL, options: .atomic)
                let (signature, _) = try await URLSession.shared.data(from: signatureURL)
                self.logMicStickOTA("DOWNLOAD signature bytes=\(signature.count)")
                guard MicStickOTADownloadPolicy.canCommit(
                    state: self.firmwareUpdateState,
                    taskCancelled: Task.isCancelled) else { return }
                try MicStickOTAFileVerifier.verify(
                    imageURL: imageTempURL,
                    expectedSize: artifact.size,
                    expectedSHA256: artifact.sha256,
                    signature: signature)
                self.logMicStickOTA("VERIFY artifact=ok")
                try? FileManager.default.removeItem(at: imageFinalURL)
                try FileManager.default.moveItem(at: imageTempURL, to: imageFinalURL)
                self.otaImageURL = imageFinalURL
                self.otaSignature = signature
                self.otaTargetVersion = release.latest
                self.firmwareUpdateProgress = 0
                self.firmwareUpdateState = .transferring
                self.beginMicStickOTAIfReady()
            } catch is CancellationError {
                self?.logMicStickOTA("CANCEL download task")
                if self?.firmwareUpdateState == .downloading {
                    self?.firmwareUpdateState = .cancelled
                }
            } catch {
                guard !Task.isCancelled, self?.firmwareUpdateState == .downloading else { return }
                try? FileManager.default.removeItem(at: imageTempURL)
                self?.firmwareUpdateState = .failed
                self?.logMicStickOTA("FAIL artifact error=\(error.localizedDescription)")
                self?.logger.error("MicStick OTA artifact rejected: \(error.localizedDescription)")
            }
        }
    }

    func cancelMicStickFirmwareUpdate() {
        guard firmwareUpdateState == .downloading || firmwareUpdateState == .transferring else { return }
        logMicStickOTA("CANCEL requested ack=\(otaOffset) sent=\(otaSendOffset)")
        abortMicStickOTA()
        otaManifestTask?.cancel()
        otaPumpTask?.cancel()
        otaAckTimeoutTask?.cancel()
        otaAckTimeoutTask = nil
        otaInfoResponseTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask = nil
        clearMicStickOTABootVerification()
        otaInfoRetryPolicy.reset()
        cancelPendingMicStickOTAControlWrite()
        otaManifestTask = nil
        otaPumpTask = nil
        if let imageURL = otaImageURL { try? FileManager.default.removeItem(at: imageURL) }
        if let version = otaRelease?.latest.description {
            let tempURL = AppUpdateStorage.updatesDirectory
                .appendingPathComponent("MicStick-v\(version).bin.tmp")
            try? FileManager.default.removeItem(at: tempURL)
        }
        otaImageURL = nil
        otaSignature = nil
        otaTargetPeripheralID = nil
        otaOffset = 0
        otaSendOffset = 0
        otaTransferWindow.rewind(to: 0)
        otaRetryPolicy.reset()
        otaInfoRetryPolicy.reset()
        otaBeginSent = false
        otaBeginFragments.removeAll()
        otaBeginFragmentIndex = 0
        otaFinishSent = false
        firmwareUpdateState = .cancelled
        firmwareUpdateProgress = nil
    }

    private func resetMicStickOTAState() {
        otaManifestTask?.cancel()
        otaPumpTask?.cancel()
        otaAckTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask?.cancel()
        clearMicStickOTABootVerification()
        otaManifestTask = nil
        otaPumpTask = nil
        otaAckTimeoutTask = nil
        otaInfoResponseTimeoutTask = nil
        clearMicStickOTAControlWriteForDisconnect()
        if let imageURL = otaImageURL { try? FileManager.default.removeItem(at: imageURL) }
        if let version = otaRelease?.latest.description {
            let tempURL = AppUpdateStorage.updatesDirectory
                .appendingPathComponent("MicStick-v\(version).bin.tmp")
            try? FileManager.default.removeItem(at: tempURL)
        }
        otaImageURL = nil
        otaSignature = nil
        otaRelease = nil
        otaInfo = nil
        otaTargetVersion = nil
        otaTargetPeripheralID = nil
        micStickFirmwareVersion = nil
        otaOffset = 0
        otaSendOffset = 0
        otaTransferWindow.rewind(to: 0)
        otaRetryPolicy.reset()
        otaInfoRetryPolicy.reset()
        otaBeginSent = false
        otaBeginFragments.removeAll()
        otaBeginFragmentIndex = 0
        otaFinishSent = false
        otaInfoRequested = false
        firmwareUpdateState = .unavailable
        firmwareUpdateProgress = nil
    }

    private func checkMicStickFirmwareRelease() {
        guard !firmwareUpdateState.isActive else { return }
        otaManifestTask?.cancel()
        firmwareUpdateState = .checking
        otaManifestTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.compatibilityURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let manifest = try JSONDecoder().decode(MicStickCompatibilityManifest.self, from: data)
                guard let self,
                      let release = manifest.firmware["micstick-v14"],
                      let info = self.otaInfo,
                      let currentVersion = AppVersion(self.micStickFirmwareVersion ?? ""),
                      let appVersion = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"),
                      MicStickFirmwareRelease.isCompatible(
                        release,
                        product: info.product,
                        hardware: info.hardware,
                        protocol: info.protocolVersion,
                        currentVersion: currentVersion,
                        currentApp: appVersion) else {
                    self?.otaRelease = nil
                    self?.firmwareUpdateState = .unavailable
                    self?.firmwareUpdateProgress = nil
                    return
                }
                self.otaRelease = release
                self.firmwareUpdateState = .available
                self.firmwareUpdateProgress = nil
            } catch is CancellationError {
                return
            } catch {
                self?.otaRelease = nil
                self?.firmwareUpdateState = .failed
                self?.logger.error("MicStick OTA manifest rejected: \(error.localizedDescription)")
            }
        }
    }

    private func handleMicStickOTAServiceDiscovery(
        hasOTAService: Bool,
        hasRequiredCharacteristics: Bool = true
    ) {
        let serviceState = MicStickOTAResumePolicy.stateAfterServiceDiscovery(
            firmwareUpdateState, hasOTAService: hasOTAService)
        let nextState = MicStickOTAResumePolicy.stateAfterCharacteristicDiscovery(
            serviceState, hasRequiredCharacteristics: hasRequiredCharacteristics)
        guard nextState != firmwareUpdateState else { return }
        let shouldAbortIncompleteService = nextState == .failed && hasOTAService &&
            !hasRequiredCharacteristics

        otaManifestTask?.cancel()
        otaPumpTask?.cancel()
        otaAckTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask?.cancel()
        otaControlWriteTimeoutTask?.cancel()
        otaManifestTask = nil
        otaPumpTask = nil
        otaAckTimeoutTask = nil
        otaInfoResponseTimeoutTask = nil
        otaControlWriteTimeoutTask = nil
        pendingMicStickOTAControlWrite = nil
        queuedMicStickOTAControlWrite = nil
        otaInfoRequested = false
        firmwareUpdateState = nextState
        firmwareUpdateProgress = nil
        if shouldAbortIncompleteService {
            abortMicStickOTA()
        }
        logger.warning("MicStick OTA service missing during active update; marking update failed")
    }

    private func failMicStickOTAForDiscoveryError() {
        guard firmwareUpdateState.isActive else { return }
        abortMicStickOTA()
        otaManifestTask?.cancel()
        otaPumpTask?.cancel()
        firmwareUpdateState = .failed
        firmwareUpdateProgress = nil
    }

    private func trustedFirmwareURL(_ relativeURL: URL) -> URL? {
        guard relativeURL.scheme == nil, relativeURL.host == nil,
              relativeURL.path.hasPrefix("/firmware/micstick/") else { return nil }
        return URL(string: relativeURL.path, relativeTo: Self.firmwareBaseURL)?.absoluteURL
    }

    private func hexData(_ value: String) -> Data {
        var data = Data()
        let bytes = Array(value.utf8)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let pair = String(decoding: bytes[index...index + 1], as: UTF8.self)
            data.append(UInt8(pair, radix: 16)!)
        }
        return data
    }

    private func writeMicStickOTAControl(
        _ data: Data,
        operation: MicStickOTAControlOperation,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        let next = PendingMicStickOTAControlWrite(data: data, operation: operation)
        if pendingMicStickOTAControlWrite != nil {
            if operation == .abort || queuedMicStickOTAControlWrite == nil {
                queuedMicStickOTAControlWrite = next
                logMicStickOTA("CONTROL queued op=\(operation.logName) bytes=\(data.count)")
            }
            return
        }
        otaControlWriteTimeoutTask?.cancel()
        pendingMicStickOTAControlWrite = next
        sendPendingMicStickOTAControlWrite(peripheral: peripheral, characteristic: characteristic)
    }

    private func sendQueuedMicStickOTAControlWrite() -> Bool {
        guard pendingMicStickOTAControlWrite == nil,
              let next = queuedMicStickOTAControlWrite,
              let peripheral = connectedPeripheral,
              let characteristic = otaControlCharacteristic else { return false }
        queuedMicStickOTAControlWrite = nil
        pendingMicStickOTAControlWrite = next
        sendPendingMicStickOTAControlWrite(peripheral: peripheral, characteristic: characteristic)
        return true
    }

    private func sendPendingMicStickOTAControlWrite(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard let pending = pendingMicStickOTAControlWrite else { return }
        logMicStickOTA(
            "CONTROL send op=\(pending.operation.logName) bytes=\(pending.data.count) " +
            "retry=\(pending.retryPolicy.timeoutRetries)"
        )
        peripheral.writeValue(pending.data, for: characteristic, type: .withResponse)
        scheduleMicStickOTAControlWriteTimeout(for: pending)
    }

    private func abortMicStickOTA() {
        guard let peripheral = connectedPeripheral,
              let characteristic = otaControlCharacteristic else {
            otaAbortState.request(for: otaTargetPeripheralID ?? connectedPeripheral?.identifier)
            return
        }
        if otaAbortState.isPending &&
           !otaAbortState.consumeIfPending(connected: peripheral.identifier) {
            return
        }
        writeMicStickOTAControl(
            Data([MicStickOTAProtocol.abort]),
            operation: .abort,
            peripheral: peripheral,
            characteristic: characteristic)
    }

    private func cancelPendingMicStickOTAControlWrite() {
        if queuedMicStickOTAControlWrite?.operation != .abort {
            queuedMicStickOTAControlWrite = nil
        }
        guard pendingMicStickOTAControlWrite == nil else { return }
        otaControlWriteTimeoutTask?.cancel()
        otaControlWriteTimeoutTask = nil
        pendingMicStickOTAControlWrite = nil
    }

    private func clearMicStickOTAControlWriteForDisconnect() {
        if pendingMicStickOTAControlWrite?.operation == .abort {
            otaAbortState.request(for: connectedPeripheral?.identifier ?? otaTargetPeripheralID)
        }
        if queuedMicStickOTAControlWrite?.operation == .abort {
            otaAbortState.request(for: connectedPeripheral?.identifier ?? otaTargetPeripheralID)
        }
        otaControlWriteTimeoutTask?.cancel()
        otaControlWriteTimeoutTask = nil
        pendingMicStickOTAControlWrite = nil
        queuedMicStickOTAControlWrite = nil
    }

    private func scheduleMicStickOTAControlWriteTimeout(
        for pending: PendingMicStickOTAControlWrite
    ) {
        otaControlWriteTimeoutTask?.cancel()
        otaControlWriteTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.otaAckTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.pendingMicStickOTAControlWrite?.operation == pending.operation,
                  self.pendingMicStickOTAControlWrite?.data == pending.data else { return }
            self.otaControlWriteTimeoutTask = nil
            self.logMicStickOTA(
                "CONTROL timeout op=\(pending.operation.logName) bytes=\(pending.data.count)"
            )
            self.handleMicStickOTAControlWrite(error: URLError(.timedOut))
        }
    }

    private func handleMicStickOTAControlWrite(error: Error?) {
        guard var pending = pendingMicStickOTAControlWrite else { return }
        otaControlWriteTimeoutTask?.cancel()
        otaControlWriteTimeoutTask = nil
        guard error != nil else {
            logMicStickOTA("CONTROL ack op=\(pending.operation.logName)")
            pendingMicStickOTAControlWrite = nil
            if sendQueuedMicStickOTAControlWrite() { return }
            if pending.operation == .abort {
                if firmwareUpdateState != .cancelled && firmwareUpdateState != .failed {
                    requestMicStickOTAInfo()
                }
                return
            }
            if pending.operation == .info {
                if otaInfoRequested {
                    scheduleMicStickOTAInfoResponseTimeout()
                }
                if firmwareUpdateState == .transferring {
                    beginMicStickOTAIfReady()
                }
            }
            if pending.operation == .begin {
                if otaBeginFragmentIndex + 1 < otaBeginFragments.count,
                   let peripheral = connectedPeripheral,
                   let characteristic = otaControlCharacteristic {
                    otaBeginFragmentIndex += 1
                    writeMicStickOTAControl(
                        otaBeginFragments[otaBeginFragmentIndex],
                        operation: .begin,
                        peripheral: peripheral,
                        characteristic: characteristic)
                } else {
                    otaBeginFragments.removeAll()
                    otaBeginFragmentIndex = 0
                    scheduleMicStickOTAPump()
                }
            }
            return
        }

        logMicStickOTA(
            "CONTROL error op=\(pending.operation.logName) " +
            "detail=\(error?.localizedDescription ?? "unknown")"
        )
        pendingMicStickOTAControlWrite = nil
        if sendQueuedMicStickOTAControlWrite() { return }
        guard pending.retryPolicy.recordTimeout() else {
            logMicStickOTA("CONTROL fail op=\(pending.operation.logName) retries=exhausted")
            switch pending.operation {
            case .info:
                otaInfoRequested = false
                otaInfoResponseTimeoutTask?.cancel()
                otaInfoResponseTimeoutTask = nil
            case .begin:
                otaBeginSent = false
            case .finish:
                otaFinishSent = false
            case .abort:
                otaAbortState.request(for: connectedPeripheral?.identifier ?? otaTargetPeripheralID)
                return
            }
            if pending.operation != .info || firmwareUpdateState.isActive {
                abortMicStickOTA()
                firmwareUpdateState = .failed
                firmwareUpdateProgress = nil
            } else {
                otaInfo = nil
                micStickFirmwareVersion = nil
                firmwareUpdateState = .unavailable
            }
            return
        }

        pendingMicStickOTAControlWrite = pending
        logMicStickOTA(
            "CONTROL retry op=\(pending.operation.logName) attempt=\(pending.retryPolicy.timeoutRetries)"
        )
        otaControlWriteTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self,
                  self.pendingMicStickOTAControlWrite?.operation == pending.operation,
                  self.pendingMicStickOTAControlWrite?.data == pending.data,
                  let peripheral = self.connectedPeripheral,
                  let characteristic = self.otaControlCharacteristic else { return }
            self.otaControlWriteTimeoutTask = nil
            self.sendPendingMicStickOTAControlWrite(peripheral: peripheral, characteristic: characteristic)
        }
    }

    private func requestMicStickOTAInfo() {
        guard !otaInfoRequested,
              let peripheral = connectedPeripheral,
              let characteristic = otaControlCharacteristic else { return }
        otaInfoRequested = true
        writeMicStickOTAControl(
            Data([MicStickOTAProtocol.infoRequest]),
            operation: .info,
            peripheral: peripheral,
            characteristic: characteristic)
    }

    private func scheduleMicStickOTAInfoFallback(for peripheralID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self,
                  self.connectedPeripheral?.identifier == peripheralID,
                  self.micStickFirmwareVersion == nil else { return }
            // Legacy firmware may not preload INFO into the readable status
            // characteristic. Only then use the encrypted control request.
            self.requestMicStickOTAInfo()
        }
    }

    private func scheduleMicStickOTAInfoResponseTimeout() {
        otaInfoResponseTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.otaAckTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.otaInfoRequested,
                  self.pendingMicStickOTAControlWrite == nil else { return }
            self.otaInfoResponseTimeoutTask = nil
            guard self.otaInfoRetryPolicy.recordTimeout() else {
                self.otaInfoRequested = false
                if self.firmwareUpdateState.isActive {
                    self.abortMicStickOTA()
                    self.firmwareUpdateState = .failed
                    self.firmwareUpdateProgress = nil
                } else {
                    self.otaInfo = nil
                    self.micStickFirmwareVersion = nil
                    self.firmwareUpdateState = .unavailable
                }
                return
            }
            self.otaInfoRequested = false
            self.requestMicStickOTAInfo()
        }
    }

    private func beginMicStickOTAIfReady() {
        guard !otaAbortState.blocksTransfer(for: connectedPeripheral?.identifier) else {
            abortMicStickOTA()
            return
        }
        guard firmwareUpdateState == .transferring,
              !otaBeginSent,
              let release = otaRelease,
              let artifact = release.ota,
              let info = otaInfo,
              let imageURL = otaImageURL,
              let signature = otaSignature,
              let peripheral = connectedPeripheral,
              let control = otaControlCharacteristic,
              otaDataCharacteristic != nil else { return }
        guard let fileSize = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(fileSize) == artifact.size,
              let imageSize = UInt32(exactly: artifact.size) else {
            logMicStickOTA(
                "FAIL begin invalidArtifact expected=\(artifact.size) actual=\((try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)"
            )
            abortMicStickOTA()
            firmwareUpdateState = .failed
            return
        }
        let maxPayload = peripheral.maximumWriteValueLength(for: .withoutResponse) - 4
        otaChunkSize = min(max(maxPayload, 1), 480)
        let metadataHardware = MicStickOTAHardwareCompatibility.metadataHardware(
            deviceHardware: info.hardware,
            currentVersion: info.version)
        let begin = MicStickOTABegin(
            schema: 1,
            hardware: metadataHardware,
            protocolVersion: info.protocolVersion,
            version: release.latest.description,
            imageSize: imageSize,
            sha256: hexData(artifact.sha256),
            signature: signature,
            resumeOffset: UInt32(max(0, otaOffset)))
        do {
            let fragments = try MicStickOTAProtocol.encodeBeginFragments(
                begin,
                maximumLength: peripheral.maximumWriteValueLength(for: .withResponse))
            guard let firstFragment = fragments.first else {
                throw MicStickOTAProtocolError.invalidValue
            }
            otaBeginFragments = fragments
            otaBeginFragmentIndex = 0
            logMicStickOTA(
                "BEGIN prepared fragments=\(fragments.count) imageSize=\(imageSize) " +
                "deviceHardware=\(info.hardware) metadataHardware=\(metadataHardware) " +
                "currentVersion=\(info.version) resume=\(otaOffset) chunk=\(otaChunkSize) " +
                "writeMax=\(peripheral.maximumWriteValueLength(for: .withResponse)) " +
                "writeNRMax=\(peripheral.maximumWriteValueLength(for: .withoutResponse))"
            )
            writeMicStickOTAControl(
                firstFragment,
                operation: .begin,
                peripheral: peripheral,
                characteristic: control)
            otaBeginSent = true
            otaTransferWindow.rewind(to: otaOffset)
            otaSendOffset = otaOffset
        } catch {
            logMicStickOTA("FAIL begin encoding error=\(error.localizedDescription)")
            abortMicStickOTA()
            firmwareUpdateState = .failed
        }
    }

    private func handleMicStickOTAInfo(_ info: MicStickOTAInfo) {
        otaInfoResponseTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask = nil
        otaInfoRetryPolicy.reset()
        otaInfoRequested = false
        otaInfo = info
        micStickFirmwareVersion = info.version
        deviceHardwareRevision = info.hardware
        BLEManager.logEvent(
            "OTA_INFO product=\(info.product) hw=\(info.hardware) protocol=\(info.protocolVersion) version=\(info.version) state=\(info.state.rawValue)"
        )
        logMicStickOTA(
            "INFO product=\(info.product) hardware=\(info.hardware) protocol=\(info.protocolVersion) " +
            "version=\(info.version) deviceState=\(info.state.rawValue)"
        )
        guard info.product == "micstick", info.hardware == 14, info.protocolVersion == 5 else {
            if firmwareUpdateState.isActive {
                abortMicStickOTA()
                firmwareUpdateState = .failed
                firmwareUpdateProgress = nil
            } else {
                firmwareUpdateState = .unavailable
            }
            return
        }
        if firmwareUpdateState == .waitingForReboot || firmwareUpdateState == .verifying {
            if let target = otaTargetVersion, AppVersion(info.version) == target {
                let isStableIdleRead = otaBootVerificationDeadline.map { Date() >= $0 } ?? false
                if MicStickOTABootVerificationPolicy.acceptsTarget(
                    state: info.state,
                    afterStableIdleRead: isStableIdleRead
                ) {
                    completeMicStickOTASuccess(
                        source: info.state == .confirmed ? "confirmed" : "stableIdle")
                } else if info.state == .idle {
                    scheduleMicStickOTAStableIdleRead()
                }
            } else if otaFinishSent,
                      MicStickOTAResumePolicy.canResumeAfterFinish(deviceState: info.state) {
                clearMicStickOTABootVerification()
                firmwareUpdateState = .transferring
                otaBeginSent = false
                otaFinishSent = false
                otaTransferWindow.rewind(to: otaOffset)
                otaSendOffset = otaOffset
                beginMicStickOTAIfReady()
            } else if otaFinishSent,
                      info.state != .validating,
                      info.state != .rebootPending {
                clearMicStickOTABootVerification()
                firmwareUpdateState = .failed
                firmwareUpdateProgress = nil
            } else if otaFinishSent {
                return
            }
            return
        }
        if firmwareUpdateState == .transferring {
            beginMicStickOTAIfReady()
        } else {
            checkMicStickFirmwareRelease()
        }
    }

    private func scheduleMicStickOTAStableIdleRead() {
        guard otaBootVerificationTask == nil,
              let peripheral = connectedPeripheral,
              let status = otaStatusCharacteristic,
              let target = otaTargetVersion,
              AppVersion(micStickFirmwareVersion ?? "") == target else { return }

        firmwareUpdateState = .verifying
        otaBootVerificationDeadline = Date().addingTimeInterval(
            Double(MicStickOTABootVerificationPolicy.stableIdleDelayNanoseconds) / 1_000_000_000)
        let peripheralID = peripheral.identifier
        logMicStickOTA("VERIFY idleGrace start seconds=8 target=\(target.description)")
        otaBootVerificationTask = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(
                nanoseconds: MicStickOTABootVerificationPolicy.stableIdleDelayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.firmwareUpdateState == .verifying,
                  self.connectedPeripheral?.identifier == peripheralID,
                  let peripheral,
                  let currentStatus = self.otaStatusCharacteristic,
                  currentStatus.uuid == status.uuid else { return }
            self.otaBootVerificationTask = nil
            self.logMicStickOTA("VERIFY idleGrace elapsed action=readInfo")
            peripheral.readValue(for: currentStatus)
        }
    }

    private func completeMicStickOTASuccess(source: String) {
        clearMicStickOTABootVerification()
        firmwareUpdateState = .succeeded
        firmwareUpdateProgress = 1
        otaFinishSent = false
        logMicStickOTA("SUCCESS bootVerification=\(source) version=\(micStickFirmwareVersion ?? "unknown")")
        sendHandshake()
    }

    private func clearMicStickOTABootVerification() {
        otaBootVerificationTask?.cancel()
        otaBootVerificationTask = nil
        otaBootVerificationDeadline = nil
    }

    private func pauseMicStickOTABootVerificationForDisconnect() {
        guard firmwareUpdateState == .verifying else { return }
        clearMicStickOTABootVerification()
        firmwareUpdateState = .waitingForReboot
    }

    private func handleMicStickOTAStatus(_ status: MicStickOTAStatus) {
        guard firmwareUpdateState.isActive else { return }
        logMicStickOTA(
            "STATUS deviceState=\(status.state.rawValue) error=\(status.error.rawValue) " +
            "accepted=\(status.acceptedOffset) hostAck=\(otaTransferWindow.acknowledgedOffset) " +
            "hostSent=\(otaTransferWindow.sendOffset)"
        )
        if status.error != .none {
            if status.error == .badOffset {
                otaAckTimeoutTask?.cancel()
                otaAckTimeoutTask = nil
                otaRetryPolicy.reset()
                cancelPendingMicStickOTAControlWrite()
                otaFinishSent = false
                otaOffset = Int(status.acceptedOffset)
                otaTransferWindow.rewind(to: otaOffset)
                otaSendOffset = otaOffset
                otaBeginSent = false
                otaBeginFragments.removeAll()
                otaBeginFragmentIndex = 0
                firmwareUpdateState = MicStickOTAResumePolicy.stateAfterBadOffset(
                    firmwareUpdateState)
                beginMicStickOTAIfReady()
            } else {
                logMicStickOTA(
                    "FAIL device error=\(status.error.rawValue) deviceState=\(status.state.rawValue) " +
                    "accepted=\(status.acceptedOffset)"
                )
                firmwareUpdateState = .failed
                firmwareUpdateProgress = nil
            }
            return
        }
        let previousAcknowledgedOffset = otaTransferWindow.acknowledgedOffset
        otaTransferWindow.acknowledge(Int(status.acceptedOffset))
        otaOffset = otaTransferWindow.acknowledgedOffset
        otaSendOffset = otaTransferWindow.sendOffset
        if otaOffset > previousAcknowledgedOffset {
            otaRetryPolicy.reset()
        }
        if otaTransferWindow.canStartNextWindow {
            otaAckTimeoutTask?.cancel()
            otaAckTimeoutTask = nil
        }
        if let imageSize = otaRelease?.ota?.size, imageSize > 0 {
            firmwareUpdateProgress = min(1, Double(otaOffset) / Double(imageSize))
        }
        if status.state == .validating || status.state == .rebootPending {
            otaAckTimeoutTask?.cancel()
            otaAckTimeoutTask = nil
            firmwareUpdateState = .waitingForReboot
            return
        }
        guard firmwareUpdateState == .transferring else { return }
        guard let release = otaRelease, let imageSize = release.ota?.size else { return }
        if otaOffset >= imageSize {
            guard !otaFinishSent,
                  pendingMicStickOTAControlWrite == nil,
                  let peripheral = connectedPeripheral,
                  let characteristic = otaControlCharacteristic else { return }
            writeMicStickOTAControl(
                Data([MicStickOTAProtocol.finish]),
                operation: .finish,
                peripheral: peripheral,
                characteristic: characteristic)
            otaFinishSent = true
            firmwareUpdateState = .waitingForReboot
        } else {
            if otaTransferWindow.canStartNextWindow {
                scheduleMicStickOTAPump()
            }
        }
    }

    private func scheduleMicStickOTAPump() {
        guard otaPumpTask == nil else { return }
        otaPumpTask = Task { @MainActor [weak self] in
            await self?.pumpMicStickOTA()
            self?.otaPumpTask = nil
        }
    }

    private func scheduleMicStickOTAAckTimeout(for expectedOffset: Int) {
        otaAckTimeoutTask?.cancel()
        otaAckTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.otaAckTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.firmwareUpdateState == .transferring,
                  self.otaTransferWindow.sendOffset == expectedOffset,
                  self.otaTransferWindow.acknowledgedOffset < expectedOffset else { return }
            self.otaAckTimeoutTask = nil
            guard self.otaRetryPolicy.recordTimeout() else {
                self.logMicStickOTA(
                    "FAIL dataAck retries=exhausted expected=\(expectedOffset) " +
                    "accepted=\(self.otaTransferWindow.acknowledgedOffset)"
                )
                self.abortMicStickOTA()
                self.firmwareUpdateState = .failed
                self.firmwareUpdateProgress = nil
                return
            }
            let retryOffset = self.otaTransferWindow.acknowledgedOffset
            self.logMicStickOTA(
                "DATA retry attempt=\(self.otaRetryPolicy.timeoutRetries) expected=\(expectedOffset) " +
                "rewind=\(retryOffset)"
            )
            self.otaOffset = retryOffset
            self.otaTransferWindow.rewind(to: retryOffset)
            self.otaSendOffset = retryOffset
            self.otaBeginSent = false
            self.beginMicStickOTAIfReady()
        }
    }

    private func pumpMicStickOTA() async {
        guard firmwareUpdateState == .transferring,
              otaBeginSent,
              pendingMicStickOTAControlWrite == nil,
              queuedMicStickOTAControlWrite == nil,
              otaTransferWindow.canStartNextWindow,
              let imageURL = otaImageURL,
              let dataCharacteristic = otaDataCharacteristic,
              let peripheral = connectedPeripheral,
              let imageSize = otaRelease?.ota?.size else { return }
        do {
            let handle = try FileHandle(forReadingFrom: imageURL)
            defer { try? handle.close() }
            var sent = 0
            let windowStart = otaSendOffset
            while sent < 8,
                  otaSendOffset < imageSize,
                  peripheral.canSendWriteWithoutResponse {
                try handle.seek(toOffset: UInt64(otaSendOffset))
                let payload = try handle.read(upToCount: min(otaChunkSize, Int(imageSize) - otaSendOffset)) ?? Data()
                guard !payload.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                var frame = Data([
                    UInt8(otaSendOffset & 0xFF),
                    UInt8((otaSendOffset >> 8) & 0xFF),
                    UInt8((otaSendOffset >> 16) & 0xFF),
                    UInt8((otaSendOffset >> 24) & 0xFF)
                ])
                frame.append(payload)
                peripheral.writeValue(frame, for: dataCharacteristic, type: .withoutResponse)
                otaSendOffset += payload.count
                otaTransferWindow.markSent(otaSendOffset)
                sent += 1
            }
            if sent > 0 {
                logMicStickOTA(
                    "DATA sent chunks=\(sent) range=\(windowStart)..<\(otaSendOffset) " +
                    "canSend=\(peripheral.canSendWriteWithoutResponse)"
                )
                scheduleMicStickOTAAckTimeout(for: otaTransferWindow.sendOffset)
            }
        } catch {
            logMicStickOTA(
                "FAIL dataRead offset=\(otaSendOffset) error=\(error.localizedDescription)"
            )
            abortMicStickOTA()
            firmwareUpdateState = .failed
            firmwareUpdateProgress = nil
        }
    }

    /// When true, scans for all BLE devices (dev/testing mode).
    /// When false, only scans for VibeEverything Audio Service UUID.
    var scanAll = false

    func startScan() {
        guard let centralManager = self.centralManager else { return }   // headless / IUO nil-safety
        logState("scan.begin")
        BLEManager.logEvent("SCAN preflight state=\(centralManager.state.rawValue) isScanning=\(centralManager.isScanning) scanAll=\(scanAll) map=\(peripheralMap.count)")
        guard disconnectingPeripheral == nil else {
            shouldScanAfterDisconnect = true
            BLEManager.logEvent("SCAN deferred disconnecting=\(disconnectingPeripheral?.identifier.uuidString ?? "nil")")
            return
        }
        guard connectionState != .connecting, connectionState != .connected else {
            BLEManager.logEvent("SCAN blocked activeState=\(connectionState.rawValue)")
            return
        }
        guard centralManager.state == .poweredOn else {
            logger.warning("Bluetooth not powered on, state: \(centralManager.state.rawValue)")
            BLEManager.logEvent("SCAN blocked state=\(centralManager.state.rawValue)")
            return
        }
        discoveredDevices.removeAll()
        connectionState = .scanning

        // Retrieve peripherals already connected to the system (they don't advertise)
        // Must provide known Service UUIDs — common BLE audio/HID/battery services
        let knownServices: [CBUUID] = scanAll
            ? [
                CBUUID(string: "180A"), // Device Information
                CBUUID(string: "180F"), // Battery Service
                CBUUID(string: "1812"), // HID (Human Interface Device)
                CBUUID(string: "1801"), // Generic Attribute
                VibePanelBLE.audioServiceUUID,
              ]
            : [VibePanelBLE.audioServiceUUID]
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: knownServices)
        BLEManager.logEvent("SCAN retrieveConnected services=\(knownServices.map(\.uuidString).joined(separator: ",")) count=\(alreadyConnected.count) ids=\(alreadyConnected.map { "\($0.name ?? "?"):\($0.identifier.uuidString)" }.joined(separator: ","))")
        for peripheral in alreadyConnected {
            let name = peripheral.name ?? "Unknown"
            peripheralMap[peripheral.identifier] = peripheral
            let type: DeviceType = VibePanelBLE.isPadName(name) ? .micPad : .stickS3
            discoveredDevices.append(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: 0, type: type))
            BLEManager.logEvent("SCAN retrieveConnected.add name=\(name) id=\(peripheral.identifier.uuidString) type=\(type.rawValue)")
            logger.info("Already connected: \(name)")
        }

        // Scan for advertising peripherals
        let serviceFilter: [CBUUID]? = scanAll ? nil : [VibePanelBLE.audioServiceUUID]
        BLEManager.logEvent("SCAN issue services=\(serviceFilter?.map(\.uuidString).joined(separator: ",") ?? "nil") allowDuplicates=false isScanningBefore=\(centralManager.isScanning)")
        centralManager.scanForPeripherals(
            withServices: serviceFilter,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        BLEManager.logEvent("SCAN start scanAll=\(scanAll) isScanningAfter=\(centralManager.isScanning)")
        logState("scan.started")
        logger.info("Started scanning (scanAll: \(self.scanAll))")
    }

    func stopScan() {
        guard let centralManager = self.centralManager else { return }   // headless / IUO nil-safety
        logState("scan.stop.begin")
        BLEManager.logEvent("SCAN stop.issue isScanningBefore=\(centralManager.isScanning)")
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
        BLEManager.logEvent("SCAN stop isScanningAfter=\(centralManager.isScanning)")
        logState("scan.stop.end")
        logger.info("Stopped scanning")
    }

    func connect(to device: DiscoveredDevice) {
        guard let centralManager = self.centralManager else { return }   // headless / IUO nil-safety
        logState("connect.begin name=\(device.name) id=\(device.id)")
        guard let peripheral = peripheralMap[device.id] else {
            logger.error("No peripheral found for \(device.id)")
            BLEManager.logEvent("CONNECT missingPeripheral id=\(device.id) name=\(device.name)")
            AnalyticsClient.shared.captureDeviceConnectResult(
                deviceType: analyticsDeviceType(device.type),
                result: "failure",
                errorKind: "ble_unavailable"
            )
            return
        }
        if let active = connectingPeripheral ?? connectedPeripheral {
            BLEManager.logEvent("CONNECT ignored active=\(active.identifier.uuidString) requested=\(device.id.uuidString) state=\(connectionState.rawValue)")
            return
        }
        isManualDisconnect = false
        connectingPeripheral = peripheral
        connectionState = .connecting
        centralManager.connect(peripheral, options: nil)
        stopScan()
        BLEManager.logEvent("CONNECT manual name=\(device.name) id=\(device.id)")
        logState("connect.issued name=\(device.name) id=\(device.id)")
        connectTimeoutTimer?.invalidate()
        let deviceID = device.id
        let deviceName = device.name
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.connectionState == .connecting,
                      let peripheral = self.connectingPeripheral,
                      peripheral.identifier == deviceID else { return }
                BLEManager.logEvent("CONNECT manualTimeout 20s name=\(deviceName) id=\(deviceID)")
                self.logState("connect.timeout name=\(deviceName) id=\(deviceID)")
                AnalyticsClient.shared.captureDeviceConnectResult(
                    deviceType: self.analyticsDeviceType(device.type),
                    result: "failure",
                    errorKind: "ble_timeout"
                )
                self.isTimeoutCancel = true
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.cleanupForReconnect()
                self.logState("connect.timeout.afterCleanup name=\(deviceName) id=\(deviceID)")
            }
        }
        logger.info("Connecting to \(device.name)")
    }

    func disconnect() {
        guard MicStickOTAResumePolicy.allowsManualDisconnect(state: firmwareUpdateState) else {
            logger.warning("Ignoring manual disconnect while MicStick OTA is in progress")
            return
        }
        BLEManager.logEvent("DISCONNECT requested state=\(connectionState.rawValue) connected=\(connectedPeripheral?.identifier.uuidString ?? "nil") connecting=\(connectingPeripheral?.identifier.uuidString ?? "nil")")
        logState("disconnect.begin")
        let hasActivePeripheral = connectedPeripheral != nil || connectingPeripheral != nil || pendingPeripheral != nil || disconnectingPeripheral != nil
        isManualDisconnect = hasActivePeripheral
        cancelAutoReconnect()
        clearPendingWait(cancelConnection: true)
        if let peripheral = connectedPeripheral {
            disconnectingPeripheral = peripheral
            centralManager.cancelPeripheralConnection(peripheral)
        }
        if let peripheral = connectingPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
        logState("disconnect.afterCleanup")
    }

    // MARK: - Auto Reconnect

    /// Whether the current cancelPeripheralConnection was triggered by our own timeout handler.
    /// Prevents didDisconnectPeripheral from starting a duplicate reconnect cycle.
    private var isTimeoutCancel = false

    private func attemptAutoReconnect() {
        guard let centralManager = self.centralManager else { return }   // headless / IUO nil-safety
        guard let uuid = UUID(uuidString: lastDeviceUUIDString),
              centralManager.state == .poweredOn,
              connectionState != .connected else { return }

        autoReconnectAttempts += 1
        logger.info("Auto-reconnect: attempt \(self.autoReconnectAttempts)/\(self.maxAutoReconnectAttempts)")

        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = peripherals.first else {
            logger.info("Auto-reconnect: device not retrievable")
            scheduleNextAttemptOrGiveUp()
            return
        }

        peripheralMap[peripheral.identifier] = peripheral
        connectingPeripheral = peripheral
        connectionState = .connecting
        centralManager.connect(peripheral, options: nil)

        // CoreBluetooth connect() never times out — add our own 3s timeout
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.connectionState == .connecting else { return }
                self.logger.info("Auto-reconnect: connection timed out")
                // Mark as timeout-initiated cancel so didDisconnectPeripheral won't start a duplicate cycle
                self.isTimeoutCancel = true
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.connectionState = .disconnected
                self.scheduleNextAttemptOrGiveUp()
            }
        }
    }

    private func scheduleNextAttemptOrGiveUp() {
        guard autoReconnectAttempts < maxAutoReconnectAttempts else {
            // 快速阶段耗尽:不再放弃,改挂系统级 pending connect(永不超时)。
            // 设备冻死一夜/长时间离开后回归,一广播即自动连回,无需手动"重新连接"。
            logger.info("Auto-reconnect: fast attempts exhausted, switching to pending wait")
            autoReconnectTimer?.invalidate()
            autoReconnectTimer = nil
            connectTimeoutTimer?.invalidate()
            connectTimeoutTimer = nil
            connectionState = .disconnected
            startPendingWait()
            return
        }
        // Backoff: 2s, 2s, 3s, 5s, 8s, 10s, 10s, ...
        let delay: TimeInterval = min(Double([2, 2, 3, 5, 8, 10][min(autoReconnectAttempts, 5)]), 10)
        logger.info("Auto-reconnect: next attempt in \(delay)s")
        autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.attemptAutoReconnect()
            }
        }
    }

    private func cancelAutoReconnect() {
        autoReconnectTimer?.invalidate()
        autoReconnectTimer = nil
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        autoReconnectAttempts = 0
        isTimeoutCancel = false
    }

    /// 挂起系统级 pending connect:connect() 不配超时,交给 CoreBluetooth 等设备出现。
    /// 失败(设备不可检索,极少见)则回落到 memorizedFailed,由用户手动重连。
    private func startPendingWait() {
        guard let centralManager = self.centralManager,
              centralManager.state == .poweredOn,
              connectionState != .connected,
              let uuid = UUID(uuidString: lastDeviceUUIDString) else { return }
        guard let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            logger.info("Pending wait: device not retrievable — falling back to failed")
            return
        }
        peripheralMap[peripheral.identifier] = peripheral
        pendingPeripheral = peripheral
        isPendingWait = true
        BLEManager.logEvent("PENDING_WAIT start")
        centralManager.connect(peripheral, options: nil)   // 不配超时:系统挂着等广播
        logger.info("Pending wait: indefinite connect issued, waiting for device to appear")
    }

    /// 清除挂起等待。cancelConnection=false 用于 didConnect(pending 刚成功,不能把连接取消掉)。
    private func clearPendingWait(cancelConnection: Bool) {
        if cancelConnection, let peripheral = pendingPeripheral, let centralManager = self.centralManager {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        pendingPeripheral = nil
        if isPendingWait { isPendingWait = false }
    }

    /// Send start recording command to device
    func sendStartRecording() {
        guard !firmwareUpdateState.isActive,
              let char = controlCharacteristic, let peripheral = connectedPeripheral else { return }
        pcmBufferLock.lock()
        pcmBuffer.removeAll()
        pcmBufferLock.unlock()
        adpcmDecoder.reset()
        packetsReceived = 0
        bytesReceived = 0
        peripheral.writeValue(Data([0x01]), for: char, type: .withResponse)
        logger.info("Sent start recording command")
    }

    /// Send stop recording command to device, returns WAV data
    func sendStopRecording() -> Data {
        // Protocol v2: device returns to IDLE on button release, no need to send 0x02
        // Sending 0x02 in v2 causes race condition: if user starts a new recording
        // before 0x02 arrives, it kills the new recording's isRecording flag
        if !firmwareUpdateState.isActive,
           deviceProtocolVersion < 2, let char = controlCharacteristic, let peripheral = connectedPeripheral {
            peripheral.writeValue(Data([0x02]), for: char, type: .withResponse)
            logger.info("Sent stop recording command (v1 protocol)")
        }
        isReceivingAudio = false
        sessionStartTime = nil  // REQ-005 Phase 1: 防 stale timestamp 跨 session 串

        pcmBufferLock.lock()
        let samples = pcmBuffer
        pcmBuffer.removeAll()
        pcmBufferLock.unlock()

        logger.info("Building WAV: \(samples.count) samples (\(Double(samples.count) / 16000.0, format: .fixed(precision: 1))s)")
        return createWAV(from: samples)
    }

    // MARK: - Voice State Push

    /// Send voice/ASR state to device: 0x03=recognizing, 0x04=done, 0x05=error (legacy)
    /// For error state (0x05), optionally include a short error message
    func sendVoiceState(_ state: UInt8, errorMessage: String? = nil) {
        guard !firmwareUpdateState.isActive,
              let char = controlCharacteristic, let peripheral = connectedPeripheral else { return }
        var data = Data([state])
        if state == 0x05, let msg = errorMessage {
            let msgBytes = Array(msg.utf8.prefix(30))
            data.append(contentsOf: msgBytes)
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
        logger.info("Sent voice state: 0x\(String(format: "%02X", state))\(errorMessage.map { " msg=\($0)" } ?? "")")
    }

    /// Send async ASR result notification to device
    /// Format: [0x06/0x07, buttonId, optional error message bytes...]
    func sendASRNotification(success: Bool, buttonId: UInt8, errorMessage: String? = nil) {
        guard !firmwareUpdateState.isActive,
              let char = controlCharacteristic, let peripheral = connectedPeripheral else { return }
        var data = Data([success ? 0x06 : 0x07, buttonId])
        if !success, let msg = errorMessage {
            data.append(contentsOf: Array(msg.utf8.prefix(28)))
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
        logger.info("Sent ASR notification: \(success ? "OK" : "FAIL") btn=\(buttonId)\(errorMessage.map { " msg=\($0)" } ?? "")")
    }

    // MARK: - Buzzer Volume (REQ-022 音效批次)

    /// UserDefaults key:蜂鸣器音量百分比(0/20/40/60/80/100),默认 60
    static let buzzerVolumePercentKey = "buzzerVolumePercent"

    /// UserDefaults key:蜂鸣器静音开关,默认 false(不静音)
    static let buzzerMutedKey = "buzzerMuted"

    /// UserDefaults key:MicPad 指示灯亮度百分比(0/8/32/70),默认 32
    static let ledBrightnessPercentKey = "ledBrightnessPercent"

    /// 下发蜂鸣器音量:[0x37, pct] 两字节(CMD_BUZZER_VOLUME=0x37,固件同批实现)
    /// 触发时机:设备页用户改动;连接时不主动覆盖固件 NVS。
    func sendBuzzerVolume(pct: UInt8) {
        guard !firmwareUpdateState.isActive,
              let char = controlCharacteristic, let peripheral = connectedPeripheral else { return }
        peripheral.writeValue(Data([0x37, pct]), for: char, type: .withResponse)
        logger.info("Sent buzzer volume: \(pct)%")
    }

    /// 下发蜂鸣器音量并播放短试听音:[0x39, pct];仅用户调整音量时使用
    func sendBuzzerVolumePreview(pct: UInt8) {
        guard !firmwareUpdateState.isActive,
              let char = controlCharacteristic, let peripheral = connectedPeripheral else { return }
        peripheral.writeValue(Data([0x39, pct]), for: char, type: .withResponse)
        logger.info("Sent buzzer volume preview: \(pct)%")
    }

    /// 下发 MicPad 指示灯亮度:[0x38, pct] 两字节(CMD_LED_BRIGHTNESS=0x38)
    func sendLedBrightness(percent: UInt8) {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = controlCharacteristic,
              let peripheral = connectedPeripheral else { return }
        peripheral.writeValue(Data([0x38, percent]), for: char, type: .withResponse)
        logger.info("Sent LED brightness: \(percent)%")
    }

    /// 查询设备端 NVS 中的硬件偏好:[0x3A] → [0x3B,buzzerPct,ledPct]。
    func requestDevicePreferences() {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = controlCharacteristic,
              let peripheral = connectedPeripheral else { return }
        peripheral.writeValue(Data([0x3A]), for: char, type: .withResponse)
        logger.info("Requested device preferences")
    }

    /// 请求 V13+ MicStick 在设备屏幕显示运输模式确认页。Mac 不能直接断开
    /// BATFET，最终决定
    /// 必须由用户在设备上按 B 确认或按 C 取消。
    func requestDeviceTransportModeConfirmation() {
        guard !firmwareUpdateState.isActive,
              supportsTransportMode,
              deviceProtocolVersion >= 5,
              let char = controlCharacteristic,
              let peripheral = connectedPeripheral else { return }
        peripheral.writeValue(Data([0x3D]), for: char, type: .withResponse)
        logger.info("Requested device transport-mode confirmation for PCB v\(self.deviceHardwareRevision)")
    }

    // MARK: - Protocol Handshake

    /// Send protocol version handshake to device after BLE characteristics are ready
    private func sendHandshake() {
        guard !firmwareUpdateState.isActive,
              let char = controlCharacteristic, let peripheral = connectedPeripheral else { return }
        let version = expectedProtocolVersion   // v5: MicPad=5 / Stick S3=4
        let data = Data([0x20, version])  // CMD_HANDSHAKE + version
        peripheral.writeValue(data, for: char, type: .withResponse)
        logger.info("Sent protocol handshake: version \(version)")
    }

    // MARK: - Claude Code Status Push

    /// v3 dashboard session entry
    struct DashboardSession {
        let name: String     // project name, UTF-8 prefix 12B
        let colorIndex: UInt8
        let phase: UInt8
    }

    /// Send Claude Code session status to device (binary format).
    /// Prefix (v2, never truncated):
    ///   phase(1) sessionCount(1) colorIndex(1) projLen(1) proj... toolLen(1) tool... usage(1) ctx(1)
    /// v3 suffix (deviceProtocolVersion >= 3):
    ///   tokenInK(2 LE) tokenOutK(2 LE) linesAdded(2 LE) linesRemoved(2 LE)
    ///   activeSessionCount(1) [ nameLen(1) name... colorIdx(1) phase(1) ] × N
    /// v4 addition (deviceProtocolVersion >= 4):
    ///   exclusiveIdx(1) — 0xFF=no exclusive, 0..N-1=index in session list
    /// Payload is trimmed field-by-field if it exceeds the negotiated MTU; v2 prefix never truncated.
    func sendClaudeStatus(phase: UInt8,
                          sessionCount: UInt8,
                          projectName: String,
                          toolName: String,
                          colorIndex: UInt8 = 0,
                          usagePercent: UInt8 = 0,
                          contextPercent: UInt8 = 0,
                          tokenInK: UInt16 = 0,
                          tokenOutK: UInt16 = 0,
                          linesAdded: UInt16 = 0,
                          linesRemoved: UInt16 = 0,
                          sessions: [DashboardSession] = [],
                          exclusiveIndex: UInt8 = 0xFF) {
        guard !firmwareUpdateState.isActive,
              let char = claudeStatusCharacteristic, let peripheral = connectedPeripheral else { return }

        let projData = Array(projectName.utf8.prefix(20))
        let toolData = Array(toolName.utf8.prefix(20))

        var prefix = Data()
        prefix.append(phase)
        prefix.append(sessionCount)
        prefix.append(colorIndex)
        prefix.append(UInt8(projData.count))
        prefix.append(contentsOf: projData)
        prefix.append(UInt8(toolData.count))
        prefix.append(contentsOf: toolData)
        prefix.append(usagePercent)
        prefix.append(contextPercent)

        // v2: prefix only
        guard deviceProtocolVersion >= 3 else {
            writeWithRetry(prefix, for: char, peripheral: peripheral)
            return
        }

        // v3+: dashboard metrics
        var dash = Data()
        dash.append(contentsOf: withUnsafeBytes(of: tokenInK.littleEndian) { Array($0) })
        dash.append(contentsOf: withUnsafeBytes(of: tokenOutK.littleEndian) { Array($0) })
        dash.append(contentsOf: withUnsafeBytes(of: linesAdded.littleEndian) { Array($0) })
        dash.append(contentsOf: withUnsafeBytes(of: linesRemoved.littleEndian) { Array($0) })

        let maxLen = max(23, peripheral.maximumWriteValueLength(for: .withResponse))

        // v3: max 3 sessions, no exclusive byte
        // v4: max 5 sessions + exclusive byte
        let maxSessions = deviceProtocolVersion >= 4 ? 5 : 3
        let cappedSessions = Array(sessions.prefix(maxSessions))

        func sessionBlock(_ s: DashboardSession) -> Data {
            // Truncate on UTF-8 character boundary so we never emit a half codepoint.
            // Budget 20B (device shows up to 13 chars; longer → first 10 + "...").
            var truncated = ""
            var byteCount = 0
            for ch in s.name {
                let chBytes = ch.utf8.count
                if byteCount + chBytes > 20 { break }
                truncated.append(ch)
                byteCount += chBytes
            }
            let nameBytes = Array(truncated.utf8)
            var b = Data()
            b.append(UInt8(nameBytes.count))
            b.append(contentsOf: nameBytes)
            b.append(s.colorIndex)
            b.append(s.phase)
            return b
        }

        // Priority trim: drop sessions from tail. Exclusive is pinned at index 0 (by caller),
        // so trimTo >= 1 → exclusiveIndex(0) < trimTo → exclusive stays visible.
        // trimTo == 0 is the fallback (no sessions renderable).
        for trimTo in (0...cappedSessions.count).reversed() {
            var candidate = prefix + dash
            candidate.append(UInt8(trimTo))
            for s in cappedSessions.prefix(trimTo) { candidate.append(sessionBlock(s)) }
            // v4: append exclusive byte after session blocks
            if deviceProtocolVersion >= 4 {
                let effectiveIdx = (exclusiveIndex < trimTo) ? exclusiveIndex : 0xFF
                candidate.append(effectiveIdx)
            }
            if candidate.count <= maxLen {
                writeWithRetry(candidate, for: char, peripheral: peripheral)
                return
            }
        }

        // No session block fits — try prefix+dash with 0 sessions
        var noSessions = prefix + dash
        noSessions.append(UInt8(0))
        if deviceProtocolVersion >= 4 { noSessions.append(0xFF) }
        if noSessions.count <= maxLen {
            writeWithRetry(noSessions, for: char, peripheral: peripheral)
            return
        }

        // Last resort: v2-only prefix (never truncated)
        writeWithRetry(prefix, for: char, peripheral: peripheral)
    }

    // MARK: - v5 Frames(REQ-007,仅 MicPad;首字节 = 帧类型)

    /// v5 会话条目(8 态 DisplayState:0=ready 1=active 2=completed 3=stale
    /// 4=needs_review 5=permission 6=blocked 7=paused)
    struct V5Session {
        let name: String
        let agentId: UInt8    // 0=Claude Code 1=Codex
        let state: UInt8
        let ctxPct: UInt8     // context 余量%;0xFF=未知(设备显示 "--")
        let colorIndex: UInt8
    }

    struct V5AgentInfo {
        let agentId: UInt8
        let usage5hPct: UInt8
        let usage7dPct: UInt8
        let resetInHours: UInt8   // 5h 窗口重置剩余小时(向上取整);0xFF=未知
        let activeCount: UInt8
        let totalCount: UInt8
        var billingMode: UInt8 = 0    // REQ-020: 0=订阅 1=API(默认订阅,向后兼容)
        var dailyTokens: UInt32 = 0   // REQ-020: 当日累计 token
        var metricKind: UInt8 = 0     // 0=quota windows 1=daily tokens 2=cumulative credits 3=counts only
        var displayName: String = ""
    }

    /// 0x51 会话帧:[0x51][exclusiveIdx(0xFF=无)][count] × {agentId,state,ctxPct,colorIdx,nameLen,name≤20B}
    ///              [inactiveStart:1]   ← T-034 追加:非活跃组起始下标;0xFF=无非活跃组
    /// 上限 12 条(设备端 V5_MAX_SESSIONS);名称 20B 截断保证帧 ≤ MTU。
    /// inactiveStart 追加在**所有条目之后**:v5ParseSessions 两趟校验只判 cur>len、
    /// 从不校验 cur==len,老固件静默忽略尾字节(与 0x52 扩展块 / 0x53 micSource 同法),
    /// 因此 handshake 版本仍为 5,**不得 bump**(BLEManager:1081 是版本不匹配即 disconnect)。
    func sendV5Sessions(_ sessions: [V5Session], exclusiveIndex: UInt8 = 0xFF,
                        inactiveStart: UInt8 = 0xFF) {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        let capped = Array(sessions.prefix(12))
        var d = Data([0x51,
                      exclusiveIndex < UInt8(capped.count) ? exclusiveIndex : 0xFF,
                      UInt8(capped.count)])
        for s in capped {
            var truncated = ""
            var byteCount = 0
            for ch in s.name {
                let n = ch.utf8.count
                if byteCount + n > 20 { break }
                truncated.append(ch)
                byteCount += n
            }
            let nb = Array(truncated.utf8)
            d.append(contentsOf: [s.agentId, s.state, s.ctxPct, s.colorIndex, UInt8(nb.count)])
            d.append(contentsOf: nb)
        }
        d.append(inactiveStart < UInt8(capped.count) ? inactiveStart : 0xFF)
        writeWithRetry(d, for: char, peripheral: peripheral)
    }

    /// 0x52 Agent 信息帧:[0x52][count]
    ///   × {agentId,usage5h,usage7d,resetInHours,active,total}          // 核心 6B
    ///   × {billingMode, value LE 4}                                    // REQ-020 可选扩展块
    ///   × {metricKind,nameLen,name UTF-8}                              // 可扩展 Agent 元数据
    /// 扩展块追加在核心块之后,老固件按 len 忽略尾部;handshake 版本不动(spec A3)。
    func sendV5AgentInfo(_ agents: [V5AgentInfo]) {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        // A usage row without any corresponding session is noise on the small
        // device home screen. Filtering before encoding also makes `count`
        // describe exactly the rows firmware should lay out. The next session
        // count update sends the card again automatically.
        let visibleAgents = agents.filter { $0.totalCount > 0 }
        let maxCards = supportsExtendedAgentCards ? max(2, Int(deviceMaxAgentCards)) : 2
        let capped = Array(visibleAgents.prefix(maxCards))
        var d = Data([0x52, UInt8(capped.count)])
        for a in capped {   // 核心 6B
            d.append(contentsOf: [a.agentId, a.usage5hPct, a.usage7dPct,
                                  a.resetInHours, a.activeCount, a.totalCount])
        }
        for a in capped {   // REQ-020 扩展块:[billingMode][dailyTokens LE 4]
            d.append(a.billingMode)
            let t = a.dailyTokens
            d.append(contentsOf: [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF),
                                  UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF)])
        }
        for a in capped {
            var name = ""
            var byteCount = 0
            for ch in a.displayName {
                let n = ch.utf8.count
                if byteCount + n > 15 { break }
                name.append(ch)
                byteCount += n
            }
            let bytes = Array(name.utf8)
            d.append(contentsOf: [a.metricKind, UInt8(bytes.count)])
            d.append(contentsOf: bytes)
        }
        writeWithRetry(d, for: char, peripheral: peripheral)
    }

    /// 0x53 配置帧:[0x53][voiceMode(0=PTT 1=长语音)][promptCount≤8] × {len,title≤24B}
    ///                 [micSource:1][language:1][laboratoryFeatures:1]
    /// 内置"AI 推荐(→+回车)"由设备端固定置顶,这里只发自定义标题
    /// T-033:micSource(0=设备麦 1=系统麦)追加在帧最末尾,老固件解析完 title 后不校验
    /// cur==len,尾字节被静默忽略 → 向后兼容,handshake 版本仍为 5
    func sendV5Config(voiceMode: UInt8, promptTitles: [String], micSource: UInt8 = 0,
                      language: DeviceDisplayLanguage = .english,
                      laboratoryFeatures: UInt8 = 0) {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        let d = Data(DeviceConfigurationFrameEncoder.encode(
            voiceMode: voiceMode,
            promptTitles: promptTitles,
            micSource: micSource,
            language: language,
            laboratoryFeatures: laboratoryFeatures
        ))
        writeWithRetry(d, for: char, peripheral: peripheral)
        logger.info("Sent v5 config: voiceMode=\(voiceMode) prompts=\(min(promptTitles.count, 8)) micSource=\(micSource) language=\(language.rawValue) laboratory=0x\(String(laboratoryFeatures, radix: 16))")
    }

    func sendPromptRecommendationLoading(requestID: UInt8) {
        sendPromptRecommendationFrame(PromptRecommendationFrameEncoder.loading(requestID: requestID))
    }

    func sendPromptRecommendations(requestID: UInt8, titles: [String]) {
        guard let peripheral = connectedPeripheral else { return }
        let maxLength = peripheral.maximumWriteValueLength(for: .withResponse)
        var fitted = Array(titles.prefix(8))
        while !fitted.isEmpty &&
              PromptRecommendationFrameEncoder.ready(requestID: requestID, titles: fitted).count > maxLength {
            fitted.removeLast()
        }
        sendPromptRecommendationFrame(PromptRecommendationFrameEncoder.ready(requestID: requestID,
                                                                               titles: fitted))
    }

    private func sendPromptRecommendationFrame(_ bytes: [UInt8]) {
        guard supportsDynamicPromptRecommendations, !firmwareUpdateState.isActive,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        writeWithRetry(Data(bytes), for: char, peripheral: peripheral)
    }

    func sendInputAssistantFrame(_ bytes: [UInt8]) {
        guard supportsInputAssistant, !firmwareUpdateState.isActive,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral,
              bytes.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { return }
        writeWithRetry(Data(bytes), for: char, peripheral: peripheral)
    }

    /// 0x57 action-mode presentation frame. The device only renders Host text;
    /// shortcut semantics remain in the Host.
    func sendActionMode(_ mode: DeviceActionModePresentation) {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        activeActionModeContext = DeviceActionContext(rawValue: mode.id)
        writeWithRetry(Data(DeviceActionModeFrameEncoder.encode(mode)), for: char, peripheral: peripheral)
    }

    func sendActionModeExit() {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        activeActionModeContext = nil
        writeWithRetry(Data(DeviceActionModeFrameEncoder.exit), for: char, peripheral: peripheral)
    }

    /// A running-App snapshot is intentionally sent as ordered, acknowledged
    /// frames. This avoids truncating the list to one ATT packet and prevents
    /// the final commit marker from overtaking an item frame.
    func sendApplicationSwitcher(_ presentation: ApplicationSwitcherPresentation) {
        guard !firmwareUpdateState.isActive,
              supportsApplicationListSwitcher,
              claudeStatusCharacteristic != nil,
              connectedPeripheral != nil else { return }
        applicationSwitcherWriteQueue = ApplicationSwitcherFrameEncoder.encode(presentation).map {
            ApplicationSwitcherPendingWrite(data: Data($0))
        }
        pumpApplicationSwitcherWrite()
    }

    func sendApplicationSwitcherExit(requestID: UInt8) {
        guard !firmwareUpdateState.isActive,
              supportsApplicationListSwitcher,
              claudeStatusCharacteristic != nil,
              connectedPeripheral != nil else { return }
        applicationSwitcherWriteQueue = [ApplicationSwitcherPendingWrite(
            data: Data(ApplicationSwitcherFrameEncoder.exit(requestID: requestID))
        )]
        pumpApplicationSwitcherWrite()
    }

    enum TaskLifecycleWireKind: UInt8 {
        case enable = 0
        case started = 1
        case completed = 2
        case failed = 3
    }

    /// Enables connection-scoped explicit task audio. The capability bit keeps
    /// new Hosts compatible with firmware that still infers sounds from status.
    private func enableExplicitTaskLifecycle() {
        guard supportsExplicitTaskLifecycle else { return }
        enqueueTaskLifecycle(Data([0x5A, 0x01, TaskLifecycleWireKind.enable.rawValue]))
    }

    @discardableResult
    func sendTaskLifecycleEvent(_ kind: TaskLifecycleWireKind, eventID: Data) -> Bool {
        guard kind != .enable, eventID.count == 16,
              supportsExplicitTaskLifecycle else { return false }
        var frame = Data([0x5A, 0x01, kind.rawValue])
        frame.append(eventID)
        return enqueueTaskLifecycle(frame)
    }

    @discardableResult
    private func enqueueTaskLifecycle(_ data: Data) -> Bool {
        guard !firmwareUpdateState.isActive,
              claudeStatusCharacteristic != nil,
              connectedPeripheral != nil else { return false }
        taskLifecycleWriteQueue.append(TaskLifecyclePendingWrite(data: data))
        pumpTaskLifecycleWrite()
        return true
    }

    private func pumpTaskLifecycleWrite() {
        guard taskLifecycleWriteInFlight == nil,
              !taskLifecycleWriteQueue.isEmpty,
              !firmwareUpdateState.isActive,
              let peripheral = connectedPeripheral,
              let characteristic = claudeStatusCharacteristic else { return }
        let entry = taskLifecycleWriteQueue.removeFirst()
        guard entry.data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else { return }
        taskLifecycleWriteInFlight = entry
        inFlightWriteKinds[characteristic.uuid, default: []].append(.taskLifecycle)
        peripheral.writeValue(entry.data, for: characteristic, type: .withResponse)
    }

    private func handleTaskLifecycleWriteCompletion(error: Error?) {
        guard var entry = taskLifecycleWriteInFlight else {
            logger.error("task-lifecycle write completion without an in-flight frame")
            return
        }
        taskLifecycleWriteInFlight = nil
        if let error {
            guard entry.retryCount < TaskLifecyclePendingWrite.maxRetries else {
                logger.error("task-lifecycle frame gave up: \(error.localizedDescription)")
                // Drop only this event. Later Prompt events are independent and
                // must not be lost because one ATT write exhausted its retries.
                pumpTaskLifecycleWrite()
                return
            }
            entry.retryCount += 1
            taskLifecycleWriteQueue.insert(entry, at: 0)
        }
        pumpTaskLifecycleWrite()
    }

    /// Language changes redraw the firmware's own strings via 0x53. If an action
    /// window is open, resend its Host-owned strings after the config write settles.
    func refreshActiveActionMode(language: DeviceDisplayLanguage) {
        guard activeActionModeContext != nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, language == DeviceDisplayLanguage.selected else { return }
            switch self.activeActionModeContext {
            case .customOne: self.sendActionMode(.customOne(language: language))
            case .chatGPTApp: self.sendActionMode(.chatGPTApp(language: language))
            case .music: self.sendActionMode(.music(language: language))
            case .home, nil: break
            }
        }
    }

    /// 0x54 时间帧:[0x54][minOfDay LE 2] — Mac 本地当日分钟数(0..1439),固件 millis 累加走时。
    /// 握手后下发一次 + 周期重同步(≥10min)防漂移;老固件按未知 opcode 忽略(向后兼容,handshake 版本不动)。
    func sendV5Time() {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let mod = UInt16((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        let d = Data([0x54, UInt8(mod & 0xFF), UInt8((mod >> 8) & 0xFF)])
        writeWithRetry(d, for: char, peripheral: peripheral)
        logger.info("Sent v5 time: \(mod / 60):\(mod % 60)")
    }

    /// REQ-022:审批帧(0x55 APPROVAL_REQUEST / 0x56 APPROVAL_RESOLVED)下发。
    /// 与其他 v5 帧同走 claudeStatus characteristic;帧本体由 ApprovalKit 编码。
    /// 不走 writeWithRetry 单槽(0x55/0x56 可能连发多帧,单槽会互相覆盖),
    /// 走独立的 approvalInFlight FIFO:失败重试上限 3 次(见
    /// handleApprovalWriteCompletion);重试耗尽后,0x55 由
    /// ApprovalCoordinator.pendingFrames 在重连时重推兜底,0x56 由设备 0x36
    /// 500ms 重发触发 Mac 重新应答(协议 §2 ack 契约)。
    func sendApprovalFrame(_ data: Data) {
        guard !firmwareUpdateState.isActive,
              deviceProtocolVersion >= 5,
              let char = claudeStatusCharacteristic,
              let peripheral = connectedPeripheral else { return }
        // MTU 校验(比照 sendClaudeStatus):0x55 最大 357B(13+24+64+256),
        // 正常协商(设备请求 MTU 512)下可写上限 ≈509B;不足(协商异常/默认 23)
        // 则不发并留在 Coordinator.pendingFrames,由 onDeviceReadyV5 →
        // deviceReconnected() 统一补发 —— 时序上 v5 握手回包(0x20 notify)发生在
        // 特征值发现 + 订阅 + Mac 写 0x01 握手之后,必然晚于 MTU 交换
        // (MTU 交换是连接建立后系统栈发起的首个 ATT 事务)。
        let maxLen = peripheral.maximumWriteValueLength(for: .withResponse)
        guard data.count <= maxLen else {
            logger.warning("approval frame 0x\(String(format: "%02X", data.first ?? 0)) len=\(data.count) > 可写上限 \(maxLen),暂不发送(pendingFrames 重推兜底)")
            return
        }
        approvalInFlight.append(ApprovalPendingWrite(data: data))
        inFlightWriteKinds[char.uuid, default: []].append(.approval)
        peripheral.writeValue(data, for: char, type: .withResponse)
        logger.info("Sent approval frame 0x\(String(format: "%02X", data.first ?? 0)) len=\(data.count)")
    }

    /// REQ-022(review fix):approval 帧写完成处理(didWriteValueFor 按 kind FIFO
    /// 路由至此)。成功 = 出队;失败 = 500ms 后重发,上限 3 次;耗尽即放弃并记日志
    /// (兜底路径见 sendApprovalFrame 注释)。
    private func handleApprovalWriteCompletion(error: Error?) async {
        guard !approvalInFlight.isEmpty else {
            logger.error("approval write completion 但 approvalInFlight 为空(FIFO 失配?)")
            return
        }
        var entry = approvalInFlight.removeFirst()
        guard let error else { return }   // 成功:出队即完成

        logger.warning("approval frame write failed: \(error.localizedDescription)")
        guard entry.retryCount < ApprovalPendingWrite.maxRetries else {
            logger.error("approval frame 0x\(String(format: "%02X", entry.data.first ?? 0)) 放弃(重试 \(ApprovalPendingWrite.maxRetries) 次耗尽);0x55 靠 Coordinator.pendingFrames 重连重推,0x56 靠设备 0x36 重发触发重新应答")
            return
        }
        entry.retryCount += 1
        logger.info("approval frame retry \(entry.retryCount)/\(ApprovalPendingWrite.maxRetries)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !firmwareUpdateState.isActive else { return }
        guard let p = connectedPeripheral, let char = claudeStatusCharacteristic else {
            logger.warning("approval frame retry 中止:连接已断,交由重连重推")
            return
        }
        approvalInFlight.append(entry)
        inFlightWriteKinds[char.uuid, default: []].append(.approval)
        p.writeValue(entry.data, for: char, type: .withResponse)
    }

    /// Write data with automatic retry tracking for critical characteristics
    private func writeWithRetry(_ data: Data, for characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        guard !firmwareUpdateState.isActive else { return }
        if retryableCharUUIDs.contains(characteristic.uuid) {
            pendingWrites[characteristic.uuid] = PendingWrite(data: data, characteristic: characteristic)
        }
        // REQ-022(review fix):记录写类型,didWriteValueFor 按 FIFO 归因
        inFlightWriteKinds[characteristic.uuid, default: []].append(.legacy)
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private func pumpApplicationSwitcherWrite() {
        guard applicationSwitcherWriteInFlight == nil,
              !applicationSwitcherWriteQueue.isEmpty,
              !firmwareUpdateState.isActive,
              let peripheral = connectedPeripheral,
              let characteristic = claudeStatusCharacteristic else { return }
        let entry = applicationSwitcherWriteQueue.removeFirst()
        applicationSwitcherWriteInFlight = entry
        inFlightWriteKinds[characteristic.uuid, default: []].append(.applicationSwitcher)
        peripheral.writeValue(entry.data, for: characteristic, type: .withResponse)
    }

    private func handleApplicationSwitcherWriteCompletion(error: Error?) {
        guard var entry = applicationSwitcherWriteInFlight else {
            logger.error("application-switcher write completion without an in-flight frame")
            return
        }
        applicationSwitcherWriteInFlight = nil
        if let error {
            guard entry.retryCount < ApplicationSwitcherPendingWrite.maxRetries else {
                logger.error("application-switcher frame gave up: \(error.localizedDescription)")
                applicationSwitcherWriteQueue.removeAll()
                return
            }
            entry.retryCount += 1
            applicationSwitcherWriteQueue.insert(entry, at: 0)
        }
        pumpApplicationSwitcherWrite()
    }

    /// Process received audio packet (header + buttonId + seq + ADPCM data)
    private func processAudioPacket(_ data: Data) {
        guard data.count > 4, data[0] == 0xAA, data[1] == 0x55 else {
            logger.warning("Invalid audio packet: \(data.count) bytes")
            return
        }

        let seq: UInt16
        let adpcmData: Data

        if deviceProtocolVersion >= 2 {
            // Protocol v2: [0xAA, 0x55, buttonId, seq_lo, seq_hi, ADPCM...]
            guard data.count > 5 else {
                logger.warning("V2 audio packet too short: \(data.count) bytes")
                return
            }
            let buttonId = data[2]
            if !isReceivingAudio {
                audioStreamButtonId = buttonId
            }
            seq = UInt16(data[3]) | (UInt16(data[4]) << 8)
            adpcmData = data.subdata(in: 5..<data.count)
        } else {
            // Protocol v1 (legacy): [0xAA, 0x55, seq_lo, seq_hi, ADPCM...]
            audioStreamButtonId = 0x01  // v1 only has Button A
            seq = UInt16(data[2]) | (UInt16(data[3]) << 8)
            adpcmData = data.subdata(in: 4..<data.count)
        }
        if seq < 3 {
            let firstBytes = adpcmData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            ClaudeCodeSessionManager.log("[BLE] Packet seq=\(seq) adpcmLen=\(adpcmData.count) first16=[\(firstBytes)]")
        }

        // Packet loss / out-of-order detection
        if packetsReceived > 0 {
            let expectedSeq = lastSeq &+ 1  // wrapping add for UInt16
            if seq != expectedSeq {
                if seq > expectedSeq {
                    let gap = Int(seq &- expectedSeq)  // wrapping subtract
                    packetsLost += gap
                    logger.warning("Packet loss detected: expected seq \(expectedSeq), got \(seq) (lost \(gap))")
                } else {
                    packetsOutOfOrder += 1
                    logger.warning("Out-of-order packet: expected seq \(expectedSeq), got \(seq)")
                }
            }
        }
        lastSeq = seq

        let pcmSamples = adpcmDecoder.decode(adpcmData)

        pcmBufferLock.lock()
        pcmBuffer.append(contentsOf: pcmSamples)
        pcmBufferLock.unlock()

        onPCMChunk?(pcmSamples)   // tee 给流式 session(锁外;仅豆包流式活跃时由 app 挂闭包)

        // 实时 RMS 电平 → 浮窗波形(0~1)。
        if let onLevel, !pcmSamples.isEmpty {
            var sum: Double = 0
            for s in pcmSamples { let v = Double(s); sum += v * v }
            let rms = (sum / Double(pcmSamples.count)).squareRoot()
            let level = Float(min(1.0, rms / 32767.0 * 6.0))
            DispatchQueue.main.async { onLevel(level) }
        }

        packetsReceived += 1
        bytesReceived += data.count

        // Reset silence timer — if no new packet arrives within timeout, finalize recording
        // After PTT stop received, don't extend timer — let the short drain window expire
        if !pttStopReceived {
            silenceTimer?.invalidate()
            silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finalizeRecording()
                }
            }
        }
    }

    /// Called when audio stream ends (silence timeout or manual stop)
    private func finalizeRecording() {
        guard isReceivingAudio else {
            ClaudeCodeSessionManager.log("[BLE] finalizeRecording: not receiving audio, skip")
            return
        }
        silenceTimer?.invalidate()
        silenceTimer = nil
        pttStopReceived = false

        let totalExpected = Int(packetsReceived) + packetsLost
        let lossRate = totalExpected > 0 ? Double(packetsLost) / Double(totalExpected) * 100 : 0
        ClaudeCodeSessionManager.log("[BLE] finalizeRecording: packets=\(packetsReceived) bytes=\(bytesReceived) pcmSamples=\(pcmBuffer.count) lost=\(packetsLost) outOfOrder=\(packetsOutOfOrder) lossRate=\(String(format: "%.1f", lossRate))%")

        // REQ-005 Phase 1: wall-clock duration gate (首帧 → 现在 Δt)
        let durationMs: Int
        if let start = sessionStartTime {
            durationMs = Int(-start.timeIntervalSinceNow * 1000)
        } else {
            durationMs = 0  // 没拿到首帧 timestamp(异常路径),按 0 处理 → 必然丢弃
        }
        sessionStartTime = nil

        let wavData = sendStopRecording()
        let audioBytes = wavData.count - 44  // Subtract WAV header
        let minAudioBytes = 16000  // ~0.5s at 16kHz 16-bit mono (8000 samples * 2 bytes)
        let durationOk = durationMs >= kMinRecordingDurationMs
        let bytesOk = audioBytes >= minAudioBytes
        if durationOk && bytesOk {
            ClaudeCodeSessionManager.log("[BLE] WAV ready: \(wavData.count) bytes (\(String(format: "%.1f", Double(audioBytes) / 32000.0))s wall=\(durationMs)ms), onAudioReady=\(onAudioReady != nil)")
            onAudioReady?(wavData)
        } else if audioBytes > 0 || durationMs > 0 {
            logger.debug("[BLE] discarded: too short \(durationMs)ms wall-clock / \(audioBytes)bytes (min=\(self.kMinRecordingDurationMs)ms / \(minAudioBytes)bytes)")
            ClaudeCodeSessionManager.log("[BLE] Audio too short (wall=\(durationMs)ms / bytes=\(audioBytes), \(String(format: "%.2f", Double(audioBytes) / 32000.0))s), skipping ASR")
            onAudioStreamAborted?()
        } else {
            ClaudeCodeSessionManager.log("[BLE] No audio data after finalize, triggering abort")
            onAudioStreamAborted?()
        }
    }

    private func handleControlNotification(_ data: Data) {
        guard data.count >= 1 else { return }
        let command = data[0]
        ClaudeCodeSessionManager.log("[BLE] Control notification: 0x\(String(format: "%02X", command)) len=\(data.count)")

        // Handle handshake reply from device: [0x20, deviceVersion]
        if command == 0x20, data.count >= 2 {
            deviceProtocolVersion = data[1]
            ClaudeCodeSessionManager.log("[BLE] Device protocol version: \(deviceProtocolVersion)")
            AnalyticsClient.shared.captureDeviceConnectResult(
                deviceType: analyticsDeviceType(),
                result: "success",
                protocolVersion: Int(deviceProtocolVersion)
            )
            // v5(REQ-007 决策):MicPad 版本不匹配 = 拒绝连接,提示升级固件
            if isConnectedMicPad && deviceProtocolVersion != VibePanelBLE.micPadProtocolVersion {
                versionMismatchMessage = AppL10n.format("固件协议 v%@ 与 App 要求 v%@ 不匹配,请升级固件后重连", String(deviceProtocolVersion), String(VibePanelBLE.micPadProtocolVersion))
                ClaudeCodeSessionManager.log("[BLE] MicPad protocol mismatch (device v\(deviceProtocolVersion) != v\(VibePanelBLE.micPadProtocolVersion)), disconnecting")
                disconnect()
                return
            }
            versionMismatchMessage = nil
            if isConnectedMicPad { onDeviceReadyV5?() }
            return
        }

        // CMD_REQUEST_STATUS (v3+): device asks for a dashboard refresh
        if command == 0x21 {
            onStatusRequestFromDevice?()
            return
        }

        // 设备硬件偏好回包:
        // [0x3B,buzzerPct,ledPct,hardwareRevision?,capabilities?,maxAgentCards?]。
        // 尾部字段均可选；老固件缺失时按 revision=0 / 两张固定 Agent 卡降级。
        if command == 0x3B, data.count >= 3 {
            let buzzerPct = Int(data[1])
            let ledPct = Int(data[2])
            Self.devicePreferenceEchoSuppressedUntil = Date().addingTimeInterval(0.5)
            if buzzerPct == 0 {
                UserDefaults.standard.set(true, forKey: Self.buzzerMutedKey)
            } else {
                UserDefaults.standard.set(false, forKey: Self.buzzerMutedKey)
                UserDefaults.standard.set(buzzerPct, forKey: Self.buzzerVolumePercentKey)
            }
            UserDefaults.standard.set(ledPct, forKey: Self.ledBrightnessPercentKey)
            deviceHardwareRevision = data.count >= 4 ? data[3] : 0
            deviceCapabilities = data.count >= 5 ? data[4] : 0
            deviceMaxAgentCards = data.count >= 6 ? max(2, data[5]) : 2
            ClaudeCodeSessionManager.log("[BLE] Device preferences synced buzzer=\(buzzerPct)% led=\(ledPct)% hw=v\(deviceHardwareRevision) caps=0x\(String(deviceCapabilities, radix: 16)) agents=\(deviceMaxAgentCards)")
            enableExplicitTaskLifecycle()
            onDeviceCapabilitiesChanged?()
            return
        }

        // T-033: PTT 开始(系统麦模式专用)。设备侧只在 micSource=SYSTEM 时发此帧。
        if command == 0x19 { // CMD_BTN_A_PTT_START
            ClaudeCodeSessionManager.log("[BLE] PTT start received (0x19), system-mic mode")
            pttWatchdogTimer?.invalidate()
            pttWatchdogTimer = Timer.scheduledTimer(withTimeInterval: pttWatchdogTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    ClaudeCodeSessionManager.log("[BUG-032] PTT watchdog fired (\(Int(self.pttWatchdogTimeout))s, no 0x14) — forcing PTT stop")
                    self.onPTTStop?()
                }
            }
            onPTTStart?()
            return
        }

        // PTT stop command (Button A) — shorten silence timer to drain in-flight packets, then finalize
        if command == 0x14 { // CMD_BTN_A_PTT_STOP
            ClaudeCodeSessionManager.log("[BLE] PTT stop received (0x14), draining in-flight packets")
            pttWatchdogTimer?.invalidate()
            pttWatchdogTimer = nil
            if isReceivingAudio {
                pttStopReceived = true
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: pttStopDrainTimeout, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finalizeRecording()
                    }
                }
            }
            onPTTStop?()   // T-033: 系统麦模式收尾(isReceivingAudio 恒 false,不进上面的 drain 分支)
            return
        }

        // v5 多字节命令(REQ-011/012/013)
        if command == 0x30, data.count >= 3, supportsDynamicPromptRecommendations {
            ClaudeCodeSessionManager.log("[BLE] Dynamic prompt select req=\(data[1]) idx=\(data[2])")
            onDynamicPromptSelect?(data[1], data[2])
            return
        }
        if command == 0x30, data.count >= 2 {  // CMD_PROMPT_SELECT
            ClaudeCodeSessionManager.log("[BLE] Prompt select idx=\(data[1])")
            onPromptSelect?(data[1])
            return
        }
        if command == 0x31, data.count >= 3, supportsInputAssistant {
            ClaudeCodeSessionManager.log("[BLE] Input assistant action req=\(data[1]) op=\(data[2])")
            onInputAssistantAction?(data[1], data[2])
            return
        }
        if command == 0x32, data.count >= 2 {  // CMD_EXCLUSIVE_TOGGLE
            ClaudeCodeSessionManager.log("[BLE] Exclusive toggle idx=\(data[1])")
            onExclusiveToggle?(data[1])
            return
        }
        if command == 0x34, data.count >= 3, data[1] == 2,
           supportsDynamicPromptRecommendations {
            ClaudeCodeSessionManager.log("[BLE] Prompt recommendations requested req=\(data[2])")
            onPromptRecommendationRequest?(data[2])
        }
        if command == 0x34, data.count >= 3, data[1] == 5,
           supportsInputAssistant {
            ClaudeCodeSessionManager.log("[BLE] Input assistant requested req=\(data[2])")
            onInputAssistantRequest?(data[2])
        }
        if command == 0x34, data.count >= 2 {  // CMD_DEVICE_MODE
            ClaudeCodeSessionManager.log("[BLE] Device mode -> \(data[1])")
            onDeviceModeChange?(data[1])
            return
        }
        if command == 0x3C, let event = DeviceActionEvent(bytes: Array(data)) {
            ClaudeCodeSessionManager.log("[BLE] Device action context=\(event.contextID) control=\(event.control.rawValue) gesture=\(event.gesture.rawValue) delta=\(event.delta)")
            onDeviceAction?(event)
            return
        }

        // REQ-022:0x36 审批应答帧(4B:magic+reqId+decision)→ ApprovalCoordinator
        // 按 reqId 精确匹配,不再走 0x10/0x11 推断
        if command == 0x36 {
            onApprovalResponse?(data)
            return
        }

        onControlCommand?(command)
    }

    private func createWAV(from samples: [Int16]) -> Data {
        let pcmData = samples.withUnsafeBufferPointer { buf in
            Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Int16>.size)
        }

        let dataSize = UInt32(pcmData.count)
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var wav = Data()
        wav.reserveCapacity(44 + pcmData.count)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE(dataSize + 36)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(channels)
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE(dataSize)
        wav.append(pcmData)

        return wav
    }

    private func cleanup() {
        logState("cleanup.begin")
        pauseMicStickOTABootVerificationForDisconnect()
        otaAckTimeoutTask?.cancel()
        otaAckTimeoutTask = nil
        otaInfoResponseTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask = nil
        otaInfoRetryPolicy.reset()
        clearMicStickOTAControlWriteForDisconnect()
        silenceTimer?.invalidate()
        silenceTimer = nil
        pttStopReceived = false
        if isReceivingAudio {
            finalizeRecording()
        }
        if firmwareUpdateState == .transferring {
            otaBeginSent = false
            otaBeginFragments.removeAll()
            otaBeginFragmentIndex = 0
            otaTransferWindow.rewind(to: otaOffset)
            otaSendOffset = otaOffset
        }
        isTimeoutCancel = false
        connectingPeripheral = nil
        connectedPeripheral = nil
        deviceHardwareRevision = 0
        deviceCapabilities = 0
        deviceMaxAgentCards = 2
        applicationSwitcherWriteQueue.removeAll()
        applicationSwitcherWriteInFlight = nil
        taskLifecycleWriteQueue.removeAll()
        taskLifecycleWriteInFlight = nil
        audioDataCharacteristic = nil
        controlCharacteristic = nil
        claudeStatusCharacteristic = nil
        characteristicsReady = false
        permRequestCharacteristic = nil
        otaControlCharacteristic = nil
        otaDataCharacteristic = nil
        otaStatusCharacteristic = nil
        otaInfoRequested = false
        activeActionModeContext = nil
        connectedDeviceName = nil
        isReceivingAudio = false
        sessionStartTime = nil  // REQ-005 Phase 1: 防 stale timestamp 跨 session 串
        connectionState = .disconnected
        packetsReceived = 0
        bytesReceived = 0
        peripheralMap.removeAll()
        discoveredDevices.removeAll()
        // REQ-022(review fix):断连后旧连接的完成回调不再到达,清空归因/重试队列
        // 防 stale 条目误配下一连接的完成回调
        inFlightWriteKinds.removeAll()
        approvalInFlight.removeAll()
        logState("cleanup.end")
    }

    /// Lightweight cleanup for auto-reconnect — preserves device identity info
    private func cleanupForReconnect() {
        logState("cleanupForReconnect.begin")
        pauseMicStickOTABootVerificationForDisconnect()
        otaAckTimeoutTask?.cancel()
        otaAckTimeoutTask = nil
        otaInfoResponseTimeoutTask?.cancel()
        otaInfoResponseTimeoutTask = nil
        otaInfoRetryPolicy.reset()
        clearMicStickOTAControlWriteForDisconnect()
        silenceTimer?.invalidate()
        silenceTimer = nil
        pttStopReceived = false
        if isReceivingAudio {
            finalizeRecording()
        }
        connectingPeripheral = nil
        connectedPeripheral = nil
        deviceHardwareRevision = 0
        deviceCapabilities = 0
        deviceMaxAgentCards = 2
        applicationSwitcherWriteQueue.removeAll()
        applicationSwitcherWriteInFlight = nil
        taskLifecycleWriteQueue.removeAll()
        taskLifecycleWriteInFlight = nil
        audioDataCharacteristic = nil
        controlCharacteristic = nil
        claudeStatusCharacteristic = nil
        characteristicsReady = false
        permRequestCharacteristic = nil
        otaControlCharacteristic = nil
        otaDataCharacteristic = nil
        otaStatusCharacteristic = nil
        otaInfoRequested = false
        if firmwareUpdateState == .transferring {
            otaBeginSent = false
            otaBeginFragments.removeAll()
            otaBeginFragmentIndex = 0
            otaTransferWindow.rewind(to: otaOffset)
            otaSendOffset = otaOffset
        }
        activeActionModeContext = nil
        isReceivingAudio = false
        sessionStartTime = nil  // REQ-005 Phase 1: 防 stale timestamp 跨 session 串
        connectionState = .disconnected
        packetsReceived = 0
        bytesReceived = 0
        pendingWrites.removeAll()
        // REQ-022(review fix):同 cleanup(),清归因/重试队列防跨连接误配
        inFlightWriteKinds.removeAll()
        approvalInFlight.removeAll()
        // Keep: connectedDeviceName, peripheralMap, discoveredDevices, lastDeviceUUIDString
        logState("cleanupForReconnect.end")
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.logState("central.stateUpdate raw=\(state.rawValue)")
            switch state {
            case .poweredOn:
                self.logger.info("Bluetooth powered on")
                if !self.lastDeviceUUIDString.isEmpty {
                    self.attemptAutoReconnect()
                }
            case .poweredOff:
                self.logger.warning("Bluetooth powered off")
                self.clearPendingWait(cancelConnection: false)   // BT 关闭 pending 失效;poweredOn 会重启快速重连
                self.isManualDisconnect = false
                self.cleanup()
            case .unauthorized:
                self.logger.error("Bluetooth unauthorized")
            default:
                self.logger.info("Bluetooth state: \(state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "QuickVibeStick Device"
        let rssi = RSSI.intValue
        let deviceID = peripheral.identifier

        // 从广播里提取 Service UUID，仅用来区分设备类型；未识别的类型直接丢弃，避免附近其它 BLE 设备混入列表。
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isKnownStickS3 = advertisedServices.contains(VibePanelBLE.audioServiceUUID)
        BLEManager.logEvent(
            "DISCOVER raw name=\(name) periphName=\(peripheral.name ?? "nil") rssi=\(rssi) id=\(deviceID.uuidString) knownService=\(isKnownStickS3) adv=\(Self.describeAdvertisementData(advertisementData))"
        )

        Task { @MainActor in
            // MicPad 与 Stick S3 共用同一 audio Service UUID,isKnownStickS3 对二者都真,
            // 故按广播名前缀二次分型。
            let deviceType: DeviceType? = isKnownStickS3
                ? (VibePanelBLE.isPadName(name) ? .micPad : .stickS3)
                : (self.scanAll ? nil : .stickS3)
            BLEManager.logEvent("DISCOVER classify name=\(name) knownService=\(isKnownStickS3) scanAll=\(self.scanAll) type=\(deviceType?.rawValue ?? "nil") state=\(self.connectionState.rawValue)")
            self.peripheralMap[deviceID] = peripheral
            if let index = self.discoveredDevices.firstIndex(where: { $0.id == deviceID }) {
                self.discoveredDevices[index].rssi = rssi
                BLEManager.logEvent("DISCOVER update name=\(name) rssi=\(rssi) id=\(deviceID.uuidString) oldName=\(self.discoveredDevices[index].name) oldType=\(self.discoveredDevices[index].type?.rawValue ?? "nil") state=\(self.connectionState.rawValue)")
                // 首包 ADV_IND 往往不带 Scan Response 名字,条目会以通用名+误判类型建档;
                // 后续回调拿到真名后必须刷新 name/type,否则通用名焊死到连接为止
                let old = self.discoveredDevices[index]
                if name != "QuickVibeStick Device", name != old.name {
                    self.discoveredDevices[index] = DiscoveredDevice(
                        id: deviceID, name: name, rssi: rssi,
                        type: deviceType ?? old.type)
                }
            } else {
                // 常规扫描路径：只收 Stick S3；类型 nil 时过滤掉
                guard deviceType != nil || self.scanAll else {
                    BLEManager.logEvent("DISCOVER filtered name=\(name) rssi=\(rssi) id=\(deviceID.uuidString) services=\(advertisedServices.map(\.uuidString).joined(separator: ","))")
                    return
                }
                self.discoveredDevices.append(DiscoveredDevice(id: deviceID, name: name, rssi: rssi, type: deviceType))
                BLEManager.logEvent("DISCOVER append name=\(name) rssi=\(rssi) id=\(deviceID.uuidString) type=\(deviceType?.rawValue ?? "nil") count=\(self.discoveredDevices.count) services=\(advertisedServices.map(\.uuidString).joined(separator: ","))")
                self.logger.info("Discovered: \(name) (RSSI: \(rssi))")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BLEManager.logEvent("DID_CONNECT_ENTER name=\(peripheral.name ?? "?") id=\(peripheral.identifier.uuidString)")
        Task { @MainActor in
            self.logState("didConnect.enter name=\(peripheral.name ?? "?") id=\(peripheral.identifier.uuidString)")
            if self.firmwareUpdateState.isActive &&
               !MicStickOTAResumePolicy.canResume(
                   target: self.otaTargetPeripheralID,
                   connected: peripheral.identifier) {
                self.logger.warning("Discarding OTA state for a different MicStick")
                self.resetMicStickOTAState()
            }
            self.connectedPeripheral = peripheral
            self.deviceHardwareRevision = 0
            self.deviceCapabilities = 0
            self.deviceMaxAgentCards = 2
            self.connectingPeripheral = nil
            let realName = peripheral.name ?? "QuickVibeStick"
            self.connectedDeviceName = realName
            // Update name in discovered list if it was the generic "QuickVibeStick Device";
            // 类型同步按真名重判(首包无名时会被误判成 .stickS3)
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }),
               self.discoveredDevices[idx].name == "QuickVibeStick Device" {
                let fixedType: DeviceType? = VibePanelBLE.isPadName(realName)
                    ? .micPad : self.discoveredDevices[idx].type
                self.discoveredDevices[idx] = DiscoveredDevice(id: peripheral.identifier, name: realName, rssi: self.discoveredDevices[idx].rssi, type: fixedType)
            }
            self.connectTimeoutTimer?.invalidate()
            self.connectTimeoutTimer = nil
            self.isManualDisconnect = false
            self.connectionState = .connected
            BLEManager.logEvent("CONNECTED \(peripheral.name ?? "?")")
            self.logState("didConnect.connected name=\(peripheral.name ?? "?") id=\(peripheral.identifier.uuidString)")
            self.cancelAutoReconnect()
            self.clearPendingWait(cancelConnection: false)   // pending 成功兑现,只清标志
            self.lastDeviceUUIDString = peripheral.identifier.uuidString
            self.lastDeviceNameString = realName
            peripheral.delegate = self
            self.serviceDiscoveryRetries = 0
            self.charDiscoveryRetries = 0
            self.otaControlCharacteristic = nil
            self.otaDataCharacteristic = nil
            self.otaStatusCharacteristic = nil
            self.otaInfoResponseTimeoutTask?.cancel()
            self.otaInfoResponseTimeoutTask = nil
            self.otaInfoRetryPolicy.reset()
            self.otaInfoRequested = false
            if !self.firmwareUpdateState.isActive {
                self.otaInfo = nil
                self.otaRelease = nil
                self.micStickFirmwareVersion = nil
                self.firmwareUpdateState = .unavailable
            }
            // In scanAll mode, discover all services for inspection
            let serviceFilter: [CBUUID]? = self.scanAll ? nil : [
                VibePanelBLE.audioServiceUUID, VibePanelBLE.otaServiceUUID
            ]
            peripheral.discoverServices(serviceFilter)
            self.logger.info("Connected to \(peripheral.name ?? "unknown")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        BLEManager.logEvent("DID_FAIL_TO_CONNECT name=\(peripheral.name ?? "?") id=\(peripheral.identifier.uuidString) err=\(error?.localizedDescription ?? "nil")")
        Task { @MainActor in
            self.logState("didFail.enter name=\(peripheral.name ?? "?") id=\(peripheral.identifier.uuidString) err=\(error?.localizedDescription ?? "nil")")
            self.logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
            AnalyticsClient.shared.captureDeviceConnectResult(
                deviceType: self.analyticsDeviceType(),
                result: "failure",
                errorKind: "ble_unavailable",
                protocolVersion: Int(self.deviceProtocolVersion)
            )
            self.connectingPeripheral = nil
            self.connectTimeoutTimer?.invalidate()
            self.connectTimeoutTimer = nil
            let wasAutoReconnecting = self.autoReconnectAttempts > 0 && self.autoReconnectAttempts < self.maxAutoReconnectAttempts
            let wasPendingWait = self.isPendingWait
            self.cleanupForReconnect()
            if wasAutoReconnecting {
                self.scheduleNextAttemptOrGiveUp()
            } else if wasPendingWait {
                // pending 等待期偶发失败(设备刚广播即消失等):2s 后重新挂起
                self.clearPendingWait(cancelConnection: false)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, self.connectionState != .connected,
                          !self.isPendingWait, self.hasMemorizedDevice else { return }
                    self.startPendingWait()
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let deviceName = peripheral.name ?? "unknown"
            self.logState("didDisconnect.enter name=\(deviceName) id=\(peripheral.identifier.uuidString) err=\(error?.localizedDescription ?? "nil")")
            let wasDisconnecting = self.disconnectingPeripheral?.identifier == peripheral.identifier
            if self.isManualDisconnect {
                self.logger.info("Disconnected from \(deviceName) (manual)")
                self.isManualDisconnect = false
                if self.firmwareUpdateState.isActive {
                    self.otaAbortState.request(for: peripheral.identifier)
                    self.resetMicStickOTAState()
                }
                self.cleanup()
            } else if self.isTimeoutCancel {
                // Triggered by our own timeout handler — it already called scheduleNextAttemptOrGiveUp(),
                // so just do lightweight cleanup without starting a duplicate reconnect cycle.
                self.logger.info("Disconnected from \(deviceName) (timeout cancel)")
                self.isTimeoutCancel = false
                self.cleanupForReconnect()
            } else {
                self.logger.warning("Unexpected disconnect from \(deviceName): \(error?.localizedDescription ?? "no error")")
                BLEManager.logEvent("UNEXPECTED_DISCONNECT \(deviceName) err=\(error?.localizedDescription ?? "nil")")
                self.cleanupForReconnect()
                self.autoReconnectAttempts = 0
                self.attemptAutoReconnect()
            }
            if wasDisconnecting {
                BLEManager.logEvent("DISCONNECT complete name=\(deviceName) id=\(peripheral.identifier.uuidString)")
                self.disconnectingPeripheral = nil
                if self.shouldScanAfterDisconnect {
                    self.shouldScanAfterDisconnect = false
                    self.startScan()
                }
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    /// macOS 在连接后异步读 GAP 名字(2A00);didConnect 时刻 peripheral.name 可能还是 nil,
    /// 真名在这里到达 — 刷新连接名与扫描列表条目(含类型重判)
    nonisolated func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        let newName = peripheral.name
        Task { @MainActor in
            guard let newName, !newName.isEmpty else { return }
            if self.connectedPeripheral?.identifier == peripheral.identifier {
                self.connectedDeviceName = newName
                self.lastDeviceNameString = newName
                BLEManager.logEvent("NAME_UPDATED \(newName)")
            }
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
                let old = self.discoveredDevices[idx]
                let fixedType: DeviceType? = VibePanelBLE.isPadName(newName) ? .micPad : old.type
                self.discoveredDevices[idx] = DiscoveredDevice(
                    id: old.id, name: newName, rssi: old.rssi, type: fixedType)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task { @MainActor in
                self.logger.warning("Service discovery failed: \(error.localizedDescription)")
                if self.serviceDiscoveryRetries < 1 {
                    self.serviceDiscoveryRetries += 1
                    self.logger.info("Retrying service discovery (attempt \(self.serviceDiscoveryRetries + 1))")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    peripheral.discoverServices([
                        VibePanelBLE.audioServiceUUID, VibePanelBLE.otaServiceUUID
                    ])
                } else {
                    self.logger.error("Service discovery failed after retry — disconnecting")
                    self.failMicStickOTAForDiscoveryError()
                    self.disconnect()
                }
            }
            return
        }
        guard let services = peripheral.services else { return }
        Task { @MainActor in
            self.serviceDiscoveryRetries = 0
            BLEManager.logEvent("SERVICES count=\(services.count) list=\(services.map { $0.uuid.uuidString }.joined(separator: ","))")
            self.handleMicStickOTAServiceDiscovery(
                hasOTAService: services.contains { $0.uuid == VibePanelBLE.otaServiceUUID })
        }
        for service in services {
            Task { @MainActor in
                self.logger.info("Service: \(service.uuid.uuidString)")
            }
            if service.uuid == VibePanelBLE.audioServiceUUID {
                peripheral.discoverCharacteristics(
                    [VibePanelBLE.audioDataCharUUID, VibePanelBLE.controlCharUUID,
                     VibePanelBLE.claudeStatusCharUUID, VibePanelBLE.permRequestCharUUID],
                    for: service
                )
            } else if service.uuid == VibePanelBLE.otaServiceUUID {
                peripheral.discoverCharacteristics(
                    [VibePanelBLE.otaControlCharUUID, VibePanelBLE.otaDataCharUUID,
                     VibePanelBLE.otaStatusCharUUID],
                    for: service
                )
            } else {
                // In scanAll mode, discover all characteristics for inspection
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            Task { @MainActor in
                self.logger.warning("Characteristic discovery failed: \(error.localizedDescription)")
                if self.charDiscoveryRetries < 1 {
                    self.charDiscoveryRetries += 1
                    self.logger.info("Retrying characteristic discovery (attempt \(self.charDiscoveryRetries + 1))")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if service.uuid == VibePanelBLE.otaServiceUUID {
                        peripheral.discoverCharacteristics(
                            [VibePanelBLE.otaControlCharUUID, VibePanelBLE.otaDataCharUUID,
                             VibePanelBLE.otaStatusCharUUID],
                            for: service
                        )
                    } else {
                        peripheral.discoverCharacteristics(
                            [VibePanelBLE.audioDataCharUUID, VibePanelBLE.controlCharUUID,
                             VibePanelBLE.claudeStatusCharUUID, VibePanelBLE.permRequestCharUUID],
                            for: service
                        )
                    }
                } else {
                    self.logger.error("Characteristic discovery failed after retry — disconnecting")
                    self.failMicStickOTAForDiscoveryError()
                    self.disconnect()
                }
            }
            return
        }
        guard let characteristics = service.characteristics else { return }

        Task { @MainActor in
            self.charDiscoveryRetries = 0
            BLEManager.logEvent("CHARS service=\(service.uuid.uuidString) count=\(characteristics.count) list=\(characteristics.map { $0.uuid.uuidString }.joined(separator: ","))")
            for char in characteristics {
                self.logger.info("  Char: \(char.uuid.uuidString) props: \(char.properties.rawValue)")
                if char.uuid == VibePanelBLE.audioDataCharUUID {
                    self.audioDataCharacteristic = char
                    peripheral.setNotifyValue(true, for: char)
                    self.logger.info("Subscribed to audio data characteristic")
                } else if char.uuid == VibePanelBLE.controlCharUUID {
                    self.controlCharacteristic = char
                    if char.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: char)
                        self.logger.info("Subscribed to control notifications")
                    }
                    self.logger.info("Found control characteristic")
                } else if char.uuid == VibePanelBLE.claudeStatusCharUUID {
                    self.claudeStatusCharacteristic = char
                    self.characteristicsReady = true
                    self.sendHandshake()
                    self.logger.info("Found Claude status characteristic")
                } else if char.uuid == VibePanelBLE.permRequestCharUUID {
                    self.permRequestCharacteristic = char
                    self.logger.info("Found permission request characteristic")
                } else if char.uuid == VibePanelBLE.otaControlCharUUID {
                    self.otaControlCharacteristic = char
                    self.logger.info("Found MicStick OTA control characteristic")
                } else if char.uuid == VibePanelBLE.otaDataCharUUID {
                    self.otaDataCharacteristic = char
                    self.logger.info("Found MicStick OTA data characteristic")
                } else if char.uuid == VibePanelBLE.otaStatusCharUUID {
                    self.otaStatusCharacteristic = char
                    self.logger.info("Found MicStick OTA status characteristic")
                }
            }
            if service.uuid == VibePanelBLE.otaServiceUUID {
                let hasRequiredCharacteristics = [
                    self.otaControlCharacteristic,
                    self.otaDataCharacteristic,
                    self.otaStatusCharacteristic
                ].allSatisfy { $0 != nil }
                self.handleMicStickOTAServiceDiscovery(
                    hasOTAService: true,
                    hasRequiredCharacteristics: hasRequiredCharacteristics)
                guard hasRequiredCharacteristics else {
                    self.logger.error("MicStick OTA service is missing required characteristics")
                    return
                }
                if let status = self.otaStatusCharacteristic {
                    peripheral.setNotifyValue(true, for: status)
                    // INFO is also the characteristic's initial readable
                    // value. Reading it makes version display independent of
                    // the encrypted OTA control write used for updates.
                    peripheral.readValue(for: status)
                }
                if self.otaAbortState.targetPeripheralID == peripheral.identifier {
                    self.abortMicStickOTA()
                } else {
                    self.scheduleMicStickOTAInfoFallback(for: peripheral.identifier)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == VibePanelBLE.otaStatusCharUUID, let error {
            Task { @MainActor in
                self.logMicStickOTA("STATUS readError detail=\(error.localizedDescription)")
                if self.firmwareUpdateState.isActive {
                    self.abortMicStickOTA()
                    self.firmwareUpdateState = .failed
                    self.firmwareUpdateProgress = nil
                }
            }
            return
        }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == VibePanelBLE.audioDataCharUUID {
            Task { @MainActor in
                // Safety: if isReceivingAudio is stuck true but no packet arrived for >2s,
                // force reset so the new recording can start properly
                // Detect buttonId and seq from incoming packet before stream-start logic
                var incomingButtonId: UInt8 = 0x01
                var incomingSeq: UInt16 = 0
                if self.deviceProtocolVersion >= 2, data.count > 5, data[0] == 0xAA, data[1] == 0x55 {
                    incomingButtonId = data[2]
                    incomingSeq = UInt16(data[3]) | (UInt16(data[4]) << 8)
                } else if data.count > 4, data[0] == 0xAA, data[1] == 0x55 {
                    incomingSeq = UInt16(data[2]) | (UInt16(data[3]) << 8)
                }

                if self.isReceivingAudio {
                    // Check 1: stuck detection (no packet for >1s)
                    if let lastTime = self.lastAudioPacketTime,
                       Date().timeIntervalSince(lastTime) > 1.0 {
                        ClaudeCodeSessionManager.log("[BLE] isReceivingAudio stuck (last packet \(String(format: "%.1f", Date().timeIntervalSince(lastTime)))s ago), force finalize")
                        self.finalizeRecording()
                    }
                    // Check 2: buttonId changed — force finalize old stream, start new one
                    else if incomingButtonId != self.audioStreamButtonId {
                        ClaudeCodeSessionManager.log("[BLE] ButtonId changed \(self.audioStreamButtonId) → \(incomingButtonId), force finalize old stream")
                        self.finalizeRecording()
                    }
                    // Check 3: seq went backward or reset to 0 — new recording from same button
                    else if self.packetsReceived > 0 && (incomingSeq < self.lastSeq || incomingSeq == 0) {
                        ClaudeCodeSessionManager.log("[BLE] Seq backward (\(incomingSeq) < \(self.lastSeq), packets=\(self.packetsReceived)), new recording from same button, force finalize")
                        self.finalizeRecording()
                    }
                }
                self.lastAudioPacketTime = Date()

                if !self.isReceivingAudio {
                    self.isReceivingAudio = true
                    self.sessionStartTime = Date()  // REQ-005 Phase 1: BLE 首帧 wall-clock
                    // Reset decoder and buffer for new recording session
                    self.adpcmDecoder.reset()
                    self.pcmBufferLock.lock()
                    self.pcmBuffer.removeAll()
                    self.pcmBufferLock.unlock()
                    self.packetsReceived = 0
                    self.bytesReceived = 0
                    self.packetsLost = 0
                    self.packetsOutOfOrder = 0
                    self.lastSeq = 0
                    // Extract buttonId from first packet BEFORE processAudioPacket
                    // (processAudioPacket checks isReceivingAudio which is already true)
                    if self.deviceProtocolVersion >= 2, data.count > 5, data[0] == 0xAA, data[1] == 0x55 {
                        self.audioStreamButtonId = data[2]
                    } else {
                        self.audioStreamButtonId = 0x01
                    }
                    ClaudeCodeSessionManager.log("[BLE] Audio stream started, buttonId=\(self.audioStreamButtonId), onAudioStreamStarted=\(self.onAudioStreamStarted != nil)")
                    self.onAudioStreamStarted?(self.audioStreamButtonId)
                }
                self.processAudioPacket(data)
            }
        } else if characteristic.uuid == VibePanelBLE.controlCharUUID {
            Task { @MainActor in
                self.handleControlNotification(data)
            }
        } else if characteristic.uuid == VibePanelBLE.otaStatusCharUUID {
            Task { @MainActor in
                do {
                    if data.first == MicStickOTAProtocol.infoResponse {
                        self.handleMicStickOTAInfo(try MicStickOTAProtocol.decodeInfo(data))
                    } else if data.first == MicStickOTAProtocol.status {
                        self.handleMicStickOTAStatus(try MicStickOTAProtocol.decodeStatus(data))
                    }
                } catch {
                    self.logMicStickOTA(
                        "FAIL statusDecode bytes=\(data.count) error=\(error.localizedDescription)"
                    )
                    self.logger.error("Invalid MicStick OTA status frame: \(error.localizedDescription)")
                    if self.firmwareUpdateState.isActive {
                        self.abortMicStickOTA()
                        self.firmwareUpdateState = .failed
                    }
                }
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.connectedPeripheral?.identifier == peripheral.identifier else { return }
            self.scheduleMicStickOTAPump()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            let uuid = characteristic.uuid

            if uuid == VibePanelBLE.otaControlCharUUID {
                self.handleMicStickOTAControlWrite(error: error)
                return
            }

            // REQ-022(review fix):完成归因 —— 按发出顺序出队本次完成的写类型
            // (ATT write-with-response 串行,回调顺序 == 发出顺序)。
            // approval 完成走独立路径,不触碰 legacy 单槽;未跟踪写(control 直写)
            // kind 为 nil,落入 legacy 分支时 pendingWrites[uuid] 为 nil,行为不变。
            var kind: TrackedWriteKind?
            if var kinds = self.inFlightWriteKinds[uuid], !kinds.isEmpty {
                kind = kinds.removeFirst()
                self.inFlightWriteKinds[uuid] = kinds.isEmpty ? nil : kinds
            }
            if kind == .approval {
                await self.handleApprovalWriteCompletion(error: error)
                return
            }
            if kind == .applicationSwitcher {
                self.handleApplicationSwitcherWriteCompletion(error: error)
                return
            }
            if kind == .taskLifecycle {
                self.handleTaskLifecycleWriteCompletion(error: error)
                return
            }

            if let error {
                self.logger.warning("BLE write failed [\(uuid.uuidString.prefix(8))]: \(error.localizedDescription)")

                // Retry critical writes
                if var pending = self.pendingWrites[uuid] {
                    if pending.retryCount < PendingWrite.maxRetries {
                        pending.retryCount += 1
                        self.pendingWrites[uuid] = pending
                        self.logger.info("BLE write retry \(pending.retryCount)/\(PendingWrite.maxRetries) for [\(uuid.uuidString.prefix(8))]")
                        // Delay 500ms before retry
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !self.firmwareUpdateState.isActive else {
                            self.pendingWrites.removeValue(forKey: uuid)
                            return
                        }
                        guard let p = self.connectedPeripheral else { return }
                        // 重发同样要入队 kind,保持 FIFO 与发出顺序一致
                        self.inFlightWriteKinds[pending.characteristic.uuid, default: []].append(.legacy)
                        p.writeValue(pending.data, for: pending.characteristic, type: .withResponse)
                    } else {
                        self.logger.error("BLE write gave up after \(PendingWrite.maxRetries) retries for [\(uuid.uuidString.prefix(8))]")
                        self.pendingWrites.removeValue(forKey: uuid)
                    }
                }
            } else {
                // Success — clear pending
                self.pendingWrites.removeValue(forKey: uuid)
            }
        }
    }
}

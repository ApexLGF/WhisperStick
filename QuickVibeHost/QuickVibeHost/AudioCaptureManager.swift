import Foundation
import AVFoundation
import CoreAudio
import os

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// T-033:CoreAudio kAudioDevicePropertyDeviceUID —— 重启/重插后稳定,
    /// 用它持久化用户选的系统麦(AudioDeviceID 每次枚举可能变)。
    let uid: String
    let name: String
}

// MARK: - T-033 音源模式

/// T-033:PTT 按键触发时的音频来源。默认 .device(task §1.7:安装后默认设备麦)。
enum MicSourceMode: Int {
    case device = 0     // MicPad 板载麦:I2S → ADPCM → BLE(既有路径)
    case system = 1     // Mac 系统麦:设备只发 0x19/0x14,音频由 AudioCaptureManager 采

    static let defaultsKey = "micSourceMode"
    /// 选中的系统麦稳定标识。用 CoreAudio kAudioDevicePropertyDeviceUID(重启/重插后稳定),
    /// 不用 AudioDeviceID(每次枚举可能变)。
    static let systemMicUIDKey = "systemMicUID"
}

/// 解析结果。回退是一等公民:调用方必须处理 .fellBack。
enum MicSourceResolution: Equatable {
    case device                                  // 用户选的就是设备麦
    case system(deviceID: AudioDeviceID, name: String)
    case fellBack(reason: String)                // 选了系统麦但不可用 → 回退设备麦 + 发通知
}

enum MicSourceResolver {
    /// 纯函数,便于测试:给定"当前可用输入设备快照"与用户偏好,算出实际音源。
    /// - devices: (uid, id, name) 三元组;调 CoreAudio 的活儿留给 AudioCaptureManager。
    static func resolve(mode: MicSourceMode,
                        preferredUID: String,
                        devices: [(uid: String, id: AudioDeviceID, name: String)],
                        systemDefaultID: AudioDeviceID? = nil) -> MicSourceResolution {
        guard mode == .system else { return .device }
        guard !devices.isEmpty else { return .fellBack(reason: AppL10n.tr("无可用系统麦克风")) }
        // BUG-032:空 UID = "默认(系统)"必须跟随系统当前默认输入(与快捷键链路同语义),
        // 不能取列表首个 —— 蓝牙麦(如 DJI)常排在首位,会对着未激活的 HFP 采到 0 样本。
        guard !preferredUID.isEmpty else {
            if let did = systemDefaultID, let d = devices.first(where: { $0.id == did }) {
                return .system(deviceID: d.id, name: d.name)
            }
            let d = devices[0]   // 查不到系统默认时的兜底
            return .system(deviceID: d.id, name: d.name)
        }
        guard let hit = devices.first(where: { $0.uid == preferredUID }) else {
            return .fellBack(reason: AppL10n.tr("所选系统麦克风已不可用"))
        }
        return .system(deviceID: hit.id, name: hit.name)
    }
}

final class AudioCaptureManager: ObservableObject {
    @Published var isRecording = false
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID = 0

    /// 流式 tee:每段转码后的 16kHz/16bit/mono LE PCM chunk 同步抛出(VoiceInputManager 接)。
    /// nil = 不 tee(仅豆包流式活跃时由 app 挂闭包,否则零影响整段路径)。
    var onPCMChunk: ((Data) -> Void)?
    /// 实时音频 RMS 电平回调(0~1),驱动浮窗录音波形。主线程回调。
    var onLevel: ((Float) -> Void)?

    private var audioEngine = AVAudioEngine()
    private var pcmData = Data()
    private let pcmDataLock = NSLock()
    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "Audio")

    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private let targetBitsPerSample: UInt16 = 16

    init() {
        refreshInputDevices()
    }

    // MARK: - Device Management

    func refreshInputDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return }

        inputDevices = deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            // Check input channels
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr else { return nil }

            let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListRaw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, bufferListRaw) == noErr else { return nil }

            let bufferList = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let inputChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { return nil }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }

            // T-033: UID —— 持久化用户选的系统麦(读法同上,只换 selector)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }

            return AudioInputDevice(id: deviceID, uid: uid as String, name: name as String)
        }

        // Default to system default input
        if selectedDeviceID == 0, let first = inputDevices.first {
            selectedDeviceID = first.id
        }

        logger.info("Found \(self.inputDevices.count) input devices")
    }

    func selectDevice(_ deviceID: AudioDeviceID) {
        guard !isRecording else { return }
        selectedDeviceID = deviceID
        // Set as system default input so AVAudioEngine picks it up
        setSystemDefaultInput(deviceID)
        // Recreate engine to cleanly bind to the new device
        audioEngine = AVAudioEngine()
        logger.info("Selected device: \(deviceID), engine recreated")
    }

    /// Set the system-level default input device via Core Audio
    private func setSystemDefaultInput(_ deviceID: AudioDeviceID) {
        var devID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devID
        )
        if status != noErr {
            logger.warning("Failed to set system default input: \(status)")
        }
    }

    /// BUG-032:查询系统当前默认输入设备("默认(系统)"选项的解析依据,与快捷键链路同语义)
    func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &devID
        )
        guard status == noErr, devID != 0 else { return nil }
        return devID
    }

    // MARK: - Recording

    func startRecording() throws {
        pcmDataLock.lock()
        pcmData = Data()
        pcmDataLock.unlock()

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch, device=\(self.selectedDeviceID)")

        // Validate format — sampleRate=0 means device is not ready
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()

        DispatchQueue.main.async { self.isRecording = true }
        logger.info("Recording started")
    }

    func stopRecording() -> Data {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        DispatchQueue.main.async { self.isRecording = false }

        pcmDataLock.lock()
        let rawPCM = pcmData
        pcmDataLock.unlock()

        logger.info("Recording stopped, PCM size: \(rawPCM.count) bytes")
        return createWAV(from: rawPCM)
    }

    // MARK: - T-033 系统麦 PTT(设备按键触发)

    /// 独立于 `audioEngine` 的第二个引擎。刻意不复用:快捷键路径(startRecording/
    /// stopRecording)在 `audioEngine` 上装 tap,共用会撞 "only one tap per bus",
    /// 也会让本路径的设备绑定溢出到快捷键路径(§1.8 要求快捷键始终跟随系统默认)。
    private var pttEngine: AVAudioEngine?
    private var pttDeviceID: AudioDeviceID?
    private let pttLock = NSLock()
    /// 400ms 环形预滚(对齐固件 PREBUF_MS,QuickVibeMicPad.ino:75):16kHz × 16bit × 0.4s
    private static let prerollByteCap = Int(16000 * 2 * 0.4)
    private var prerollRing = Data()
    private var pttPCM = Data()
    private var pttCapturing = false
    private var pttTapFrames = 0        // BUG-032 diag
    private var pttConvertFails = 0     // BUG-032 diag

    /// T-033:只把本 app 的系统麦采集引擎绑到指定设备,不碰系统默认输入
    /// (与 `selectDevice`/`setSystemDefaultInput` 的全局副作用区分),
    /// 也不碰快捷键路径使用的 `audioEngine`。传 nil = 跟随系统默认。
    func setCaptureDevice(_ deviceID: AudioDeviceID?) {
        guard pttDeviceID != deviceID else { return }
        pttDeviceID = deviceID
        if pttEngine != nil {
            disarmPreroll()
            armPreroll(deviceID: deviceID)
        }
    }

    /// T-033 预滚:系统麦模式 + BLE 已连时常驻 tap,写 400ms 环形缓冲。
    /// startSystemMicPTT() 时先 flush 环形再接续,消除按下首字丢失。
    func armPreroll(deviceID: AudioDeviceID?) {
        guard !UITestFlags.isHeadless else {
            NSLog("[ui-test] skipped mic preroll arm (microphone TCC) — headless")
            return
        }
        if pttEngine != nil, pttDeviceID == deviceID { return }
        disarmPreroll()
        pttDeviceID = deviceID

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // BUG-032(用户拍板 2026-07-27):App 不再支持指定采集设备,恒随系统默认输入 ——
        // AudioUnitSetProperty 指定设备两种场景实测均不工作(默认场景 tap 零回调、显式
        // 选 DJI 无法识别),快捷键链路的"inputNode 吃系统默认"是唯一可靠路径。
        // deviceID 参数仅作重装配触发器:系统默认切换 → resolve 出新 ID → pttDeviceID
        // 不等 → disarm + 重建 engine(新 engine 自然绑到新默认)。
        _ = deviceID
        ClaudeCodeSessionManager.log("[BUG-032][diag] preroll arming on system-default input")

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: targetSampleRate,
                                               channels: targetChannels,
                                               interleaved: true),
              let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
        else {
            logger.warning("T-033 preroll arm failed: bad format \(hardwareFormat.sampleRate)Hz")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processPTTBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            logger.error("T-033 preroll engine start failed: \(error.localizedDescription)")
            ClaudeCodeSessionManager.log("[BUG-032][diag] preroll engine start FAILED: \(error.localizedDescription)")
            return
        }
        pttEngine = engine
        pttTapFrames = 0
        pttConvertFails = 0
        logger.info("T-033 preroll armed, device=\(deviceID.map(String.init) ?? "system default")")
        ClaudeCodeSessionManager.log("[BUG-032][diag] preroll armed dev=\(deviceID.map(String.init) ?? "default") hw=\(hardwareFormat.sampleRate)Hz/\(hardwareFormat.channelCount)ch engineRunning=\(engine.isRunning)")
    }

    func disarmPreroll() {
        guard let engine = pttEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pttEngine = nil
        pttLock.lock()
        prerollRing = Data()
        pttPCM = Data()
        pttCapturing = false
        pttLock.unlock()
        logger.info("T-033 preroll disarmed")
    }

    /// 起采:先 flush 预滚环形,再接续后续 tap 数据。引擎未 arm 时就地 arm。
    func startSystemMicPTT(deviceID: AudioDeviceID?) throws {
        if pttEngine == nil || pttDeviceID != deviceID {
            armPreroll(deviceID: deviceID)
        }
        guard pttEngine != nil else { throw AudioCaptureError.systemMicUnavailable }
        pttLock.lock()
        pttPCM = prerollRing        // 预滚 flush:补上按下前 400ms
        pttCapturing = true
        pttLock.unlock()
        DispatchQueue.main.async { self.isRecording = true }
        logger.info("T-033 system-mic PTT started")
    }

    /// 停采并返回 WAV。引擎保持 arm(继续预滚),下次按下仍无首字丢失。
    func stopSystemMicPTT() -> Data {
        pttLock.lock()
        pttCapturing = false
        let rawPCM = pttPCM
        pttPCM = Data()
        pttLock.unlock()
        DispatchQueue.main.async { self.isRecording = false }
        logger.info("T-033 system-mic PTT stopped, PCM size: \(rawPCM.count) bytes")
        return createWAV(from: rawPCM)
    }

    private func processPTTBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        pttTapFrames += 1
        if pttTapFrames == 1 {   // 首帧即证明 tap 活,常驻预滚下不再周期刷日志
            ClaudeCodeSessionManager.log("[BUG-032][diag] tap first frame, inLen=\(buffer.frameLength)")
        }
        guard let data = convert(buffer, converter: converter, targetFormat: targetFormat) else {
            pttConvertFails += 1
            if pttConvertFails == 1 {
                ClaudeCodeSessionManager.log("[BUG-032][diag] first convert FAIL: inFmt=\(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch len=\(buffer.frameLength)")
            }
            return
        }

        pttLock.lock()
        let capturing = pttCapturing
        if capturing {
            pttPCM.append(data)
        } else {
            prerollRing.append(data)
            if prerollRing.count > Self.prerollByteCap {
                prerollRing.removeFirst(prerollRing.count - Self.prerollByteCap)
            }
        }
        pttLock.unlock()

        guard capturing else { return }         // 未按下不外泄音频:不 tee 流式、不驱动浮窗
        onPCMChunk?(data)
        emitLevel(data)
    }

    /// 16k/mono/Int16 转码。与 processBuffer 同算法,单独一份:processBuffer 在
    /// 快捷键采集路径上,§1.8 要求那条路径零变化,故不抽公共函数去改它。
    private func convert(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> Data? {
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard outputFrameCapacity > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity)
        else { return nil }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if let error {
            logger.error("Convert error: \(error.localizedDescription)")
            return nil
        }
        guard outputBuffer.frameLength > 0, let channelData = outputBuffer.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }

    /// 实时 RMS 电平 → 浮窗波形(归一化 + 增益,口径与 processBuffer 一致)。
    private func emitLevel(_ pcm: Data) {
        guard let onLevel else { return }
        let level: Float = pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Double = 0
            for s in samples { sum += Double(s) * Double(s) }
            let rms = (sum / Double(samples.count)).squareRoot()
            return Float(min(1.0, rms / 32767.0 * 6.0))
        }
        DispatchQueue.main.async { onLevel(level) }
    }

    // MARK: - Audio Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard outputFrameCapacity > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity)
        else { return }

        var error: NSError?
        var hasData = true
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if let error {
            logger.error("Convert error: \(error.localizedDescription)")
            return
        }

        guard outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData
        else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData[0], count: byteCount)

        pcmDataLock.lock()
        pcmData.append(data)
        pcmDataLock.unlock()

        onPCMChunk?(data)   // tee 给流式 session(仅 manager 设了闭包,即豆包流式活跃)

        // 实时 RMS 电平 → 浮窗波形(0~1,归一化 + 增益)。
        if let onLevel {
            let n = Int(outputBuffer.frameLength)
            var sum: Double = 0
            let ptr = channelData[0]
            for i in 0..<n { let s = Double(ptr[i]); sum += s * s }
            let rms = n > 0 ? (sum / Double(n)).squareRoot() : 0
            let level = Float(min(1.0, rms / 32767.0 * 6.0))   // ~1/6 满量程即满格
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    private func createWAV(from pcmData: Data) -> Data {
        let dataSize = UInt32(pcmData.count)
        let sampleRate = UInt32(targetSampleRate)
        let byteRate = UInt32(targetSampleRate) * UInt32(targetChannels) * UInt32(targetBitsPerSample / 8)
        let blockAlign = UInt16(targetChannels) * (targetBitsPerSample / 8)

        var wav = Data()
        wav.reserveCapacity(44 + pcmData.count)

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE(&wav, dataSize + 36)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE(&wav, UInt32(16))          // chunk size
        appendLE(&wav, UInt16(1))           // PCM format
        appendLE(&wav, UInt16(targetChannels))
        appendLE(&wav, sampleRate)
        appendLE(&wav, byteRate)
        appendLE(&wav, blockAlign)
        appendLE(&wav, targetBitsPerSample)

        // data chunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE(&wav, dataSize)
        wav.append(pcmData)

        return wav
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

enum AudioCaptureError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case systemMicUnavailable

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: AppL10n.tr("无法创建目标音频格式")
        case .converterCreationFailed: AppL10n.tr("无法创建音频转换器")
        case .systemMicUnavailable: AppL10n.tr("系统麦克风不可用")
        }
    }
}

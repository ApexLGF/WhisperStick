import Foundation

final class AnalyticsClient {
    static let shared = AnalyticsClient()

    private let lock = NSRecursiveLock()
    private let queue: NativeAnalyticsQueue
    private let defaults: UserDefaults
    private var configured = false
    private let hourlyPrefix = "analyticsHourlyStats."
    private let hourlyKeys = [
        "ble_connect_success_count",
        "ble_connect_failure_count",
        "recording_total_count",
        "recording_failure_count",
        "asr_total_count",
        "asr_failure_count",
        "asr_text_units",
        "injection_total_count",
        "injection_failure_count"
    ]

    init(defaults: UserDefaults = .standard, queue: NativeAnalyticsQueue? = nil) {
        self.defaults = defaults
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.queue = queue ?? NativeAnalyticsQueue(file: directory.appendingPathComponent("QuickVibeHost/analytics-native-v1.json"))
    }

    var isEnabled: Bool {
        !AnalyticsConfig.projectToken.isEmpty && (defaults.object(forKey: "analyticsEnabled") as? Bool ?? false)
    }

    func configure() {
        lock.lock(); defer { lock.unlock() }
        guard !configured else { return }
        configured = true

        setEnabled(isEnabled)
        flushHourlyStatsIfNeeded()
    }

    func setEnabled(_ requested: Bool) {
        let enabled = requested && !AnalyticsConfig.projectToken.isEmpty
        lock.lock(); defer { lock.unlock() }
        defaults.set(enabled, forKey: "analyticsEnabled")
        queue.setEnabled(enabled)
        if enabled {
            let isNewInstall = defaults.string(forKey: "analyticsInstallId") == nil
            _ = installIdHash()
            reportInstall(isNewInstall: isNewInstall)
            migrateHourlyStats()
        } else {
            clearHourlyStats()
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("analyticsSnapshot.") {
                defaults.removeObject(forKey: key)
            }
        }
    }

    func reportInstall(isNewInstall: Bool = false) {
        guard isEnabled else { return }

        if isNewInstall {
            capture("app_install")
        }
    }

    func capturePermissionState(microphone: String, bluetooth: String, accessibility: String, notification: String) {
        let signature = "\(microphone)|\(bluetooth)|\(accessibility)|\(notification)"
        captureSnapshot(event: "permission_state", signature: signature, properties: [
            "microphone": microphone,
            "bluetooth": bluetooth,
            "accessibility": accessibility,
            "notification": notification
        ])
    }

    func captureDevicePreferenceState(
        deviceType: String,
        buzzerMuted: Bool,
        buzzerVolumePercent: Int,
        ledBrightnessPercent: Int,
        micSource: String,
        voiceMode: String,
        customPromptCount: Int
    ) {
        let signature = AnalyticsSupport.devicePreferenceSignature(
            buzzerMuted: buzzerMuted,
            buzzerVolumePercent: buzzerVolumePercent,
            ledBrightnessPercent: ledBrightnessPercent,
            micSource: micSource,
            voiceMode: voiceMode,
            customPromptCount: customPromptCount
        )
        captureSnapshot(event: "device_preference_state", signature: signature, properties: [
            "device_type": deviceType,
            "buzzer_muted": buzzerMuted,
            "buzzer_volume_percent": buzzerVolumePercent,
            "led_brightness_percent": ledBrightnessPercent,
            "led_brightness_label": AnalyticsSupport.ledBrightnessLabel(percent: ledBrightnessPercent),
            "mic_source": micSource,
            "voice_mode": voiceMode,
            "custom_prompt_count": customPromptCount
        ])
    }

    func captureSettingsState(
        launchAtLoginEnabled: Bool,
        aiUsageStatsEnabled: Bool,
        overlayInputMode: String,
        overlayFontSize: String,
        historyLimit: Int,
        historyCountBucket: String,
        asrEngine: String,
        punctuationEnabled: Bool,
        itnPostprocessEnabled: Bool,
        recognitionBoostEnabled: Bool,
        deepseekPostprocessEnabled: Bool,
        customHotwordCount: Int,
        localOfflineModelDownloaded: Bool,
        localStreamingModelDownloaded: Bool,
        firstRunCompleted: Bool
    ) {
        let signature = [
            "\(launchAtLoginEnabled)",
            "\(aiUsageStatsEnabled)",
            overlayInputMode,
            overlayFontSize,
            "\(historyLimit)",
            historyCountBucket,
            asrEngine,
            "\(punctuationEnabled)",
            "\(itnPostprocessEnabled)",
            "\(recognitionBoostEnabled)",
            "\(deepseekPostprocessEnabled)",
            "\(customHotwordCount)",
            "\(localOfflineModelDownloaded)",
            "\(localStreamingModelDownloaded)",
            "\(firstRunCompleted)"
        ].joined(separator: "|")
        captureSnapshot(event: "settings_state", signature: signature, properties: [
            "launch_at_login_enabled": launchAtLoginEnabled,
            "ai_usage_stats_enabled": aiUsageStatsEnabled,
            "overlay_input_mode": overlayInputMode,
            "overlay_font_size": overlayFontSize,
            "history_limit": historyLimit,
            "history_count_bucket": historyCountBucket,
            "asr_engine": asrEngine,
            "punctuation_enabled": punctuationEnabled,
            "itn_postprocess_enabled": itnPostprocessEnabled,
            "recognition_boost_enabled": recognitionBoostEnabled,
            "deepseek_postprocess_enabled": deepseekPostprocessEnabled,
            "custom_hotword_count": customHotwordCount,
            "local_offline_model_downloaded": localOfflineModelDownloaded,
            "local_streaming_model_downloaded": localStreamingModelDownloaded,
            "first_run_completed": firstRunCompleted
        ])
    }

    func captureDeviceConnectResult(deviceType: String, result: String, errorKind: String = "none", protocolVersion: Int = 0) {
        recordHourlyStat(result == "success" ? "ble_connect_success_count" : "ble_connect_failure_count")
    }

    func captureRecordingResult(source: String, result: String, errorKind: String, durationSeconds: Double? = nil, triggerSource: String = "unknown") {
        recordHourlyStats(["recording_total_count": 1, "recording_failure_count": result == "failure" ? 1 : 0])
    }

    func captureASRResult(
        engine: ASREngine,
        result: String,
        errorKind: String,
        durationSeconds: Double,
        textLength: Int,
        localModelState: String,
        fallbackUsed: String = "none",
        source: String = "unknown",
        triggerSource: String = "unknown",
        deviceType: String = "none",
        deviceProtocolVersion: Int = 0,
        localModelVersion: String = "unknown"
    ) {
        guard result != "cancelled" else { return }
        recordHourlyStats(["asr_total_count": 1, "asr_failure_count": result == "failure" ? 1 : 0,
                           "asr_text_units": result == "success" ? max(0, textLength) : 0])
    }

    func captureInjectionResult(inputMode: String, targetKind: String, result: String, errorKind: String, fallbackUsed: String = "none", textLength: Int, source: String = "unknown") {
        recordHourlyStats(["injection_total_count": 1, "injection_failure_count": result == "failure" ? 1 : 0])
    }

    func flushHourlyStatsIfNeeded(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled else { return }
        queue.flushHours(except: hourlyBucket(now), identity: installIdHash(), properties: commonProperties())
    }

    func shutdown() {
        lock.lock()
        if isEnabled { queue.flushHours(identity: installIdHash(), properties: commonProperties()) }
        lock.unlock()
        _ = queue.waitForDrain(timeout: 2)
        queue.stop()
    }

    @discardableResult
    private func capture(_ event: String, properties: [String: Any] = [:]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled else { return false }
        return queue.enqueue(event: event, identity: installIdHash(),
                             properties: commonProperties().merging(properties) { _, new in new })
    }

    private func captureSnapshot(event: String, signature: String, properties: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled else { return }
        let now = Date()
        let lastAt = defaults.object(forKey: analyticsSnapshotLastAtKey(event)) as? TimeInterval
        guard AnalyticsSupport.shouldReportSnapshot(
            lastReportedAt: lastAt.map { Date(timeIntervalSince1970: $0) },
            now: now,
            lastSignature: defaults.string(forKey: analyticsSnapshotSignatureKey(event)),
            signature: signature
        ) else { return }

        guard capture(event, properties: properties) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: analyticsSnapshotLastAtKey(event))
        defaults.set(signature, forKey: analyticsSnapshotSignatureKey(event))
    }

    private func recordHourlyStat(_ key: String, delta: Int = 1, now: Date = Date()) {
        recordHourlyStats([key: delta], now: now)
    }

    private func recordHourlyStats(_ counters: [String: Int], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled else { return }
        flushHourlyStatsIfNeeded(now: now)
        queue.record(bucket: hourlyBucket(now), counters: counters)
    }

    /// 仅迁移旧版的本地数值计数，不读取旧 SDK 队列。固定迁移 UUID 允许崩溃后安全重放。
    private func migrateHourlyStats() {
        guard let bucket = defaults.string(forKey: hourlyBucketKey) else { return }
        guard hourlyKeys.contains(where: { defaults.integer(forKey: hourlyStatKey($0)) > 0 }) else {
            clearHourlyStats()
            return
        }
        var properties = commonProperties()
        properties["hour_bucket"] = bucket
        for key in hourlyKeys { properties[key] = defaults.integer(forKey: hourlyStatKey(key)) }
        let id = AnalyticsSupport.sha256Hex("native-migration|" + installIdHash() + "|" + bucket)
        if queue.enqueue(event: "app_hourly_stats", identity: installIdHash(), properties: properties, id: id) {
            clearHourlyStats()
        }
    }

    private func clearHourlyStats() {
        defaults.removeObject(forKey: hourlyBucketKey)
        for key in hourlyKeys {
            defaults.removeObject(forKey: hourlyStatKey(key))
        }
    }

    private var hourlyBucketKey: String {
        hourlyPrefix + "bucket"
    }

    private func hourlyStatKey(_ key: String) -> String {
        hourlyPrefix + key
    }

    private func hourlyBucket(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02dT%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0)
    }

    private func analyticsSnapshotLastAtKey(_ event: String) -> String {
        "analyticsSnapshot.\(event).lastAt"
    }

    private func analyticsSnapshotSignatureKey(_ event: String) -> String {
        "analyticsSnapshot.\(event).signature"
    }

    /// 在 App/权限/普通生命周期初始化前运行；唯一事件复用正式队列与会话。
    static func runSelfTest() -> Int32 {
        let probe = UUID().uuidString
        let eventID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ve-analytics-probe-" + probe)
        let queue = NativeAnalyticsQueue(file: directory.appendingPathComponent("queue.json"))
        queue.setEnabled(true)
        let properties: [String: Any] = ["diagnostic_run_id": probe, "diagnostic": true,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"]
        let queued = queue.enqueue(event: "app_debug_probe", identity: "diagnostic-" + probe, properties: properties, id: eventID)
        let success = queued && queue.waitForDrain(timeout: 25, acknowledged: eventID)
        queue.setEnabled(false)
        queue.stop()
        try? FileManager.default.removeItem(at: directory)
        let result: [String: Any] = ["status": success ? "PASS" : "FAIL", "event": "app_debug_probe",
            "endpoint": NativeAnalyticsQueue.endpoint.absoluteString, "probe_id": probe, "event_uuid": eventID]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        return success ? 0 : 1
    }

    private func installIdHash() -> String {
        if let id = defaults.string(forKey: "analyticsInstallId") {
            return AnalyticsSupport.sha256Hex(id)
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: "analyticsInstallId")
        return AnalyticsSupport.sha256Hex(id)
    }

    private func commonProperties() -> [String: Any] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "uploaded_at_utc": utcTimestamp(),
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "channel": AnalyticsConfig.channel,
            "macos_major": version.majorVersion,
            "macos_minor": version.minorVersion,
            "arch": arch
        ]
    }

    private func utcTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

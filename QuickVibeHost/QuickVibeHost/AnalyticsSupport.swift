import CryptoKit
import Foundation

enum AnalyticsSupport {
    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func analyticsDay(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func shouldReportActive(lastDay: String?, today: String) -> Bool {
        lastDay != today
    }

    static func shouldReportDailySnapshot(lastDay: String?, today: String, lastSignature: String?, signature: String) -> Bool {
        lastDay != today || lastSignature != signature
    }

    static func shouldReportSnapshot(
        lastReportedAt: Date?,
        now: Date = Date(),
        lastSignature: String?,
        signature: String,
        maxAgeSeconds: TimeInterval = 86_400
    ) -> Bool {
        guard lastSignature == signature, let lastReportedAt else { return true }
        return now.timeIntervalSince(lastReportedAt) > maxAgeSeconds
    }

    static func devicePreferenceSignature(
        buzzerMuted: Bool,
        buzzerVolumePercent: Int,
        ledBrightnessPercent: Int,
        micSource: String,
        voiceMode: String,
        customPromptCount: Int
    ) -> String {
        "\(buzzerMuted)|\(buzzerVolumePercent)|\(ledBrightnessPercent)|\(micSource)|\(voiceMode)|\(customPromptCount)"
    }

    static func ledBrightnessLabel(percent: Int) -> String {
        switch percent {
        case 0: return "off"
        case 8: return "weak"
        case 32: return "standard"
        case 70: return "bright"
        default: return "custom"
        }
    }

    static func shouldReportUpgrade(lastVersion: String?, currentVersion: String) -> Bool {
        lastVersion != currentVersion
    }

    static func durationBucket(seconds: Double) -> String {
        if seconds < 1 { return "lt_1s" }
        if seconds < 3 { return "1_3s" }
        if seconds < 10 { return "3_10s" }
        if seconds < 30 { return "10_30s" }
        return "gte_30s"
    }

    static func textLengthBucket(_ length: Int) -> String {
        if length == 0 { return "0" }
        if length <= 20 { return "1_20" }
        if length <= 100 { return "21_100" }
        if length <= 500 { return "101_500" }
        return "gt_500"
    }

    static func speechTextUnits(_ text: String) -> Int {
        var units = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                units += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { units += 1 }
                inWord = true
            } else if scalar == "-", inWord {
                continue
            } else {
                inWord = false
            }
        }
        return units
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    static func deviceTypeName(_ deviceType: DeviceType?) -> String {
        switch deviceType {
        case .micPad: return "micpad"
        case .stickS3: return "sticks3"
        case nil: return "none"
        }
    }

    static func targetKind(sessionId: String?) -> String {
        guard let sessionId else { return "other" }
        if sessionId.hasPrefix("codex-") { return "codex" }
        return "claude"
    }

    static func errorKindName(_ name: String) -> String {
        switch name {
        case "missingCredentials": return "asr_missing_credentials"
        case "invalidAudio": return "mic_unavailable"
        case "serverError": return "asr_server_error"
        case "timeout": return "timeout"
        case "modelNotReady": return "asr_model_not_ready"
        case "cancelled": return "cancelled"
        case "permissionDenied": return "permission_denied"
        case "bleUnavailable": return "ble_unavailable"
        case "bleTimeout": return "ble_timeout"
        case "injectionDenied": return "injection_denied"
        case "emptyResult": return "asr_empty_result"
        default: return "unknown"
        }
    }
}

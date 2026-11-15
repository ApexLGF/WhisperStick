import Foundation
#if canImport(Sentry)
import Sentry
#endif

enum DiagnosticComponent: String {
    case asr
    case modelDownload
    case localEngine
    case ble
    case inputRouting
    case hookSocket
    case approval
}

enum DiagnosticSeverity: String {
    case breadcrumb
    case warning
    case error
}

struct DiagnosticEvent {
    var component: DiagnosticComponent
    var operation: String
    var severity: DiagnosticSeverity
    var message: String
    var error: Error?
    var tags: [String: String] = [:]
    var context: [String: Any] = [:]
}

enum DiagnosticsReporter {
    static func capture(_ event: DiagnosticEvent) {
        let tags = DiagnosticPrivacy.sanitize(event.tags)
        let context = sentryContext(for: event)

        #if canImport(Sentry)
        if let error = event.error {
            let scope = Scope()
            scope.setTags(tags)
            scope.setExtras(context)
            SentrySDK.capture(error: sanitizedError(error), scope: scope)
        } else {
            let sentryEvent = Event(level: sentryLevel(event.severity))
            sentryEvent.message = SentryMessage(formatted: event.message)
            sentryEvent.tags = tags
            sentryEvent.extra = context
            SentrySDK.capture(event: sentryEvent)
        }
        #else
        _ = tags
        _ = context
        #endif
    }

    static func sentryContext(for event: DiagnosticEvent) -> [String: Any] {
        var context = DiagnosticPrivacy.sanitize(event.context)
        context["component"] = event.component.rawValue
        context["operation"] = event.operation
        context["severity"] = event.severity.rawValue
        context["message"] = event.message
        if let error = event.error {
            let safeDescription = errorKind(error)
            context["error_type"] = String(describing: type(of: error))
            context["error_message"] = safeDescription
            context["error_description"] = safeDescription
        }
        return DiagnosticPrivacy.sanitize(context)
    }

    static func sanitizedError(_ error: Error) -> NSError {
        NSError(
            domain: "QuickVibeHost.Diagnostics",
            code: errorCode(error),
            userInfo: [
                NSLocalizedDescriptionKey: errorKind(error),
                "error_type": String(describing: type(of: error))
            ]
        )
    }

    static func breadcrumb(
        component: DiagnosticComponent,
        operation: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: .info, category: component.rawValue)
        crumb.message = message
        for (key, value) in DiagnosticPrivacy.sanitize(data) {
            crumb.setData(value: value, key: key)
        }
        crumb.type = operation
        SentrySDK.addBreadcrumb(crumb)
        #else
        _ = component
        _ = operation
        _ = message
        _ = data
        #endif
    }

    static func asrFailure(
        error: Error,
        source: RecognitionSource,
        engine: ASREngine,
        buttonId: UInt8,
        wavBytes: Int,
        hotwordCount: Int,
        dialogContextCount: Int,
        fallbackUsed: String,
        modelState: String,
        streamingModelState: String,
        bleConnected: Bool,
        deviceProtocolVersion: Int,
        deviceType: String,
        deviceUUID: String?,
        routingMode: String,
        axTrusted: Bool,
        secureInputEnabled: Bool
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            component: .asr,
            operation: "recognize",
            severity: .error,
            message: "ASR recognition failed",
            error: error,
            tags: [
                "component": DiagnosticComponent.asr.rawValue,
                "operation": "recognize",
                "asr_engine": engine.rawValue,
                "source": source.rawValue,
                "error_kind": errorKind(error),
                "fallback_used": fallbackUsed
            ],
            context: [
                "error_message": error.localizedDescription,
                "button_id": Int(buttonId),
                "wav_bytes": wavBytes,
                "wav_duration_ms": wavDurationMs(wavBytes: wavBytes),
                "hotword_count": hotwordCount,
                "dialog_context_count": dialogContextCount,
                "local_model_state": modelState,
                "streaming_model_state": streamingModelState,
                "ble_connected": bleConnected,
                "device_protocol_version": deviceProtocolVersion,
                "device_type": deviceType,
                "device_uuid": deviceUUID ?? "",
                "routing_mode": routingMode,
                "ax_trusted": axTrusted,
                "secure_input_enabled": secureInputEnabled,
                "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "arch": arch,
                "apple_silicon": arch == "arm64",
                "chip_family": arch == "arm64" ? "apple_silicon" : "intel",
                "hardware_model": hardwareModel,
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            ]
        )
    }

    private static func errorKind(_ error: Error) -> String {
        if let asrError = error as? ASRError {
            switch asrError {
            case .timeout: return "timeout"
            case .serverError: return "serverError"
            case .missingCredentials: return "missingCredentials"
            case .invalidAudio: return "invalidAudio"
            case .invalidURL: return "invalidURL"
            case .unexpectedMessage: return "unexpectedMessage"
            }
        }
        if let localError = error as? FunASRSeacoError {
            switch localError {
            case .modelNotReady: return "modelNotReady"
            case .engineInitFailed: return "engineInitFailed"
            case .recognitionFailed: return "recognitionFailed"
            case .invalidAudio: return "invalidAudio"
            }
        }
        return String(describing: type(of: error))
    }

    private static func errorCode(_ error: Error) -> Int {
        if let asrError = error as? ASRError {
            switch asrError {
            case .timeout: return 1001
            case .serverError: return 1002
            case .missingCredentials: return 1003
            case .invalidAudio: return 1004
            case .invalidURL: return 1005
            case .unexpectedMessage: return 1006
            }
        }
        if let localError = error as? FunASRSeacoError {
            switch localError {
            case .modelNotReady: return 2001
            case .engineInitFailed: return 2002
            case .recognitionFailed: return 2003
            case .invalidAudio: return 2004
            }
        }
        return 9000
    }

    private static func wavDurationMs(wavBytes: Int) -> Int {
        max(0, wavBytes - 44) * 1000 / 32_000
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    #if canImport(Sentry)
    private static func sentryLevel(_ severity: DiagnosticSeverity) -> SentryLevel {
        switch severity {
        case .breadcrumb: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
    #endif
}

enum DiagnosticPrivacy {
    private static let allowedKeys: Set<String> = [
        "component", "operation", "severity", "message",
        "error_kind", "error_message", "asr_engine", "source", "button_id",
        "error_type", "error_description",
        "fallback_used", "wav_bytes", "wav_duration_ms", "hotword_count",
        "dialog_context_count", "local_model_state", "streaming_model_state",
        "ble_connected", "device_protocol_version", "device_type", "device_uuid",
        "routing_mode", "ax_trusted", "secure_input_enabled", "app_version", "build",
        "environment", "macos_version", "arch", "apple_silicon", "chip_family",
        "hardware_model"
    ]

    static func sanitize(_ values: [String: Any]) -> [String: Any] {
        values.reduce(into: [:]) { out, pair in
            guard allowedKeys.contains(pair.key) else { return }
            out[pair.key] = pair.value
        }
    }

    static func sanitize(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { out, pair in
            guard allowedKeys.contains(pair.key) else { return }
            out[pair.key] = pair.value
        }
    }
}

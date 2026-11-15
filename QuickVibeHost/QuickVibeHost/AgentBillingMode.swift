import Foundation

struct ClaudeShellEnvironmentEvidence: Equatable {
    let baseURL: String?
    let hasAPICredential: Bool
}

enum ClaudeShellEnvironmentProbe {
    static let marker = "QVH_CLAUDE_ENV_V1"

    /// Parses the intentionally non-secret output of the login-shell probe.
    /// Shell startup files may print banners, so only content after the last marker counts.
    static func parse(_ data: Data) -> ClaudeShellEnvironmentEvidence? {
        guard let text = String(data: data, encoding: .utf8),
              let markerRange = text.range(of: marker, options: .backwards) else { return nil }
        let payload = text[markerRange.upperBound...]
        var baseURL: String?
        var hasCredential: Bool?
        for lineSlice in payload.split(whereSeparator: { $0.isNewline }) {
            let line = String(lineSlice)
            if line.hasPrefix("QVH_BASE_URL=") {
                let value = String(line.dropFirst("QVH_BASE_URL=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                baseURL = value.isEmpty ? nil : value
            } else if line == "QVH_HAS_CREDENTIAL=1" {
                hasCredential = true
            } else if line == "QVH_HAS_CREDENTIAL=0" {
                hasCredential = false
            }
        }
        guard hasCredential != nil else { return nil }
        return ClaudeShellEnvironmentEvidence(
            baseURL: baseURL,
            hasAPICredential: hasCredential ?? false
        )
    }
}

enum AgentBillingMode: Equatable {
    case subscription(plan: String?)
    case api(endpoint: APIEndpointClassifier.Classification)
    case unknown

    var isAPI: Bool {
        if case .api = self { return true }
        return false
    }

    /// Only resolved authentication modes are meaningful on the compact device UI.
    /// The Mac card can explain `.unknown`; firmware has no equivalent explanatory state.
    var shouldPublishDeviceUsage: Bool {
        self != .unknown
    }

    var identityBadge: (text: String, isPlan: Bool)? {
        switch self {
        case .subscription(let plan):
            return ((plan?.isEmpty == false ? plan!.capitalized : AppL10n.tr("账号")), true)
        case .api(let endpoint):
            return (endpoint.badgeText, false)
        case .unknown:
            return nil
        }
    }

    var identityBadgeHelp: String? {
        if case .api(let endpoint) = self { return endpoint.fullURL }
        return nil
    }
}

enum AgentBillingModeDetector {
    static func claude(
        authStatusData: Data?,
        hasExplicitAPICredential: Bool,
        endpoint: APIEndpointClassifier.Classification
    ) -> AgentBillingMode {
        let object = authStatusData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let method = (object?["authMethod"] as? String)?.lowercased()
        let plan = (object?["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Claude Code lets environment/settings credentials override a saved OAuth login.
        // In particular, relays such as OpenRouter commonly use ANTHROPIC_AUTH_TOKEN
        // rather than ANTHROPIC_API_KEY while `claude auth status` still reports oauth_token.
        if hasExplicitAPICredential { return .api(endpoint: endpoint) }
        if method?.contains("api") == true { return .api(endpoint: endpoint) }
        if method?.contains("oauth") == true { return .subscription(plan: plan) }
        if plan != nil { return .subscription(plan: plan) }
        return .unknown
    }

    static func codex(
        authData: Data?,
        latestPlanType: String?,
        endpoint: APIEndpointClassifier.Classification
    ) -> AgentBillingMode {
        let object = authData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let authMode = (object?["auth_mode"] as? String)?.lowercased()
        let apiKey = (object?["OPENAI_API_KEY"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = object?["tokens"] as? [String: Any]
        let hasAccountTokens = (tokens?["id_token"] as? String)?.isEmpty == false
            || (tokens?["account_id"] as? String)?.isEmpty == false
        let plan = latestPlanType.flatMap { $0.isEmpty ? nil : $0 }

        if authMode == "apikey" || authMode == "api_key" || authMode == "api" {
            return .api(endpoint: endpoint)
        }
        if authMode == "chatgpt" { return .subscription(plan: plan) }
        if apiKey?.isEmpty == false { return .api(endpoint: endpoint) }
        if hasAccountTokens || plan != nil { return .subscription(plan: plan) }
        return .unknown
    }
}

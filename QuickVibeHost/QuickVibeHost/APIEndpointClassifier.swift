import Foundation

/// REQ-023:AI 用量卡 API 接入点分类。
///
/// 只消费"CC/Codex 实际配置的 base URL"这一个客观事实,按 host 分三类:
/// 官方 / 公网中转 / 本地(私网)中转。不读任何第三方切换工具(cc-switch 等)的
/// 内部数据,不探测本地中转的上游 —— 两者均为已否决方向,理由见 REQ-023 文档。
enum APIEndpointClassifier {
    struct Classification: Equatable {
        /// 徽章文本:"API" / "API·中转 api.aiclaude.xyz" / "API·本地中转 127.0.0.1:8787"
        let badgeText: String
        /// tooltip 用的 base URL 原文;官方/无配置时 nil(徽章语义自明)
        let fullURL: String?
    }

    /// baseURL 为空/官方域名 → "API";其余按 host 公网/私网分类,host 带非默认端口。
    /// 解析不出 host 的非空配置(缺 scheme/手写残缺)按"API·中转 <原文>"呈现——
    /// 决不 fail-open 成官方"API"(review HIGH:信任性标识必须失败向"中转"侧)。
    static func classify(baseURL: String?) -> Classification {
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return Classification(badgeText: "API", fullURL: nil)
        }
        // 缺 scheme("api.foo.com" / "127.0.0.1:8787")时补 https:// 重试
        var url = URL(string: raw)
        if url?.host == nil { url = URL(string: "https://" + raw) }
        guard let url, let host = url.host?.lowercased() else {
            return Classification(badgeText: AppL10n.format("API·中转 %@", raw), fullURL: raw)
        }
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
            || host == "api.openai.com" || host.hasSuffix(".openai.com") {
            return Classification(badgeText: "API", fullURL: nil)
        }
        let display = hostPort(host: host, port: url.port, scheme: url.scheme)
        let label = isLocalOrPrivate(host) ? AppL10n.tr("API·本地中转") : AppL10n.tr("API·中转")
        return Classification(badgeText: "\(label) \(display)", fullURL: raw)
    }

    /// host + 非默认端口(https:443 / http:80 不显示)。
    private static func hostPort(host: String, port: Int?, scheme: String?) -> String {
        guard let port else { return host }
        let s = scheme?.lowercased()
        let isDefault = (s == "https" && port == 443) || (s == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    /// 环回 / RFC1918 私网 / 链路本地(169.254、fe80)/ IPv6 ULA(fc/fd)/ .local mDNS → 本地中转。
    private static func isLocalOrPrivate(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.contains(":"), host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }

    /// Codex 侧数据源:`~/.codex/config.toml` 里当前 provider 的 base_url。
    /// 最小 TOML 解析:优先取 `model_provider = "x"` 指名的 `[model_providers.x]` 段内
    /// base_url;解析不出段结构时退化为全文首个 base_url。文件/字段缺失返回 nil(官方)。
    static func codexBaseURL(configPath: String) -> String? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // 取 = 后**第一对双引号之间**的内容:行尾注释(`base_url = "..." # 注`)、
        // 尾随空白都不会混入(review HIGH:dropLast 写法会把注释吞进值里)。
        func value(of line: String) -> String? {
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let after = line[line.index(after: eq)...]
            guard let open = after.firstIndex(of: "\"") else { return nil }
            let rest = after[after.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<close])
        }

        // 当前 provider 名(顶层 model_provider = "name")
        var providerName: String?
        for line in lines where line.hasPrefix("model_provider") {
            providerName = value(of: line)
            break
        }
        // 指名段内找 base_url
        if let name = providerName {
            var inSection = false
            for line in lines {
                if line.hasPrefix("[") {
                    inSection = (line == "[model_providers.\(name)]"
                                 || line == "[model_providers.\"\(name)\"]")
                    continue
                }
                if inSection, line.hasPrefix("base_url") { return value(of: line) }
            }
        }
        // 退化:全文首个 base_url
        for line in lines where line.hasPrefix("base_url") {
            return value(of: line)
        }
        return nil
    }
}
